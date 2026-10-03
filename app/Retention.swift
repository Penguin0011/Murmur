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

    /// Bytes of regular files directly inside `directory` (entries plus any stray temporaries).
    static func usage(directory: URL) throws -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for name in try fm.contentsOfDirectory(atPath: directory.path) {
            let attrs = try fm.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
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

/// History-off keeps results only in memory for the running session.
enum HistoryMode: String, Codable {
    case on, off

    var persistsTranscripts: Bool { self == .on }

    static let offDisclosure = "With history off, Murmur does not save transcripts to disk. If insertion fails and Murmur quits or stops unexpectedly, that text cannot be recovered. Turning history off does not delete existing history; delete it separately."
}

/// Where Murmur keeps user data. The dictionary and ledger may share one directory.
struct MurmurDataLocations {
    var history: URL
    var dictionary: URL
    var ledger: URL
    var retryAudio: URL

    /// Matches Controller's layout under Application Support/Dictation.
    static func standard(base: URL) -> MurmurDataLocations {
        let dictionary = base.appendingPathComponent("dictionary")
        return MurmurDataLocations(history: base.appendingPathComponent("history"), dictionary: dictionary,
                                   ledger: dictionary, retryAudio: base.appendingPathComponent("retry-audio"))
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
    /// Removes history, dictionary, ledger and retry-audio directories, then calls
    /// `removeKeychainItems` (which returns the item names it removed). Continues past failures
    /// and reports them. In-memory stores must be reloaded or discarded afterwards
    /// (`DictionaryStore.reload()`, `CorrectionLedger.reload()`, a new `HistoryStore`).
    /// Deletion is a filesystem unlink; backups or snapshots may still hold copies.
    static func deleteAllData(_ locations: MurmurDataLocations,
                              removeKeychainItems: () throws -> [String]) -> DeleteAllReport {
        var report = DeleteAllReport()
        var seen = Set<String>()
        let fm = FileManager.default
        for url in [locations.history, locations.dictionary, locations.ledger, locations.retryAudio] {
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
