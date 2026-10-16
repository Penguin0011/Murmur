// Speaker separation evidence (PRD 11.10, W7d). Builds synthetic calls of 2–6 speakers from
// LibriSpeech test-clean (read speech, not call audio), runs the Them stream through the real W7a/W7d
// path (Chunker at 16 kHz mono, MeetingStreamFeed, MeetingPump, the warm helper's timed request,
// the kept WAV, `ModelBench --diarize`, MeetingSpeakers.apply) and prints DER, speaker count and
// word attribution. `--long MINUTES` instead times diarization alone on one long stream and reports
// the helper's peak memory. No microphone, tap or network.
//
//   SDKROOT="$(dirname "$(xcrun --show-sdk-path)")/MacOSX26.sdk" swiftc -O -swift-version 5 -parse-as-library -suppress-warnings \
//     module-one/capture/Capture.swift app/Retention.swift app/Meetings.swift app/MeetingSpeakers.swift app/MeetingCapture.swift app/tools/measure_speakers.swift -o /tmp/ms
//   /tmp/ms HELPER ASR_MODELS DIARIZER_MODELS LIBRISPEECH_TEST_CLEAN [--long MINUTES] [--threshold T]
import Foundation
import AVFoundation

struct Utterance { let speaker: String; let url: URL; let text: String }
struct Turn { let speaker: String; let start: Double; let end: Double }

/// Deterministic, so every run scores the same corpus.
struct Random { var state: UInt64; mutating func next(_ n: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 33) % UInt64(n)) } }

final class Helper: @unchecked Sendable {
    private let task = Process(), input: FileHandle, output: FileHandle
    private var buffered = Data()
    init(helper: String, models: String) throws {
        let toChild = Pipe(), fromChild = Pipe()
        task.executableURL = URL(fileURLWithPath: helper); task.arguments = [models, "--serve"]
        task.standardInput = toChild; task.standardOutput = fromChild; task.standardError = FileHandle.nullDevice
        try task.run()
        input = toChild.fileHandleForWriting; output = fromChild.fileHandleForReading
        guard let ready = line(), String(decoding: ready, as: UTF8.self).contains("\"ready\":true") else { throw CaptureError("helper not ready") }
    }
    private func line() -> Data? {
        while true {
            if let newline = buffered.firstIndex(of: 0x0A) { let l = buffered[..<newline]; buffered = Data(buffered[(newline + 1)...]); return Data(l) }
            let chunk = output.availableData; if chunk.isEmpty { return nil }; buffered.append(chunk)
        }
    }
    /// The same request the app sends for a Them chunk with separation on.
    func timed(_ url: URL, _ done: @escaping (ChunkText?) -> Void) {
        let request = String(decoding: try! JSONSerialization.data(withJSONObject: ["timed": url.path]), as: UTF8.self)
        try? input.write(contentsOf: Data((request + "\n").utf8))
        let answer = line().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard let text = answer?["text"] as? String else { done(nil); return }
        done(ChunkText(text: text, words: answer?["words"] as? [[Double]]))
    }
    func stop() { try? input.close(); task.terminate() }
}

func loadCorpus(_ root: URL) -> [String: [Utterance]] {
    var bySpeaker: [String: [Utterance]] = [:]
    let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    while let url = walker?.nextObject() as? URL {
        guard url.lastPathComponent.hasSuffix(".trans.txt"), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let id = String(parts[0]), speaker = String(id.split(separator: "-")[0])
            bySpeaker[speaker, default: []].append(Utterance(speaker: speaker, url: url.deletingLastPathComponent().appendingPathComponent(id + ".flac"), text: String(parts[1])))
        }
    }
    return bySpeaker.mapValues { $0.sorted { $0.url.path < $1.url.path } }
}

func samples(_ url: URL) -> [Float] {
    guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)), (try? file.read(into: buffer)) != nil,
          file.processingFormat.sampleRate == 16_000 else { return [] }
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

