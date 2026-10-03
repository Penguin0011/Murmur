import Foundation
import AVFoundation
import Darwin
import os

/// Content-free capture timing (seconds of uptime), for diagnosing audio lost at start.
private let timingLog = Logger(subsystem: "cc.clouddev.dictation", category: "timing")

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
    var level: Double = 0
    var frames: AVAudioFramePosition = 0
    var firstBuffer: TimeInterval?
    var started: TimeInterval = 0
    var stopped = false
    /// Uptime after which buffers are dropped (queue-owned). Set from the shortcut thread at a hold's
    /// release, so a late main thread cannot extend the recording past release plus tail.
    private var cutoff = TimeInterval.infinity
    private static let currentLock = NSLock()
    nonisolated(unsafe) private static var _current: Capture?
    /// The capture that is recording now, for the shortcut thread.
    static var current: Capture? { currentLock.withLock { _current } }

    func cut(after uptime: TimeInterval) {
        queue.async { [self] in
            cutoff = min(cutoff, uptime)
            timingLog.notice("release-cut after=\(uptime, format: .fixed(precision: 3))")
        }
    }

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
                guard received <= cutoff else { return }
                if let samples = copy.floatChannelData, copy.frameLength > 0 {
                    var energy = 0.0
                    for index in 0..<Int(copy.frameLength) { energy += Double(samples[0][index]) * Double(samples[0][index]) }
                    level = min(1, sqrt(energy / Double(copy.frameLength)) * 8)
                }
                if firstBuffer == nil {
                    firstBuffer = received - started
                    timingLog.notice("first-buffer at=\(received, format: .fixed(precision: 3)) after-start=\(received - self.started, format: .fixed(precision: 3))")
                }
                do { try file?.write(from: copy); frames += AVAudioFramePosition(copy.frameLength) }
                catch { writeError = error }
            }
        }
        started = ProcessInfo.processInfo.systemUptime
        do { try engine.start() }
        catch { engine.inputNode.removeTap(onBus: 0); queue.sync { file = nil }; throw error }
        let running = ProcessInfo.processInfo.systemUptime
        Self.currentLock.withLock { Self._current = self }
        timingLog.notice("engine-start called=\(self.started, format: .fixed(precision: 3)) took=\(running - self.started, format: .fixed(precision: 3)) rate=\(format.sampleRate, format: .fixed(precision: 0))")
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        Self.currentLock.withLock { if Self._current === self { Self._current = nil } }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        queue.sync { file = nil }
        let now = ProcessInfo.processInfo.systemUptime
        let rate = engine.inputNode.outputFormat(forBus: 0).sampleRate
        let recorded = rate > 0 ? Double(frames) / rate : 0
        timingLog.notice("capture-stop at=\(now, format: .fixed(precision: 3)) wall=\(now - self.started, format: .fixed(precision: 3)) recorded=\(recorded, format: .fixed(precision: 3))")
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
