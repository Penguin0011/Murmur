import Foundation
import AVFoundation
import CoreAudio
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
    /// Queue-owned; nil when chunking is off.
    private var chunker: Chunker?
    /// Uptime after which buffers are dropped (queue-owned). Set from the shortcut thread at a hold's
    /// release, so a late main thread cannot extend the recording past release plus tail.
    private var cutoff = TimeInterval.infinity
    private static let currentLock = NSLock()
    nonisolated(unsafe) private static var _current: Capture?
    /// The capture that is recording now, for the shortcut thread.
    static var current: Capture? { currentLock.withLock { _current } }

    nonisolated(unsafe) private static var _preferredInputUID: String?
    /// CoreAudio UID of the chosen microphone, or `MicrophoneChoice.automatic`. Nil, or a device that
    /// is not connected, means the system default input.
    static var preferredInputUID: String? {
        get { currentLock.withLock { _preferredInputUID } }
        set { currentLock.withLock { _preferredInputUID = newValue } }
    }
    /// The device to pin now: the chosen one, Automatic's pick, or nil for the system default.
    static func resolvedInputUID() -> String? {
        guard let choice = preferredInputUID, choice == MicrophoneChoice.automatic else { return preferredInputUID }
        return MicrophoneChoice.automaticUID(defaultInput: defaultInputUID(), devices: inputDeviceInfo())
    }
    /// Connected microphones as (CoreAudio UID, name); AVCaptureDevice's uniqueID is the CoreAudio UID on macOS.
    static func inputDevices() -> [(uid: String, name: String)] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { ($0.uniqueID, $0.localizedName) }
    }
    static func deviceID(uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = initial, size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
    private static func uid(_ device: AudioDeviceID) -> String? {
        property(device, kAudioDevicePropertyDeviceUID, Unmanaged<CFString>?.none)??.takeRetainedValue() as String?
    }
    static func defaultInputUID() -> String? {
        property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, AudioDeviceID(kAudioObjectUnknown)).flatMap(uid)
    }
    /// Every device with an input stream, with its transport and whether it is alive.
    static func inputDeviceInfo() -> [MicrophoneChoice.Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0, let uid = uid(id) else { return nil }
            let transport: MicrophoneChoice.Transport
            switch property(id, kAudioDevicePropertyTransportType, UInt32(0)) {
            case kAudioDeviceTransportTypeBuiltIn: transport = .builtIn
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: transport = .bluetooth
            default: transport = .other
            }
            return MicrophoneChoice.Device(uid: uid, transport: transport, alive: property(id, kAudioDevicePropertyDeviceIsAlive, UInt32(0)) == 1)
        }
    }

    func cut(after uptime: TimeInterval) {
        queue.async { [self] in
            cutoff = min(cutoff, uptime)
            timingLog.notice("release-cut after=\(uptime, format: .fixed(precision: 3))")
        }
    }

    /// Sends this recording's chunks to `handler` on the capture queue, replaying earlier ones.
    /// Returns false when chunking is off.
    func attachChunks(_ handler: @escaping (Chunker.Event) -> Void) -> Bool {
        queue.sync { guard let chunker else { return false }; chunker.attach(handler); return true }
    }

    /// Queue-owned: also receives each kept buffer, in the file's format (live words, gap #13).
    private var tee: ((AVAudioPCMBuffer) -> Void)?
    func setTee(_ handler: ((AVAudioPCMBuffer) -> Void)?) { queue.async { [self] in tee = handler } }
    /// The file's format, fixed at start. After a device change, buffers are converted to it.
    var recordingFormat: AVAudioFormat? { format }
    private var format: AVAudioFormat?
    /// Serializes `restart` with itself and with `stop`.
    private let restartLock = NSLock()
    private var observer: NSObjectProtocol?

    /// Pins the chosen (or Automatic's) microphone; an unplugged one falls back to the system default.
    private func pinInput() {
        guard let uid = Self.resolvedInputUID(), var device = Self.deviceID(uid: uid), let unit = engine.inputNode.audioUnit else { return }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { timingLog.notice("input-device-set failed status=\(status)") }
    }

    /// Dictation passes only `url`. A meeting's microphone (PRD 11.1) passes no file, a fixed 16 kHz
    /// mono format, its own chunk folder, and `current: false` so the shortcut thread never cuts it.
    func start(url: URL?, fixedFormat: AVAudioFormat? = nil, chunkFolder: URL? = nil, current: Bool = true) throws {
        let input = engine.inputNode
        pinInput()
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError("No usable system microphone format")
        }
        let format = fixedFormat ?? inputFormat
        self.format = format
        if let url {
            file = try AVAudioFile(forWriting: url, settings: format.settings)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        if let chunkFolder { chunker = Chunker(format: format, directory: chunkFolder, boundaries: false) }
        else if Chunker.directory != nil { chunker = Chunker(format: format) }
        // Install before start: capture does not wait for tap/hold classification.
        installTap(inputFormat)
        started = ProcessInfo.processInfo.systemUptime
        do { try engine.start() }
        catch { engine.inputNode.removeTap(onBus: 0); queue.sync { file = nil }; throw error }
        let running = ProcessInfo.processInfo.systemUptime
        if current { Self.currentLock.withLock { Self._current = self } }
        // A device change (a headset connecting, the chosen mic unplugged) stops the engine; follow it.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            _ = self?.restart()
        }
        timingLog.notice("engine-start called=\(self.started, format: .fixed(precision: 3)) took=\(running - self.started, format: .fixed(precision: 3)) rate=\(format.sampleRate, format: .fixed(precision: 0))")
    }

    /// Taps the input in `tapFormat`, converting to the file's format when they differ.
    private func installTap(_ tapFormat: AVAudioFormat) {
        let converter = format.flatMap { tapFormat == $0 ? nil : AVAudioConverter(from: tapFormat, to: $0) }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [self] buffer, _ in
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
                // The converter keeps resampler state, so it runs only here, in order.
                guard let copy = converter.map({ Self.convert(copy, with: $0) }) ?? copy else { return }
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
                chunker?.append(copy)
                tee?(copy)
            }
        }
    }

    /// Converts one tap buffer, keeping the converter's state for the next (nil on failure).
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64) else { return nil }
        var given = false
        let status = converter.convert(to: output, error: nil) { _, state in
            if given { state.pointee = .noDataNow; return nil }
            given = true; state.pointee = .haveData; return buffer
        }
        return status == .error ? nil : output
    }

    /// Restarts on the device the microphone choice resolves to now, keeping the same file, so audio
    /// already captured stays. True when recording is running again. Safe to call from any thread;
    /// the monitor also calls it when it finds the engine stopped.
    func restart() -> Bool {
        restartLock.withLock {
            guard !stopped else { return false }
            if engine.isRunning { return true }
            engine.inputNode.removeTap(onBus: 0)
            pinInput()
            let tapFormat = engine.inputNode.outputFormat(forBus: 0)
            guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else { return false }
            installTap(tapFormat)
            do { try engine.start() } catch { engine.inputNode.removeTap(onBus: 0); return false }
            timingLog.notice("capture-restarted rate=\(tapFormat.sampleRate, format: .fixed(precision: 0))")
            return true
        }
    }

    func stop() {
        guard restartLock.withLock({ defer { stopped = true }; return !stopped }) else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        Self.currentLock.withLock { if Self._current === self { Self._current = nil } }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        // The last chunk is cut here; chunks nobody attached to (a cloud route) are deleted.
        queue.sync { file = nil; tee = nil; chunker?.finish(); chunker?.discardUnclaimed() }
        let now = ProcessInfo.processInfo.systemUptime
        let rate = format?.sampleRate ?? 0
        let recorded = rate > 0 ? Double(frames) / rate : 0
        timingLog.notice("capture-stop at=\(now, format: .fixed(precision: 3)) wall=\(now - self.started, format: .fixed(precision: 3)) recorded=\(recorded, format: .fixed(precision: 3))")
    }
}

