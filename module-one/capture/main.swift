import Foundation
import AVFoundation
import Darwin

struct CaptureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// A single serial queue owns file writes; stop removes the tap before draining it.
final class Capture {
    let engine = AVAudioEngine()
    let queue = DispatchQueue(label: "dictation.capture.write")
    var file: AVAudioFile?
    var writeError: Error?
    var frames: AVAudioFramePosition = 0
    var firstBuffer: TimeInterval?
    var started: TimeInterval = 0
    var stopped = false

    func start(url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError("No usable system microphone format")
        }
        file = try AVAudioFile(forWriting: url, settings: format.settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // Install before start: capture does not wait for tap/hold classification.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [self] buffer, _ in
            // AVAudioEngine owns the callback buffer, so copy before returning.
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for i in 0..<source.count {
                if let src = source[i].mData, let dst = destination[i].mData {
                    memcpy(dst, src, Int(source[i].mDataByteSize))
                }
            }
            let received = ProcessInfo.processInfo.systemUptime
            queue.async { [self] in
                if firstBuffer == nil { firstBuffer = received - started }
                do { try file?.write(from: copy); frames += AVAudioFramePosition(copy.frameLength) }
                catch { writeError = error }
            }
        }
        started = ProcessInfo.processInfo.systemUptime
        do { try engine.start() }
        catch { engine.inputNode.removeTap(onBus: 0); queue.sync { file = nil }; throw error }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        queue.sync { file = nil }
    }
}

struct RetryAudio {
    static let lifetime: TimeInterval = 24 * 60 * 60
    let directory: URL

    init(directory: URL) throws {
        self.directory = directory
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            let attributes = try manager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw CaptureError("Recovery path must be a real directory, not a symlink")
            }
        } else {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try purge()
    }

    func create(now: Date = Date()) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        // Exclusive create and 0600 before AVAudioFile writes any samples.
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CaptureError("Cannot create private recording file") }
        close(fd)
        try FileManager.default.setAttributes([.creationDate: now], ofItemAtPath: url.path)
        return url
    }

    func purge(now: Date = Date()) throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard url.pathExtension == "wav" else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            guard let created = attributes[.creationDate] as? Date else { throw CaptureError("Missing audio creation date") }
            if now.timeIntervalSince(created) >= Self.lifetime || created > now {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    func delete(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CaptureError("Self-check failed: \(message)") }
}

func selfCheck() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-capture-check-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RetryAudio(directory: root)
    let url = try store.create()
    let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
    buffer.frameLength = 1600
    for i in 0..<1600 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 16000) * 0.1) }
    do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
    let reopened = try AVAudioFile(forReading: url)
    try check(reopened.length == 1600, "synthetic WAV duration")
    let recovered = AVAudioPCMBuffer(pcmFormat: reopened.processingFormat, frameCapacity: 1600)!
    try reopened.read(into: recovered)
    try check(abs(recovered.floatChannelData![0][1] - buffer.floatChannelData![0][1]) < 0.00001, "synthetic WAV samples")
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let dirAttrs = try FileManager.default.attributesOfItem(atPath: root.path)
    try check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "file privacy")
    try check((dirAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700, "directory privacy")
    let created = attrs[.creationDate] as! Date
    try store.purge(now: created.addingTimeInterval(RetryAudio.lifetime - 1))
    try check(FileManager.default.fileExists(atPath: url.path), "recoverable before 24 hours")
    try store.purge(now: created.addingTimeInterval(RetryAudio.lifetime))
    try check(!FileManager.default.fileExists(atPath: url.path), "expired at 24 hours")
    let canceled = try store.create()
    try store.delete(canceled)
    try check(!FileManager.default.fileExists(atPath: canceled.path), "cancellation deletes audio")
    print("capture-check=passed synthetic-WAV=1600-frames permissions=0700/0600 expiry=24h cancellation=deleted")
}

func permission() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "not-determined"
    @unknown default: return "unknown"
    }
}

func recoveryDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DictationCaptureSpike/retry-audio", isDirectory: true)
}

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args == ["--check"] { try selfCheck(); return }
    if args == ["--probe"] {
        print("microphone-permission=\(permission()); no request or capture performed")
        return
    }
    if args == ["--purge"] {
        _ = try RetryAudio(directory: recoveryDirectory())
        print("expired-retry-audio=purged")
        return
    }
    guard args.count >= 2, args[0] == "--record-seconds", let seconds = Double(args[1]),
          seconds.isFinite, seconds > 0, seconds <= 120 else {
        throw CaptureError("Usage: --check | --probe | --purge | --record-seconds 0.1..120 [--cancel-after SECONDS]")
    }
    var cancelAfter: Double?
    if args.count > 2 {
        if args.count == 4 && args[2] == "--cancel-after", let delay = Double(args[3]), delay.isFinite, delay > 0, delay < seconds { cancelAfter = delay }
        else { throw CaptureError("Invalid recording options") }
    }
    guard permission() == "authorized" else {
        throw CaptureError("Microphone permission is \(permission()); this harness never requests it")
    }
    let store = try RetryAudio(directory: recoveryDirectory())
    let url = try store.create()
    let capture = Capture()
    // Cancellation and failed startup delete the temporary file.
    var retain = false
    defer { if !retain { try? store.delete(url) } }
    try capture.start(url: url)
    defer { capture.stop() }
    print("capture=listening duration-limit=\(seconds)s; Ctrl-C cancels and deletes")
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    var canceled = false
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    interrupt.setEventHandler { canceled = true }; terminate.setEventHandler { canceled = true }
    interrupt.resume(); terminate.resume()
    let start = ProcessInfo.processInfo.systemUptime
    while !canceled && ProcessInfo.processInfo.systemUptime - start < seconds {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if let delay = cancelAfter, ProcessInfo.processInfo.systemUptime - start >= delay { canceled = true }
        if !capture.engine.isRunning || capture.queue.sync(execute: { capture.writeError != nil }) { break }
        try store.purge()
    }
    capture.stop()
    interrupt.cancel(); terminate.cancel()
    if canceled { print("capture=canceled audio=deleted"); return }
    retain = capture.frames > 0
    print("capture=stopped frames=\(capture.frames) first-buffer-ms=\(capture.firstBuffer.map { String(format: "%.1f", $0 * 1000) } ?? "none")")
    if retain { print("retry-audio=\(url.path); expiry=24h-from-creation; delete after usable transcription") }
    else { print("audio=deleted") }
    if let error = capture.writeError { throw CaptureError("Audio write failed: \(error.localizedDescription)") }
    if capture.frames == 0 { throw CaptureError("No audio frames received") }
}

do { try run() }
catch { fputs("\(error)\n", stderr); exit(1) }