/// A conversation: speakers take turns of one or two utterances, 0.2–1.0 s apart, no overlap.
/// ponytail: no overlapping speech, no channel effects; real calls (PRD 11.10) have both.
func conversation(_ corpus: [String: [Utterance]], speakers: [String], minutes: Double, seed: UInt64) -> (audio: [Float], turns: [Turn]) {
    var random = Random(state: seed), audio: [Float] = [], turns: [Turn] = [], used: [String: Int] = [:], previous = ""
    while Double(audio.count) / 16_000 < minutes * 60 {
        var speaker = speakers[random.next(speakers.count)]
        if speaker == previous { speaker = speakers[(speakers.firstIndex(of: speaker)! + 1) % speakers.count] }
        previous = speaker
        for _ in 0..<(1 + random.next(2)) {
            let list = corpus[speaker]!, utterance = list[used[speaker, default: 0] % list.count]; used[speaker, default: 0] += 1
            let clip = samples(utterance.url)
            let start = Double(audio.count) / 16_000
            audio += clip
            turns.append(Turn(speaker: speaker, start: start, end: Double(audio.count) / 16_000))
            audio += [Float](repeating: 0, count: 3_200 + random.next(12_800))
        }
    }
    return (audio, turns)
}

/// Runs `ModelBench --diarize` under /usr/bin/time -l, sampling wired memory while it runs.
func diarize(helper: String, models: String, audio: URL, threshold: Double) -> (segments: [SpeakerSegment], seconds: Double, peakMB: Double, rssMB: Double, wiredMB: Double) {
    func wired() -> Double {
        let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat"); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let line = text.split(separator: "\n").first { $0.hasPrefix("Pages wired down") } ?? ""
        return (Double(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? "") ?? 0) * 16_384 / 1_048_576
    }
    let before = wired()
    let process = Process(), out = Pipe(), err = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/time")
    process.arguments = ["-l", helper, models, "--diarize", audio.path, String(threshold)]
    process.standardOutput = out; process.standardError = err
    let began = Date()
    try! process.run()
    var maxWired = before
    let sampler = Thread { while process.isRunning { maxWired = max(maxWired, wired()); Thread.sleep(forTimeInterval: 0.25) } }
    sampler.start()
    let reply = out.fileHandleForReading.readDataToEndOfFile(), report = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    let seconds = Date().timeIntervalSince(began)
    func field(_ name: String) -> Double {
        (report.split(separator: "\n").first { $0.hasSuffix(name) }?.split(separator: " ").first).flatMap { Double($0) } ?? 0
    }
    return (MeetingSpeakers.segments(reply) ?? [], seconds, field("peak memory footprint") / 1_048_576, field("maximum resident set size") / 1_048_576, maxWired - before)
}

/// Best one-to-one mapping between hypothesis and reference labels, maximising `score`.
func bestMapping<H: Hashable, R: Hashable>(_ hyps: [H], _ refs: [R], _ score: (H, R) -> Double) -> [H: R] {
    var best: (Double, [H: R]) = (-1, [:])
    func go(_ i: Int, _ used: Set<R>, _ total: Double, _ map: [H: R]) {
        if i == hyps.count { if total > best.0 { best = (total, map) }; return }
        go(i + 1, used, total, map)
        for r in refs where !used.contains(r) { var m = map; m[hyps[i]] = r; go(i + 1, used.union([r]), total + score(hyps[i], r), m) }
    }
    go(0, [], 0, [:])
    return best.1
}

