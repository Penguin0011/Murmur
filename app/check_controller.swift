import CryptoKit
import Foundation
import AppKit
import ApplicationServices
import AVFoundation

@main struct ControllerChecks {
    static func main() throws {
        runInsertionChecks()
        let a = AXUIElementCreateApplication(getpid()), b = AXUIElementCreateApplication(getpid() + 10000)
        let identity = LearningFocusIdentity(field: a, window: a)
        precondition(identity.matches(LearningFocusIdentity(field: a, window: a)))
        precondition(!identity.matches(LearningFocusIdentity(field: b, window: a)), "field departure refuses")
        precondition(!identity.matches(LearningFocusIdentity(field: a, window: b)), "window departure refuses")
        precondition(!identity.matches(LearningFocusIdentity(field: nil, window: a)), "lost identity refuses")
        precondition(!identity.matches(LearningFocusIdentity(field: a, window: a, secure: true)), "secure metadata refuses")
        for size in [256 * 1024, 4 * 1024 * 1024 + 1] {
            let producer = Process(), pipe = Pipe()
            producer.executableURL = URL(fileURLWithPath: "/usr/bin/head")
            producer.arguments = ["-c", "\(size)", "/dev/zero"]; producer.standardOutput = pipe
            try producer.run(); try pipe.fileHandleForWriting.close()
            do {
                let data = try readHelperOutput(pipe.fileHandleForReading)
                precondition(size == data.count && size < 4 * 1024 * 1024, "stdout larger than pipe capacity drains without a file")
            } catch {
                precondition(size > 4 * 1024 * 1024, "oversized helper output refuses")
                if producer.isRunning { kill(producer.processIdentifier, SIGKILL) }
            }
            producer.waitUntilExit(); try pipe.fileHandleForReading.close()
        }
        // Keys the correction watch follows: shifted letters keep their case even when a synthetic
        // event carries only the Shift flag; Cmd chords are not edits it can follow.
        func key(_ code: CGKeyCode, _ text: String, _ flags: CGEventFlags) -> KeystrokeSpan.Key {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
            event.flags = flags
            let units = Array(text.utf16); event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            return AppController.watchedKey(event)
        }
        precondition(key(0, "a", .maskShift) == .text("A") && key(0, "A", .maskShift) == .text("A") && key(0, "a", []) == .text("a"))
        precondition(key(18, "!", .maskShift) == .text("!") && key(0, "a", .maskCommand) == .other)
        precondition(key(123, "", [.maskAlternate, .maskShift]) == .left(word: true, extend: true) && key(51, "", .maskAlternate) == .backspace(word: true))
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
        // Gap #9: settle once the accepted reading has been stable for 2 s, never before, never without one.
        precondition(!AppController.settlesEarly(pending: true, changedAt: 10, now: 11.9))
        precondition(AppController.settlesEarly(pending: true, changedAt: 10, now: 12))
        precondition(!AppController.settlesEarly(pending: false, changedAt: 10, now: 30), "rejected or already settled reading waits for the window")
        // Undo (gap #18) keeps a canceled recording as 16 kHz mono samples.
        let undoAudio = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-undo-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: undoAudio) }
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let file = try AVAudioFile(forWriting: undoAudio, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!; buffer.frameLength = 48_000
            for i in 0..<48_000 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.5 }
            try file.write(from: buffer)
        }
        let held = AppController.samples16k(undoAudio) ?? []
        // The resampler drops under 20 ms at the edges, well inside the 0.4 s release tail.
        precondition(abs(held.count - 16_000) < 500 && held.contains { abs($0) > 0.3 }, "a second at 48 kHz becomes about 16,000 samples")
        precondition(AppController.samples16k(URL(fileURLWithPath: "/nonexistent.wav")) == nil, "an unreadable file holds nothing")
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
        controller.lastDictationText = entry.finalText
        for status in [InsertionResult.Status.verified, .unverified] {
            controller.setPhase("Processing", "Processing synthetic dictation")
            controller.showInsertionResult(InsertionResult(status: status, detail: "synthetic", snapshot: nil), entryID: entry.id, text: entry.finalText)
            precondition(controller.pasteFailure == nil, "a posted paste shows no card")
            precondition(controller.phase == "Ready" && !controller.hasStatusToShow, "posted pastes finish quietly regardless of read-back")
            precondition(controller.lastDictationText == entry.finalText, "paste-last remains available after delivery")
            precondition(SettingsView.statusLabel(status.rawValue) == nil && SettingsView.statusNote(status.rawValue) == nil)
            precondition(!SettingsView.needsAttention(status.rawValue), "unreadable fields do not trigger the attention filter")
        }
        controller.showInsertionResult(InsertionResult(status: .failed, detail: "synthetic", snapshot: nil), entryID: entry.id, text: entry.finalText)
        precondition(controller.phase == "Error" && controller.message.contains("⌃⌘V") && controller.lastDictationText == entry.finalText)
        precondition(controller.pasteFailure == AppController.PasteFailure(entryID: entry.id, text: entry.finalText), "a failed paste shows the text card (gap #17)")
        controller.setPhase("Error", "Another failure")
        precondition(controller.pasteFailure == nil, "any later status replaces the card")
        precondition(SettingsView.needsAttention("failed") && SettingsView.statusLabel("failed") == "Not inserted")
        precondition(SettingsView.needsAttention("insertion-pending") && SettingsView.statusLabel("insertion-pending") == "Saved")
        precondition(SettingsView.statusNote("insertion-pending")?.contains("avoid a duplicate") == true)
        controller.setupTestTranscript = entry.finalText
        controller.deleteEntry(entry)
        precondition(controller.lastDictationText == entry.finalText && controller.recoveryEntryID == entry.id, "failed deletion preserves recovery")
        let historyStore = try HistoryStore(directory: temp.appendingPathComponent(name).appendingPathComponent("history"))
        try historyStore.save(entry)
        controller.deleteEntry(entry)
        precondition(controller.lastDictationText == nil && controller.setupTestTranscript.isEmpty && controller.recoveryEntryID == nil, "deleting the transcript clears recovery buffers")
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
        controller.history = [entry]; controller.recoveryEntryID = entry.id
        controller.setPhase("Saved", "Saved in History. Press ⌃⌘V to paste it where your cursor is.")
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        precondition(controller.phase == "Saved", "saved notice stays visible before five seconds")
        RunLoop.main.run(until: Date().addingTimeInterval(2.8))
        precondition(controller.phase == "Ready", "saved notice dismisses after five seconds")
        precondition(controller.history.first?.id == entry.id && manager.fileExists(atPath: recovery.path), "automatic dismissal preserves recovery")
        controller.setPhase("Saved", "Older saved notice")
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        controller.setPhase("Saved", "Newer saved notice")
        RunLoop.main.run(until: Date().addingTimeInterval(2.8))
        precondition(controller.phase == "Saved" && controller.message == "Newer saved notice", "an old timer cannot dismiss a newer saved notice")
        controller.setPhase("Inserted", "Inserted.")
        RunLoop.main.run(until: Date().addingTimeInterval(5.3))
        precondition(!controller.hasStatusToShow, "inserted notice dismisses after five seconds")
        controller.setPhase("Error", "Transcription failed. Audio is saved for retry for up to 24 hours.")
        RunLoop.main.run(until: Date().addingTimeInterval(5.3))
        precondition(controller.phase == "Error", "an error stays readable past five seconds")
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        precondition(!controller.hasStatusToShow, "an error notice dismisses after eight seconds")
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
        controller.customTranscriptionAPIBaseURL = "https://first.example/v1"
        precondition(controller.saveKey(.customTranscription, "synthetic-transcription-key") && !controller.customAPIKeyNeedsConfirmation(.customTranscription))
        controller.customTranscriptionAPIBaseURL = "https://second.example/v1"
        precondition(controller.customAPIKeyNeedsConfirmation(.customTranscription), "changed transcription destination needs its own confirmation")
        controller.validateKey(.customTranscription)
        precondition(controller.keyMessages[.customTranscription] == CredentialError.destinationMismatch.description, "transcription validation refuses an unconfirmed destination without HTTP")
        controller.customAPIBaseURL = "https://cleanup.example/v1"
        precondition(controller.saveKey(.customCleanup, "synthetic-cleanup-key") && !controller.customAPIKeyNeedsConfirmation(.customCleanup))
        controller.removeKey(.customTranscription)
        precondition(controller.savedKeys.contains(.customCleanup) && !controller.savedKeys.contains(.customTranscription), "removing transcription key keeps cleanup key")
        controller.removeKey(.customCleanup)
        // The learning lexicon uses the real English spell checker.
        precondition(isCommonEnglishWord("lunch") && isCommonEnglishWord("launch") && !isCommonEnglishWord("akmeq"))
        controller.lastDictationText = "held synthetic text"; controller.setupTestTranscript = "setup synthetic text"
        let chunk = temp.appendingPathComponent(name).appendingPathComponent("chunks/abandoned.wav")
        try Data([4, 5, 6]).write(to: chunk)
        controller.phase = "Processing"
        controller.deleteConfirmedData()
        precondition(controller.lastDictationText != nil && !controller.setupTestTranscript.isEmpty && manager.fileExists(atPath: recovery.path), "busy wipe refuses")
        controller.phase = "Ready"
        controller.deleteConfirmedData()
        precondition(controller.lastDictationText == nil && controller.setupTestTranscript.isEmpty, "wipe clears paste and setup buffers")
        precondition(controller.history.isEmpty && !controller.hasRecoveryAudio && !manager.fileExists(atPath: recovery.path), "wipe refreshes empty storage")
        precondition(!manager.fileExists(atPath: chunk.path), "wipe removes abandoned chunk audio")
        controller.pasteLastDictation()
        precondition(controller.lastDictationText == nil, "deleted text cannot be pasted later")
        print("Controller dismissal checks passed (idle recovery, configured shortcut, busy exclusion, history/audio preservation).")
        try warmRunnerChecks()
        try chunkChecks()
    }

    /// A fake helper speaks the --serve protocol: ready line, one answer per path, "die" exits.
    static func warmRunnerChecks() throws {
        signal(SIGPIPE, SIG_IGN)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("warm-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = dir.appendingPathComponent("helper"), starts = dir.appendingPathComponent("starts")
        try "#!/bin/sh\necho \"start $*\" >> '\(starts.path)'\ncase \"$*\" in *--ctc*) echo '{\"ready\":true,\"vocabulary_error\":true}';; *) echo '{\"ready\":true}';; esac\nwhile read p; do [ \"$p\" = \"$(dirname \"$p\")/die\" ] && exit 1; echo \"{\\\"text\\\":\\\"$(basename \"$p\")\\\"}\"; done\n"
            .write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let runner = WarmRunner(), models = dir
        var dictionaryStatus: Bool?
        runner.onDictionaryStatus = { dictionaryStatus = $0 }
        func ask(_ name: String, key: String = "k1", dictionary: [String] = []) -> String? {
            let done = DispatchSemaphore(value: 0); var answer: String?
            runner.transcribe(dir.appendingPathComponent(name), helper: helper, launch: HelperLaunch(models: models, dictionaryArguments: dictionary, key: key)) { line in
                answer = line.flatMap { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["text"] as? String }; done.signal()
            }
            done.wait(); return answer
        }
        func launches() -> Int { ((try? String(contentsOf: starts, encoding: .utf8)) ?? "").split(separator: "\n").count }
        precondition(ask("a.wav") == "a.wav" && ask("b.wav") == "b.wav" && launches() == 1, "warm helper answers repeatedly from one launch")
        precondition(ask("die") == nil, "a helper that dies answers nil so the caller falls back")
        precondition(ask("c.wav") == "c.wav" && launches() == 2, "the next request restarts the helper")
        precondition(ask("d.wav", key: "k2") == "d.wav" && launches() == 3, "a new model fingerprint restarts the helper")
        precondition(dictionaryStatus == nil, "no dictionary status without dictionary arguments")
        precondition(ask("e.wav", key: "k3", dictionary: ["--ctc", "/c", "--vocabulary", "/v"]) == "e.wav" && launches() == 4, "dictionary arguments restart the helper")
        let lastStart = ((try? String(contentsOf: starts, encoding: .utf8)) ?? "").split(separator: "\n").last ?? ""
        precondition(lastStart == "start \(models.path) --serve --ctc /c --vocabulary /v", "helper receives the dictionary arguments")
        precondition(dictionaryStatus == true, "a helper that could not load dictionary support is reported")
        runner.stopNow()
        try helperLaunchChecks(dir)
        print("Warm runner checks passed (one launch, fallback on death, restart, model change).")
    }

    /// HelperLaunch.make: dictionary arguments only with a verified dictionary model and a vocabulary.
    static func helperLaunchChecks(_ dir: URL) throws {
        let models = dir.appendingPathComponent("unified"), ctc = dir.appendingPathComponent("ctc")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ctc, withIntermediateDirectories: true)
        let weights = Data("weights".utf8), encoder = Data("encoder".utf8)
        try weights.write(to: models.appendingPathComponent("w")); try encoder.write(to: ctc.appendingPathComponent("e"))
        func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
        let manifest = dir.appendingPathComponent("pins.json")
        try JSONSerialization.data(withJSONObject: ["models": [
            unifiedRepository: ["files": [["rfilename": "w", "size": weights.count, "lfs": ["sha256": sha(weights)]]], "batch_files": ["w"]],
            dictionaryModelRepository: ["files": [["rfilename": "e", "size": encoder.count, "lfs": ["sha256": sha(encoder)]]], "batch_files": ["e"]]]]).write(to: manifest)
        let vocabulary = dir.appendingPathComponent("vocabulary.json")
        let plain = HelperLaunch.make(models: models, manifest: manifest, vocabulary: vocabulary, dictionaryModel: ctc)
        precondition(plain?.dictionaryArguments == [], "no vocabulary file: no dictionary arguments")
        try Data(#"{"terms":[{"text":"Kubernetes"}]}"#.utf8).write(to: vocabulary)
        let boosted = HelperLaunch.make(models: models, manifest: manifest, vocabulary: vocabulary, dictionaryModel: ctc)
        precondition(boosted?.dictionaryArguments == ["--ctc", ctc.path, "--vocabulary", vocabulary.path] && boosted?.key != plain?.key, "verified model and vocabulary: dictionary arguments and a new key")
        try Data(#"{"terms":[{"text":"Kubectl"}]}"#.utf8).write(to: vocabulary)
        precondition(HelperLaunch.make(models: models, manifest: manifest, vocabulary: vocabulary, dictionaryModel: ctc)?.key != boosted?.key, "a dictionary edit changes the key")
        try Data("tampered".utf8).write(to: ctc.appendingPathComponent("e"))
        precondition(HelperLaunch.make(models: models, manifest: manifest, vocabulary: vocabulary, dictionaryModel: ctc)?.dictionaryArguments == [], "an unverified dictionary model is not used, and transcription still runs")
        print("Helper launch checks passed (dictionary arguments only when verified, key follows the dictionary).")
    }

    /// Cut picker, join rule, ⌃⌘C match and ChunkJob, without audio hardware or the model.
    static func chunkChecks() throws {
        // 100 buffers of 0.1 s at rate 10 (1 frame each): loud except a quiet stretch at 13–14 s.
        let rate = 10.0
        var buffers = Array(repeating: (1, 1.0), count: 200)
        for i in 130..<133 { buffers[i] = (1, 0.0) }
        for i in 50..<53 { buffers[i] = (1, 0.0) }   // 5 s: quieter but before target - slack
        let cut = Chunker.quietestCut(buffers, rate: rate)
        precondition((130...133).contains(cut), "cuts in the quiet stretch inside 10–20 s, not the earlier one (got \(cut))")
        precondition(Chunker.quietestCut(Array(repeating: (1, 1.0), count: 200), rate: rate) >= 100, "no pause still cuts inside the window")
        precondition(Chunker.join(["Hello there", "General Kenobi."], sentenceEnds: [true, false]) == "Hello there. General Kenobi.", "a sentence pause adds a period")
        precondition(Chunker.join(["we were going", "I think to the store."], sentenceEnds: [false, false]) == "we were going I think to the store.", "a capital without a sentence pause adds nothing")
        precondition(Chunker.join(["Done.", " ", "Next one?", "Yes"], sentenceEnds: [true, true, true, false]) == "Done. Next one? Yes")
        precondition(Chunker.join(["It works.", "The next one."], sentenceEnds: [false, false]) == "It works. The next one.", "a model period survives a short pause")
        precondition(Chunker.join(["appears in the.", "Windows and doors."], sentenceEnds: [true, false]) == "appears in the Windows and doors.", "no sentence ends on 'the', even at a long pause; names keep capitals")
        precondition(Chunker.join(["to value", "The mysterious qualities"], sentenceEnds: [false, false]) == "to value the mysterious qualities")
        precondition(Chunker.join(["It works.", "The next one."], sentenceEnds: [true, false]) == "It works. The next one.", "a sentence pause keeps the period and capital")
        precondition(Chunker.join(["It works.", "Finally done."], sentenceEnds: [false, false]) == "It works. Finally done.", "a period stays unless the next word is lowercased")
        precondition(Chunker.join(["I think so.", "The plan works."], sentenceEnds: [true, false]) == "I think so. The plan works.", "'so' can end a sentence")
        precondition(Chunker.join(["Wait...", "So what?"], sentenceEnds: [false, false]) == "Wait... so what?", "an ellipsis stays")
        // Pause length: 10 frames at rate 10 per buffer; quiet run of 5 buffers around the cut.
        let shape = (0..<20).map { (10, (8...12).contains($0) ? 0.0 : 1.0) }
        precondition(abs(Chunker.pauseLength(shape, at: 10, rate: 10) - 5) < 1e-9, "pause spans the whole quiet run")
        precondition(Chunker.pauseLength(shape, at: 2, rate: 10) == 0, "a loud cut has no pause")
        precondition(ShortcutListener.isCopyChord(keyCode: 8, flags: [.maskControl, .maskCommand]))
        precondition(ShortcutListener.isCopyChord(keyCode: 8, flags: [.maskControl, .maskCommand, .maskNumericPad]))
        precondition(!ShortcutListener.isCopyChord(keyCode: 8, flags: [.maskCommand]))
        precondition(!ShortcutListener.isCopyChord(keyCode: 8, flags: [.maskControl, .maskCommand, .maskShift]))
        precondition(!ShortcutListener.isCopyChord(keyCode: 9, flags: [.maskControl, .maskCommand]))
        precondition(ShortcutListener.isPasteChord(keyCode: 9, flags: [.maskControl, .maskCommand]))
        precondition(!ShortcutListener.isPasteChord(keyCode: 9, flags: [.maskCommand]), "plain ⌘V is never taken")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chunks-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func file(_ name: String) throws -> URL { let url = dir.appendingPathComponent(name); try Data().write(to: url); return url }
        /// `answers`: chunk text, or for a boundary clip a raw JSON answer.
        func run(_ events: [Chunker.Event], answers: [String: String?]) -> String?? {
            let job = ChunkJob { url, boundary, done in
                let text = answers[url.lastPathComponent] ?? nil
                DispatchQueue.global().async { done(text.map { Data((boundary ? $0 : "{\"text\":\"\($0)\"}").utf8) }) }
            }
            events.forEach(job.receive)
            guard job.isEnded else { return .none }
            let got = DispatchSemaphore(value: 0); var answer: String?
            job.result { answer = $0; got.signal() }
            got.wait(); return .some(answer)
        }
        let a = try file("a.wav"), b = try file("b.wav")
        precondition(run([.chunk(a, last: false, sentenceEnd: false), .chunk(b, last: true, sentenceEnd: false)], answers: ["a.wav": "One two", "b.wav": "three."]) == .some("One two three."), "chunks join in order")
        precondition(!FileManager.default.fileExists(atPath: a.path) && !FileManager.default.fileExists(atPath: b.path), "chunk files are deleted once read")
        let c = try file("c.wav"), d = try file("d.wav")
        precondition(run([.chunk(c, last: false, sentenceEnd: false), .chunk(d, last: true, sentenceEnd: false)], answers: ["c.wav": "fine"]) == .some(nil), "a failed chunk answers nil for the WAV fallback")
        let e = try file("e.wav")
        precondition(run([.chunk(e, last: false, sentenceEnd: false), .end], answers: ["e.wav": "Only"]) == .some("Only"), "an empty last chunk still ends")
        precondition(run([.failed], answers: [:]) == .some(nil), "chunking failure answers nil")
        let f = try file("f.wav")
        precondition(run([.chunk(f, last: false, sentenceEnd: false)], answers: ["f.wav": "x"]) == .none, "no end yet: not ready, caller uses the WAV")
        // One chunk at a time: after the first failure, queued chunks are dropped unsent.
        var sent: [String] = []
        let sendLock = NSLock()
        let serial = ChunkJob { url, _, done in
            sendLock.withLock { sent.append(url.lastPathComponent) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { done(nil) }
        }
        let h = try file("h.wav"), i = try file("i.wav"), j = try file("j.wav")
        [Chunker.Event.chunk(h, last: false, sentenceEnd: false), .chunk(i, last: false, sentenceEnd: false), .chunk(j, last: true, sentenceEnd: false)].forEach(serial.receive)
        let gotSerial = DispatchSemaphore(value: 0); var serialAnswer: String? = "unset"
        serial.result { serialAnswer = $0; gotSerial.signal() }
        gotSerial.wait(); Thread.sleep(forTimeInterval: 0.2)
        precondition(serialAnswer == nil && sendLock.withLock({ sent }) == ["h.wav"], "only the first chunk was sent: \(sent)")
        precondition(![h, i, j].contains { FileManager.default.fileExists(atPath: $0.path) }, "dropped chunk files are deleted")
        let discarded = ChunkJob { _, _, done in done(nil) }
        discarded.discard()
        let g = try file("g.wav")
        discarded.receive(.chunk(g, last: true, sentenceEnd: false))
        precondition(!FileManager.default.fileExists(atPath: g.path), "a discarded job deletes later chunks unread")
        // Dictionary terms split by a cut: repaired from the boundary clip's replacements.
        precondition(Chunker.repair(tail: "Route calls through open.", head: "Router, then deploy.", from: "open router", to: "OpenRouter")! == ("Route calls through OpenRouter,", "then deploy."), "two-word term split by a cut")
        precondition(Chunker.repair(tail: "Deploy it to Cooper.", head: "Netties today.", from: "coopernetties", to: "Kubernetes")! == ("Deploy it to Kubernetes", "today."), "one word split mid-word")
        precondition(Chunker.repair(tail: "Ask about it.", head: "Then go.", from: "open router", to: "OpenRouter") == nil, "a replacement that does not cross the cut is ignored")
        precondition(Chunker.repair(tail: "", head: "open router", from: "open router", to: "OpenRouter") == nil, "empty side never traps")
        let k = try file("k.wav"), kb = try file("kb.wav"), l = try file("l.wav")
        precondition(run([.chunk(k, last: false, sentenceEnd: false), .boundary(kb), .chunk(l, last: true, sentenceEnd: false)],
                         answers: ["k.wav": "Route calls through open.", "kb.wav": #"{"replacements":[{"from":"open router","to":"OpenRouter"}]}"#, "l.wav": "Router, then deploy."])
                  == .some("Route calls through OpenRouter, then deploy."), "boundary repair joins the term")
        let m = try file("m.wav"), mb = try file("mb.wav"), n = try file("n.wav")
        precondition(run([.chunk(m, last: false, sentenceEnd: false), .boundary(mb), .chunk(n, last: true, sentenceEnd: false)], answers: ["m.wav": "One two", "n.wav": "three."])
                  == .some("One two three."), "a failed boundary only skips its repair")
        precondition(![k, kb, l, m, mb, n].contains { FileManager.default.fileExists(atPath: $0.path) }, "boundary clips are deleted once read")
        print("Chunk checks passed (quiet cut, pause length, join rule, copy chord, ordered join, one-at-a-time with drop on failure, failure fallback, cleanup, boundary repair).")
    }
}
