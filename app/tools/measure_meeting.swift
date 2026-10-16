// Feeds two synthetic meeting streams from LibriSpeech clips through the real W7a pipeline (Chunker
// at 16 kHz mono, MeetingStreamFeed, MeetingPump with one chunk in flight, Meeting.insert) into a
// warm `ModelBench --serve` helper, and prints transcript accuracy, timing, CPU and memory. No
// microphone, tap or network. The helper client is a serial queue, like WarmRunner.
//
//   SDKROOT="$(dirname "$(xcrun --show-sdk-path)")/MacOSX26.sdk" swiftc -O -swift-version 5 -parse-as-library -suppress-warnings \
//     module-one/capture/Capture.swift app/Retention.swift app/Meetings.swift app/MeetingSpeakers.swift app/MeetingCapture.swift app/tools/measure_meeting.swift -o /tmp/mm
//   /tmp/mm HELPER MODELS BENCH_DIR MINUTES SPEED [--dictation]
//
// BENCH_DIR holds test-clean-100.jsonl and wav/ (MODEL_BENCHMARK.md). MINUTES of meeting audio per
// stream; SPEED 1 feeds in real time (lag and dictation contention), higher feeds faster (memory
// and CPU per meeting hour). --dictation sends a 10 s "dictation" every 60 s of audio through the
// same helper queue, ahead of nothing, and reports its latency.
import Foundation
import AVFoundation

struct Clip: Decodable { let id: String; let audio: String; let reference: String; let audio_seconds: Double }

final class Helper: @unchecked Sendable {
    private let queue = DispatchQueue(label: "measure.helper")
    private let task = Process(), input: FileHandle, output: FileHandle
    private var buffered = Data()
    var pid: Int32 { task.processIdentifier }
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
    func transcribe(_ url: URL, _ done: @escaping (String?) -> Void) {
        queue.async { [self] in
            try? input.write(contentsOf: Data((url.path + "\n").utf8))
            let answer = line().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            done(answer?["text"] as? String)
        }
    }
    func stop() { try? input.close(); task.terminate() }
}

func words(_ text: String) -> [String] { text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init) }
func editDistance(_ a: [String], _ b: [String]) -> Int {
    if a.isEmpty { return b.count }
    var previous = Array(0...b.count), current = previous
    for i in 1...a.count {
        current[0] = i
        for j in stride(from: 1, through: b.count, by: 1) { current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
        previous = current
    }
    return previous[b.count]
}
func rss(_ pid: Int32) -> Double {
    let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-o", "rss=", "-p", "\(pid)"]; p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    return (Double(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) / 1024
}
func cpuSeconds(_ pid: Int32) -> Double {
    let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-o", "time=", "-p", "\(pid)"]; p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
}

/// One stream: clips looped with 0.8 s of silence after each, read one clip at a time and handed
/// out as 0.1 s buffers at 16 kHz mono, until MINUTES of audio.
final class Source {
    private let clips: [Clip], bench: URL, limit: Double
    private var index = 0, samples: [Float] = [], offset = 0
    private(set) var produced = 0.0
    private(set) var reference: [String] = []
    /// The clips used, in order, for the whole-clip baseline.
    private(set) var used: [Clip] = []
    init(_ clips: [Clip], bench: URL, minutes: Double) { self.clips = clips; self.bench = bench; limit = minutes * 60 }
    func next() -> AVAudioPCMBuffer? {
        while offset >= samples.count {
            guard produced < limit else { return nil }
            let clip = clips[index % clips.count]; index += 1
            guard let file = try? AVAudioFile(forReading: bench.appendingPathComponent(clip.audio), commonFormat: .pcmFormatFloat32, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)), (try? file.read(into: buffer)) != nil else { continue }
            samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))) + [Float](repeating: 0, count: 12_800)
            offset = 0; reference += words(clip.reference); used.append(clip); produced += Double(samples.count) / 16_000
        }
        let n = min(1600, samples.count - offset)
        let buffer = AVAudioPCMBuffer(pcmFormat: SystemAudioTap.format, frameCapacity: 1600)!; buffer.frameLength = AVAudioFrameCount(n)
        for k in 0..<n { buffer.floatChannelData![0][k] = samples[offset + k] }
        offset += n
        return buffer
    }
}

