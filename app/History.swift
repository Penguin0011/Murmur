import Foundation
import CryptoKit
import Darwin

struct HistoryEntry: Codable, Identifiable {
    let id: String
    let recordedAt: Date
    let rawText: String
    /// Editable in History (gap #10); `rawText` never changes.
    var finalText: String
    var insertionStatus: String
    /// Why the full cleanup was not used (a content-free `CleanupFailureReason`), or nil.
    var cleanupFallback: String? = nil
    /// The cleanup model's output the guard rejected, kept for debugging (user request, October 6,
    /// 2026). It is dictation text, so it lives and expires with the rest of the entry.
    var cleanupRejectedOutput: String? = nil
    /// Recording length in seconds, for Insights' pace and time saved (gap #19); nil before October 15, 2026.
    var seconds: Double? = nil
    /// Bundle ID of the app the text was pasted into, for Insights; nil when unknown or not pasted.
    var app: String? = nil
    // Provenance (October 21, 2026): identifiers and settings only, never text, context or keys. Nil before then.
    /// Cleanup options in effect, after any writing mode's override.
    var cleanupOptions: CleanupOptions? = nil
    var writingModeID: String? = nil
    var writingModeName: String? = nil
    /// `ProviderID` raw value, or "local" for this Mac's model.
    var transcriptionProvider: String? = nil
    var transcriptionModel: String? = nil
    /// `ProviderID` raw value, or "local-rules".
    var cleanupProvider: String? = nil
    var cleanupModel: String? = nil
    var appVersion: String? = nil
    /// Whether screen context was sent to the cleanup model.
    var contextUsed: Bool? = nil
    var cleanupOutcome: CleanupPath? = nil
    /// True once the user edits `finalText` in History.
    var edited: Bool? = nil
    // Diagnostics (October 22, 2026): what a developer needs to see why a dictation came out as it did.
    // Dictation text lives only here, with the entry's permissions and retention, never in the unified log. Nil before then.
    var transcription: TranscriptionDetail? = nil
    var cleanup: CleanupDetail? = nil
    var afterPaste: AfterPaste? = nil
    var timing: StageTiming? = nil
    /// File name in `history/recordings` when "Keep recordings for diagnostics" was on; purged after 7 days.
    var recordingFile: String? = nil

    /// The same dictation with new text and status; the recording facts carry over.
    func with(finalText: String, status: String, fallback: String? = nil, rejected: String? = nil) -> HistoryEntry {
        var next = self
        next.finalText = finalText; next.insertionStatus = status; next.cleanupFallback = fallback; next.cleanupRejectedOutput = rejected
        return next
    }
}

/// One Whisper segment as parsed, with the loud-window count under it and whether the parser dropped it.
struct SegmentDetail: Codable, Equatable {
    var text: String
    var start: Double? = nil, end: Double? = nil
    var avgLogprob: Double? = nil, noSpeechProb: Double? = nil, compressionRatio: Double? = nil
    var loudWindows: Int? = nil
    var dropped = false
}

/// What the transcriber heard and how loud the clip was. Segments only for Whisper verbose_json.
struct TranscriptionDetail: Codable, Equatable {
    var segments: [SegmentDetail]? = nil
    var clipSeconds: Double? = nil
    /// Median and 90th-percentile peak of the clip's 100 ms windows.
    var peakP50: Double? = nil, peakP90: Double? = nil
    /// The silence pre-check's level (second-highest window peak) and the threshold it was held against.
    var silencePeak: Double? = nil, silenceThreshold: Double? = nil
    /// "passed", or "unchecked" when the provider has no pre-check or the audio could not be decoded.
    var precheck: String? = nil
}

/// The cleanup model's exchange, without any screen text.
struct CleanupDetail: Codable, Equatable {
    /// The model's exact output where the guard accepted it. A rejected output is `cleanupRejectedOutput`.
    var modelOutput: String? = nil
    /// "cleaned", "unchanged", "rejected" or "provider-error", one per section, comma-separated.
    var guardVerdict: String? = nil
    var providerError: String? = nil
    /// Short hash of the system prompt, to correlate prompt changes with results.
    var promptHash: String? = nil
    var dictionaryTerms: [String]? = nil
    /// The text sent for cleanup when the dictionary changed it from `rawText`.
    var input: String? = nil
    var contextUsed: Bool? = nil
    /// Bundle ID of the app dictated into, and the characters of each context part sent. Never the context.
    var contextApp: String? = nil
    var contextChars: [String: Int]? = nil
}

