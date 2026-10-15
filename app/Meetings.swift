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

    var title: String {
        let date = DateFormatter.localizedString(from: recordedAt, dateStyle: .medium, timeStyle: .short)
        if source.micOnly { return "Meeting notes, \(date)" }
        return source.allApps ? "Meeting, \(date)" : "Meeting with \(source.name), \(date)"
    }

    /// Inserts a transcribed line in capture-time order and re-runs echo suppression near it.
    mutating func insert(stream: MeetingStream, start: Double, end: Double, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let line = MeetingLine(id: (lines.map(\.id).max() ?? 0) + 1, stream: stream, start: start, end: end, text: trimmed)
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
    static func purge(_ root: URL, keep: Set<String>, now: Date = Date()) {
        let fm = FileManager.default
        for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard keep.contains(folder.lastPathComponent) else { try? fm.removeItem(at: folder); continue }
            for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
                let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                if parse(file) == nil || now.timeIntervalSince(created) >= RetryWindow.lifetime || created > now { try? fm.removeItem(at: file) }
            }
            if ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty { try? fm.removeItem(at: folder) }
        }
    }
}

/// The PRD's 24-hour retry-audio window (section 6), restated here so this file stays Foundation-only.
enum RetryWindow { static let lifetime: TimeInterval = 24 * 60 * 60 }

// MARK: - Transcription pump

/// One queue for both streams' chunks. Only one chunk is with the warm helper at a time, so a
/// dictation waits for at most one chunk (PRD 11.4); chunks go in the order they were recorded.
/// A chunk that fails twice is left on disk for "Finish transcript"; nothing is dropped.
final class MeetingPump: @unchecked Sendable {
    struct Job: Equatable { let stream: MeetingStream; let url: URL; let start: Double; let duration: Double; var attempts = 0 }
    private let lock = NSLock()
    private var queued: [Job] = [], inFlight: Job?, stopped = false
    private let transcribe: (URL, @escaping (String?) -> Void) -> Void
    private let deliver: (Job, String?) -> Void
    static let attempts = 2

    /// `transcribe(url, completion)` answers the text or nil; `deliver(job, text)` gets nil after the last attempt.
    init(transcribe: @escaping (URL, @escaping (String?) -> Void) -> Void, deliver: @escaping (Job, String?) -> Void) {
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
        meeting.lines.filter { !$0.isHidden }.map { "[\(clock($0.start))] \(label($0.stream)): \($0.visibleText)" }.joined(separator: "\n")
    }
    static func markdown(_ meeting: Meeting) -> String {
        var out = "# \(meeting.title)\n\n"
        out += "- Date: \(ISO8601DateFormatter().string(from: meeting.recordedAt))\n- Length: \(clock(meeting.seconds))\n"
        out += "- Audio: \(meeting.source.micOnly ? "my microphone only" : "my microphone and \(meeting.source.name)")\n"
        let notes = meeting.myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { out += "\n## My notes\n\n\(notes)\n" }
        out += "\n## Transcript\n\n"
        for line in meeting.lines where !line.isHidden {
            out += "**\(label(line.stream))** [\(clock(line.start))]: \(escape(line.visibleText))\n\n"
        }
        return out
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
        for id in running where id.hasPrefix(bundleID + ".") && !ids.contains(id) { ids.append(id) }
        return ids
    }
    /// Murmur and its helpers, excluded from an "All apps" tap.
    static func ownBundleIDs(main: String?, running: [String]) -> [String] {
        guard let main else { return [] }
        return [main] + running.filter { $0.hasPrefix(main + ".") }
    }
}