/// The "Automatic" microphone (gap #16). A Bluetooth headset's microphone forces it into its low-
/// quality call mode, so while one is the default input and the built-in microphone is available,
/// Automatic records from the built-in one and the headset keeps full playback quality.
enum MicrophoneChoice {
    static let automatic = "automatic"
    enum Transport { case builtIn, bluetooth, other }
    struct Device: Equatable { let uid: String; let transport: Transport; let alive: Bool }
    /// The built-in microphone's UID when the default input is Bluetooth and a live built-in one exists;
    /// otherwise nil, meaning the system default.
    static func automaticUID(defaultInput: String?, devices: [Device]) -> String? {
        guard let current = devices.first(where: { $0.uid == defaultInput }), current.transport == .bluetooth,
              let builtIn = devices.first(where: { $0.transport == .builtIn && $0.alive }) else { return nil }
        return builtIn.uid
    }
}

/// Splits a recording into chunk files at pauses while it is still being recorded, so local
/// transcription can run during the recording and only the last chunk waits for release. Owned by
/// its Capture's queue. The full WAV is still written and stays the fallback.
/// Measured (STREAMING_TRANSCRIPTION.md): cuts at the quietest 0.2 s near 15 s matched the
/// whole-file words; blind cuts did not.
final class Chunker {
    /// Private per-user folder for chunk files; nil turns chunking off.
    nonisolated(unsafe) static var directory: URL?
    /// A meeting stream's own folder (PRD 11.5); nil uses `directory`.
    private let folder: URL?
    /// Boundary clips repair dictionary terms in a joined dictation; meeting lines are not joined.
    private let boundaries: Bool
    static let target: TimeInterval = 15, slack: TimeInterval = 5, window: TimeInterval = 0.2
    private let format: AVAudioFormat
    private var buffers: [(buffer: AVAudioPCMBuffer, energy: Double)] = []
    private var frames = 0
    /// `sentenceEnd`: the pause at this chunk's cut was long enough to end a sentence.
    /// `boundary`: audio spanning the cut after the previous chunk (`boundarySpan` each side), so a
    /// dictionary term the cut split can be repaired. It always arrives before the next chunk.
    enum Event { case chunk(URL, last: Bool, sentenceEnd: Bool), boundary(URL), end, failed }
    /// Seconds of audio kept on each side of a cut for its boundary clip; spoken terms are shorter.
    static let boundarySpan: TimeInterval = 3
    /// The audio before the last cut, waiting for `boundarySpan` seconds after it.
    private var boundaryBefore: [AVAudioPCMBuffer]?
    /// ponytail: fixed threshold; measured on `say` speech (comma pauses 0.2–0.3 s, sentence pauses 0.5–0.7 s). Tune on real voices.
    static let sentencePause: TimeInterval = 0.45
    private var pending: [Event] = []
    private var handler: ((Event) -> Void)?
    private var failed = false, finished = false

