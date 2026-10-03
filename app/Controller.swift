import AppKit
import SwiftUI
import ApplicationServices
import AVFoundation
import Combine
import Darwin
@preconcurrency import Dispatch

@MainActor final class AppController: ObservableObject {
    @Published var phase = "Ready"
    @Published var message = "Hold Right Option to dictate, or tap to start and tap again to finish."
    @Published var history: [HistoryEntry] = []
    @Published var recoveryEntryID: String?
    @Published var recoveryAudio: URL?
    @Published var modelDirectory: String
    @Published var shortcut: String
    @Published var showMenuBar: Bool
    @Published var permissionsSummary = ""
    @Published var automaticInsertion: Bool
    @Published var retention: String
    var isBusy: Bool { phase == "Listening" || phase == "Processing" || (sessionAvailable && session.state != .idle) }
    var openSettings: (() -> Void)?
    var updateMenu: (() -> Void)?
    lazy var bubble = BubblePresenter(controller: self)
    private var store: HistoryStore?
    private var retry: RetryAudio?
    private var capture: Capture?
    private var destination: FocusSnapshot?
    private var destinationScreen: NSScreen?
    private var focusStable = true
    private var insertThisSession = true
    private var listener: ShortcutListener?
    private var source: CFRunLoopSource?
    private var monitor: Timer?
    private var expiry: Timer?
    private var runner: Process?
    private var runnerOutput: URL?
    private var recordingFailed = false
    private var generation = UUID()
    private var hideGeneration = UUID()
    private var appliedRetention: String
    private var activeModelDirectory = ""
    private var listeningStarted = Date()
    private var preview = false
    private lazy var session: CaptureSession = {
        CaptureSession(store: retry!, start: { [weak self] url in
            guard let self else { throw CaptureError("Application stopped") }
            let recording = Capture(); self.capture = recording
            try recording.start(url: url)
            self.setPhase("Listening", "Listening… Release to finish, or press Escape to cancel.")
        }, stop: { [weak self] in
            guard let self else { return false }
            self.capture?.stop()
            self.recordingFailed = self.recordingFailed || self.capture?.writeError != nil
            let hasAudio = (self.capture?.frames ?? 0) > 0
            self.capture = nil
            return hasAudio
        }, process: { [weak self] url, done in
            guard let self else { done(); return }
            if self.recordingFailed {
                self.setPhase("Error", "Recording was interrupted. Partial audio is saved for retry.")
                done()
            } else { self.transcribe(url, done: done) }
        })
    }()

