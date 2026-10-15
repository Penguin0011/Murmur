import Foundation

// App-level decisions that sit between the Foundation modules (ModelDownload, Retention, Updates)
// and Controller/UI. Foundation only, so app/check_app_services.swift runs on Linux. Controller keeps
// only the AppKit calls (alerts, NSWorkspace) and the wiring.

// MARK: - Model row (PRD R2)

// TODO(R2): show measured on-device performance in the row and offer model selection once a
// second model is pinned; only Parakeet Unified is pinned today.
enum ModelFacts {
    static let displayName = "Parakeet Unified English 0.6B"
    static let language = "English"
    static let location = "Runs on this Mac"

    /// The folder existing installs already use, so a model placed there before is recognized.
    static func defaultDirectory(home: URL) -> URL {
        home.appendingPathComponent("Library/Caches/Dictation/module-one/unified-d32e972")
    }

    /// Decimal units, as Finder shows download sizes: 1,801,783,964 bytes is "1.80 GB".
    static func formatBytes(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        if value >= 1_000_000_000 { return String(format: "%.2f GB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.0f MB", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0f KB", value / 1_000) }
        return "\(Int64(value)) bytes"
    }

    /// "1.80 GB download · English · Runs on this Mac"
    static func summary(downloadSize: Int64) -> String {
        "\(formatBytes(downloadSize)) download · \(language) · \(location)"
    }

    /// One line per declaration, with its link, then the note (which says when the license is unresolved).
    static func licenseText(_ license: ModelLicenseInfo) -> String {
        var lines = license.declarations.map { "\($0.name) (\($0.source)): \($0.url.absoluteString)" }
        lines.append(license.note)
        return lines.joined(separator: "\n")
    }

    /// Shown before any byte is downloaded.
    static func confirmation(downloadSize: Int64, license: ModelLicenseInfo) -> (title: String, body: String) {
        ("Download \(displayName) (\(formatBytes(downloadSize)))?",
         "Murmur downloads \(formatBytes(downloadSize)) from Hugging Face and checks every file against its pinned checksum. After that, transcription runs on this Mac without the network.\n\nLicense:\n\(licenseText(license))")
    }

    static func completionMessage(_ result: Result<Void, ModelDownloadError>) -> String {
        switch result {
        case .success: return "The model is downloaded and verified. Murmur is ready to dictate."
        case .failure(.cancelled): return "The download was cancelled. Retry continues from the files already downloaded."
        case .failure(let error): return error.userMessage
        }
    }
}

/// The CTC model that rescores on-device transcripts toward the dictionary (FluidAudio vocabulary
/// boosting). It lives in FluidAudio's own cache folder, because FluidAudio's rescorer reads the CTC
/// tokenizer only from there; that folder can be shared with other apps built on FluidAudio, so
/// Murmur checks it against the pinned hashes before every use and runs without it otherwise.
enum DictionaryModelFacts {
    static let displayName = "Dictionary support for on-device transcription"
    static let modelName = "Parakeet CTC 110M"

    static func directory(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/FluidAudio/Models/parakeet-ctc-110m-coreml")
    }

    /// "Parakeet CTC 110M · 103 MB download · Runs on this Mac"
    static func summary(downloadSize: Int64) -> String {
        "\(modelName) · \(ModelFacts.formatBytes(downloadSize)) download · \(ModelFacts.location)"
    }

    static let explanation = "Helps on-device transcription spell your dictionary words without touching everyday English. Your words stay on this Mac."

    static func confirmation(downloadSize: Int64, license: ModelLicenseInfo, folder: URL) -> (title: String, body: String) {
        ("Download \(modelName) (\(ModelFacts.formatBytes(downloadSize)))?",
         "Murmur downloads \(ModelFacts.formatBytes(downloadSize)) from Hugging Face and checks every file against its pinned checksum. It is saved in FluidAudio's shared model folder (\(folder.path)); a copy another app put there is replaced.\n\nLicense:\n\(ModelFacts.licenseText(license))")
    }

    static let removeTitle = "Remove dictionary support?"
    static func removeBody(folder: URL) -> String {
        "On-device transcription stops using your dictionary until you download it again. This deletes \(folder.path), which other apps built on FluidAudio may also use."
    }

    static func completionMessage(_ result: Result<Void, ModelDownloadError>) -> String {
        switch result {
        case .success: return "Dictionary support is downloaded and verified. On-device transcription now uses your dictionary."
        case .failure(.cancelled): return "The download was cancelled. Retry continues from the files already downloaded."
        case .failure(let error): return error.userMessage
        }
    }

    static let unavailableMessage = "Dictionary support could not start, so on-device transcription is running without your dictionary. Remove it and download it again."
}

enum ModelRowAction: Equatable { case download, cancel, retry, remove }

struct ModelRowPresentation: Equatable {
    let statusText: String
    let actions: [ModelRowAction]
    /// 0...1 while bytes are arriving; nil otherwise.
    let progress: Double?
    let isWorking: Bool
    let isReady: Bool

    /// `status` is nil when the bundled manifest is missing or invalid.
    static func make(_ status: ModelStatus?) -> ModelRowPresentation {
        guard let status else {
            return ModelRowPresentation(statusText: ModelDownloadError.invalidManifest.userMessage, actions: [], progress: nil, isWorking: false, isReady: false)
        }
        switch status {
        case .notDownloaded:
            return ModelRowPresentation(statusText: "Not downloaded", actions: [.download], progress: nil, isWorking: false, isReady: false)
        case .downloading(let progress):
            let text = "Downloading… \(Int((progress.fraction * 100).rounded(.down)))% (\(ModelFacts.formatBytes(progress.bytesDone)) of \(ModelFacts.formatBytes(progress.totalBytes)))"
            return ModelRowPresentation(statusText: text, actions: [.cancel], progress: progress.fraction, isWorking: true, isReady: false)
        case .verifying:
            return ModelRowPresentation(statusText: "Verifying downloaded files…", actions: [.cancel], progress: nil, isWorking: true, isReady: false)
        case .ready:
            return ModelRowPresentation(statusText: "Downloaded", actions: [.remove], progress: nil, isWorking: false, isReady: true)
        case .corrupt(let reason):
            return ModelRowPresentation(statusText: reason, actions: [.retry, .remove], progress: nil, isWorking: false, isReady: false)
        case .failed(let error):
            return ModelRowPresentation(statusText: ModelFacts.completionMessage(.failure(error)), actions: [.retry, .remove], progress: nil, isWorking: false, isReady: false)
        }
    }
}

/// Content-free refusals. Each returns nil when the action may proceed.
enum ModelGate {
    static let downloadingMessage = "The model is still downloading. Wait for it to finish, or cancel it in Settings."
    static let missingRuntimeMessage = "The local model runtime is missing from this build. Reinstall Murmur."
    static let missingModelMessage = "The transcription model is not available. Download the model in Settings, or choose a downloaded model folder."

    /// `downloadingActiveModel`: a download is replacing the folder this dictation would read.
    static func startRefusal(modelAvailable: Bool, runtimeAvailable: Bool, downloadingActiveModel: Bool) -> String? {
        if downloadingActiveModel { return downloadingMessage }
        if !runtimeAvailable { return missingRuntimeMessage }
        if !modelAvailable { return missingModelMessage }
        return nil
    }

    static func downloadRefusal(isBusy: Bool, preview: Bool, downloading: Bool) -> String? {
        if preview { return "Model download is disabled in preview." }
        if downloading { return ModelDownloadError.busy.userMessage }
        if isBusy { return "Finish the current dictation before downloading the model." }
        return nil
    }

    static func removeRefusal(isBusy: Bool, preview: Bool, downloading: Bool) -> String? {
        if preview { return "Removing the model is disabled in preview." }
        if downloading { return "Cancel the download before removing the model." }
        if isBusy { return "Finish the current dictation before removing the model." }
        return nil
    }
}

extension ModelLicenseDeclaration: Identifiable {
    var id: String { name + "|" + url.absoluteString }
}

// MARK: - History routing and history-off (PRD R9, §6)

/// The disk side of history, as closures over HistoryStore (which is not Foundation-only).
struct HistoryDisk<Entry> {
    let save: (Entry) throws -> Void
    let entries: () throws -> [Entry]
    let delete: (Entry) throws -> Void
}

/// Every history write goes through here. With history on, entries go to disk. With history off,
/// they stay in memory for this app session only, so a held cleanup or a failed insertion can still
/// be copied from History until Murmur quits; nothing is written to disk. Thread-safe: the first save
/// of a dictation happens off the main thread.
final class HistoryRouter<Entry: RetainedHistoryItem>: @unchecked Sendable {
    /// Memory entries above this count are dropped oldest first.
    let memoryLimit: Int
    private let disk: HistoryDisk<Entry>
    private let lock = NSLock()
    private var memory: [String: Entry] = [:]
    private var persists: Bool

    init(disk: HistoryDisk<Entry>, persists: Bool, memoryLimit: Int = 100) {
        self.disk = disk; self.persists = persists; self.memoryLimit = max(1, memoryLimit)
    }

    /// Changing this does not move existing entries: memory entries stay in memory, disk entries stay on disk.
    var persistsTranscripts: Bool {
        get { lock.lock(); defer { lock.unlock() }; return persists }
        set { lock.lock(); persists = newValue; lock.unlock() }
    }

    /// An entry already held in memory stays in memory, so one dictation never splits across both.
    func save(_ entry: Entry) throws {
        lock.lock()
        if !persists || memory[entry.id] != nil {
            memory[entry.id] = entry
            if memory.count > memoryLimit {
                let excess = memory.values.sorted { $0.recordedAt < $1.recordedAt }.prefix(memory.count - memoryLimit)
                for old in excess { memory[old.id] = nil }
            }
            lock.unlock()
            return
        }
        lock.unlock()
        try disk.save(entry)
    }

    /// Replaces an existing entry where it already lives (memory or disk), whatever `persistsTranscripts` says now.
    func update(_ entry: Entry) throws {
        lock.lock()
        if memory[entry.id] != nil { memory[entry.id] = entry; lock.unlock(); return }
        lock.unlock()
        try disk.save(entry)
    }

    /// Disk and memory entries, newest first. A memory entry wins over a disk entry with the same id.
    func entries() throws -> [Entry] {
        let stored = try disk.entries()
        lock.lock(); let held = memory; lock.unlock()
        return (stored.filter { held[$0.id] == nil } + Array(held.values)).sorted { $0.recordedAt > $1.recordedAt }
    }

    func delete(_ entry: Entry) throws {
        lock.lock(); let wasHeld = memory.removeValue(forKey: entry.id) != nil; lock.unlock()
        if !wasHeld { try disk.delete(entry) }
    }

    var sessionOnlyIDs: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(memory.keys) }

    /// Applies time-based retention to memory entries (disk entries use HistoryStore.purge).
    func purgeSessionOnly(recordedAtOrBefore cutoff: Date) {
        lock.lock(); memory = memory.filter { $0.value.recordedAt > cutoff }; lock.unlock()
    }

    func clearSessionOnly() { lock.lock(); memory.removeAll(); lock.unlock() }
}

enum HistoryExpiry {
    /// The same cutoff HistoryStore.expired uses (entries at or before it expire); nil for Forever.
    static func cutoff(_ retention: HistoryRetention, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch retention {
        case .forever: return nil
        case .thirtyDays: return now.addingTimeInterval(-30 * 86400)
        case .sixMonths: return calendar.date(byAdding: .month, value: -6, to: now)
        }
    }
}

enum HistoryText {
    static func summary(mode: HistoryMode, count: Int, sessionOnly: Int) -> String {
        let noun = count == 1 ? "transcript" : "transcripts"
        switch mode {
        case .on:
            return sessionOnly == 0 ? "Saved locally · \(count) \(noun)" : "Saved locally · \(count) \(noun), \(sessionOnly) kept only until Murmur quits"
        case .off:
            return "History is off · \(count) \(noun) · new transcripts are kept only until Murmur quits"
        }
    }

