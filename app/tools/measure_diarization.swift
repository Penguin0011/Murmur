// Speaker separation measurement (W7d, PRD 11.10) on a synthetic Them stream: LibriSpeech test-clean
// clips from SPEAKERS readers taking turns (0.4 s apart) for MINUTES, written as 16 kHz mono 16-bit,
// then run through the real helper (`ModelBench DIR --diarize WAV THRESHOLD`) under /usr/bin/time.
// Prints DER (10 ms frames, no collar, greedy speaker mapping), the speaker count, word attribution
// (each turn's words go to the speaker the assignment rule picks for that span, through
// SpeakerSeparation.pieces), wall time and the helper's peak memory. Read speech, not call audio.
//
//   swiftc -swift-version 5 -parse-as-library app/Retention.swift app/Meetings.swift app/MeetingNotes.swift \
//     app/tools/measure_diarization.swift -o /tmp/mdz && \
//     /tmp/mdz runtime/Murmur.app/Contents/MacOS/ModelBench ~/Library/Caches/Dictation/module-one/diarizer-df2625a \
//       ~/Library/Caches/Dictation/asr-benchmark MINUTES SPEAKERS [SEED]
import AVFoundation
import Foundation

struct Clip: Decodable { let id: String; let audio: String; let reference: String }
struct Turn { let speaker: Int; let start: Double; let end: Double; let words: Int }

/// Deterministic, so a run can be repeated.
struct LCG { var state: UInt64; mutating func next(_ n: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 33) % UInt64(n)) } }

@main enum MeasureDiarization {
    static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let a = CommandLine.arguments
        guard a.count >= 6, let minutes = Double(a[4]), let count = Int(a[5]) else { print("usage: mdz HELPER DIAR_DIR BENCH_DIR MINUTES SPEAKERS [SEED]"); exit(2) }
        var rng = LCG(state: UInt64(a.count > 6 ? Int(a[6]) ?? 1 : 1))
        let bench = URL(fileURLWithPath: a[3])
        let clips = try String(contentsOf: bench.appendingPathComponent("test-clean-100.jsonl"), encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Clip.self, from: Data($0.utf8)) }
        let byReader = Dictionary(grouping: clips) { String($0.id.split(separator: "-")[0]) }
        let readers = byReader.keys.sorted()
        var chosen: [String] = []
        while chosen.count < count { let r = readers[rng.next(readers.count)]; if !chosen.contains(r) { chosen.append(r) } }

        // Write the stream.
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-diar-\(UUID().uuidString).wav")
        defer { if ProcessInfo.processInfo.environment["MDZ_KEEP"] == nil { try? FileManager.default.removeItem(at: wav) } else { print("kept", wav.path) } }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let out = try AVAudioFile(forWriting: wav, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
        let gap = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 6_400)!; gap.frameLength = 6_400
        var turns: [Turn] = [], now = 0.0, previous = -1, used = [String: Int]()
        while now < minutes * 60 {
            var speaker = rng.next(count); if speaker == previous && count > 1 { speaker = (speaker + 1) % count }
            previous = speaker
            let reader = chosen[speaker], list = byReader[reader]!
            let clip = list[(used[reader, default: 0]) % list.count]; used[reader, default: 0] += 1
            let file = try AVAudioFile(forReading: bench.appendingPathComponent(clip.audio))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1 else { print("clips must be 16 kHz mono"); exit(2) }
            try out.write(from: buffer)
            let seconds = Double(buffer.frameLength) / 16_000
            turns.append(Turn(speaker: speaker, start: now, end: now + seconds, words: clip.reference.split(separator: " ").count))
            now += seconds
            try out.write(from: gap); now += 0.4
        }

        out.close()

        // Run the helper.
        let p = Process(), pipe = Pipe(), errors = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/time")
        p.arguments = ["-l", a[1], a[2], "--diarize", wav.path, String(SpeakerSeparation.threshold)]
        p.standardOutput = pipe; p.standardError = errors
        let started = Date()
        try p.run()
        let answer = pipe.fileHandleForReading.readDataToEndOfFile()
        let timing = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let wall = Date().timeIntervalSince(started)
        guard let segments = SpeakerSeparation.parse(answer) else { print("helper failed:", String(decoding: answer.prefix(300), as: UTF8.self), timing.suffix(300)); exit(1) }
        let peak = timing.split(separator: "\n").first { $0.contains("maximum resident set size") }.flatMap { Double($0.trimmingCharacters(in: .whitespaces).split(separator: " ")[0]) } ?? 0

        // DER on 10 ms frames.
        let frames = Int((now * 100).rounded(.up)) + 1
        var ref = [Int](repeating: -1, count: frames), hyp = [Int](repeating: -1, count: frames)
        for t in turns { for f in Int(t.start * 100)..<min(frames, Int(t.end * 100)) { ref[f] = t.speaker } }
        for s in segments { for f in max(0, Int(s.start * 100))..<min(frames, Int(s.end * 100)) { hyp[f] = s.speaker } }
        var overlap: [Int: [Int: Int]] = [:]
        for f in 0..<frames where ref[f] >= 0 && hyp[f] >= 0 { overlap[hyp[f], default: [:]][ref[f], default: 0] += 1 }
        // Greedy one-to-one mapping by overlap.
        var mapping: [Int: Int] = [:], taken = Set<Int>()
        for (h, r, _) in overlap.flatMap({ h, refs in refs.map { (h, $0.key, $0.value) } }).sorted(by: { $0.2 > $1.2 }) where mapping[h] == nil && !taken.contains(r) { mapping[h] = r; taken.insert(r) }
        var speech = 0, miss = 0, falseAlarm = 0, confusion = 0
        for f in 0..<frames {
            if ref[f] >= 0 { speech += 1; if hyp[f] < 0 { miss += 1 } else if mapping[hyp[f]] != ref[f] { confusion += 1 } }
            else if hyp[f] >= 0 { falseAlarm += 1 }
        }
        let der = Double(miss + falseAlarm + confusion) / Double(max(speech, 1)) * 100
        // Attribution: each turn's span through the app's assignment rule.
        var correct = 0, total = 0
        for t in turns {
            total += t.words
            let pieces = SpeakerSeparation.pieces(start: t.start, end: t.end, segments: segments)
            if let best = pieces.max(by: { $0.end - $0.start < $1.end - $1.start }), mapping[best.speaker] == t.speaker { correct += t.words }
        }
        let found = Set(segments.map(\.speaker)).count
        print(String(format: "RESULT minutes=%.0f speakers=%d found=%d DER=%.1f%% (miss %.1f, false alarm %.1f, confusion %.1f) words attributed %.1f%% wall %.1f s peak RSS %.0f MB threshold %.3f turns=%d",
                     now / 60, count, found, der, Double(miss) / Double(speech) * 100, Double(falseAlarm) / Double(speech) * 100, Double(confusion) / Double(speech) * 100,
                     Double(correct) / Double(max(total, 1)) * 100, wall, peak / 1_048_576, SpeakerSeparation.threshold, turns.count))
    }
}
