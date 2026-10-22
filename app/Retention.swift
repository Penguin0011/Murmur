import Foundation

// History features beyond time-based expiry (which stays in History.swift's HistoryStore):
// a size cap, a history-off mode, and a "Delete all data" plan. Foundation only; it does not
// depend on History.swift, so it builds in Linux checks. To use the cap with the app's store:
//
//     extension HistoryEntry: RetainedHistoryItem {}
//     try HistoryCap.enforce(entries: store.entries(), directory: store.directory,
//                            retention: HistoryRetention(rawValue: retention) ?? .thirtyDays,
//                            delete: store.delete)

struct RetentionError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The retention strings HistoryStore already accepts.
enum HistoryRetention: String, CaseIterable, Codable {
    case thirtyDays = "30-days"
    case sixMonths = "six-months"
    case forever
}

/// The history fields the cap needs. HistoryEntry already has both.
protocol RetainedHistoryItem {
    var id: String { get }
    var recordedAt: Date { get }
}

enum HistoryCapStatus: Equatable {
    case withinCap(usedBytes: Int64, capBytes: Int64)
    /// Forever retention only: at or above `HistoryCap.warningFraction` of the cap.
    case approachingCap(usedBytes: Int64, capBytes: Int64)
    /// Forever retention (never dropped), or a finite policy whose newest entry alone exceeds the cap.
    case overCap(usedBytes: Int64, capBytes: Int64)

    var usedBytes: Int64 {
        switch self {
        case .withinCap(let used, _), .approachingCap(let used, _), .overCap(let used, _): return used
        }
    }

    /// User-facing warning, or nil when no warning is needed.
    var warning: String? {
        switch self {
        case .withinCap: return nil
        case .approachingCap(let used, let cap):
            return "History uses \(HistoryCap.megabytes(used)) of \(HistoryCap.megabytes(cap)). With Forever retention, Murmur does not remove old entries. Delete entries you no longer need."
        case .overCap(let used, let cap):
            return "History uses \(HistoryCap.megabytes(used)), above the \(HistoryCap.megabytes(cap)) limit. With Forever retention, Murmur does not remove old entries. Delete entries or choose a shorter retention period."
        }
    }
}

struct HistoryCapResult<Item> {
    let status: HistoryCapStatus
    /// Entries dropped, oldest first.
    let dropped: [Item]
}

enum HistoryCap {
    /// 50 MB, counted as 50 × 1024 × 1024 bytes.
    static let defaultCapBytes: Int64 = 50 * 1024 * 1024
    static let warningFraction = 0.9

    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// Bytes of history files, including quarantined data; symbolic links are not followed.
    static func usage(directory: URL) throws -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for name in try fm.contentsOfDirectory(atPath: directory.path) {
            // Diagnostic recordings are not transcripts: they expire after 7 days on their own, and counting
            // them would make the cap delete transcript History to make room for audio it cannot remove.
            if name == DiagnosticRecordings.folderName { continue }
            let file = directory.appendingPathComponent(name)
            let attrs = try fm.attributesOfItem(atPath: file.path)
            if attrs[.type] as? FileAttributeType == .typeDirectory { total += try usage(directory: file); continue }
            guard attrs[.type] as? FileAttributeType == .typeRegular else { continue }
            total += (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }
        return total
    }

    /// Pure plan. Finite retention drops oldest entries until usage fits, always keeping the newest
    /// entry (it may be the only copy of a just-failed insertion). Forever never drops; it warns.
    static func plan<Item: RetainedHistoryItem>(entries: [Item], sizes: [String: Int64], otherBytes: Int64 = 0,
                                                retention: HistoryRetention,
                                                capBytes: Int64 = defaultCapBytes) -> HistoryCapResult<Item> {
        var used = otherBytes + entries.reduce(0) { $0 + (sizes[$1.id] ?? 0) }
        if retention == .forever {
            let status: HistoryCapStatus
            if used > capBytes { status = .overCap(usedBytes: used, capBytes: capBytes) }
            else if Double(used) >= Double(capBytes) * warningFraction { status = .approachingCap(usedBytes: used, capBytes: capBytes) }
            else { status = .withinCap(usedBytes: used, capBytes: capBytes) }
            return HistoryCapResult(status: status, dropped: [])
        }
        let oldestFirst = entries.sorted { $0.recordedAt < $1.recordedAt }
        var dropped: [Item] = []
        for item in oldestFirst.dropLast() where used > capBytes {
            used -= sizes[item.id] ?? 0
            dropped.append(item)
        }
        let status: HistoryCapStatus = used > capBytes ? .overCap(usedBytes: used, capBytes: capBytes)
                                                       : .withinCap(usedBytes: used, capBytes: capBytes)
        return HistoryCapResult(status: status, dropped: dropped)
    }

    /// Measures `<id>.json` files in `directory`, then deletes the planned entries through `delete`
    /// (pass `HistoryStore.delete`). Stops at the first failed deletion and rethrows.
    @discardableResult
    static func enforce<Item: RetainedHistoryItem>(entries: [Item], directory: URL, retention: HistoryRetention,
                                                   capBytes: Int64 = defaultCapBytes,
                                                   delete: (Item) throws -> Void) throws -> HistoryCapResult<Item> {
        let sizes = try entrySizes(entries, directory: directory)
        let other = max(0, try usage(directory: directory) - sizes.values.reduce(0, +))
        let result = plan(entries: entries, sizes: sizes, otherBytes: other, retention: retention, capBytes: capBytes)
        for item in result.dropped { try delete(item) }
        return result
    }