    init(format: AVAudioFormat, directory: URL? = nil, boundaries: Bool = true) {
        self.format = format; folder = directory; self.boundaries = boundaries
    }

    /// Receives every event in order, replaying earlier ones. `.end` follows an empty last chunk;
    /// after `.failed` nothing more is sent and the caller uses the full WAV.
    func attach(_ handler: @escaping (Event) -> Void) {
        self.handler = handler
        for event in pending { handler(event) }
        pending = []
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard !failed, !finished, let samples = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        var energy = 0.0
        for i in 0..<Int(buffer.frameLength) { energy += Double(samples[0][i]) * Double(samples[0][i]) }
        buffers.append((buffer, energy)); frames += Int(buffer.frameLength)
        if boundaryBefore != nil, Double(frames) >= Self.boundarySpan * format.sampleRate { emitBoundary() }
        guard Double(frames) >= (Self.target + Self.slack) * format.sampleRate else { return }
        let shape = buffers.map { (Int($0.buffer.frameLength), $0.energy) }
        let cut = Self.quietestCut(shape, rate: format.sampleRate)
        let chunk = Array(buffers[..<cut].map(\.buffer))
        emit(chunk, final: false, sentenceEnd: Self.pauseLength(shape, at: cut, rate: format.sampleRate) >= Self.sentencePause)
        buffers.removeFirst(cut); frames = buffers.reduce(0) { $0 + Int($1.buffer.frameLength) }
        guard !failed else { return }
        guard boundaries else { return }
        boundaryBefore = Self.tail(chunk, seconds: Self.boundarySpan, rate: format.sampleRate)
        if Double(frames) >= Self.boundarySpan * format.sampleRate { emitBoundary() }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        if failed { return }
        if boundaryBefore != nil { emitBoundary() }
        emit(buffers.map(\.buffer), final: true, sentenceEnd: false); buffers = []
    }

