import Foundation

// Meeting notes, milestone W7a (PRD section 11): the record, its store and retention, echo
// suppression, the shared transcription pump, limits, consent and export. Foundation only, so
// check_meetings.swift builds without audio frameworks. Capture lives in MeetingCapture.swift.

enum MeetingStream: String, Codable { case me, them }

struct MeetingLine: Codable, Equatable, Identifiable {
    let id: Int
    let stream: MeetingStream
    /// Seconds from the meeting's start, by capture time.
    let start: Double
    let end: Double
    /// As transcribed, with the dictionary applied. Never changed by echo suppression.
    let text: String
    /// Me lines only: the text with words that repeat the other side removed (PRD 11.2), or nil
    /// when nothing was removed. An empty string means the whole line is hidden.
    var shown: String? = nil
    /// True when the meeting's cloud route failed for this chunk and this Mac transcribed it.
    var localFallback: Bool? = nil
    /// Them lines after speaker separation (W7d): 1, 2… in order of first speech.
    var speaker: Int? = nil

    var isHidden: Bool { shown == "" }
    /// What the transcript, exports and (later) notes use.
    var visibleText: String { shown ?? text }
}

/// Whose audio "Them" is: one call app (and its helper processes), every app except Murmur, or none.
struct MeetingSource: Codable, Equatable {
    var name: String
    var bundleID: String?
    var allApps = false
    var micOnly = false

    static let everything = MeetingSource(name: "All apps", bundleID: nil, allApps: true)
    static let microphoneOnly = MeetingSource(name: "Only my microphone", bundleID: nil, micOnly: true)
}

struct Meeting: Codable, Identifiable, Equatable {
    let id: String
    /// When recording started; retention counts from here, as for dictations.
    let recordedAt: Date
    var seconds: Double = 0
    var source: MeetingSource
    var lines: [MeetingLine] = []
    /// What the user typed in the live view's My notes field.
    var myNotes = ""
    /// Seconds where a stream stopped or restarted, marked in the transcript.
    var gaps: [Double] = []
    /// False while recording, so a crash leaves a record that relaunch finishes.
    var finished = false
    /// The cloud transcriber's name when the meeting used the cloud route; nil means this Mac.
    var transcribedBy: String? = nil
    /// Written after Stop by the notes route (W7b, PRD 11.6). Optional, so W7a records still decode.
    var notes: MeetingNotes? = nil
    /// Speaker separation (W7d, PRD 11.8), fixed when the meeting starts; nil means off.
    var separation: SeparationState? = nil
    /// Names the user gave speakers in this meeting, by number ("2": "Dana"). Expire with it.
    var speakerNames: [String: String]? = nil

    /// "Me", or a Them line's speaker name, "Speaker 2", or "Them" before separation.
    func label(_ line: MeetingLine) -> String {
        guard line.stream == .them, let speaker = line.speaker else { return MeetingExport.label(line.stream) }
        return speakerNames?[String(speaker)] ?? "Speaker \(speaker)"
    }
    /// Speaker numbers in order of first speech.
    var speakers: [Int] {
        var seen: [Int] = []
        for line in lines { if let s = line.speaker, !seen.contains(s) { seen.append(s) } }
        return seen
    }

    /// The notes' title once they have one, otherwise the source and date.
    var title: String { notes?.title ?? defaultTitle }
    var defaultTitle: String {
        let date = DateFormatter.localizedString(from: recordedAt, dateStyle: .medium, timeStyle: .short)
        if source.micOnly { return "Meeting notes, \(date)" }
        return source.allApps ? "Meeting, \(date)" : "Meeting with \(source.name), \(date)"
    }

    /// Inserts a transcribed line in capture-time order and re-runs echo suppression near it.
    mutating func insert(stream: MeetingStream, start: Double, end: Double, text: String, localFallback: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var line = MeetingLine(id: (lines.map(\.id).max() ?? 0) + 1, stream: stream, start: start, end: end, text: trimmed)
        if localFallback { line.localFallback = true }
        let index = lines.firstIndex { $0.start > start || ($0.start == start && $0.stream == .them && stream == .me) } ?? lines.endIndex
        lines.insert(line, at: index)
        seconds = max(seconds, end)
        MeetingEcho.apply(&lines, near: start - MeetingEcho.window - 30, to: end + MeetingEcho.window + 30)
    }
}

// MARK: - Echo suppression