    static let sessionOnlyNote = "Not saved to disk. This text is lost when Murmur quits."

    /// The first sentence of a completion message.
    static func saved(persists: Bool) -> String {
        persists ? "Saved in History." : "Kept in History until Murmur quits."
    }
}

// MARK: - Delete all data (PRD §6)

enum DeleteAllDataText {
    static let title = "Delete all Murmur data?"
    static let body = "This permanently deletes transcript history, your dictionary and learned entries, retry audio, and API keys Murmur saved in the Keychain. Settings and the downloaded model are kept. Backups or snapshots may still hold copies. This cannot be undone."
    static let explanation = "Deletes history, dictionary, learned entries, retry audio and saved API keys. Settings and the downloaded model stay."
}

/// What happens after DataWipe: every in-memory store pointing at a deleted directory is discarded
/// and recreated empty, in this order. Steps run even when an earlier one fails.
enum PostWipeStep: String, CaseIterable, Equatable {
    /// Drop history router (including memory-only entries), recovery selection and retry-audio pointer.
    case discardInMemoryState
    case recreateHistory
    case recreateRetryAudio
    /// A new ProcessingCoordinator re-reads the (now absent) dictionary and ledger as empty.
    case reloadDictionary
    case refreshViews

    var label: String {
        switch self {
        case .discardInMemoryState: return "in-memory data"
        case .recreateHistory: return "history"
        case .recreateRetryAudio: return "retry audio"
        case .reloadDictionary: return "dictionary"
        case .refreshViews: return "display"
        }
    }

