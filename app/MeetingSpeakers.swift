import Foundation

// Speaker separation, milestone W7d (PRD 11.8, Q4): after Stop, the kept Them stream goes through
// FluidAudio's offline diarizer in a short-lived helper; each Them line goes to the speaker it
// overlaps most and is split where the voice changes. Foundation only, so check_speakers.swift
// builds without audio frameworks.
//
// Never kept: voice embeddings stay inside the helper process, which prints only speaker ids and
// times. Speakers are numbered per meeting; nothing recognises a person across meetings.

/// One stretch of speech from the diarizer: its raw speaker id (only meaningful within one run) and times.
struct SpeakerSegment: Codable, Equatable {
    let speaker: String
    let start: Double
    let end: Double
}

/// A meeting's speaker separation, stored with the meeting and expiring with it.
struct SpeakerSeparation: Codable, Equatable {
    enum State: String, Codable { case pending, done, skipped, failed }
    var state: State
    /// Names the user gave speakers in this meeting, by speaker number.
    var names: [Int: String] = [:]
    /// The clustering threshold the diarizer ran with (PRD 11.8 asks for it to be recorded).
    var threshold: Double? = nil
    /// Last rename, merge or reassignment. Notes written before it are out of date (PRD 11.6).
    var editedAt: Date? = nil
    /// Content-free reason when the state is failed.
    var failure: String? = nil
}

enum MeetingSpeakers {
    /// FluidAudio's community-1 default; fixed before any scoring (PRD 11.10 evidence in the PR).
    static let threshold = 0.6

    /// "Speaker 2", or the name the user gave; Me and unassigned Them lines keep their stream label.
    static func label(_ line: MeetingLine, in meeting: Meeting) -> String {
        guard line.stream == .them, let number = line.speaker else { return MeetingExport.label(line.stream) }
        return meeting.speakers?.names[number] ?? "Speaker \(number)"
    }

    /// Speaker numbers in use in this meeting, ascending.
    static func numbers(_ meeting: Meeting) -> [Int] { Array(Set(meeting.lines.compactMap(\.speaker))).sorted() }

    /// The raw speaker whose segments overlap `start...end` most; with no overlap, the nearest segment's.
    static func speaker(_ start: Double, _ end: Double, _ segments: [SpeakerSegment], nearest: Bool) -> String? {
        var overlap: [String: Double] = [:]
        for segment in segments {
            let shared = min(end, segment.end) - max(start, segment.start)
            if shared > 0 { overlap[segment.speaker, default: 0] += shared }
        }
        if let best = overlap.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) { return best.key }
        guard nearest else { return nil }
        func distance(_ s: SpeakerSegment) -> Double { max(s.start - end, start - s.end, 0) }
        return segments.min { distance($0) < distance($1) }?.speaker
    }

    /// Assigns every Them line to a speaker, splitting a line where the voice changes when its word
    /// times are known (local transcription). Lines without word times (the cloud route, or a
    /// dictionary change of the word count) go whole to the speaker they overlap most.
    /// ponytail: per-word midpoint vote, no smoothing; a one-word interjection becomes its own line.
    /// Speakers are numbered 1, 2… in order of their first line. The first piece of a split line keeps
    /// its id (notes cite line ids); word times are dropped once used.
    static func apply(_ segments: [SpeakerSegment], to meeting: inout Meeting) {
        var nextID = (meeting.lines.map(\.id).max() ?? 0) + 1
        var out: [MeetingLine] = []
        var raw: [Int: String] = [:]  // line id → raw speaker
        for var line in meeting.lines {
            let words = line.words
            line.words = nil
            guard line.stream == .them else { out.append(line); continue }
            let pieces = split(line, words: words, segments: segments)
            for (index, piece) in pieces.enumerated() {
                var part = piece.line
                if index > 0 { part = MeetingLine(id: nextID, stream: .them, start: part.start, end: part.end, text: part.text, localFallback: line.localFallback); nextID += 1 }
                if let speaker = piece.speaker { raw[part.id] = speaker }
                out.append(part)
            }
        }
        // A split piece can start after a Me line inside its chunk: keep capture-time order (Me first on a tie, as insert does).
        out = out.enumerated().sorted { a, b in
            a.element.start != b.element.start ? a.element.start < b.element.start
                : a.element.stream != b.element.stream ? a.element.stream == .me : a.offset < b.offset
        }.map(\.element)
        var numbers: [String: Int] = [:]
        for i in out.indices {
            guard let speaker = raw[out[i].id] else { out[i].speaker = nil; continue }
            if numbers[speaker] == nil { numbers[speaker] = numbers.count + 1 }
            out[i].speaker = numbers[speaker]
        }
        // Them words are unchanged, so echo suppression's results on Me lines still hold.
        meeting.lines = out
        var separation = meeting.speakers ?? SpeakerSeparation(state: .done)
        separation.state = .done
        meeting.speakers = separation
    }

    /// One Them line as one or more (line, raw speaker) pieces.
    static func split(_ line: MeetingLine, words: [[Double]]?, segments: [SpeakerSegment]) -> [(line: MeetingLine, speaker: String?)] {
        let whole = [(line, speaker(line.start, line.end, segments, nearest: true))]
        let tokens = line.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let words, words.count == tokens.count, words.allSatisfy({ $0.count == 2 }), !tokens.isEmpty else { return whole }
        // Word times are seconds from the line's start; a word with no overlapping speech takes its neighbour's speaker.
        var who = words.map { w -> String? in
            let mid = line.start + (w[0] + w[1]) / 2
            return speaker(mid - 0.05, mid + 0.05, segments, nearest: false) ?? speaker(line.start + w[0], line.start + w[1], segments, nearest: false)
        }
        guard who.contains(where: { $0 != nil }) else { return whole }
        for i in who.indices.dropFirst() where who[i] == nil { who[i] = who[i - 1] }
        for i in who.indices.reversed().dropFirst() where who[i] == nil { who[i] = who[i + 1] }
        var pieces: [(line: MeetingLine, speaker: String?)] = []
        var first = 0
        for i in 1...tokens.count where i == tokens.count || who[i] != who[first] {
            let start = first == 0 ? line.start : line.start + words[first][0]
            let end = i == tokens.count ? line.end : max(start, line.start + words[i - 1][1])
            pieces.append((MeetingLine(id: line.id, stream: .them, start: start, end: end, text: tokens[first..<i].joined(separator: " "), localFallback: line.localFallback), who[first]))
            first = i
        }
        return pieces
    }

    /// Parses the helper's reply. Anything but ids and times (such as an embedding) is ignored.
    static func segments(_ reply: Data) -> [SpeakerSegment]? {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let list = object["segments"] as? [[String: Any]] else { return nil }
        return list.compactMap { item in
            guard let speaker = item["speaker"] as? String, let start = item["start"] as? Double, let end = item["end"] as? Double,
                  start.isFinite, end.isFinite, end > start else { return nil }
            return SpeakerSegment(speaker: speaker, start: start, end: end)
        }
    }
}