    /// Writes the last cut's boundary clip: the tail before the cut and up to `boundarySpan` after it.
    /// A failed write only skips the repair; the chunks are unaffected.
    private func emitBoundary() {
        guard let before = boundaryBefore, let directory = folder ?? Self.directory else { boundaryBefore = nil; return }
        boundaryBefore = nil
        let after = Self.head(buffers.map(\.buffer), seconds: Self.boundarySpan, rate: format.sampleRate)
        guard !after.isEmpty, let url = write(before + after, in: directory) else { return }
        send(.boundary(url))
    }

    static func tail(_ chunk: [AVAudioPCMBuffer], seconds: TimeInterval, rate: Double) -> [AVAudioPCMBuffer] {
        var kept: [AVAudioPCMBuffer] = [], total = 0
        for buffer in chunk.reversed() where Double(total) < seconds * rate { kept.insert(buffer, at: 0); total += Int(buffer.frameLength) }
        return kept
    }

    static func head(_ buffers: [AVAudioPCMBuffer], seconds: TimeInterval, rate: Double) -> [AVAudioPCMBuffer] {
        var kept: [AVAudioPCMBuffer] = [], total = 0
        for buffer in buffers where Double(total) < seconds * rate { kept.append(buffer); total += Int(buffer.frameLength) }
        return kept
    }

    /// Unclaimed chunk files (a cloud-route or canceled recording) are deleted.
    func discardUnclaimed() {
        for event in pending {
            switch event {
            case .chunk(let url, _, _), .boundary(let url): try? FileManager.default.removeItem(at: url)
            case .end, .failed: break
            }
        }
        pending = []
    }

    /// Index of the buffer that starts the next chunk: the middle of the quietest `window` whose
    /// middle lies within target ± slack seconds. Buffers are (frames, energy).
    static func quietestCut(_ buffers: [(Int, Double)], rate: Double) -> Int {
        var starts: [Int] = [0]
        for b in buffers { starts.append(starts.last! + b.0) }
        let lo = (target - slack) * rate, hi = (target + slack) * rate, span = window * rate
        var best: (energy: Double, cut: Int)?
        var end = 0, sum = 0.0
        for begin in 0..<buffers.count {
            while end < buffers.count && Double(starts[end] - starts[begin]) < span { sum += buffers[end].1; end += 1 }
            guard Double(starts[end] - starts[begin]) >= span else { break }
            let middle = (begin + end) / 2
            if Double(starts[middle]) >= lo, Double(starts[middle]) <= hi, best == nil || sum < best!.energy { best = (sum, middle) }
            sum -= buffers[begin].1
        }
        return max(1, best?.cut ?? buffers.count)
    }

    /// Seconds of near-silence (under 1% of the median buffer energy) around `cut`.
    static func pauseLength(_ buffers: [(Int, Double)], at cut: Int, rate: Double) -> Double {
        guard !buffers.isEmpty else { return 0 }
        let quiet = buffers.map(\.1).sorted()[buffers.count / 2] * 0.01
        var lo = cut, hi = cut
        while lo > 0, buffers[lo - 1].1 <= quiet { lo -= 1 }
        while hi < buffers.count, buffers[hi].1 <= quiet { hi += 1 }
        return Double(buffers[lo..<hi].reduce(0) { $0 + $1.0 }) / rate
    }

    private func emit(_ chunk: [AVAudioPCMBuffer], final: Bool, sentenceEnd: Bool) {
        guard !chunk.isEmpty else { send(.end); return }
        guard let directory = folder ?? Self.directory, let url = write(chunk, in: directory) else { failed = true; send(.failed); return }
        send(.chunk(url, last: final, sentenceEnd: sentenceEnd))
    }

