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
    /// Queue-owned; nil when chunking is off.
    private var chunker: Chunker?
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

    /// Sends this recording's chunks to `handler` on the capture queue, replaying earlier ones.
    /// Returns false when chunking is off.
    func attachChunks(_ handler: @escaping (Chunker.Event) -> Void) -> Bool {
        queue.sync { guard let chunker else { return false }; chunker.attach(handler); return true }
    }

    func start(url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError("No usable system microphone format")
        }
        file = try AVAudioFile(forWriting: url, settings: format.settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if Chunker.directory != nil { chunker = Chunker(format: format) }
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
                chunker?.append(copy)
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
        // The last chunk is cut here; chunks nobody attached to (a cloud route) are deleted.
        queue.sync { file = nil; chunker?.finish(); chunker?.discardUnclaimed() }
        let now = ProcessInfo.processInfo.systemUptime
        let rate = engine.inputNode.outputFormat(forBus: 0).sampleRate
        let recorded = rate > 0 ? Double(frames) / rate : 0
        timingLog.notice("capture-stop at=\(now, format: .fixed(precision: 3)) wall=\(now - self.started, format: .fixed(precision: 3)) recorded=\(recorded, format: .fixed(precision: 3))")
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
    static let target: TimeInterval = 15, slack: TimeInterval = 5, window: TimeInterval = 0.2
    private let format: AVAudioFormat
    private var buffers: [(buffer: AVAudioPCMBuffer, energy: Double)] = []
    private var frames = 0
    /// `sentenceEnd`: the pause at this chunk's cut was long enough to end a sentence.
    enum Event { case chunk(URL, last: Bool, sentenceEnd: Bool), end, failed }
    /// ponytail: fixed threshold; measured on `say` speech (comma pauses 0.2–0.3 s, sentence pauses 0.5–0.7 s). Tune on real voices.
    static let sentencePause: TimeInterval = 0.45
    private var pending: [Event] = []
    private var handler: ((Event) -> Void)?
    private var failed = false, finished = false

    init(format: AVAudioFormat) { self.format = format }

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
        guard Double(frames) >= (Self.target + Self.slack) * format.sampleRate else { return }
        let shape = buffers.map { (Int($0.buffer.frameLength), $0.energy) }
        let cut = Self.quietestCut(shape, rate: format.sampleRate)
        emit(Array(buffers[..<cut].map(\.buffer)), final: false, sentenceEnd: Self.pauseLength(shape, at: cut, rate: format.sampleRate) >= Self.sentencePause)
        buffers.removeFirst(cut); frames = buffers.reduce(0) { $0 + Int($1.buffer.frameLength) }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        if failed { return }
        emit(buffers.map(\.buffer), final: true, sentenceEnd: false); buffers = []
    }

    /// Unclaimed chunk files (a cloud-route or canceled recording) are deleted.
    func discardUnclaimed() {
        for case .chunk(let url, _, _) in pending { try? FileManager.default.removeItem(at: url) }
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
        guard let directory = Self.directory else { failed = true; send(.failed); return }
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        do {
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw CaptureError("Cannot create chunk file") }
            close(fd)
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            for buffer in chunk { try file.write(from: buffer) }
            send(.chunk(url, last: final, sentenceEnd: sentenceEnd))
        } catch { try? FileManager.default.removeItem(at: url); failed = true; send(.failed) }
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
