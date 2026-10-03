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
        for phase in ["Listening", "Processing", "Error"] { precondition(showsFloatingIndicator(phase: phase)) }
        for phase in ["Saved", "Inserted", "Ready"] { precondition(!showsFloatingIndicator(phase: phase)) }
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
        // Any folder change (Use Default, a finished download) is applied and saved, not only Choose Folder.
        controller.phase = "Ready"
        controller.modelDirectory = "/tmp/murmur-check-folder-\(UUID().uuidString)"
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(UserDefaults.standard.string(forKey: "modelDirectory") == controller.modelDirectory, "a model folder change is saved without an Apply button")
        UserDefaults.standard.removeObject(forKey: "modelDirectory")
        // "No speech" clears itself after 2 s; a status that replaced it in the meantime stays.
        controller.phase = "Ready"
        controller.setPhase("Error", "No speech was detected. Check your microphone and try again.")
        RunLoop.main.run(until: Date().addingTimeInterval(2.3))
        precondition(controller.phase == "Ready", "no-speech popup dismisses itself")
        controller.setPhase("Error", "No speech was detected. Check your microphone and try again.")
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        controller.setPhase("Error", "Transcription failed. Audio is saved for retry for up to 24 hours.")
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        precondition(controller.phase == "Error" && controller.message.hasPrefix("Transcription failed"), "a newer error is not dismissed")
        controller.phase = "Saved"
        // The check binary has no bundled artifact-pins.json: the model row offers nothing and refuses quietly, without an alert.
        precondition(controller.modelRow.actions.isEmpty && !controller.usesCustomModelFolder)
        controller.downloadModel()
        precondition(controller.modelMessage == ModelDownloadError.invalidManifest.userMessage && controller.phase == "Saved")
        precondition(controller.historySummary.hasPrefix(controller.historyMode == .on ? "Saved locally" : "History is off"))
        // Routes and keys (R4, R5): nothing to cancel while idle; preview keeps keys in memory and publishes only presence.
        precondition(!controller.canCancelRequest)
        controller.cancelCloudRequest()
        precondition(controller.phase == "Saved")
        precondition(!controller.saveKey(.gemini, "sk bad 99") && controller.keyMessages[.gemini] == KeyText.invalid && !controller.savedKeys.contains(.gemini))
        precondition(controller.saveKey(.gemini, "test-key-123") && controller.savedKeys.contains(.gemini) && controller.keyMessages[.gemini] == KeyText.saved)
        controller.removeKey(.gemini)
        precondition(!controller.savedKeys.contains(.gemini))
        // The learning lexicon uses the real English spell checker.
        precondition(isCommonEnglishWord("lunch") && isCommonEnglishWord("launch") && !isCommonEnglishWord("akmeq"))
        print("Controller dismissal checks passed (idle recovery, configured shortcut, busy exclusion, history/audio preservation).")
        try warmRunnerChecks()
    }

    /// A fake helper speaks the --serve protocol: ready line, one answer per path, "die" exits.
    static func warmRunnerChecks() throws {
        signal(SIGPIPE, SIG_IGN)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("warm-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = dir.appendingPathComponent("helper"), starts = dir.appendingPathComponent("starts")
        try "#!/bin/sh\necho start >> '\(starts.path)'\necho '{\"ready\":true}'\nwhile read p; do [ \"$p\" = \"$(dirname \"$p\")/die\" ] && exit 1; echo \"{\\\"text\\\":\\\"$(basename \"$p\")\\\"}\"; done\n"
            .write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let runner = WarmRunner(), models = dir
        func ask(_ name: String, key: String = "k1") -> String? {
            let done = DispatchSemaphore(value: 0); var answer: String?
            runner.transcribe(dir.appendingPathComponent(name), helper: helper, models: models, key: key) { line in
                answer = line.flatMap { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["text"] as? String }; done.signal()
            }
            done.wait(); return answer
        }
        func launches() -> Int { ((try? String(contentsOf: starts, encoding: .utf8)) ?? "").split(separator: "\n").count }
        precondition(ask("a.wav") == "a.wav" && ask("b.wav") == "b.wav" && launches() == 1, "warm helper answers repeatedly from one launch")
        precondition(ask("die") == nil, "a helper that dies answers nil so the caller falls back")
        precondition(ask("c.wav") == "c.wav" && launches() == 2, "the next request restarts the helper")
        precondition(ask("d.wav", key: "k2") == "d.wav" && launches() == 3, "a new model fingerprint restarts the helper")
        runner.stopNow()
        print("Warm runner checks passed (one launch, fallback on death, restart, model change).")
    }
}
