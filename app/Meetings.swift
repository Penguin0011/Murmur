import Foundation
import Darwin

// Meeting notetaker, W7a (PRD section 11): the record, its storage, line ordering, echo masking,
// the cap and silence clock, the helper queue's two lanes and the consent version. Foundation only,
// so check_meetings.swift builds against this file alone. Capture lives in MeetingCapture.swift.

enum MeetingStream: String, Codable { case me, them }

struct MeetingError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// One transcribed chunk. Times are seconds from the meeting's start, taken from the capture clock,
/// so lines sort by when they were said, not when transcription finished (11.4). `text` is never
/// altered; echo is hidden at display and export time (`EchoMask`).
struct MeetingLine: Codable, Equatable {
    /// Unique within its meeting; W7b cites lines by it.
    let id: Int
    let stream: MeetingStream
    let start: Double
    let end: Double
    let text: String
    /// A capture gap (the tap or microphone stopped and restarted); `text` is empty.
    var gap: Bool? = nil
}

/// Everything about a meeting except its lines. W7b (notes) and W7d (speakers) add optional fields;
/// `schema` rises only if a field changes meaning.
struct MeetingRecord: Codable, Equatable {
    static let schemaVersion = 1
    var schema = MeetingRecord.schemaVersion
    let id: String
    let startedAt: Date
    /// The call app's name, or nil for All apps or microphone only.
    var sourceApp: String?
    var sourceBundleID: String?
    var them: MeetingSource.Kind
    var seconds: Double = 0
    var myNotes = ""
    /// False while recording. A record still false at launch was cut short by a crash.
    var ended = false
    var interrupted: Bool? = nil

    var title: String {
        let day = DateFormatter.localizedString(from: startedAt, dateStyle: .medium, timeStyle: .none)
        return sourceApp.map { "Meeting with \($0), \(day)" } ?? "Meeting, \(day)"
    }
}

struct Meeting: Equatable {
    var record: MeetingRecord
    /// Sorted by capture time.
    var lines: [MeetingLine]
}

/// What "Them" captures (Q1).
struct MeetingSource: Equatable {
    enum Kind: String, Codable { case app, allApps, none }
    let kind: Kind
    var bundleID: String? = nil
    var name: String? = nil

    static let allApps = MeetingSource(kind: .allApps)
    static let microphoneOnly = MeetingSource(kind: .none)
    static func app(_ bundleID: String, _ name: String) -> MeetingSource { MeetingSource(kind: .app, bundleID: bundleID, name: name) }
}