// MARK: - Editing (per meeting)

extension Meeting {
    /// An empty name goes back to "Speaker N".
    mutating func renameSpeaker(_ number: Int, to name: String) {
        guard speakers != nil else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        speakers?.names[number] = trimmed.isEmpty ? nil : String(trimmed.prefix(60))
        speakers?.editedAt = Date()
    }

    /// Every line of `from` goes to `into`; `from`'s name is dropped. Other numbers stay as they are.
    mutating func mergeSpeaker(_ from: Int, into: Int) {
        guard speakers != nil, from != into else { return }
        for i in lines.indices where lines[i].speaker == from { lines[i].speaker = into }
        speakers?.names[from] = nil
        speakers?.editedAt = Date()
    }

    /// Moves one Them line to another speaker, or to a new one when `to` is not in use.
    mutating func reassignLine(_ id: Int, to speaker: Int) {
        guard speakers != nil, speaker > 0, let i = lines.firstIndex(where: { $0.id == id && $0.stream == .them }) else { return }
        lines[i].speaker = speaker
        speakers?.editedAt = Date()
    }
}

// MARK: - Kept Them audio (PRD 11.5, Q4)

/// With speaker separation on, the Them stream is kept as one 16 kHz mono 16-bit WAV per meeting in
/// `retry-audio/speakers/<meeting id>.wav` (owner-only): each transcribed chunk is written at its
/// own time, so gaps read as silence. It is deleted once diarization finishes or is skipped, with
/// its meeting, and in any case 24 hours after it was created. The Me stream is never kept.
enum SpeakerAudio {
    static let sampleRate = 16_000
    static let header = 44

    static func file(_ root: URL, meeting id: String) -> URL { root.appendingPathComponent(id + ".wav") }

    /// Writes 16-bit samples at `start` seconds, creating the file (and its owner-only folder) first.
    static func write(_ samples: [Int16], at start: Double, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: wavHeader(dataBytes: 0), attributes: [.posixPermissions: 0o600]) else { throw RetentionError("Could not keep call audio") }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(header + max(0, Int((start * Double(sampleRate)).rounded())) * 2))
        try handle.write(contentsOf: samples.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    /// Sets the header's sizes from the file's length; the helper reads it after this.
    static func finish(_ url: URL) throws {
        let length = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: wavHeader(dataBytes: max(0, length - header)))
    }

    static func wavHeader(dataBytes: Int) -> Data {
        var data = Data()
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; data.append(Data(bytes: &x, count: 2)) }
        data.append(Data("RIFF".utf8)); u32(36 + dataBytes); data.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(dataBytes)
        return data
    }

    /// Deletes kept audio older than 24 hours (or dated in the future), files of meetings not in
    /// `keep` (those still waiting for diarization), and anything that is not a kept file. `active`
    /// (the meeting recording now, still transcribing, or being diarized) is never touched.
    static func purge(_ root: URL, keep: Set<String>, active: Set<String> = [], now: Date = Date()) {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            let id = url.deletingPathExtension().lastPathComponent
            if active.contains(id) { continue }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if url.pathExtension != "wav" || !keep.contains(id) || now.timeIntervalSince(created) >= RetryWindow.lifetime || created > now {
                try? fm.removeItem(at: url)
            }
        }
    }
}