    /// Returns the steps that failed.
    static func run(_ perform: (PostWipeStep) throws -> Void) -> [PostWipeStep] {
        var failed: [PostWipeStep] = []
        for step in allCases {
            do { try perform(step) } catch { failed.append(step) }
        }
        return failed
    }

    static func message(report: DeleteAllReport, failedSteps: [PostWipeStep]) -> (succeeded: Bool, text: String) {
        var problems = report.failures
        if !failedSteps.isEmpty {
            problems.append("Could not set up empty storage for: " + failedSteps.map(\.label).joined(separator: ", ") + ".")
        }
        if problems.isEmpty {
            return (true, "All Murmur data was deleted. Settings and the downloaded model were kept.")
        }
        return (false, "Some Murmur data could not be deleted. " + problems.joined(separator: " "))
    }
}

// MARK: - Update check presentation (PRD R12)

enum UpdateSchedule {
    /// The running app attempts an automatic check at launch and then at most hourly. The checker's
    /// UserDefaults store limits completed checks to one a day; an offline attempt does not count
    /// there, so this interval is what keeps an offline Mac from retrying every minute.
    static let automaticAttemptInterval: TimeInterval = 60 * 60

    static func shouldAttemptAutomatic(lastAttempt: Date?, now: Date = Date()) -> Bool {
        guard let lastAttempt, lastAttempt <= now else { return true }
        return now.timeIntervalSince(lastAttempt) >= automaticAttemptInterval
    }
}

enum UpdateText {
    static let explanation = "Murmur asks GitHub for new releases at launch and at most once a day. This uses the network even though transcription runs on this Mac. Nothing is downloaded or installed, and no transcripts, audio, dictionary or API keys are sent."

