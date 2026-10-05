import Foundation
import CryptoKit

@main struct HistoryChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-history-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(directory: root)
        let now = Date(timeIntervalSince1970: 1791021600)
        let entry = HistoryEntry(id: UUID().uuidString, recordedAt: now.addingTimeInterval(-31 * 86400), rawText: "Synthetic original", finalText: "Synthetic final", insertionStatus: "saved-not-inserted")
        try store.save(entry)
        let loaded = try store.entries()
        precondition(loaded.count == 1 && loaded[0].rawText == entry.rawText)
        let path = root.appendingPathComponent(entry.id + ".json")
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        let thirty = try store.expired(retention: "30-days", now: now); precondition(thirty.count == 1)
        let forever = try store.expired(retention: "forever", now: now); precondition(forever.isEmpty)
        do { try store.purge(retention: "invalid"); fatalError("Unknown retention policy accepted") } catch {}
        let afterInvalidPolicy = try store.entries(); precondition(afterInvalidPolicy.count == 1)
        let mismatched = root.appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode(entry).write(to: mismatched)
        do { _ = try store.entries(); fatalError("Mismatched history identity accepted") } catch {}
        try FileManager.default.removeItem(at: mismatched)
        let corrupt = root.appendingPathComponent(UUID().uuidString + ".json")
        try Data("broken JSON".utf8).write(to: corrupt)
        do { _ = try store.entries(); fatalError("Unreadable history silently hidden") } catch {}
        // Startup moves it aside instead of refusing to start; it still expires by modification date.
        let movedCount = try store.quarantineUnreadable(), remaining = try store.entries().count
        precondition(movedCount == 1 && remaining == 1)
        let moved = try FileManager.default.contentsOfDirectory(at: store.unreadableDirectory, includingPropertiesForKeys: nil)
        precondition(moved.count == 1 && !FileManager.default.fileExists(atPath: corrupt.path))
        try store.purge(retention: "six-months", now: now); precondition(FileManager.default.fileExists(atPath: moved[0].path))
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-200 * 86400)], ofItemAtPath: moved[0].path)
        try store.purge(retention: "forever", now: now); precondition(FileManager.default.fileExists(atPath: moved[0].path))
        try store.purge(retention: "six-months", now: now); precondition(!FileManager.default.fileExists(atPath: moved[0].path))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let sixMonths = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31))!
        let cutoff = calendar.date(byAdding: .month, value: -6, to: sixMonths)!
        let boundary = HistoryEntry(id: UUID().uuidString, recordedAt: cutoff, rawText: "Calendar boundary", finalText: "Calendar boundary", insertionStatus: "pending")
        try store.save(boundary)
        let six = try store.expired(retention: "six-months", now: sixMonths, calendar: calendar); precondition(six.contains { $0.id == boundary.id })
        try store.delete(entry); try store.delete(boundary)
        let empty = try store.entries(); precondition(empty.isEmpty)
        // Native manifest verifier must fail closed on absent and corrupted artifacts.
        let modelRoot = root.appendingPathComponent("model"); try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        let bytes = Data("synthetic weight".utf8)
        let checksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let manifest = root.appendingPathComponent("manifest.json")
        let fixture: [String: Any] = ["models": ["FluidInference/parakeet-unified-en-0.6b-coreml": ["files": [["rfilename": "weights", "size": bytes.count, "lfs": ["sha256": checksum]]], "batch_files": ["weights"]]]]
        try JSONSerialization.data(withJSONObject: fixture).write(to: manifest)
        do { try verifyAppModels(modelRoot, manifest: manifest); fatalError("Missing weights accepted") } catch {}
        let weight = modelRoot.appendingPathComponent("weights"); try bytes.write(to: weight)
        try verifyAppModels(modelRoot, manifest: manifest)
        try Data(repeating: 0, count: bytes.count).write(to: weight)
        do { try verifyAppModels(modelRoot, manifest: manifest); fatalError("Corrupt weights accepted") } catch {}
        // The cache skips re-hashing only while size, mtime and inode are unchanged.
        let cache = ModelVerificationCache()
        do { try cache.verify(modelRoot, manifest: manifest); fatalError("Cache accepted corrupt weights") } catch {}
        try bytes.write(to: weight); try cache.verify(modelRoot, manifest: manifest)
        let hashed = try ModelVerificationCache.fingerprint(modelRoot, manifest: manifest)
        try cache.verify(modelRoot, manifest: manifest)   // hit
        try Data(repeating: 0, count: bytes.count).write(to: weight)
        let rewritten = try ModelVerificationCache.fingerprint(modelRoot, manifest: manifest)
        precondition(rewritten != hashed, "rewrite must change the fingerprint")
        do { try cache.verify(modelRoot, manifest: manifest); fatalError("Cache accepted rewritten weights") } catch {}
        print("Native history and verifier checks passed (atomic roundtrip, permissions, calendar expiry, invalid policy, mismatched/corrupt history, quarantine and expiry of unreadable files, deletion, absent/corrupt weights).")
    }
}