    /// Current status without deleting anything (e.g. for the History settings row).
    static func capStatus<Item: RetainedHistoryItem>(entries: [Item], directory: URL, retention: HistoryRetention,
                                                     capBytes: Int64 = defaultCapBytes) throws -> HistoryCapStatus {
        let used = try usage(directory: directory)
        if retention == .forever {
            return plan(entries: [Item](), sizes: [:], otherBytes: used, retention: .forever, capBytes: capBytes).status
        }
        let sizes = try entrySizes(entries, directory: directory)
        return plan(entries: entries, sizes: sizes, otherBytes: max(0, used - sizes.values.reduce(0, +)),
                    retention: retention, capBytes: capBytes).status
    }

    private static func entrySizes<Item: RetainedHistoryItem>(_ entries: [Item], directory: URL) throws -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for item in entries {
            guard UUID(uuidString: item.id) != nil else { throw RetentionError("Invalid history identifier") }
            let path = directory.appendingPathComponent(item.id + ".json").path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               attrs[.type] as? FileAttributeType == .typeRegular {
                sizes[item.id] = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return sizes
    }
}

/// Optional recordings kept for diagnostics (off by default): the WAV the app would delete after a
/// successful transcription is copied into `history/recordings`, linked from its History entry by file
/// name, and purged after 7 days. `directory` is nil while the setting is off, so nothing is kept.
/// Safe to read from any thread: the transcription callbacks run off the main actor.
final class DiagnosticRecordings: @unchecked Sendable {
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    static let folderName = "recordings"
    static func directory(inHistory history: URL) -> URL { history.appendingPathComponent(folderName, isDirectory: true) }
    private let lock = NSLock()
    private var target: URL?
    var directory: URL? {
        get { lock.lock(); defer { lock.unlock() }; return target }
        set { lock.lock(); target = newValue; lock.unlock() }
    }

    /// Copies `audio` to `<entry id>.wav` (owner-only) and returns its file name, or nil when off or on any failure.
    /// A copy, not a move: if saving the entry fails, the retry audio is still there.
    func keep(_ audio: URL, entryID: String) -> String? {
        guard let directory, UUID(uuidString: entryID) != nil else { return nil }
        let name = entryID + ".wav", destination = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: audio, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: Date()], ofItemAtPath: destination.path)
            return name
        } catch { try? FileManager.default.removeItem(at: destination); return nil }
    }

    /// Removes recordings older than `lifetime`. Runs whether or not the setting is still on.
    static func purge(history: URL, now: Date = Date()) throws {
        let folder = directory(inHistory: history)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where file.pathExtension == "wav" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(modified) >= lifetime || modified > now { try FileManager.default.removeItem(at: file) }
        }
    }
}

/// History-off keeps results only in memory for the running session.
enum HistoryMode: String, Codable {
    case on, off

    var persistsTranscripts: Bool { self == .on }

    static let offDisclosure = "With history off, Murmur does not save transcript history to disk. If insertion fails and Murmur quits or stops unexpectedly, that text cannot be recovered. Retry audio can still remain for up to 24 hours, and learning can still save spellings in your dictionary. Turning history off does not delete existing history; delete it separately."
}

/// Where Murmur keeps user data. The dictionary and ledger may share one directory.
struct MurmurDataLocations {
    var history: URL
    var dictionary: URL
    var ledger: URL
    var retryAudio: URL
    var chunks: URL

    /// Matches Controller's layout under Application Support/Dictation.
    static func standard(base: URL) -> MurmurDataLocations {
        let dictionary = base.appendingPathComponent("dictionary")
        return MurmurDataLocations(history: base.appendingPathComponent("history"), dictionary: dictionary,
                                   ledger: dictionary, retryAudio: base.appendingPathComponent("retry-audio"), chunks: base.appendingPathComponent("chunks"))
    }
}

struct DeleteAllReport {
    var removed: [URL] = []
    /// Locations that did not exist (nothing to delete).
    var absent: [URL] = []
    var keychainItems: [String] = []
    var failures: [String] = []
    var succeeded: Bool { failures.isEmpty }
}

enum DataWipe {
    /// Removes history, dictionary, ledger, retry audio and chunk directories, then calls
    /// `removeKeychainItems` (which returns the item names it removed). Continues past failures
    /// and reports them. In-memory stores must be reloaded or discarded afterwards
    /// (`DictionaryStore.reload()`, `CorrectionLedger.reload()`, a new `HistoryStore`).
    /// Deletion is a filesystem unlink; backups or snapshots may still hold copies.
    static func deleteAllData(_ locations: MurmurDataLocations,
                              removeKeychainItems: () throws -> [String]) -> DeleteAllReport {
        var report = DeleteAllReport()
        var seen = Set<String>()
        let fm = FileManager.default
        for url in [locations.history, locations.dictionary, locations.ledger, locations.retryAudio, locations.chunks] {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            guard (try? fm.attributesOfItem(atPath: path)) != nil else { report.absent.append(url); continue }
            do { try fm.removeItem(atPath: path); report.removed.append(url) }
            catch { report.failures.append("Could not delete \(url.lastPathComponent): \(error.localizedDescription)") }
        }
        do { report.keychainItems = try removeKeychainItems() }
        catch { report.failures.append("Could not remove Keychain items: \(error.localizedDescription)") }
        return report
    }
}
