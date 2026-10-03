import Foundation
import AppKit

@main struct ControllerChecks {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("caller.wav")
        let bytes = Data(repeating: 42, count: 1024 * 1024 + 7)
        try bytes.write(to: original)
        let retry = try RetryAudio(directory: folder.appendingPathComponent("retry"))
        let owned = try copyProbeAudio(original, into: retry)
        precondition(owned != original && owned.deletingLastPathComponent().path == retry.directory.path)
        let copied = try Data(contentsOf: owned)
        precondition(copied == bytes)
        let attrs = try FileManager.default.attributesOfItem(atPath: owned.path)
        precondition((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try retry.delete(owned)
        let preserved = try Data(contentsOf: original)
        precondition(preserved == bytes)
        do {
            _ = try copyProbeAudio(folder.appendingPathComponent("missing.wav"), into: retry)
            preconditionFailure("Missing probe input accepted")
        } catch { }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: retry.directory.path)
        precondition(remaining.isEmpty)
        try MainActor.assumeIsolated { try checkDismissal() }
        print("Controller probe ownership checks passed (multi-buffer copy, private mode, original preserved, failed-copy cleanup).")
    }
    @MainActor static func checkDismissal() throws {
        for phase in ["Listening", "Processing", "Inserted"] {
            precondition(usesMinimalTranscriptionDisplay(true, phase: phase, message: "normal"))
            precondition(!usesMinimalTranscriptionDisplay(false, phase: phase, message: "normal"))
        }
        for phase in ["Error", "Saved", "Ready"] { precondition(!usesMinimalTranscriptionDisplay(true, phase: phase, message: "normal")) }
        precondition(!usesMinimalTranscriptionDisplay(true, phase: "Inserted", message: "unverified"))
        func spaced(_ text: String, _ value: String?, _ location: Int, _ length: Int = 0, _ enabled: Bool = true) -> String {
            textWithLeadingSpace(text, value: value, selection: CFRange(location: location, length: length), enabled: enabled)
        }
        precondition(spaced("world", "Hello", 5) == " world")
        precondition(spaced("word", "HelloWorld", 5) == "word")
        precondition(spaced("Next", "Done.", 5) == " Next")
        precondition(spaced("world", "Hello ", 6) == "world")
        precondition(spaced("world", "Hello\n", 6) == "world")
        precondition(spaced(" world", "Hello", 5) == " world")
        precondition(spaced(", yes", "Hello", 5) == ", yes")
        precondition(spaced("word", "(", 1) == "word")
        precondition(spaced("word", "", 0) == "word")
        precondition(spaced("word", nil, 3) == "word")
        precondition(spaced("word", "Hello", 2, 3) == "word")
        precondition(spaced("world", "Hello", 5, 0, false) == "world")
        precondition(spaced("word", "😀", 1) == "word")
        precondition(spaced("word", "😀", 2) == " word")
        precondition(spaced("word", "Hello", 99) == "word")
        _ = NSApplication.shared
        let manager = FileManager.default
        let temp = manager.temporaryDirectory
        let before = Set(try manager.contentsOfDirectory(atPath: temp.path))
        let controller = AppController(preview: true)
        defer { controller.shutdown() }
        let created = Set(try manager.contentsOfDirectory(atPath: temp.path)).subtracting(before)
        guard let name = created.first(where: { $0.hasPrefix("Dictation-preview-") }) else { preconditionFailure("Preview storage missing") }
        let retry = try RetryAudio(directory: temp.appendingPathComponent(name).appendingPathComponent("retry-audio"))
        let recovery = try retry.create()
        try Data([1, 2, 3]).write(to: recovery)
        let entry = HistoryEntry(id: UUID().uuidString, recordedAt: Date(), rawText: "retained", finalText: "retained", insertionStatus: "saved-not-inserted")
        controller.history = [entry]; controller.recoveryEntryID = entry.id
        controller.shortcut = "fn"; controller.phase = "Error"
        controller.dismissStatus()
        precondition(controller.phase == "Ready" && !controller.message.contains("Right Option"))
        precondition(controller.history.first?.id == entry.id && controller.recoveryEntryID == entry.id)
        precondition(controller.hasRecoveryAudio && manager.fileExists(atPath: recovery.path))
        controller.phase = "Processing"; controller.message = "busy"
        controller.dismissStatus()
        precondition(controller.phase == "Processing" && controller.message == "busy")
        precondition(controller.history.first?.id == entry.id && manager.fileExists(atPath: recovery.path))
        controller.phase = "Saved"
        print("Controller dismissal checks passed (idle recovery, configured shortcut, busy exclusion, history/audio preservation).")
    }
}