/// Frame DER at 10 ms with a 0.25 s collar around reference boundaries (no overlap in this corpus).
func der(_ turns: [Turn], _ segments: [SpeakerSegment], seconds: Double) -> Double {
    let frames = Int(seconds * 100)
    var ref = [String?](repeating: nil, count: frames), hyp = [String?](repeating: nil, count: frames), skip = [Bool](repeating: false, count: frames)
    for t in turns {
        for f in max(0, Int(t.start * 100))..<min(frames, Int(t.end * 100)) { ref[f] = t.speaker }
        for edge in [t.start, t.end] { for f in max(0, Int((edge - 0.25) * 100))..<min(frames, Int((edge + 0.25) * 100)) { skip[f] = true } }
    }
    for s in segments { for f in max(0, Int(s.start * 100))..<min(frames, Int(s.end * 100)) { hyp[f] = s.speaker } }
    var overlap: [String: [String: Double]] = [:]
    for f in 0..<frames where !skip[f] { if let h = hyp[f], let r = ref[f] { overlap[h, default: [:]][r, default: 0] += 1 } }
    let map = bestMapping(Array(Set(segments.map(\.speaker))).sorted(), Array(Set(turns.map(\.speaker))).sorted()) { overlap[$0]?[$1] ?? 0 }
    var speech = 0.0, error = 0.0
    for f in 0..<frames where !skip[f] {
        if ref[f] != nil { speech += 1 }
        switch (ref[f], hyp[f]) {
        case (nil, nil): break
        case (nil, _?), (_?, nil): error += 1
        case let (r?, h?): if map[h] != r { error += 1 }
        }
    }
    return error / max(1, speech) * 100
}

@main struct MeasureSpeakers {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 5 else { print("Usage: ms HELPER ASR_MODELS DIARIZER_MODELS LIBRISPEECH_TEST_CLEAN [--long MINUTES] [--threshold T]"); exit(2) }
        let threshold = args.firstIndex(of: "--threshold").flatMap { Double(args[$0 + 1]) } ?? MeetingSpeakers.threshold
        let corpus = loadCorpus(URL(fileURLWithPath: args[4]))
        let names = corpus.keys.sorted()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("measure-speakers-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        if let flag = args.firstIndex(of: "--long"), let minutes = Double(args[flag + 1]) {
            // Six speakers, then the stream as the app keeps it (16-bit WAV), then diarization alone.
            let call = conversation(corpus, speakers: Array(names.prefix(6)), minutes: minutes, seed: 7)
            let kept = folder.appendingPathComponent("long.wav")
            try SpeakerAudio.write(call.audio.map { Int16(max(-1, min(1, $0)) * 32_767) }, at: 0, to: kept); try SpeakerAudio.finish(kept)
            let result = diarize(helper: args[1], models: args[3], audio: kept, threshold: threshold)
            let found = Set(result.segments.map(\.speaker)).count
            print(String(format: "long: %.0f min, 6 speakers, threshold %.3f: %.1f s wall (helper start to exit), peak footprint %.0f MB, max RSS %.0f MB, wired +%.0f MB, %d speakers found, DER %.2f%%",
                         Double(call.audio.count) / 960_000, threshold, result.seconds, result.peakMB, result.rssMB, result.wiredMB, found, der(call.turns, result.segments, seconds: Double(call.audio.count) / 16_000)))
            return
        }