    /// A new owner-only WAV, or nil (nothing left behind) when it cannot be written.
    private func write(_ audio: [AVAudioPCMBuffer], in directory: URL) -> URL? {
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        do {
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw CaptureError("Cannot create chunk file") }
            close(fd)
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            for buffer in audio { try file.write(from: buffer) }
            return url
        } catch { try? FileManager.default.removeItem(at: url); return nil }
    }

    /// Applies a boundary clip's dictionary replacement to the two chunk texts around its cut, when
    /// the replaced words are the last 1–3 words of `tail` plus the first 1–3 of `head` (letters
    /// only, so a word the cut split in two also matches). The term goes at the end of `tail`; the
    /// cut's own punctuation on the tail side is dropped, the head's following punctuation kept.
    /// nil when the replacement does not cross this cut (chunks already handle the rest).
    static func repair(tail: String, head: String, from: String, to: String) -> (tail: String, head: String)? {
        func letters(_ text: Substring) -> String { String(text.lowercased().filter { $0.isLetter || $0.isNumber }) }
        let target = letters(Substring(from))
        let tailWords = tail.split(separator: " "), headWords = head.split(separator: " ")
        guard !target.isEmpty, !tailWords.isEmpty, !headWords.isEmpty else { return nil }
        for t in 1...min(3, tailWords.count) {
            for h in 1...min(3, headWords.count) {
                let spoken = tailWords.suffix(t).map(letters).joined() + headWords.prefix(h).map(letters).joined()
                guard spoken == target else { continue }
                let last = headWords[h - 1]
                let trailing = String(last.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
                let newTail = (tailWords.dropLast(t).map(String.init) + [to + trailing]).joined(separator: " ")
                return (newTail, headWords.dropFirst(h).joined(separator: " "))
            }
        }
        return nil
    }

    private func send(_ event: Event) { if let handler { handler(event) } else { pending.append(event) } }

    /// Joins chunk transcripts. The model punctuates every chunk as if the speaker stopped there:
    /// it ends each with a period and capitalizes each first word. A cut at a sentence-length
    /// pause (`sentenceEnds[i]`) keeps or adds the period. At any other cut, an unpunctuated
    /// chunk's capitalized next word is lowercased. A sentence never ends on a word like "the" or
    /// "and", so that period always goes. Only words in `lowercaseStarts` lose a capital, so names
    /// and "I" keep theirs.
    static func join(_ texts: [String], sentenceEnds: [Bool]) -> String {
        var out = "", sentenceBreak = false
        for (i, raw) in texts.enumerated() {
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if !out.isEmpty {
                    let lastWord = String(out.split(separator: " ").last ?? "").lowercased().trimmingCharacters(in: .punctuationCharacters)
                    let firstWord = String(text.prefix { $0.isLetter || $0 == "'" || $0 == "’" })
                    let dangling = danglingWords.contains(lastWord)
                    if !sentenceBreak || dangling {
                        let lower = lowercaseStarts.contains(firstWord.lowercased()) && firstWord.first?.isUppercase == true
                        // A model period is real unless the sentence would end on a word like "the";
                        // a short pause alone does not prove the speaker kept going.
                        let period = out.last == "." && !out.hasSuffix("..")
                        if period && dangling { out.removeLast() }
                        if lower && (!period || dangling) { text = firstWord.lowercased() + text.dropFirst(firstWord.count) }
                    } else if let last = out.last, !".?!".contains(last) { out += "." }
                    out += " "
                }
                out += text
            }
            sentenceBreak = i < sentenceEnds.count && sentenceEnds[i]
        }
        return out
    }
    /// Words a sentence cannot end on.
    static let danglingWords: Set<String> = ["a", "an", "the", "and", "or", "but", "nor", "of", "my", "your", "our", "their", "its", "than", "because"]
    /// Common words that start a chunk only because the model capitalized it.
    static let lowercaseStarts: Set<String> = danglingWords.union(["to", "in", "on", "at", "for", "with", "from", "by", "into", "as", "that", "which", "who", "is", "are", "was", "were", "be", "been", "will", "would", "could", "should", "can", "may", "might", "must", "do", "does", "did", "have", "has", "had", "this", "these", "those", "his", "her", "very", "so", "if", "when", "while", "where", "like", "about", "some", "any", "every", "each", "no", "not", "it", "it's", "we", "you", "they", "he", "she", "there", "here", "then", "more", "most", "less", "also", "just", "all", "one", "two", "what", "how", "why", "now", "even", "only", "still", "other", "another", "such", "make", "made", "get", "got", "go", "going", "see", "use", "used", "new", "same", "up", "out", "over", "after", "before", "between", "through", "during", "without", "within", "instead", "rather", "well", "really", "much", "many", "few", "things", "thing", "way", "people"])
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