// MARK: - The helper

/// Runs `ModelBench DIARIZER_DIRECTORY --diarize KEPT_WAV THRESHOLD` once per meeting. The process
/// exits when it is done, so its memory goes back; Skip, deletion and quitting terminate it.
final class SpeakerRunner: @unchecked Sendable {
    /// A 2-hour meeting took 32 s on the M3 (PRD 11.11, W7d status); far beyond that, give up.
    static let timeout: TimeInterval = 30 * 60
    private let lock = NSLock()
    private var running: [String: Process] = [:]

    var active: Set<String> { lock.withLock { Set(running.keys) } }

    /// `done` runs on a background queue with the segments, or nil when the helper failed or timed out.
    /// It is not called for a run that was cancelled or replaced.
    /// `check` verifies the model files against their pins first, off the main thread.
    func run(_ id: String, helper: URL, models: URL, audio: URL, check: @escaping () -> Bool = { true }, threshold: Double, done: @escaping ([SpeakerSegment]?) -> Void) {
        let process = Process(), output = Pipe()
        process.executableURL = helper
        process.arguments = [models.path, "--diarize", audio.path, String(threshold)]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        lock.withLock { running[id].map(Self.stop); running[id] = process }
        DispatchQueue.global(qos: .utility).async { [self] in
            guard check(), (try? process.run()) != nil else { if finish(id, process) { done(nil) }; return }
            // Cancelled while it was starting.
            if lock.withLock({ running[id] !== process }) { process.terminate() }
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: watchdog)
            let reply = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); watchdog.cancel()
            // A cancelled run (Skip, deletion, quitting) answers nothing; its meeting is handled by the canceller.
            guard finish(id, process) else { return }
            done(process.terminationStatus == 0 ? MeetingSpeakers.segments(reply) : nil)
        }
    }

    func cancel(_ id: String) { lock.withLock { running.removeValue(forKey: id) }.map(Self.stop) }
    func cancelAll() { lock.withLock { let all = running; running = [:]; return all }.values.forEach(Self.stop) }
    /// A process that has not started yet must not be terminated; the run notices the cancel instead.
    private static func stop(_ process: Process) { if process.isRunning { process.terminate() } }

    /// False when this run was cancelled or replaced.
    @discardableResult
    private func finish(_ id: String, _ process: Process) -> Bool {
        lock.withLock {
            guard running[id] === process else { return false }
            running[id] = nil; return true
        }
    }
}

// MARK: - Settings text

/// Settings → Meetings → Speaker separation: an optional 21.6 MB download (PRD 11.8).
enum SpeakerFacts {
    static let repository = "FluidInference/speaker-diarization-coreml"
    static let key = "meetingSpeakers"
    static let displayName = "Separate speakers after a meeting"
    static func directory(home: URL) -> URL { home.appendingPathComponent("Library/Caches/Dictation/module-one/speaker-diarization-df2625a") }
    static let explanation = "After Stop, the call’s audio is split into Speaker 1, Speaker 2… on this Mac. To do that, Murmur keeps the call’s audio (never your microphone) until separation finishes, at most 24 hours, then deletes it. Voice prints are discarded after each meeting, and nobody is recognised across meetings."
    /// Credits required by the repository's NOTICE.md (CC-BY-4.0 attribution).
    static let credits = "Speaker separation uses modified Core ML conversions by Fluid Inference of the pyannote speaker-diarization-community-1 pipeline (pyannote segmentation, WeSpeaker embeddings) with PLDA parameters from BUT Speech@FIT, licensed under CC-BY-4.0: https://creativecommons.org/licenses/by/4.0/"
    /// The meeting page's line while speakers are being separated, or waiting to be.
    static func status(_ separation: SpeakerSeparation?, running: Bool) -> String? {
        switch separation?.state {
        case .pending?: return running ? "Separating speakers…" : "Waiting to separate speakers. The call’s audio is kept for up to 24 hours."
        case .failed?: return "Speakers could not be separated, so the call’s side is labelled Them. Its audio was deleted."
        default: return nil
        }
    }
}