/// Acoustic echo, not vocabulary filtering: with speakers, the microphone also hears the other side,
/// so their words appear in Me too. A run of at least `minimumRun` Me words that repeats a run in a
/// nearby Them line is hidden from Me. Them is never changed, nothing is deleted, and "Show hidden
/// echo" brings it back. This lives only in the meeting layer, never in transcription or providers.
enum MeetingEcho {
    /// ponytail: exact word runs over chunk-level timing; measure on real speaker calls (PRD 11.10) before tuning.
    static let minimumRun = 3
    /// Seconds of slack around a Me line when looking for Them lines; chunks are about 15 s long.
    static let window = 3.0

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
    }

    /// The Me text with echoed runs removed; "" when nothing of its own is left; nil when nothing was removed.
    static func shown(me text: String, them: [String]) -> String? {
        let original = text.split(whereSeparator: \.isWhitespace)
        let mine = words(text)
        let theirs = them.map(words).filter { !$0.isEmpty }
        var hidden = [Bool](repeating: false, count: mine.count)
        for start in mine.indices where !mine[start].isEmpty {
            for other in theirs {
                for j in other.indices where other[j] == mine[start] {
                    var length = 0
                    while start + length < mine.count, j + length < other.count, !mine[start + length].isEmpty, mine[start + length] == other[j + length] { length += 1 }
                    if length >= minimumRun { for k in start..<(start + length) { hidden[k] = true } }
                }
            }
        }
        guard hidden.contains(true) else { return nil }
        return zip(original, hidden).filter { !$0.1 }.map { String($0.0) }.joined(separator: " ")
    }

    /// Recomputes `shown` for Me lines that start between `from` and `to`.
    static func apply(_ lines: inout [MeetingLine], near from: Double, to: Double) {
        for i in lines.indices where lines[i].stream == .me && lines[i].start >= from && lines[i].start <= to {
            let me = lines[i]
            let them = lines.filter { $0.stream == .them && $0.end >= me.start - window && $0.start <= me.end + window }.map(\.text)
            lines[i].shown = shown(me: me.text, them: them)
        }
    }
}

// MARK: - Store

