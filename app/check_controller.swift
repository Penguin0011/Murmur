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
        try chunkChecks()
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
        precondition(Chunker.join(["made a medieval past look.", "More stable."], sentenceEnds: [false, false]) == "made a medieval past look more stable.", "a mid-sentence cut drops the model's period and capital")
        precondition(Chunker.join(["appears in the.", "Windows and doors."], sentenceEnds: [true, false]) == "appears in the Windows and doors.", "no sentence ends on 'the', even at a long pause; names keep capitals")
        precondition(Chunker.join(["to value", "The mysterious qualities"], sentenceEnds: [false, false]) == "to value the mysterious qualities")
        precondition(Chunker.join(["It works.", "The next one."], sentenceEnds: [true, false]) == "It works. The next one.", "a sentence pause keeps the period and capital")
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

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chunks-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func file(_ name: String) throws -> URL { let url = dir.appendingPathComponent(name); try Data().write(to: url); return url }
        func run(_ events: [Chunker.Event], answers: [String: String?]) -> String?? {
            let job = ChunkJob { url, done in
                let text = answers[url.lastPathComponent] ?? nil
                DispatchQueue.global().async { done(text.map { Data("{\"text\":\"\($0)\"}".utf8) }) }
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
        let serial = ChunkJob { url, done in
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
        let discarded = ChunkJob { _, done in done(nil) }
        discarded.discard()
        let g = try file("g.wav")
        discarded.receive(.chunk(g, last: true, sentenceEnd: false))
        precondition(!FileManager.default.fileExists(atPath: g.path), "a discarded job deletes later chunks unread")
        print("Chunk checks passed (quiet cut, pause length, join rule, copy chord, ordered join, one-at-a-time with drop on failure, failure fallback, cleanup).")
    }
}