/// Call apps and browsers offered in the Start menu (and, in W7c, watched for microphone use).
/// Most apps play audio from helpers whose bundle ID starts with the app's. Safari and FaceTime do
/// not: on this Mac, Safari's audio comes from com.apple.WebKit.GPU (shared by every WebKit app)
/// and FaceTime's from com.apple.avconferenced (PRD note, October 15, 2026).
enum MeetingApps {
    struct App: Equatable { let bundleID: String; let name: String; var extra: [String] = []; var browser = false }
    static let known: [App] = [
        App(bundleID: "us.zoom.xos", name: "Zoom"),
        App(bundleID: "com.microsoft.teams2", name: "Microsoft Teams"),
        App(bundleID: "com.microsoft.teams", name: "Microsoft Teams (classic)"),
        App(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
        App(bundleID: "com.cisco.webexmeetingsapp", name: "Webex"),
        App(bundleID: "Cisco-Systems.Spark", name: "Webex"),
        App(bundleID: "com.apple.FaceTime", name: "FaceTime", extra: ["com.apple.avconferenced"]),
        App(bundleID: "com.hnc.Discord", name: "Discord"),
        App(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp"),
        App(bundleID: "org.whispersystems.signal-desktop", name: "Signal"),
        App(bundleID: "ru.keepcoder.Telegram", name: "Telegram"),
        App(bundleID: "com.apple.Safari", name: "Safari", extra: ["com.apple.WebKit"], browser: true),
        App(bundleID: "com.google.Chrome", name: "Google Chrome", browser: true),
        App(bundleID: "company.thebrowser.Browser", name: "Arc", browser: true),
        App(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", browser: true),
        App(bundleID: "com.brave.Browser", name: "Brave", browser: true),
        App(bundleID: "org.mozilla.firefox", name: "Firefox", browser: true),
    ]
    /// Whether an audio process with `processBundleID` belongs to the app `bundleID`.
    static func owns(_ bundleID: String, process processBundleID: String) -> Bool {
        ([bundleID] + (known.first { $0.bundleID == bundleID }?.extra ?? [])).contains { processBundleID.hasPrefix($0) }
    }
    /// What the live view adds about the source.
    static func note(_ source: MeetingSource) -> String? {
        switch source.kind {
        case .allApps: return "Recording all apps’ sound, including music, videos and notifications."
        case .none: return "Recording only your microphone."
        case .app where source.bundleID == "com.apple.Safari": return "Safari’s sound is shared with other apps that show web pages, such as Mail, so their sound is recorded too."
        case .app: return nil
        }
    }
}

// MARK: - Ordering

enum MeetingTranscript {
    /// Inserts by capture time; a Me and a Them line starting together keep Me first.
    static func insert(_ line: MeetingLine, into lines: inout [MeetingLine]) {
        let index = lines.firstIndex { ($0.start, $0.stream == .me ? 0 : 1, $0.id) > (line.start, line.stream == .me ? 0 : 1, line.id) } ?? lines.endIndex
        lines.insert(line, at: index)
    }
    static func sorted(_ lines: [MeetingLine]) -> [MeetingLine] {
        var out: [MeetingLine] = []
        for line in lines { insert(line, into: &out) }
        return out
    }
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

// MARK: - Echo (11.2)

/// With speakers, the microphone also hears the other side, so their words show up in Me too. A run
/// of `minRun` Me words that repeats a Them run said within `slack` seconds is hidden (never deleted).
/// Them is never altered. Computed over the lines each time, since a Them line often finishes after
/// the Me line it echoes.
enum EchoMask {
    // ponytail: fixed run length and window, set before measurement; tune on the 5 speaker calls (11.10).
    static let minRun = 4
    static let slack: Double = 3

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { String($0.lowercased().filter { $0.isLetter || $0.isNumber }) }
    }

    /// Hidden word indices per Me line id. A line whose words are all hidden is hidden.
    static func hidden(_ lines: [MeetingLine]) -> [Int: Set<Int>] {
        let them = lines.filter { $0.stream == .them && $0.gap != true }
        var result: [Int: Set<Int>] = [:]
        for line in lines where line.stream == .me && line.gap != true {
            let near = them.filter { $0.start <= line.end + slack && $0.end >= line.start - slack }
            guard !near.isEmpty else { continue }
            let theirs = near.flatMap { words($0.text) }.filter { !$0.isEmpty }
            guard theirs.count >= minRun else { continue }
            let runs = Set((0...(theirs.count - minRun)).map { theirs[$0..<$0 + minRun].joined(separator: " ") })
            let mine = words(line.text)
            // Indices of real words, so punctuation-only tokens neither break nor make a run.
            let real = mine.indices.filter { !mine[$0].isEmpty }
            guard real.count >= minRun else { continue }
            var marked = Set<Int>()
            for i in 0...(real.count - minRun) where runs.contains(real[i..<i + minRun].map { mine[$0] }.joined(separator: " ")) {
                marked.formUnion(real[i..<i + minRun])
            }
            if !marked.isEmpty { result[line.id] = marked.union(mine.indices.filter { mine[$0].isEmpty && marked.contains($0 - 1) }) }
        }
        return result
    }

    /// The line's text without hidden words, or nil when nothing of its own is left.
    static func visibleText(_ line: MeetingLine, hidden: Set<Int>?) -> String? {
        guard let hidden, !hidden.isEmpty else { return line.text }
        let tokens = line.text.split(whereSeparator: \.isWhitespace)
        let kept = tokens.indices.filter { !hidden.contains($0) }.map { String(tokens[$0]) }
        return kept.contains(where: { $0.contains(where: { $0.isLetter || $0.isNumber }) }) ? kept.joined(separator: " ") : nil
    }
}

// MARK: - Cap and silence (11.3, 11.4, Q7)

enum MeetingClock {
    static let cap: TimeInterval = 3 * 3600
    static let warning: TimeInterval = cap - 10 * 60
    static let askAfterSilence: TimeInterval = 5 * 60
    static let stopAfterSilence: TimeInterval = 10 * 60
    /// Above this level (Capture's 0–1 scale) a stream counts as not silent.
    // ponytail: one fixed level for both streams; tune on real calls if room noise keeps it above.
    static let voiceLevel = 0.02
    /// Queued meeting audio past which the live view says the transcript is behind.
    static let behindSeconds: Double = 120

    enum Stop: Equatable { case cap, silence }
    struct State: Equatable { var warn = false; var askEnded = false; var stop: Stop? = nil }

    /// `silent`: seconds since either stream was last above `voiceLevel`.
    static func evaluate(elapsed: TimeInterval, silent: TimeInterval) -> State {
        if elapsed >= cap { return State(warn: true, stop: .cap) }
        if silent >= stopAfterSilence { return State(warn: elapsed >= warning, askEnded: true, stop: .silence) }
        return State(warn: elapsed >= warning, askEnded: silent >= askAfterSilence)
    }
}

/// When each stream last had voice, on the meeting's clock.
struct SilenceTracker {
    private(set) var lastVoice: Double = 0
    mutating func hear(level: Double, at time: Double) { if level >= MeetingClock.voiceLevel { lastVoice = max(lastVoice, time) } }
    func silent(at time: Double) -> Double { max(0, time - lastVoice) }
}

// MARK: - Helper queue (Q2)

/// One warm helper serves dictation and both meeting streams. Dictation requests take the urgent lane
/// and run before any queued meeting chunk; meeting chunks run in the order they were queued. Each
/// pop happens when the helper is free, so at most the chunk already running delays a dictation.
struct HelperLanes<Job> {
    private var urgent: [Job] = [], background: [Job] = []
    mutating func push(_ job: Job, urgent isUrgent: Bool) { if isUrgent { urgent.append(job) } else { background.append(job) } }
    mutating func pop() -> Job? {
        if !urgent.isEmpty { return urgent.removeFirst() }
        return background.isEmpty ? nil : background.removeFirst()
    }
    var count: Int { urgent.count + background.count }
}

// MARK: - Consent (11.3, Q8)

enum MeetingConsent {
    /// Raise when `sheetBody` changes enough that everyone should acknowledge it again.
    static let version = 1
    static let key = "meetingConsentVersion"
    static func needed(_ defaults: UserDefaults) -> Bool { defaults.integer(forKey: key) < version }
    static func acknowledge(_ defaults: UserDefaults) { defaults.set(version, forKey: key) }

    static let sheetTitle = "Before your first meeting notes"
    static let sheetBody = "Murmur records your microphone and the call’s sound, and turns both into a transcript on this Mac. Recording other people may require their consent where you or they are. Murmur does not give legal advice. You are responsible for telling the people in the call."
    static let checkbox = "I’ll let participants know"
    static let reminder = "Let others know you’re taking notes"
    /// Copied for the user to paste into the call's chat. Murmur never sends it.
    static let notice = "Heads up: I’m taking notes on this call with Murmur, which transcribes it on my Mac."
}

// MARK: - Storage (11.5)

/// One append-only file per meeting, `<id>.jsonl`, in `history/meetings/`: record lines and transcript
/// lines as they arrive, so a crash keeps everything already transcribed. The last record wins. With
/// History off, meetings live in memory until Murmur quits.
final class MeetingStore: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var memory: [String: Meeting] = [:]
    var persists: Bool

    init(directory: URL, persists: Bool) throws {
        self.directory = directory; self.persists = persists
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw MeetingError("Meetings require a real directory") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private enum Item: Codable { case record(MeetingRecord), line(MeetingLine)
        private enum Key: String, CodingKey { case record, line }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            if let r = try c.decodeIfPresent(MeetingRecord.self, forKey: .record) { self = .record(r) } else { self = .line(try c.decode(MeetingLine.self, forKey: .line)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            switch self { case .record(let r): try c.encode(r, forKey: .record); case .line(let l): try c.encode(l, forKey: .line) }
        }
    }
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    private func file(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw MeetingError("Invalid meeting identifier") }
        return directory.appendingPathComponent(id + ".jsonl")
    }
    private func append(_ item: Item, to id: String) throws {
        let url = try file(id)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw MeetingError("Cannot write meeting") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Self.encoder.encode(item) + Data("\n".utf8))
        try handle.close()
    }

    /// Saves a new or changed record. A meeting started with History off stays in memory.
    func save(_ record: MeetingRecord) throws {
        lock.lock()
        if !persists && memory[record.id] == nil && !FileManager.default.fileExists(atPath: (try? file(record.id).path) ?? "") {
            memory[record.id] = Meeting(record: record, lines: [])
        }
        if memory[record.id] != nil { memory[record.id]?.record = record; lock.unlock(); return }
        lock.unlock()
        try append(.record(record), to: record.id)
    }
    func append(_ line: MeetingLine, to id: String) throws {
        lock.lock()
        if memory[id] != nil { MeetingTranscript.insert(line, into: &memory[id]!.lines); lock.unlock(); return }
        lock.unlock()
        try append(.line(line), to: id)
    }

    func load(_ id: String) throws -> Meeting? {
        lock.lock(); let held = memory[id]; lock.unlock()
        if let held { return held }
        let url = try file(id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        var record: MeetingRecord?, lines: [MeetingLine] = []
        // A line cut short by a crash is skipped; everything before it is kept.
        for raw in data.split(separator: UInt8(ascii: "\n")) {
            switch try? Self.decoder.decode(Item.self, from: Data(raw)) {
            case .record(let r): record = r
            case .line(let l): lines.append(l)
            case nil: continue
            }
        }
        return record.map { Meeting(record: $0, lines: MeetingTranscript.sorted(lines)) }
    }
    /// Every meeting, newest first. Unreadable files are skipped.
    func all() -> [Meeting] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        lock.lock(); let held = memory; lock.unlock()
        let stored = names.filter { $0.hasSuffix(".jsonl") }.compactMap { name -> Meeting? in
            let id = String(name.dropLast(6)); return held[id] == nil ? (try? load(id)) ?? nil : nil
        }
        return (stored + held.values).sorted { $0.record.startedAt > $1.record.startedAt }
    }
    func delete(_ id: String) throws {
        lock.lock(); let wasHeld = memory.removeValue(forKey: id) != nil; lock.unlock()
        if wasHeld { return }
        let url = try file(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    /// Retention from each meeting's start time (11.5); `cutoff` nil is Forever. Returns removed ids.
    @discardableResult
    func purge(recordedAtOrBefore cutoff: Date?) throws -> [String] {
        guard let cutoff else { return [] }
        let old = all().filter { $0.record.startedAt <= cutoff }.map(\.record.id)
        for id in old { try delete(id) }
        return old
    }
    /// How many meetings a shorter retention would remove, for the preview before shortening it.
    func count(recordedAtOrBefore cutoff: Date?) -> Int { cutoff.map { c in all().filter { $0.record.startedAt <= c }.count } ?? 0 }
    func clearMemory() { lock.lock(); memory.removeAll(); lock.unlock() }

    /// At launch: a record a crash left unended is closed as interrupted, its length taken from its
    /// last line. Returns the ids closed.
    func closeInterrupted() -> [String] {
        var closed: [String] = []
        for meeting in all() where !meeting.record.ended {
            var record = meeting.record
            record.ended = true; record.interrupted = true
            record.seconds = max(record.seconds, meeting.lines.map(\.end).max() ?? 0)
            if (try? save(record)) != nil { closed.append(record.id) }
        }
        return closed
    }
}

// MARK: - Meeting audio (11.5)

/// Chunk files waiting for transcription, in `retry-audio/meetings/<meeting id>/`, named
/// `<stream>-<start ms>.wav` so a meeting cut short can be finished in order. Each is deleted once
/// its text is saved; anything left after 24 hours is deleted, like other retry audio.
enum MeetingAudio {
    static let lifetime: TimeInterval = 24 * 60 * 60
    static func name(_ stream: MeetingStream, start: Double) -> String { "\(stream.rawValue)-\(Int((start * 1000).rounded())).wav" }
    static func parse(_ name: String) -> (stream: MeetingStream, start: Double)? {
        guard name.hasSuffix(".wav") else { return nil }
        let parts = name.dropLast(4).split(separator: "-")
        guard parts.count == 2, let stream = MeetingStream(rawValue: String(parts[0])), let ms = Int(parts[1]), ms >= 0 else { return nil }
        return (stream, Double(ms) / 1000)
    }
    static func folder(_ root: URL, meeting id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    /// Leftover chunks per meeting id, in capture order.
    static func leftovers(_ root: URL) -> [String: [URL]] {
        var out: [String: [URL]] = [:]
        for id in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where UUID(uuidString: id) != nil {
            let files = ((try? FileManager.default.contentsOfDirectory(at: folder(root, meeting: id), includingPropertiesForKeys: nil)) ?? [])
                .compactMap { url in parse(url.lastPathComponent).map { (url, $0.start) } }.sorted { $0.1 < $1.1 }.map(\.0)
            if !files.isEmpty { out[id] = files }
        }
        return out
    }
    /// Deletes chunks older than `lifetime` and empty folders, except `active`'s folder.
    static func purge(_ root: URL, now: Date = Date(), active: String? = nil) {
        let fm = FileManager.default
        for id in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where id != active {
            let dir = folder(root, meeting: id)
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                if now.timeIntervalSince(created) >= lifetime || created > now { try? fm.removeItem(at: url) }
            }
            if ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty { try? fm.removeItem(at: dir) }
        }
    }
}

// MARK: - Export (11.9)

enum MeetingExport {
    static func length(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(max(minutes, seconds > 0 ? 1 : 0)) min"
    }
    /// Transcript lines with hidden echo left out (and gaps marked), as plain text.
    static func transcript(_ meeting: Meeting) -> String {
        let hidden = EchoMask.hidden(meeting.lines)
        return meeting.lines.compactMap { line -> String? in
            let at = MeetingTranscript.clock(line.start)
            if line.gap == true { return "[\(at)] (gap in recording)" }
            guard let text = EchoMask.visibleText(line, hidden: hidden[line.id]) else { return nil }
            return "[\(at)] \(line.stream == .me ? "Me" : "Them"): \(text)"
        }.joined(separator: "\n")
    }
    /// Title, date, length, source and the user's notes, then the transcript (hidden echo left out).
    static func markdown(_ meeting: Meeting) -> String {
        let r = meeting.record
        var out = "# \(r.title)\n\n"
        out += "- Date: \(DateFormatter.localizedString(from: r.startedAt, dateStyle: .long, timeStyle: .short))\n"
        out += "- Length: \(length(r.seconds))\n"
        out += "- Source: \(r.sourceApp ?? (r.them == .allApps ? "All apps" : "Microphone only"))\n"
        if r.interrupted == true { out += "- Recording was interrupted.\n" }
        let notes = r.myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { out += "\n## My notes\n\n\(notes)\n" }
        out += "\n## Transcript\n\n"
        out += transcript(meeting).split(separator: "\n").map { $0 + "  " }.joined(separator: "\n") + "\n"
        return out
    }
}