/// The pasted span as last observed when the correction watch closed. Text and `changed` are nil when
/// the watch lost the span (the reason is in `endReason`), so "unchanged" is never claimed without evidence.
struct AfterPaste: Codable, Equatable {
    var text: String? = nil
    var changed: Bool? = nil
    /// "ax" (read back from the field) or "keys" (followed by keystrokes).
    var route: String? = nil
    var endReason: String? = nil
}

/// Seconds per stage, in pipeline order, from the key release: `capture` (release until transcription
/// starts: the release tail plus stopping the recording), `transcription`, `cleanup`, `handoff` (cleanup
/// done until insertion starts: saving the entry, reading the focused field), `insertion`, then `total`.
/// `insertion` ends when the text is visible (⌘V posted, or the field first read back as matching) and
/// `total` is release to that moment. `insertionDone` is the insertion call's whole duration, which
/// also covers the read-back's wait; the clipboard restore runs after both and is in neither.
/// Entries from 0.2.3 and earlier lack `capture`, `handoff` and `insertionDone`, and their `insertion`
/// and `total` run to the end of a fixed 0.5 s clipboard wait, so they read about 0.5 s higher.
struct StageTiming: Codable, Equatable {
    var transcription: Double? = nil, cleanup: Double? = nil, insertion: Double? = nil, total: Double? = nil
    var capture: Double? = nil, handoff: Double? = nil, insertionDone: Double? = nil
}