    /// Status line for Settings. Nil means keep the current line (a skipped automatic check).
    static func status(_ result: UpdateCheckResult, manual: Bool, currentVersion: String,
                       timeFormatter: (Date) -> String = { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) }) -> String? {
        switch result {
        case .updateAvailable(let release):
            return "Murmur \(release.version) is available. This Mac has \(currentVersion)."
        case .upToDate:
            return "Murmur \(currentVersion) is up to date."
        case .noReleases:
            return "No Murmur releases have been published yet."
        case .repositoryNotFound:
            return "The Murmur release page could not be found. Try again later."
        case .throttled:
            return manual ? "Murmur checked for updates recently. Try again later." : nil
        case .rateLimited(let until):
            if let until { return "GitHub is limiting update checks. Try again after \(timeFormatter(until))." }
            return "GitHub is limiting update checks. Try again later."
        case .offline:
            return manual ? "Could not reach GitHub. Check your internet connection and try again." : "Could not reach GitHub to check for updates. Murmur will try again later."
        case .failed:
            return "The update check did not complete. Try again later."
        }
    }

    /// Nil clears a previously shown release only when the check positively says there is none newer.
    static func release(_ result: UpdateCheckResult, previous: ReleaseInfo?) -> ReleaseInfo? {
        switch result {
        case .updateAvailable(let release): return release
        case .upToDate, .noReleases: return nil
        default: return previous
        }
    }

    static func headline(_ release: ReleaseInfo) -> String {
        let title = release.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Murmur \(release.version)" : title
    }

    /// Release notes are shown as plain text, never rendered as Markdown or HTML, and trimmed.
    static func notesExcerpt(_ notes: String, limit: Int = 1500) -> String {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func menuTitle(_ release: ReleaseInfo?) -> String {
        release.map { "Update Available: Murmur \($0.version)…" } ?? "Check for Updates…"
    }
}