        let helper = try Helper(helper: args[1], models: args[2])
        defer { helper.stop() }
        // Twelve calls of 8 minutes: 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 6, 6 remote speakers, never the same group twice.
        let plan = [2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 6, 6]
        var rows: [(n: Int, der: Double, found: Int, attribution: Double, words: Int, split: Int)] = []
        for (index, n) in plan.enumerated() {
            var random = Random(state: UInt64(1_000 + index))
            var group: [String] = []
            while group.count < n { let s = names[random.next(names.count)]; if !group.contains(s) { group.append(s) } }
            let call = conversation(corpus, speakers: group, minutes: 8, seed: UInt64(index + 1))
            let seconds = Double(call.audio.count) / 16_000
            let dir = folder.appendingPathComponent("call-\(index)"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let kept = dir.appendingPathComponent("kept.wav")
            let lock = NSLock()
            var meeting = Meeting(id: UUID().uuidString, recordedAt: Date(), source: .everything)
            meeting.speakers = SpeakerSeparation(state: .pending, threshold: threshold)
            let pump = MeetingPump(transcribe: { url, done in helper.timed(url, done) }, deliver: { job, chunk in
                lock.withLock { if let chunk { meeting.insert(stream: .them, start: job.start, end: job.start + job.duration, text: chunk.text, words: chunk.words) } }
                // As MeetingRecorder.keepAudio: the chunk's 16-bit samples at its own time.
                if let file = try? AVAudioFile(forReading: job.url, commonFormat: .pcmFormatInt16, interleaved: false),
                   let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)), (try? file.read(into: buffer)) != nil {
                    try? SpeakerAudio.write(Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength))), at: job.start, to: kept)
                }
                try? FileManager.default.removeItem(at: job.url)
            })
            let chunker = Chunker(format: SystemAudioTap.format, directory: dir, boundaries: false, fileSettings: Chunker.int16(SystemAudioTap.format))
            chunker.attach(MeetingStreamFeed(stream: .them, folder: dir, offset: 0, enqueue: pump.enqueue, failed: {}).receive)
            var offset = 0
            while offset < call.audio.count {
                autoreleasepool {
                    let n = min(1600, call.audio.count - offset)
                    let buffer = AVAudioPCMBuffer(pcmFormat: SystemAudioTap.format, frameCapacity: 1600)!; buffer.frameLength = AVAudioFrameCount(n)
                    for k in 0..<n { buffer.floatChannelData![0][k] = call.audio[offset + k] }
                    chunker.append(buffer); offset += n
                }
            }
            chunker.finish()
            while !pump.isIdle { Thread.sleep(forTimeInterval: 0.1) }
            Thread.sleep(forTimeInterval: 0.3)
            try SpeakerAudio.finish(kept)
            let result = diarize(helper: args[1], models: args[3], audio: kept, threshold: threshold)

            // Each transcript word's true speaker: the reference turn at the word's midpoint (or nearest).
            var truth: [String] = []
            let linesBefore = lock.withLock { meeting.lines.count }
            for line in lock.withLock({ meeting.lines }) {
                let tokens = line.text.split(whereSeparator: \.isWhitespace)
                for (i, _) in tokens.enumerated() {
                    let mid = line.words.map { line.start + ($0[i][0] + $0[i][1]) / 2 } ?? (line.start + line.end) / 2
                    func distance(_ t: Turn) -> Double { max(t.start - mid, mid - t.end, 0) }
                    truth.append(call.turns.min { distance($0) < distance($1) }!.speaker)
                }
            }
            lock.withLock { MeetingSpeakers.apply(result.segments, to: &meeting) }
            let assigned = meeting.lines.flatMap { line in line.text.split(whereSeparator: \.isWhitespace).map { _ in line.speaker } }
            var counts: [Int: [String: Double]] = [:]
            for (h, r) in zip(assigned, truth) { if let h { counts[h, default: [:]][r, default: 0] += 1 } }
            let map = bestMapping(counts.keys.sorted(), group.sorted()) { counts[$0]?[$1] ?? 0 }
            let correct = zip(assigned, truth).filter { h, r in h.flatMap { map[$0] } == r }.count
            let found = Set(result.segments.map(\.speaker)).count
            rows.append((n, der(call.turns, result.segments, seconds: seconds), found, Double(correct) / Double(max(1, truth.count)) * 100, truth.count, meeting.lines.count - linesBefore))
            print(String(format: "call %2d: %d speakers, %.1f min, DER %.2f%%, found %d, words %d, attributed %.1f%%, lines split +%d, diarize %.1f s",
                         index + 1, n, seconds / 60, rows.last!.der, found, truth.count, rows.last!.attribution, rows.last!.split, result.seconds))
        }
        let meanDER = rows.map(\.der).reduce(0, +) / Double(rows.count)
        let countOK = rows.filter { $0.found == $0.n }.count
        let big = rows.filter { $0.n >= 3 }
        let bigWords = big.map(\.words).reduce(0, +)
        let bigCorrect = big.map { $0.attribution / 100 * Double($0.words) }.reduce(0, +)
        print(String(format: "threshold %.3f: mean DER %.2f%% (bar ≤ 20%%), correct speaker count %d/%d = %.0f%% (bar ≥ 80%%), words attributed on 3+ speakers %.1f%% of %d (bar ≥ 85%%)",
                     threshold, meanDER, countOK, rows.count, Double(countOK) / Double(rows.count) * 100, bigCorrect / Double(max(1, bigWords)) * 100, bigWords))
    }
}