struct HistoryStore {
    let directory: URL
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Dictation/history")) throws {
        self.directory = directory
        if FileManager.default.fileExists(atPath: directory.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw CaptureError("History requires a real directory") }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try removePendingFiles()
    }
    /// Writers and cleanup share a directory lock across processes, so cleanup cannot unlink a live save.
    private func locked<T>(_ operation: () throws -> T) throws -> T {
        let descriptor = open(directory.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CaptureError("Cannot open history directory") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CaptureError("Cannot lock history directory") }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
    private func removePendingFiles() throws {
        try locked {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let name = file.lastPathComponent
                guard name.hasPrefix(".pending-"), UUID(uuidString: String(name.dropFirst(9))) != nil else { continue }
                try FileManager.default.removeItem(at: file)
            }
        }
    }
    func save(_ entry: HistoryEntry) throws {
        try locked { try saveLocked(entry) }
    }
    private func saveLocked(_ entry: HistoryEntry) throws {
        guard UUID(uuidString: entry.id) != nil else { throw CaptureError("Invalid history identifier") }
        let target = directory.appendingPathComponent(entry.id + ".json")
        let temporary = directory.appendingPathComponent(".pending-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CaptureError("Cannot create private history") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: JSONEncoder().encode(entry))
        try handle.synchronize()
        guard rename(temporary.path, target.path) == 0 else { throw CaptureError("Cannot commit history") }
        let folder = open(directory.path, O_RDONLY)
        guard folder >= 0 else { throw CaptureError("Cannot flush history directory") }
        defer { close(folder) }
        guard fsync(folder) == 0 else { throw CaptureError("Cannot flush history directory") }
    }
    func entries() throws -> [HistoryEntry] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .filter { $0.pathExtension == "json" && ((try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true) }
            .map { file in
                let entry = try JSONDecoder().decode(HistoryEntry.self, from: Data(contentsOf: file))
                guard UUID(uuidString: entry.id) != nil,
                      file.lastPathComponent == entry.id + ".json" else {
                    throw CaptureError("History identifier does not match its file")
                }
                return entry
            }
            .sorted { $0.recordedAt > $1.recordedAt }
    }
    func delete(_ entry: HistoryEntry) throws {
        guard UUID(uuidString: entry.id) != nil else { throw CaptureError("Invalid history identifier") }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(entry.id + ".json"))
    }
    func expired(retention: String, now: Date = Date(), calendar: Calendar = .current) throws -> [HistoryEntry] {
        guard let cutoff = try Self.cutoff(retention: retention, now: now, calendar: calendar) else { return [] }
        return try entries().filter { $0.recordedAt <= cutoff }
    }
    /// Nil for forever.
    static func cutoff(retention: String, now: Date = Date(), calendar: Calendar = .current) throws -> Date? {
        if retention == "forever" { return nil }
        if retention == "six-months" {
            guard let date = calendar.date(byAdding: .month, value: -6, to: now) else { throw CaptureError("Invalid retention date") }
            return date
        }
        if retention == "30-days" { return now.addingTimeInterval(-30 * 86400) }
        throw CaptureError("Invalid history retention policy")
    }
    /// Files moved aside by `quarantineUnreadable`. Inside the history folder, so Delete All Data removes them.
    var unreadableDirectory: URL { directory.appendingPathComponent("unreadable", isDirectory: true) }
    /// Moves history files that cannot be decoded (or whose name does not match their id) into
    /// `unreadable/`, so one damaged file cannot stop Murmur from starting. Returns how many moved.
    func quarantineUnreadable() throws -> Int {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .filter { $0.pathExtension == "json" && ((try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true) }
        var moved = 0
        for file in files {
            if let entry = try? JSONDecoder().decode(HistoryEntry.self, from: Data(contentsOf: file)),
               UUID(uuidString: entry.id) != nil, file.lastPathComponent == entry.id + ".json" { continue }
            try FileManager.default.createDirectory(at: unreadableDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let target = unreadableDirectory.appendingPathComponent(UUID().uuidString + ".json")
            try FileManager.default.moveItem(at: file, to: target)
            moved += 1
        }
        return moved
    }
    /// Expires entries, and unreadable files by their modification date: their text still counts as history.
    func purge(retention: String, now: Date = Date()) throws {
        for entry in try expired(retention: retention, now: now) { try delete(entry) }
        try removePendingFiles()
        guard let cutoff = try Self.cutoff(retention: retention, now: now) else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: unreadableDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where ((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture) <= cutoff {
            try FileManager.default.removeItem(at: file)
        }
    }
}

/// Hashing the 1.8 GB model took about 0.9 s before every dictation. Verify once, then reuse the
/// result while every pinned file keeps the same size, modification time and inode.
// ponytail: a same-user writer that restores size, mtime and inode evades this; that writer could
// also replace the app itself. Re-hash per dictation if that threat model changes.
final class ModelVerificationCache: @unchecked Sendable {
    static let shared = ModelVerificationCache()
    private let lock = NSLock()
    /// Verified fingerprint per folder (the transcription model and the dictionary model).
    private var verified: [String: [String]] = [:]
    func verify(_ directory: URL, manifest: URL, repository: String = unifiedRepository, list: String = "batch_files") throws {
        let fingerprint = try Self.fingerprint(directory, manifest: manifest, repository: repository, list: list)
        lock.lock(); let hit = verified[directory.path] == fingerprint; lock.unlock()
        if hit { return }
        try verifyAppModels(directory, manifest: manifest, repository: repository, list: list)
        lock.lock(); verified[directory.path] = fingerprint; lock.unlock()
    }
    static func fingerprint(_ directory: URL, manifest: URL, repository: String = unifiedRepository, list: String = "batch_files") throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        guard let models = object?["models"] as? [String: Any],
              let model = models[repository] as? [String: Any],
              let batch = model[list] as? [String] else { throw CaptureError("Invalid model manifest") }
        return try batch.map { name in
            var info = stat()
            guard stat(directory.appendingPathComponent(name).path, &info) == 0 else { throw CaptureError("Missing model file") }
            return "\(name):\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec):\(info.st_ino)"
        }
    }
}

let unifiedRepository = "FluidInference/parakeet-unified-en-0.6b-coreml"
/// The live-words files (gap #13): the streaming encoder plus the decoder, joint and vocabulary it
/// loads with, in their own folder so the batch model is never touched.
let liveWordsFileList = "live_files"
/// The CTC model that rescores local transcripts toward the dictionary.
let dictionaryModelRepository = "FluidInference/parakeet-ctc-110m-coreml"

func verifyAppModels(_ directory: URL, manifest: URL, repository: String = unifiedRepository, list: String = "batch_files") throws {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
    guard let models = object?["models"] as? [String: Any],
          let model = models[repository] as? [String: Any],
          let files = model["files"] as? [[String: Any]], let batch = model[list] as? [String] else {
        throw CaptureError("Invalid model manifest")
    }
    for name in batch {
        guard !name.hasPrefix("/"), !name.split(separator: "/").contains(".."),
              let metadata = files.first(where: { $0["rfilename"] as? String == name }),
              let size = metadata["size"] as? Int else { throw CaptureError("Invalid model file") }
        let path = directory.appendingPathComponent(name)
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        guard (attrs[.size] as? NSNumber)?.intValue == size else { throw CaptureError("Model file size mismatch") }
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        if let lfs = metadata["lfs"] as? [String: Any], let expected = lfs["sha256"] as? String {
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw CaptureError("Model checksum mismatch") }
        } else if let expected = metadata["git_blob_sha1"] as? String {
            var hash = Insecure.SHA1()
            hash.update(data: Data("blob \(size)\0".utf8))
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw CaptureError("Model checksum mismatch") }
        } else { throw CaptureError("Missing model checksum") }
    }
}