/// One JSON file per meeting in `history/meetings/`, owner-only, written atomically. Inside the
/// History folder, so Delete All Data removes it with History.
struct MeetingStore {
    let directory: URL
    init(directory: URL) throws {
        self.directory = directory
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: directory.path) {
            guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw RetentionError("Meetings require a real directory") }
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private func file(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw RetentionError("Invalid meeting identifier") }
        return directory.appendingPathComponent(id + ".json")
    }
    func save(_ meeting: Meeting) throws {
        let url = try file(meeting.id)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType != .typeRegular {
            throw RetentionError("Meeting file is not a regular file")
        }
        try JSONEncoder().encode(meeting).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    /// Newest first. A file that cannot be read moves to `unreadable/` (still expiring by date) so one
    /// damaged meeting cannot hide the rest.
    func meetings() throws -> [Meeting] {
        var found: [Meeting] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) where url.pathExtension == "json" {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            if let meeting = try? JSONDecoder().decode(Meeting.self, from: Data(contentsOf: url)), url.lastPathComponent == meeting.id + ".json" {
                found.append(meeting); continue
            }
            try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.moveItem(at: url, to: unreadable.appendingPathComponent(UUID().uuidString + ".json"))
        }
        return found.sorted { $0.recordedAt > $1.recordedAt }
    }
    var unreadable: URL { directory.appendingPathComponent("unreadable", isDirectory: true) }
    func delete(_ id: String) throws { try FileManager.default.removeItem(at: try file(id)) }
    func size(_ id: String) -> Int64 {
        ((try? file(id)).flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber })?.int64Value ?? 0
    }
    /// Deletes meetings that started at or before `cutoff` (from `HistoryExpiry.cutoff`; nil is Forever).
    @discardableResult
    func purge(cutoff: Date?) throws -> [String] {
        guard let cutoff else { return [] }
        let expired = try meetings().filter { $0.recordedAt <= cutoff }.map(\.id)
        for id in expired { try delete(id) }
        try purgeUnreadable(cutoff: cutoff)
        return expired
    }
    /// Damaged files still hold meeting text, so they expire by their modification date.
    func purgeUnreadable(cutoff: Date) throws {
        let files = (try? FileManager.default.contentsOfDirectory(at: unreadable, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files where ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture) <= cutoff {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// The 50 MB History cap counts meetings (they live inside the History folder), so they join the
/// same oldest-first list as dictations. Otherwise meetings over the cap would drop every dictation.
struct CappedHistoryItem: RetainedHistoryItem {
    let id: String
    let recordedAt: Date
    let isMeeting: Bool
}

enum MeetingCap {
    @discardableResult
    static func enforce(entries: [(id: String, recordedAt: Date)], meetings: [Meeting], historyDirectory: URL, meetingStore: MeetingStore,
                        retention: HistoryRetention, capBytes: Int64 = HistoryCap.defaultCapBytes,
                        deleteEntry: (String) throws -> Void) throws -> HistoryCapResult<CappedHistoryItem> {
        var sizes: [String: Int64] = [:]
        for entry in entries {
            sizes[entry.id] = ((try? FileManager.default.attributesOfItem(atPath: historyDirectory.appendingPathComponent(entry.id + ".json").path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        for meeting in meetings { sizes[meeting.id] = meetingStore.size(meeting.id) }
        let items = entries.map { CappedHistoryItem(id: $0.id, recordedAt: $0.recordedAt, isMeeting: false) }
            + meetings.map { CappedHistoryItem(id: $0.id, recordedAt: $0.recordedAt, isMeeting: true) }
        let other = max(0, try HistoryCap.usage(directory: historyDirectory) - sizes.values.reduce(0, +))
        let result = HistoryCap.plan(entries: items, sizes: sizes, otherBytes: other, retention: retention, capBytes: capBytes)
        for item in result.dropped { if item.isMeeting { try meetingStore.delete(item.id) } else { try deleteEntry(item.id) } }
        return result
    }
}

// MARK: - Chunk audio and recovery

/// Chunk audio waiting for transcription, in `retry-audio/meetings/<meeting id>/`, named
/// `<stream>-<start ms>.wav`. A chunk is deleted once its line is saved. What a crash or a failed
/// transcription leaves is retry audio: offered as "Finish transcript", gone after 24 hours.
enum MeetingAudio {
    static func folder(_ root: URL, meeting id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    /// Them chunks kept until speaker separation finishes (W7d), apart from untranscribed leftovers.
    static let keptName = "kept-them"
    static func kept(_ root: URL, meeting id: String) -> URL { folder(root, meeting: id).appendingPathComponent(keptName, isDirectory: true) }
    /// Kept Them chunks, oldest first.
    static func keptChunks(_ root: URL, meeting id: String) -> [(url: URL, start: Double)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: kept(root, meeting: id), includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url in parse(url).flatMap { $0.stream == .them ? (url, $0.start) : nil } }.sorted { $0.start < $1.start }
    }
    static func name(_ stream: MeetingStream, start: Double) -> String { "\(stream.rawValue)-\(Int((start * 1000).rounded())).wav" }
    static func parse(_ url: URL) -> (stream: MeetingStream, start: Double)? {
        guard url.pathExtension == "wav" else { return nil }
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let stream = MeetingStream(rawValue: String(parts[0])), let ms = Int(parts[1]), ms >= 0 else { return nil }
        return (stream, Double(ms) / 1000)
    }
    /// Leftover chunks of one meeting, oldest first.
    static func leftovers(_ root: URL, meeting id: String) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder(root, meeting: id), includingPropertiesForKeys: nil)) ?? []
        return urls.filter { parse($0) != nil }.sorted { parse($0)!.start < parse($1)!.start }
    }
    /// Removes folders of meetings that no longer exist (or are not to be kept), chunk files older
    /// than 24 hours, and anything that is not a chunk. `keep` holds the meeting ids still on record.
    /// `active` (the meeting recording now, and any still transcribing) is never touched: its folder
    /// holds the chunker's file being written, and deleting it stopped both streams in the first live tests.
    static func purge(_ root: URL, keep: Set<String>, active: Set<String> = [], now: Date = Date()) {
        let fm = FileManager.default
        for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            if active.contains(folder.lastPathComponent) { continue }
            guard keep.contains(folder.lastPathComponent) else { try? fm.removeItem(at: folder); continue }
            for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
                let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                // Them audio kept for speaker separation: the same 24 hours, file by file (Q4).
                if file.lastPathComponent == keptName {
                    for kept in (try? fm.contentsOfDirectory(at: file, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
                        let made = (try? kept.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                        if now.timeIntervalSince(made) >= RetryWindow.lifetime || made > now { try? fm.removeItem(at: kept) }
                    }
                    if ((try? fm.contentsOfDirectory(atPath: file.path)) ?? []).isEmpty { try? fm.removeItem(at: file) }
                    continue
                }
                if parse(file) == nil || now.timeIntervalSince(created) >= RetryWindow.lifetime || created > now { try? fm.removeItem(at: file) }
            }
            if ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty { try? fm.removeItem(at: folder) }
        }
    }
}

/// The PRD's 24-hour retry-audio window (section 6), restated here so this file stays Foundation-only.
enum RetryWindow { static let lifetime: TimeInterval = 24 * 60 * 60 }

// MARK: - Transcription route (decision of October 15, 2026, amending Q2)

/// Settings → Meetings: where meeting audio is transcribed, separate from dictation's route.
enum MeetingTranscription: String, Codable, CaseIterable {
    case local, cloud
    static let key = "meetingTranscription"
    /// On this Mac unless the user chose Cloud.
    static func load(_ defaults: UserDefaults) -> MeetingTranscription { MeetingTranscription(rawValue: defaults.string(forKey: key) ?? "") ?? .local }
}

/// One chunk's transcript; `localFallback` marks a chunk this Mac transcribed after the cloud failed.
struct ChunkText: Equatable {
    let text: String
    var localFallback = false
}

enum MeetingCloudResult: Equatable { case text(String), noSpeech, failed }

enum MeetingRoute {
    typealias Local = (URL, @escaping (String?) -> Void) -> Void
    typealias Cloud = (URL, @escaping (MeetingCloudResult) -> Void) -> Void

    /// The pump's transcriber for one meeting. The route is fixed here, when the meeting starts, so
    /// changing the setting never switches a meeting in progress. A cloud chunk that fails (rate
    /// limit, network, an answer-shaped LLM reply) is transcribed on this Mac and marked; the route
    /// itself never changes, and a local chunk never goes to the cloud.
    static func transcriber(cloud: Cloud?, local: @escaping Local) -> (URL, @escaping (ChunkText?) -> Void) -> Void {
        { url, done in
            guard let cloud else { local(url) { done($0.map { ChunkText(text: $0) }) }; return }
            cloud(url) { result in
                switch result {
                case .text(let text): done(ChunkText(text: text))
                case .noSpeech: done(ChunkText(text: ""))
                case .failed: local(url) { done($0.map { ChunkText(text: $0, localFallback: true) }) }
                }
            }
        }
    }

    /// Chunks are 16 kHz mono 16-bit: 115.2 MB an hour per stream, so up to about 230 MB with both.
    static let megabytesPerStreamHour = 115.2

    /// The inline note under Cloud. No price is quoted: per-minute prices are not verified for
    /// either route, so the note says the price depends on the provider.
    static func cloudNote(provider: String, host: String, storesAudio: Bool) -> String {
        var note = "Meetings send all of their audio, including other participants’ voices, to \(provider) at \(host): up to about \(Int((megabytesPerStreamHour * 2).rounded())) MB an hour with both streams. Long meetings can cost significantly; the price depends on the provider and model, so check its pricing before a long call."
        if storesAudio { note += " Google stores audio requests (55 days on the paid tier, 1 day on the free tier)." }
        note += " If a part fails, it is transcribed on this Mac instead and marked; the meeting stays on the cloud route."
        return note
    }
}

// MARK: - Transcription pump

/// One queue for both streams' chunks. Only one chunk is with the warm helper at a time, so a
/// dictation waits for at most one chunk (PRD 11.4); chunks go in the order they were recorded.
/// A chunk that fails twice is left on disk for "Finish transcript"; nothing is dropped.
final class MeetingPump: @unchecked Sendable {
    struct Job: Equatable { let stream: MeetingStream; let url: URL; let start: Double; let duration: Double; var attempts = 0 }
    private let lock = NSLock()
    private var queued: [Job] = [], inFlight: Job?, stopped = false
    private let transcribe: (URL, @escaping (ChunkText?) -> Void) -> Void
    private let deliver: (Job, ChunkText?) -> Void
    static let attempts = 2

    /// `transcribe(url, completion)` answers the text or nil; `deliver(job, text)` gets nil after the last attempt.
    init(transcribe: @escaping (URL, @escaping (ChunkText?) -> Void) -> Void, deliver: @escaping (Job, ChunkText?) -> Void) {
        self.transcribe = transcribe; self.deliver = deliver
    }
    func enqueue(_ job: Job) {
        lock.withLock {
            guard !stopped else { return }
            let index = queued.firstIndex { $0.start > job.start } ?? queued.endIndex
            queued.insert(job, at: index)
        }
        pump()
    }
    /// Seconds of audio waiting, including the chunk in flight.
    var backlog: Double { lock.withLock { queued.reduce(inFlight?.duration ?? 0) { $0 + $1.duration } } }
    var isIdle: Bool { lock.withLock { queued.isEmpty && inFlight == nil } }
    /// Drops the queue (files stay for recovery) and ignores answers still in flight.
    func stop() { lock.withLock { stopped = true; queued = [] } }
    private func pump() {
        let next: Job? = lock.withLock {
            guard !stopped, inFlight == nil, !queued.isEmpty else { return nil }
            inFlight = queued.removeFirst(); return inFlight
        }
        guard let next else { return }
        transcribe(next.url) { [self] text in
            let retry: Bool = lock.withLock {
                inFlight = nil
                guard !stopped else { return false }
                if text == nil && next.attempts + 1 < Self.attempts {
                    var again = next; again.attempts += 1; queued.insert(again, at: 0); return true
                }
                return false
            }
            if !retry && !lock.withLock({ stopped }) { deliver(next, text) }
            pump()
        }
    }
}

// MARK: - Stream health

/// Watches one stream's delivered audio (a frame or buffer count) and decides when it has stalled
/// and must be rebuilt (PRD 11.2). A call app turning on voice processing, or a headset switching to
/// its call mode, can stop a microphone engine or a tap's aggregate device without an error; the
/// first FaceTime test lost both streams that way. A stall is reported once (one gap), then the
/// stream is rebuilt every `rebuildEvery` seconds until audio flows again.
struct StreamWatch {
    static let stallAfter: TimeInterval = 3
    static let rebuildEvery: TimeInterval = 3
    enum Action: Equatable { case none, stalled, rebuild, recovered(after: Double) }

    private var lastCount: Int64 = 0
    private var lastProgress: TimeInterval
    private var lastRebuild = -TimeInterval.infinity
    private(set) var stalledSince: TimeInterval?

    init(now: TimeInterval) { lastProgress = now }

    /// `idle`: nothing the stream records is producing audio (a tap delivers no buffers while no
    /// tapped app plays), which is not a stall.
    mutating func update(count: Int64, now: TimeInterval, idle: Bool = false) -> Action {
        if count > lastCount || idle {
            lastCount = max(lastCount, count); lastProgress = now
            guard let since = stalledSince else { return .none }
            stalledSince = nil
            return .recovered(after: now - since)
        }
        guard now - lastProgress >= Self.stallAfter else { return .none }
        if stalledSince == nil { stalledSince = lastProgress; return .stalled }
        return now - lastRebuild >= Self.rebuildEvery ? .rebuild : .none
    }

    /// A new capture or tap counts from zero; only its own audio counts as progress.
    mutating func rebuilt(now: TimeInterval) { lastCount = 0; lastRebuild = now }
}

/// The live meters (PRD 11.9): call audio from a tap is often much quieter than the microphone, so
/// each meter is scaled to its own recent loudness, with a floor so silence and hiss stay low. The
/// square root lifts quiet speech, as the dictation bubble does.
struct MeterScale {
    static let floor = 0.05
    /// Per update (about 6–7 a second): the reference falls by about two thirds in 5 s.
    static let decay = 0.97
    private var reference = floor
    mutating func display(_ level: Double) -> Double {
        reference = max(level, reference * Self.decay, Self.floor)
        return min(1, (max(0, level) / reference).squareRoot())
    }
}

// MARK: - Limits

/// The 3-hour cap and the silence rules (PRD 11.3 and 11.4, Q7).
enum MeetingLimits {
    static let cap: TimeInterval = 3 * 60 * 60
    static let warning: TimeInterval = cap - 10 * 60
    static let askEnded: TimeInterval = 5 * 60
    static let stopSilent: TimeInterval = 10 * 60
    /// Above this much queued audio, the live view says the transcript is behind.
    static let behind: TimeInterval = 2 * 60
    /// A level under this counts as silence (the meters' 0–1 scale).
    static let silenceLevel = 0.02

    enum Action: Equatable { case none, warnCap, stopCap, askEnded, stopSilent }
    static func action(elapsed: TimeInterval, silentFor: TimeInterval) -> Action {
        if elapsed >= cap { return .stopCap }
        if silentFor >= stopSilent { return .stopSilent }
        if elapsed >= warning { return .warnCap }
        if silentFor >= askEnded { return .askEnded }
        return .none
    }
}

// MARK: - Consent (PRD 11.3, Q8)

enum MeetingConsent {
    /// Raise when the sheet's text changes, so it is shown again.
    static let version = 1
    static let key = "meetingConsentVersion"
    static func needed(_ defaults: UserDefaults) -> Bool { defaults.integer(forKey: key) < version }
    static func acknowledge(_ defaults: UserDefaults) { defaults.set(version, forKey: key) }

    static let title = "Before your first meeting notes"
    static let body = "Murmur records your microphone and the audio of the call or apps you choose, and transcribes both on this Mac. Recording other people may require their consent where you or they are. You are responsible for letting participants know."
    static let acknowledgement = "I'll let participants know"
    static let reminder = "Let others know you're taking notes."
    /// Copied for the user to paste into the call chat. Murmur never sends it.
    static let notice = "Heads up: I'm taking notes on this call with Murmur, which transcribes the audio on my Mac."
}

// MARK: - Export

enum MeetingExport {
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
    static func label(_ stream: MeetingStream) -> String { stream == .me ? "Me" : "Them" }
    /// Visible lines only: hidden echo is left out of exports.
    static func transcript(_ meeting: Meeting) -> String {
        meeting.lines.filter { !$0.isHidden }.map { "[\(clock($0.start))] \(meeting.label($0)): \($0.visibleText)" }.joined(separator: "\n")
    }
    static func markdown(_ meeting: Meeting) -> String {
        var out = "# \(escape(meeting.title))\n\n"
        out += "- Date: \(ISO8601DateFormatter().string(from: meeting.recordedAt))\n- Length: \(clock(meeting.seconds))\n"
        out += "- Audio: \(meeting.source.micOnly ? "my microphone only" : "my microphone and \(meeting.source.name)")\n"
        out += "- Transcribed: \(meeting.transcribedBy.map { "by \($0)" } ?? "on this Mac")\n"
        if !meeting.speakers.isEmpty { out += "- Speakers: Me, " + meeting.speakers.map { meeting.speakerNames?[String($0)] ?? "Speaker \($0)" }.map(escape).joined(separator: ", ") + "\n" }
        if let notes = meeting.notes, !notes.isEmpty { out += "\n## Notes\n\n" + self.notes(meeting, markdown: true) + "\n" }
        let mine = meeting.myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mine.isEmpty { out += "\n## My notes\n\n\(mine)\n" }
        out += "\n## Transcript\n\n"
        for line in meeting.lines where !line.isHidden {
            out += "**\(escape(meeting.label(line)))** [\(clock(line.start))]: \(escape(line.visibleText))\n\n"
        }
        return out
    }
    /// The generated notes (PRD 11.6) for Copy Notes, or the Markdown export's Notes section. Each
    /// item ends with the time of the first line it cites. Model text is escaped like transcript text.
    static func notes(_ meeting: Meeting, markdown: Bool = false) -> String {
        guard let notes = meeting.notes else { return "" }
        let times = Dictionary(meeting.lines.map { ($0.id, $0.start) }, uniquingKeysWith: { a, _ in a })
        let text: (String) -> String = markdown ? escape : { $0 }
        func item(_ item: NoteItem, box: Bool) -> String {
            var line = (box ? (item.done == true ? "- [x] " : "- [ ] ") : "- ") + text(item.text)
            var extra: [String] = []
            if let owner = item.owner { extra.append(text(owner)) }
            if let due = item.due { extra.append("due " + text(due)) }
            if !extra.isEmpty { line += " (" + extra.joined(separator: ", ") + ")" }
            if let first = item.lines.compactMap({ times[$0] }).min() { line += " [\(clock(first))]" }
            return line
        }
        var sections: [String] = []
        if !markdown { sections.append(meeting.title) }
        if let summary = notes.summary { sections.append(text(summary)) }
        let heading = markdown ? "### " : ""
        if !notes.keyPoints.isEmpty { sections.append(heading + "Key points\n" + notes.keyPoints.map { item($0, box: false) }.joined(separator: "\n")) }
        if !notes.decisions.isEmpty { sections.append(heading + "Decisions\n" + notes.decisions.map { item($0, box: false) }.joined(separator: "\n")) }
        if !notes.actions.isEmpty { sections.append(heading + "Action items\n" + notes.actions.map { item($0, box: true) }.joined(separator: "\n")) }
        sections.append("Written by \(notes.route) from the transcript\(notes.outdated == true ? "; out of date" : "").")
        return sections.joined(separator: "\n\n")
    }
    /// Transcript text is data: a line that starts like Markdown structure stays plain text.
    static func escape(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_").replacingOccurrences(of: "<", with: "\\<")
        if let first = out.first, "#>-+|`".contains(first) { out = "\\" + out }
        return out
    }
    static func fileName(_ meeting: Meeting) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Meeting \(formatter.string(from: meeting.recordedAt)).md"
    }
}

// MARK: - Call apps

/// Known call apps and browsers (PRD 11.2 and 11.7). Used for the Start menu and to resolve which
/// processes play the call's audio. ponytail: bundle IDs and helper IDs are the best known values;
/// list each app's audio processes on the test Mac (PRD 11.10) and correct them there.
struct CallApp: Equatable {
    let bundleID: String
    let name: String
    let isBrowser: Bool
    /// Processes outside the bundle-ID prefix that play this app's audio.
    let helpers: [String]

    /// Whether a process belongs to this app: its own ID, an ID under it (`.helper`), or a known
    /// helper. Case is ignored: Arc is `company.thebrowser.Browser`, its audio helper
    /// `company.thebrowser.browser.helper`.
    func matches(_ id: String) -> Bool {
        let id = id.lowercased(), own = bundleID.lowercased()
        return id == own || id.hasPrefix(own + ".") || helpers.contains { $0.lowercased() == id }
    }

    static let catalog: [CallApp] = [
        CallApp(bundleID: "us.zoom.xos", name: "Zoom", isBrowser: false, helpers: []),
        CallApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams", isBrowser: false, helpers: []),
        CallApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", isBrowser: false, helpers: []),
        CallApp(bundleID: "Cisco-Systems.Spark", name: "Webex", isBrowser: false, helpers: []),
        CallApp(bundleID: "com.apple.FaceTime", name: "FaceTime", isBrowser: false, helpers: ["com.apple.avconferenced"]),
        CallApp(bundleID: "com.hnc.Discord", name: "Discord", isBrowser: false, helpers: []),
        CallApp(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", isBrowser: false, helpers: []),
        CallApp(bundleID: "org.whispersystems.signal-desktop", name: "Signal", isBrowser: false, helpers: []),
        CallApp(bundleID: "ru.keepcoder.Telegram", name: "Telegram", isBrowser: false, helpers: []),
        CallApp(bundleID: "com.apple.Safari", name: "Safari", isBrowser: true, helpers: ["com.apple.WebKit.GPU", "com.apple.WebKit.WebContent"]),
        CallApp(bundleID: "com.google.Chrome", name: "Google Chrome", isBrowser: true, helpers: []),
        CallApp(bundleID: "company.thebrowser.Browser", name: "Arc", isBrowser: true, helpers: []),
        CallApp(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", isBrowser: true, helpers: []),
        CallApp(bundleID: "com.brave.Browser", name: "Brave", isBrowser: true, helpers: []),
        CallApp(bundleID: "org.mozilla.firefox", name: "Firefox", isBrowser: true, helpers: []),
    ]
    static func app(_ bundleID: String) -> CallApp? { catalog.first { $0.bundleID == bundleID } }

    /// Bundle IDs to tap for this app: its own, every running audio process whose ID starts with it
    /// (helpers such as `com.google.Chrome.helper`), and its known out-of-prefix helpers.
    func tapBundleIDs(running: [String]) -> [String] {
        var ids = [bundleID] + helpers
        for id in running where matches(id) && !ids.contains(where: { $0.lowercased() == id.lowercased() }) { ids.append(id) }
        return ids
    }
    /// Murmur and its helpers, excluded from an "All apps" tap.
    static func ownBundleIDs(main: String?, running: [String]) -> [String] {
        guard let main else { return [] }
        return [main] + running.filter { $0.hasPrefix(main + ".") }
    }
}

// MARK: - Call detection (W7c, PRD 11.7, Q5, Q6)

/// Offers meeting notes when a known call app or a browser starts using the microphone. It reads
/// only which processes run audio input: no window titles, URLs or screen, and nothing is stored
/// except the user's "Never" list. It never starts recording; Take Notes does.
struct CallDetector {
    /// Input must run this long before an offer, which filters short voice searches.
    static let settle: TimeInterval = 5
    static let offerLifetime: TimeInterval = 30
    /// ponytail: a mic session survives this long without input (a call app reopening its input
    /// on a device change); tune if one call gets two offers on the test Mac.
    static let grace: TimeInterval = 10
    static let enabledKey = "meetingDetection", neverKey = "meetingDetectionNever"

    /// On unless the user turned it off (Q6).
    static func enabled(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: enabledKey) as? Bool ?? true }
    static func never(_ defaults: UserDefaults) -> [String] { defaults.stringArray(forKey: neverKey) ?? [] }

    struct Offer: Equatable { let app: CallApp; let shownAt: TimeInterval }
    private struct Session { var since: TimeInterval; var lastSeen: TimeInterval; var offered: Bool }
    private var sessions: [String: Session] = [:]
    private(set) var offer: Offer?

    /// The wording (Q5): microphone use, never a claimed call, for browsers and call apps alike.
    static func text(_ app: CallApp) -> String { "\(app.name) is using the microphone. Take meeting notes?" }

    /// The catalog app a process belongs to, or nil (Murmur's own processes included).
    static func app(for bundleID: String, own: String?) -> CallApp? {
        if let own, !own.isEmpty, bundleID.lowercased() == own.lowercased() || bundleID.lowercased().hasPrefix(own.lowercased() + ".") { return nil }
        return CallApp.catalog.first { $0.matches(bundleID) }
    }

    /// Called about once a second. `inputs`: bundle IDs of processes running audio input now.
    /// `meeting`: a meeting is recording, so every current session counts as offered.
    /// `dictating`: no offer while Murmur records a dictation. Returns the offer to show, if any.
    mutating func update(now: TimeInterval, inputs: [String], own: String?, enabled: Bool, never: [String], meeting: Bool, dictating: Bool) -> Offer? {
        let active = Set(inputs.compactMap { Self.app(for: $0, own: own)?.bundleID })
        for id in active {
            if sessions[id] == nil { sessions[id] = Session(since: now, lastSeen: now, offered: false) } else { sessions[id]?.lastSeen = now }
        }
        sessions = sessions.filter { active.contains($0.key) || now - $0.value.lastSeen < Self.grace }
        if meeting { for id in sessions.keys { sessions[id]?.offered = true } }
        if let current = offer, meeting || dictating || !enabled || !active.contains(current.app.bundleID) || now - current.shownAt >= Self.offerLifetime { offer = nil }
        guard offer == nil, enabled, !meeting, !dictating else { return offer }
        let blocked = Set(never.map { $0.lowercased() })
        let ready = sessions.filter { !$0.value.offered && active.contains($0.key) && now - $0.value.since >= Self.settle && !blocked.contains($0.key.lowercased()) }
        guard let next = ready.min(by: { $0.value.since < $1.value.since }), let app = CallApp.app(next.key) else { return nil }
        sessions[next.key]?.offered = true
        offer = Offer(app: app, shownAt: now)
        return offer
    }

    /// Not now, Never or Take Notes: the offer goes; this mic session is not offered again.
    mutating func dismiss() { offer = nil }
}

// MARK: - Speaker separation (W7d, PRD 11.8, Q4)

enum SeparationState: String, Codable { case pending, done, failed, expired }

enum SpeakerSeparation {
    static let key = "meetingSpeakerSeparation"
    /// FluidAudio's clustering threshold, set explicitly (PRD 11.8): about 0.775 in today's units
    /// matches the `--threshold 0.7` run behind its 10.62% AMI result; FluidAudio's default is 0.6.
    static let threshold = 0.775
    /// A Them line is split only where another speaker holds at least this long inside it.
    static let minimumPiece = 1.5

    struct Segment: Equatable { let speaker: Int; let start: Double; let end: Double }

    /// The helper's {"segments":[{"speaker","start","end"}]}, speakers renumbered 1, 2… in order of
    /// first speech. Nil when the answer is not that shape.
    static func parse(_ data: Data) -> [Segment]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let raw = object["segments"] as? [[String: Any]] else { return nil }
        let rows = raw.compactMap { row -> (String, Double, Double)? in
            guard let id = row["speaker"].map({ "\($0)" }), let start = (row["start"] as? NSNumber)?.doubleValue, let end = (row["end"] as? NSNumber)?.doubleValue, end > start else { return nil }
            return (id, start, end)
        }.sorted { $0.1 < $1.1 }
        var numbers: [String: Int] = [:]
        return rows.map { row in
            let n = numbers[row.0] ?? (numbers.count + 1); numbers[row.0] = n
            return Segment(speaker: n, start: row.1, end: row.2)
        }
    }

    /// Each Them line's one speaker, or the pieces it must be re-transcribed in. Lines nobody
    /// overlaps keep no speaker.
    static func plan(_ lines: [MeetingLine], segments: [Segment]) -> (speakers: [Int: Int], splits: [Int: [Segment]]) {
        var speakers: [Int: Int] = [:], splits: [Int: [Segment]] = [:]
        for line in lines where line.stream == .them {
            let found = pieces(start: line.start, end: line.end, segments: segments)
            if found.count == 1 { speakers[line.id] = found[0].speaker } else if found.count > 1 { splits[line.id] = found }
        }
        return (speakers, splits)
    }

    /// Who speaks in `start..<end`: consecutive pieces, each at least `minimumPiece` long (shorter
    /// ones join their neighbour), cut at the middle of the gap between speakers and stretched to
    /// the line's ends. One piece means the line is not split. Empty when nobody overlaps it.
    static func pieces(start: Double, end: Double, segments: [Segment]) -> [Segment] {
        var runs: [Segment] = []
        for segment in segments where segment.end > start && segment.start < end {
            let clipped = Segment(speaker: segment.speaker, start: max(start, segment.start), end: min(end, segment.end))
            if let last = runs.last, last.speaker == clipped.speaker { runs[runs.count - 1] = Segment(speaker: last.speaker, start: last.start, end: max(last.end, clipped.end)) }
            else { runs.append(clipped) }
        }
        // Fold short runs into the longer neighbour until every run is long enough (or one is left).
        while runs.count > 1, let shortest = runs.indices.min(by: { runs[$0].end - runs[$0].start < runs[$1].end - runs[$1].start }),
              runs[shortest].end - runs[shortest].start < minimumPiece {
            let left = shortest > 0 ? shortest - 1 : nil, right = shortest + 1 < runs.count ? shortest + 1 : nil
            let into = [left, right].compactMap { $0 }.max { runs[$0].end - runs[$0].start < runs[$1].end - runs[$1].start }!
            let merged = Segment(speaker: runs[into].speaker, start: min(runs[into].start, runs[shortest].start), end: max(runs[into].end, runs[shortest].end))
            runs[into] = merged; runs.remove(at: shortest)
            // Neighbours that now share a speaker become one run.
            var i = 1
            while i < runs.count { if runs[i].speaker == runs[i - 1].speaker { runs[i - 1] = Segment(speaker: runs[i].speaker, start: runs[i - 1].start, end: runs[i].end); runs.remove(at: i) } else { i += 1 } }
        }
        guard !runs.isEmpty else { return [] }
        var out: [Segment] = []
        for (i, run) in runs.enumerated() {
            let from = i == 0 ? start : (runs[i - 1].end + run.start) / 2
            let to = i == runs.count - 1 ? end : (run.end + runs[i + 1].start) / 2
            out.append(Segment(speaker: run.speaker, start: from, end: to))
        }
        return out
    }
}

extension Meeting {
    /// Applies a separation result: each Them line takes its one speaker, or is replaced by
    /// re-transcribed pieces (`split[lineID]`, text per piece). Echo is re-run, since Me's hidden
    /// text depends on Them's. Written notes are marked out of date.
    mutating func applySpeakers(_ speakers: [Int: Int], split: [Int: [(speaker: Int, start: Double, end: Double, text: String)]]) {
        var next = (lines.map(\.id).max() ?? 0) + 1
        var out: [MeetingLine] = []
        for line in lines {
            guard line.stream == .them else { out.append(line); continue }
            if let pieces = split[line.id] {
                for piece in pieces where !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var made = MeetingLine(id: next, stream: .them, start: piece.start, end: piece.end, text: piece.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    made.speaker = piece.speaker; made.localFallback = line.localFallback
                    out.append(made); next += 1
                }
            } else {
                var line = line; line.speaker = speakers[line.id] ?? line.speaker; out.append(line)
            }
        }
        lines = out.sorted { $0.start < $1.start || ($0.start == $1.start && $0.stream == .them) }
        MeetingEcho.apply(&lines, near: -.infinity, to: .infinity)
        separation = .done
        if notes != nil { notes?.outdated = true }
    }

    /// Renaming, merging and reassigning (PRD 11.8) mark written notes out of date (11.6).
    mutating func renameSpeaker(_ speaker: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = speakerNames ?? [:]
        names[String(speaker)] = trimmed.isEmpty ? nil : trimmed
        speakerNames = names.isEmpty ? nil : names
        if notes != nil { notes?.outdated = true }
    }
    mutating func mergeSpeaker(_ speaker: Int, into other: Int) {
        guard speaker != other else { return }
        for i in lines.indices where lines[i].speaker == speaker { lines[i].speaker = other }
        speakerNames?[String(speaker)] = nil
        if notes != nil { notes?.outdated = true }
    }
    mutating func reassign(line id: Int, to speaker: Int) {
        guard let i = lines.firstIndex(where: { $0.id == id && $0.stream == .them }) else { return }
        lines[i].speaker = speaker
        if notes != nil { notes?.outdated = true }
    }
}