    init(preview: Bool = false) {
        let defaults = UserDefaults.standard
        modelDirectory = defaults.string(forKey: "modelDirectory") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Dictation/module-one/unified-d32e972").path
        shortcut = defaults.string(forKey: "shortcut") ?? "right-option"
        showMenuBar = defaults.object(forKey: "showMenuBar") as? Bool ?? true
        automaticInsertion = defaults.object(forKey: "automaticInsertion") as? Bool ?? true
        retention = defaults.string(forKey: "retention") ?? "30-days"
        appliedRetention = defaults.string(forKey: "retention") ?? "30-days"
        self.preview = preview
        do {
            store = try HistoryStore()
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            retry = try RetryAudio(directory: base.appendingPathComponent("Dictation/retry-audio"))
            if let retry {
                for file in try FileManager.default.contentsOfDirectory(at: retry.directory, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix(".result-") {
                    try FileManager.default.removeItem(at: file)
                }
            }
            try store?.purge(retention: appliedRetention)
            refreshHistory()
        } catch { store = nil; retry = nil; phase = "Error"; message = "Private storage is unavailable. Murmur cannot start." }
    }
    func start() {
        refreshPermissions()
        if !preview { configureShortcut() }
        // Returning from System Settings reactivates Murmur: re-check grants and start the shortcut once Input Monitoring is allowed.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPermissions()
                if !self.preview && self.listener == nil && CGPreflightListenEventAccess() { self.configureShortcut(); if self.listener != nil { self.message = "Input Monitoring allowed. The shortcut is ready." } }
            }
        }
        monitor = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.sessionAvailable && self.session.state == .listening, let capture = self.capture,
                   !capture.engine.isRunning || capture.queue.sync(execute: { capture.writeError != nil }) { self.recordingFailed = true; self.stopRecording() }
                if self.sessionAvailable && self.session.state != .idle, let initial = self.destination {
                    guard let current = try? captureFocus(), current.pid == initial.pid, CFEqual(current.element, initial.element),
                          !current.secure, current.value == initial.value,
                          current.selection?.location == initial.selection?.location,
                          current.selection?.length == initial.selection?.length else { self.focusStable = false; return }
                }
            }
        }
        expiry = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                do { try self.retry?.purge(); try self.store?.purge(retention: self.appliedRetention); self.refreshHistory() }
                catch { self.setPhase("Error", "Data expiry failed. Open History to review saved data.") }
            }
        }
    }
    private var sessionAvailable: Bool { retry != nil && store != nil }
    func refreshPermissions() {
        permissionsSummary = "Microphone: \(permission()) · Accessibility: \(AXIsProcessTrusted() ? "allowed" : "needed") · Input Monitoring: \(CGPreflightListenEventAccess() ? "allowed" : "needed")"
    }
    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in DispatchQueue.main.async { self?.refreshPermissions() } }
    }
    func openPermissionSettings(_ kind: String) {
        let pane = kind.lowercased().contains("input") ? "Privacy_ListenEvent" : kind.lowercased().contains("micro") ? "Privacy_Microphone" : "Privacy_Accessibility"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
    func chooseModelDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.message = "Choose the pinned Parakeet Unified model folder."
        if panel.runModal() == .OK, let url = panel.url { modelDirectory = url.path }
    }
    func applySettings() {
        guard !isBusy else { message = "Finish the current dictation before changing settings."; return }
        if retention != appliedRetention, let expired = try? store?.expired(retention: retention), !expired.isEmpty {
            let alert = NSAlert(); alert.messageText = "Delete \(expired.count) expired transcripts?"
            alert.informativeText = "Applying this retention period permanently removes these older entries."
            alert.addButton(withTitle: "Apply and Delete"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { retention = appliedRetention; return }
        }
        appliedRetention = retention
        let defaults = UserDefaults.standard
        defaults.set(modelDirectory, forKey: "modelDirectory"); defaults.set(shortcut, forKey: "shortcut")
        defaults.set(showMenuBar, forKey: "showMenuBar"); defaults.set(automaticInsertion, forKey: "automaticInsertion")
        defaults.set(retention, forKey: "retention")
        do { try store?.purge(retention: appliedRetention); refreshHistory() } catch { setPhase("Error", "Could not apply history retention.") }
        refreshPermissions(); if !preview { configureShortcut() }; updateMenu?()
    }
    private func configureShortcut() {
        removeShortcut()
        guard sessionAvailable else { return }
        guard CGPreflightListenEventAccess() else { message = "Allow Input Monitoring, then click Apply Settings to enable the shortcut."; return }
        let binding: ShortcutBinding = shortcut == "fn" ? .fn : shortcut == "ctrl-option-space" ? .controlOptionSpace : .rightOption
        let next = ShortcutListener(binding: binding, processingSeconds: 0, onAction: { [weak self] action, done in self?.handle(action, done: done) })
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        // The chord needs an active tap so its Space never reaches the destination field.
        next.tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: binding == .controlOptionSpace ? .defaultTap : .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
            if let context {
                let listener = Unmanaged<ShortcutListener>.fromOpaque(context).takeUnretainedValue()
                listener.enqueue(type: type, event: event)
                if listener.binding.consumes(type, event) { return nil }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(next).toOpaque())
        guard let tap = next.tap, let nextSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { message = binding == .controlOptionSpace ? "The shortcut could not start. Check Input Monitoring and Accessibility." : "The shortcut could not start. Check Input Monitoring."; return }
        listener = next; source = nextSource
        CFRunLoopAddSource(CFRunLoopGetMain(), nextSource, .commonModes); CGEvent.tapEnable(tap: tap, enable: true)
        session.finishRecording = { [weak self] in guard let self, let listener = self.listener else { return }; listener.emit(listener.machine.finish()) }
        session.resetShortcut = { [weak self] in guard let self, let listener = self.listener else { return }; listener.emit(listener.machine.eventStreamLost()); listener.machine.processingFinished() }
    }
    private func removeShortcut() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = listener?.tap { CFMachPortInvalidate(tap) }
        source = nil; listener = nil
    }
    private func handle(_ action: ShortcutMachine.Action, done: @escaping () -> Void) {
        guard sessionAvailable else { done(); return }
        if action == .start {
            guard permission() == "authorized" else { session.resetShortcut?(); setPhase("Error", "Allow Microphone access in Settings before dictating."); done(); return }
            guard modelFilesAvailable(), Bundle.main.url(forAuxiliaryExecutable: "ModelBench") != nil else { session.resetShortcut?(); setPhase("Error", "Choose a downloaded model folder in Settings."); done(); return }
            destination = try? captureFocus()
            if destination?.secure == true { session.resetShortcut?(); setPhase("Error", "Password fields cannot receive dictation."); done(); return }
            if destination?.pid == getpid() { destination = nil }
            focusStable = true; insertThisSession = automaticInsertion; activeModelDirectory = modelDirectory
            listeningStarted = Date(); generation = UUID(); recoveryEntryID = nil; recordingFailed = false
            destinationScreen = screenForDestination(destination)
        }
        session.receive(action, completed: done)
        if action == .cancel { destination = nil; setPhase("Ready", "Recording canceled."); bubble.hide() }
        else if action == .start && session.state == .idle { setPhase("Error", "The microphone could not start. Check the selected input device.") }
        else if action == .finish && session.state == .idle && phase == "Listening" {
            destination = nil; setPhase("Error", "No audio was captured. Check your microphone and try again.")
        }
    }
    private func modelFilesAvailable() -> Bool {
        guard let manifest = Bundle.main.url(forResource: "artifact-pins", withExtension: "json"),
              let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [String: Any],
              let model = models["FluidInference/parakeet-unified-en-0.6b-coreml"] as? [String: Any],
              let files = model["files"] as? [[String: Any]], let names = model["batch_files"] as? [String] else { return false }
        return names.allSatisfy { name in
            guard let size = files.first(where: { $0["rfilename"] as? String == name })?["size"] as? Int,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: modelDirectory).appendingPathComponent(name).path) else { return false }
            return (attrs[.size] as? NSNumber)?.intValue == size
        }
    }
    private func screenForDestination(_ destination: FocusSnapshot?) -> NSScreen? {
        if let destination {
            var rawPosition: CFTypeRef?, rawSize: CFTypeRef?
            if AXUIElementCopyAttributeValue(destination.element, kAXPositionAttribute as CFString, &rawPosition) == .success,
               AXUIElementCopyAttributeValue(destination.element, kAXSizeAttribute as CFString, &rawSize) == .success,
               let rawPosition, let rawSize,
               CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() {
                var point = CGPoint.zero; var size = CGSize.zero
                if AXValueGetValue(unsafeBitCast(rawPosition, to: AXValue.self), .cgPoint, &point),
                   AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size) {
                    let center = NSPoint(x: point.x + size.width / 2, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y - size.height / 2)
                    if let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) { return screen }
                }
            }
        }
        return NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
    }
    func stopRecording() { guard let listener else { return }; listener.emit(listener.machine.finish()) }
    func cancelRecording() { guard let listener else { return }; listener.emit(listener.machine.cancel()) }
    private func setPhase(_ phase: String, _ message: String) {
        self.phase = phase; self.message = message
        // Errors raised while processing leave that session's audio retained for retry.
        recoveryAudio = phase == "Error" && sessionAvailable && session.state == .processing ? session.audio : nil
        hideGeneration = UUID(); updateMenu?()
        if phase != "Ready" { bubble.show(phase: phase, message: message, screen: destinationScreen) }
        if phase == "Inserted" {
            let token = hideGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in guard self?.hideGeneration == token else { return }; self?.bubble.hide() }
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    private func transcribe(_ audio: URL, done: @escaping () -> Void) {
        setPhase("Processing", "Transcribing on this Mac…")
        let token = generation; let models = URL(fileURLWithPath: activeModelDirectory)
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "ModelBench"), let manifest = Bundle.main.url(forResource: "artifact-pins", withExtension: "json"), let store else { setPhase("Error", "The model runtime is unavailable. Audio is saved for retry."); done(); return }
        let timestamp = listeningStarted
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do { try verifyAppModels(models, manifest: manifest) }
            catch { DispatchQueue.main.async { guard let self, self.generation == token else { return }; self.setPhase("Error", "Model verification failed. Choose the pinned model folder. Audio is saved for retry."); done() }; return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.launchRunner(helper, models: models, audio: audio, store: store, timestamp: timestamp, token: token, done: done)
            }
        }
    }
    private struct NoSpeech: Error {}
    private func launchRunner(_ helper: URL, models: URL, audio: URL, store: HistoryStore, timestamp: Date, token: UUID, done: @escaping () -> Void) {
        let temp = audio.deletingLastPathComponent().appendingPathComponent(".result-" + UUID().uuidString)
        let fd = open(temp.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { setPhase("Error", "Could not prepare transcription. Audio is saved for retry."); done(); return }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let task = Process(); task.executableURL = helper; task.arguments = [models.path, audio.path, "--single"]
        task.standardOutput = output; task.standardError = FileHandle.nullDevice
        do { try task.run(); runner = task; runnerOutput = temp } catch { try? output.close(); try? FileManager.default.removeItem(at: temp); setPhase("Error", "Transcription could not start. Audio is saved for retry."); done(); return }
        let timeout = DispatchWorkItem { if task.isRunning { task.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if task.isRunning { kill(task.processIdentifier, SIGKILL) } } } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timeout)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            task.waitUntilExit(); timeout.cancel()
            defer { try? output.close(); try? FileManager.default.removeItem(at: temp) }
            do {
                guard task.terminationStatus == 0 else { throw CaptureError("Transcription failed") }
                try output.synchronize(); try output.seek(toOffset: 0)
                let data = try output.readToEnd() ?? Data()
                guard let last = String(data: data, encoding: .utf8)?.split(separator: "\n").last,
                      let result = try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any],
                      let text = result["text"] as? String else { throw CaptureError("No usable transcript") }
                // The model ran and answered, but heard nothing; audio stays until the 24-hour purge.
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NoSpeech() }
                let savedEntry = HistoryEntry(id: UUID().uuidString, recordedAt: timestamp, rawText: text, finalText: text, insertionStatus: "saved-not-inserted")
                try store.save(savedEntry)
                try? FileManager.default.removeItem(at: audio)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.runner = nil; self.runnerOutput = nil
                    var entry = savedEntry
                    self.recoveryEntryID = entry.id
                    if self.insertThisSession, self.focusStable, let destination = self.destination {
                        // Persist uncertainty before the one permitted delivery attempt.
                        entry.insertionStatus = "insertion-pending"
                        do {
                            try store.save(entry)
                            let insertion = insertText(text, into: destination, policy: .singleAttempt)
                            entry.insertionStatus = insertion.status.rawValue
                            try store.save(entry)
                            self.setPhase(insertion.status == .verified ? "Inserted" : "Saved", insertion.status == .verified ? "Inserted." : "Saved in History. Delivery could not be verified; no retry was attempted.")
                        } catch { self.setPhase("Saved", "Saved in History. Insertion status could not be saved.") }
                    } else { self.setPhase("Saved", "Saved in History. The destination changed or automatic insertion is off.") }
                    self.destination = nil; self.refreshHistory(); done()
                }
            } catch {
                let message = error is NoSpeech ? "No speech was detected. Check your microphone and try again." : "Transcription failed. Audio is saved for retry for up to 24 hours."
                DispatchQueue.main.async { [weak self] in guard let self, self.generation == token else { return }; self.runner = nil; self.runnerOutput = nil; self.setPhase("Error", message); done() }
            }
        }
    }
    // Explicit developer check of the production pipeline, using a synthetic file
    // and an exact disposable destination. Never enabled during ordinary launch.
    func checkSavedAudio(_ audio: URL, expectedApp: String, completion: @escaping () -> Void) {
        guard sessionAvailable, modelFilesAvailable(), let focused = try? captureFocus(),
              focused.bundleID == expectedApp, focused.pid != getpid(), !focused.secure else {
            fputs("app-check=refused destination-or-model-unavailable\n", stderr); completion(); return
        }
        destination = focused; focusStable = true; insertThisSession = true
        activeModelDirectory = modelDirectory; listeningStarted = Date(); generation = UUID()
        destinationScreen = screenForDestination(focused); recoveryEntryID = nil
        transcribe(audio) { [weak self] in
            print("app-check=complete state=\(self?.phase ?? "unknown")")
            fflush(stdout); completion()
        }
    }
    func refreshHistory() { history = (try? store?.entries()) ?? [] }
    func copyEntry(_ entry: HistoryEntry) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.finalText, forType: .string) }
    func deleteEntry(_ entry: HistoryEntry) { do { try store?.delete(entry); refreshHistory() } catch { message = "Could not delete this transcript." } }
    func clearHistory() {
        let alert = NSAlert(); alert.messageText = "Delete all saved transcripts?"; alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Delete All"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { for entry in history { try? store?.delete(entry) }; refreshHistory() }
    }
    func showSettings() { openSettings?() }
    func revealRecoveryAudio() { if let recoveryAudio { NSWorkspace.shared.activateFileViewerSelecting([recoveryAudio]) } }
    func shutdown() {
        generation = UUID(); monitor?.invalidate(); expiry?.invalidate(); removeShortcut()
        if sessionAvailable { session.shutdown() }
        if let runner, runner.isRunning {
            runner.terminate()
            // Closing the app cancels this one local helper; reap it before process exit.
            if runner.isRunning { kill(runner.processIdentifier, SIGKILL) }
            runner.waitUntilExit()
        }
        if let runnerOutput { try? FileManager.default.removeItem(at: runnerOutput) }
        bubble.hide()
    }
}