@main struct MeasureMeeting {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 6, let minutes = Double(args[4]), let speed = Double(args[5]), speed > 0 else {
            print("Usage: mm HELPER MODELS BENCH_DIR MINUTES SPEED [--dictation]"); exit(2)
        }
        let bench = URL(fileURLWithPath: args[3])
        let clips = try String(contentsOf: bench.appendingPathComponent("test-clean-100.jsonl"), encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Clip.self, from: Data($0.utf8)) }
        let dictationClip = bench.appendingPathComponent(clips.first { $0.audio_seconds > 9 && $0.audio_seconds < 12 }!.audio)
        let me = Source(clips, bench: bench, minutes: minutes)
        let them = Source(Array(clips.reversed()), bench: bench, minutes: minutes)
        let helper = try Helper(helper: args[1], models: args[2])
        defer { helper.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("measure-meeting-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Baseline dictation latency with an idle helper.
        var baseline: [Double] = []
        for _ in 0..<5 {
            let s = Date(), done = DispatchSemaphore(value: 0)
            helper.transcribe(dictationClip) { _ in done.signal() }; done.wait(); baseline.append(Date().timeIntervalSince(s))
        }

        let lock = NSLock()
        var meeting = Meeting(id: UUID().uuidString, recordedAt: Date(), source: .everything)
        var lags: [Double] = [], dictations: [Double] = [], failed = 0, maxBacklog = 0.0
        let began = Date()
        let pump = MeetingPump(transcribe: MeetingRoute.transcriber(cloud: nil, local: { url, done in helper.transcribe(url, done) }), deliver: { job, chunk in
            let text = chunk?.text
            lock.withLock {
                // Lag: wall time since the chunk's audio ended, in audio-clock seconds (meaningful at SPEED 1).
                lags.append(Date().timeIntervalSince(began) - (job.start + job.duration) / speed)
                if let text { meeting.insert(stream: job.stream, start: job.start, end: job.start + job.duration, text: text) } else { failed += 1 }
            }
            try? FileManager.default.removeItem(at: job.url)
        })
        let meChunker = Chunker(format: SystemAudioTap.format, directory: folder, boundaries: false, fileSettings: Chunker.int16(SystemAudioTap.format))
        let themChunker = Chunker(format: SystemAudioTap.format, directory: folder, boundaries: false, fileSettings: Chunker.int16(SystemAudioTap.format))
        meChunker.attach(MeetingStreamFeed(stream: .me, folder: folder, offset: 0, enqueue: pump.enqueue, failed: { failed += 1000 }).receive)
        themChunker.attach(MeetingStreamFeed(stream: .them, folder: folder, offset: 0, enqueue: pump.enqueue, failed: { failed += 1000 }).receive)

        var memory: [(Double, Double, Double)] = []   // audio minute, harness MB, helper MB
        let cpuStart = (cpuSeconds(getpid()), cpuSeconds(helper.pid))
        var i = 0
        while true {
            // The app's capture runs on dispatch queues, which drain autorelease pools; this loop must too.
            let more: Bool = autoreleasepool {
                let a = me.next(), b = them.next()
                if let a { meChunker.append(a) }
                if let b { themChunker.append(b) }
                return a != nil || b != nil
            }
            if !more { break }
            i += 1
            let audio = Double(i) * 0.1
            if audio.truncatingRemainder(dividingBy: 60) < 0.05 {
                memory.append((audio / 60, rss(getpid()), rss(helper.pid)))
                lock.withLock { maxBacklog = max(maxBacklog, pump.backlog) }
                if args.contains("--dictation") {
                    let s = Date()
                    helper.transcribe(dictationClip) { _ in lock.withLock { dictations.append(Date().timeIntervalSince(s)) } }
                }
            }
            let due = began.addingTimeInterval(audio / speed)
            if due > Date() { Thread.sleep(until: due) }
        }
        meChunker.finish(); themChunker.finish()
        while !pump.isIdle { Thread.sleep(forTimeInterval: 0.2) }
        Thread.sleep(forTimeInterval: 0.5)
        let wall = Date().timeIntervalSince(began)
        let cpu = (cpuSeconds(getpid()) - cpuStart.0, cpuSeconds(helper.pid) - cpuStart.1)

        func wer(_ stream: MeetingStream, _ reference: [String]) -> Double {
            let hypothesis = meeting.lines.filter { $0.stream == stream }.flatMap { words($0.text) }
            return Double(editDistance(reference, hypothesis)) / Double(max(1, reference.count)) * 100
        }
        // Baseline: the same clips, each transcribed whole by the same helper.
        var whole: [String: [String]] = [:]
        for clip in Set((me.used + them.used).map(\.id)).compactMap({ id in clips.first { $0.id == id } }) {
            let done = DispatchSemaphore(value: 0)
            helper.transcribe(bench.appendingPathComponent(clip.audio)) { text in whole[clip.id] = words(text ?? ""); done.signal() }
            done.wait()
        }
        func baselineWER(_ source: Source) -> Double {
            Double(editDistance(source.reference, source.used.flatMap { whole[$0.id] ?? [] })) / Double(max(1, source.reference.count)) * 100
        }
        let sortedLags = lags.sorted()
        func pct(_ values: [Double], _ p: Double) -> Double { values.isEmpty ? 0 : values[min(values.count - 1, Int(Double(values.count) * p))] }
        print(String(format: "audio: %.1f min per stream, speed %.0fx, wall %.1f s, lines %d, failed chunks %d", minutes, speed, wall, meeting.lines.count, failed))
        print(String(format: "WER chunked: Me %.2f%%, Them %.2f%%; same clips whole: Me %.2f%%, Them %.2f%% (LibriSpeech test-clean, %d reference words per stream)",
                     wer(.me, me.reference), wer(.them, them.reference), baselineWER(me), baselineWER(them), me.reference.count))
        print(String(format: "CPU: harness %.1f s, helper %.1f s for %.1f min of two-stream meeting (%.1f%% of one core at 1x)",
                     cpu.0, cpu.1, minutes, (cpu.0 + cpu.1) / (minutes * 60) * 100))
        if speed == 1 { print(String(format: "lag after chunk end: median %.1f s, p90 %.1f s, max %.1f s", pct(sortedLags, 0.5), pct(sortedLags, 0.9), sortedLags.last ?? 0)) }
        print(String(format: "max backlog %.1f s of audio", maxBacklog))
        print(String(format: "dictation alone: median %.3f s; during meeting: median %.3f s, max %.3f s (n=%d)",
                     pct(baseline.sorted(), 0.5), pct(dictations.sorted(), 0.5), dictations.max() ?? 0, dictations.count))
        for m in memory where m.0 == 1 || Int(m.0) % 10 == 0 { print(String(format: "memory at %5.1f min: harness %.0f MB, helper %.0f MB", m.0, m.1, m.2)) }
        if let tenth = memory.first(where: { $0.0 >= 10 }), let last = memory.last {
            print(String(format: "memory growth from minute 10 to the end: harness %+.0f MB, helper %+.0f MB", last.1 - tenth.1, last.2 - tenth.2))
        }
    }
}
