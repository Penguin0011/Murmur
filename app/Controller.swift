import AppKit
import SwiftUI
import ApplicationServices
import AVFoundation
import os
import Combine
import Darwin
@preconcurrency import Dispatch

/// Content-free timing and stop reasons, alongside the capture and shortcut timing.
private let timingLog = Logger(subsystem: "cc.clouddev.dictation", category: "timing")

/// Keeps `ModelBench MODEL_DIRECTORY --serve` running with the model loaded, so a dictation skips
/// process launch and model load (about 0.4 s). One request at a time on a private queue. Any
/// failure (not ready, died, timed out) answers nil so the caller falls back to a one-shot helper;
/// the warm process restarts on the next request. A changed model fingerprint restarts it.
final class WarmRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "murmur.warm-runner", qos: .userInitiated)
    private var task: Process?, input: FileHandle?, output: FileHandle?, key: String?
    private var buffered = Data()

    func prepare(helper: URL, models: URL, key: String) { queue.async { [self] in _ = start(helper, models, key) } }
    func transcribe(_ audio: URL, helper: URL, models: URL, key: String, completion: @escaping (Data?) -> Void) {
        queue.async { [self] in
            guard !audio.path.contains("\n"), start(helper, models, key), let input,
                  (try? input.write(contentsOf: Data((audio.path + "\n").utf8))) != nil,
                  let line = readLine(timeout: 300) else { stopLocked(); completion(nil); return }
            completion(line)
        }
    }
    func stop() { queue.async { [self] in stopLocked() } }
    func stopNow() { queue.sync { stopLocked() } }

    private func start(_ helper: URL, _ models: URL, _ key: String) -> Bool {
        if let task, task.isRunning, self.key == key { return true }
        stopLocked()
        let next = Process(), toChild = Pipe(), fromChild = Pipe()
        next.executableURL = helper; next.arguments = [models.path, "--serve"]
        next.standardInput = toChild; next.standardOutput = fromChild; next.standardError = FileHandle.nullDevice
        do { try next.run() } catch { return false }
        task = next; input = toChild.fileHandleForWriting; output = fromChild.fileHandleForReading; self.key = key; buffered = Data()
        guard let ready = readLine(timeout: 60),
              (try? JSONSerialization.jsonObject(with: ready) as? [String: Any])?["ready"] as? Bool == true else { stopLocked(); return false }
        timingLog.notice("warm-runner ready pid=\(next.processIdentifier)")
        return true
    }
    /// Reads one line; a watchdog terminates the helper on timeout, which ends the read with EOF.
    private func readLine(timeout: TimeInterval) -> Data? {
        guard let output, let task else { return nil }
        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        while true {
            if let newline = buffered.firstIndex(of: 0x0A) {
                let line = buffered[buffered.startIndex..<newline]; buffered = Data(buffered[(newline + 1)...])
                return Data(line)
            }
            let chunk = output.availableData
            if chunk.isEmpty { return nil }
            buffered.append(chunk)
        }
    }
    private func stopLocked() {
        try? input?.close()
        if let task, task.isRunning { task.terminate() }
        task = nil; input = nil; output = nil; key = nil; buffered = Data()
    }
}

/// One local recording's chunk transcripts, made while it records (see Chunker), so release waits
/// only for the last chunk. Any failed chunk makes `result` answer nil, and the caller transcribes
/// the full WAV as before.
final class ChunkJob: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String?] = []
    private var failed = false, ended = false, discarded = false
    private var waiter: ((String?) -> Void)?
    private let transcribe: (URL, @escaping (Data?) -> Void) -> Void

    init(transcribe: @escaping (URL, @escaping (Data?) -> Void) -> Void) { self.transcribe = transcribe }

    /// Called on the capture queue, in order.
    func receive(_ event: Chunker.Event) {
        switch event {
        case .failed: lock.withLock { failed = true }; settle()
        case .end: lock.withLock { ended = true }; settle()
        case .chunk(let url, let last):
            let index: Int? = lock.withLock {
                if discarded { return nil }
                texts.append(nil); if last { ended = true }
                return texts.count - 1
            }
            guard let index else { try? FileManager.default.removeItem(at: url); return }
            transcribe(url) { [self] line in
                try? FileManager.default.removeItem(at: url)
                let text = line.flatMap { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["text"] as? String }
                lock.withLock { if let text { texts[index] = text } else { failed = true } }
                settle()
            }
        }
    }
    /// Whether the last chunk arrived (or chunking failed), so `result` will answer.
    var isEnded: Bool { lock.withLock { ended || failed } }
    /// Answers once: the joined transcript, or nil on any failure.
    func result(_ completion: @escaping (String?) -> Void) { lock.withLock { waiter = completion }; settle() }
    /// A canceled or abandoned recording: later chunks are deleted unread.
    func discard() { lock.withLock { discarded = true; waiter = nil } }
    private func settle() {
        let answer: (((String?) -> Void), String?)? = lock.withLock {
            guard let waiter, failed || (ended && !texts.contains(where: { $0 == nil })) else { return nil }
            self.waiter = nil
            return (waiter, failed ? nil : Chunker.join(texts.map { $0! }))
        }
        if let (waiter, text) = answer { waiter(text) }
    }
}

/// Starts capture on a dedicated queue as soon as the tap thread sees a shortcut press, so a slow
/// main thread does not delay the microphone. The session adopts it; anything unclaimed is deleted.
final class PreStart: @unchecked Sendable {
    private let queue = DispatchQueue(label: "murmur.prestart", qos: .userInteractive)
    private var pending: (capture: Capture, url: URL, id: UUID)?
    func begin(store: RetryAudio) {
        queue.async { [self] in
            guard pending == nil, permission() == "authorized", let url = try? store.create() else { return }
            let capture = Capture()
            do { try capture.start(url: url) } catch { try? store.delete(url); return }
            let id = UUID(); pending = (capture, url, id)
            timingLog.notice("prestart engine running at=\(ProcessInfo.processInfo.systemUptime, format: .fixed(precision: 3))")
            // ponytail: unclaimed after 10 s means the main thread never handled the press.
            queue.asyncAfter(deadline: .now() + 10) { [self] in if pending?.id == id { drop(store) } }
        }
    }
    func take() -> (Capture, URL)? { queue.sync { defer { pending = nil }; return pending.map { ($0.capture, $0.url) } } }
    func discard(store: RetryAudio) { queue.sync { drop(store) } }
    private func drop(_ store: RetryAudio) {
        guard let p = pending else { return }
        pending = nil; p.capture.stop(); try? store.delete(p.url)
    }
}

@MainActor final class AppController: ObservableObject {
    @Published var phase = "Ready"
    @Published var message = "Hold your shortcut to dictate, or double-press it to dictate until you press it again."
    @Published var history: [HistoryEntry] = []
    @Published var recoveryEntryID: String?
    @Published var recoveryAudio: URL?
    @Published var modelDirectory: String
    @Published var shortcut: String
    @Published var voiceLevel = 0.0
    @Published var showMenuBar: Bool
    @Published var permissionsSummary = ""
    @Published var hasRecoveryAudio = false
    var microphoneAuthorized: Bool { permission() == "authorized" }
    var accessibilityAuthorized: Bool { AXIsProcessTrusted() }
    var inputMonitoringAuthorized: Bool { CGPreflightListenEventAccess() }
    var modelAvailable: Bool { modelFilesAvailable() }
    @Published var intelligentLeadingSpace: Bool
    @Published var automaticInsertion: Bool
    @Published var retention: String
    // Cleanup and learning settings, applied as soon as they change like the others.
    @Published var cleanupFillers: Bool
    @Published var cleanupCorrections: Bool
    @Published var cleanupLists: Bool
    @Published var learningEnabled: Bool
    // Dictionary edits apply immediately; dictionaryMessage reports the last edit error.
    @Published var dictionaryEntries: [DictionaryEntry] = []
    @Published var dictionaryMessage = ""
    // Model download (R2). modelMessage reports the last download action, never interrupting dictation.
    @Published var modelStatus: ModelStatus = .notDownloaded
    @Published var modelMessage = ""
    var modelRow: ModelRowPresentation { ModelRowPresentation.make(downloader == nil ? nil : modelStatus) }
    var modelLicense: ModelLicenseInfo? { downloader?.license }
    var modelSummary: String { downloader.map { ModelFacts.summary(downloadSize: $0.downloadSize) } ?? "" }
    var usesCustomModelFolder: Bool { downloader.map { URL(fileURLWithPath: modelDirectory).standardizedFileURL.path != $0.target.path } ?? false }
    // History-off mode and the size cap (R9, §6). History-off and update checks apply as soon as they change.
    @Published var historyMode: HistoryMode
    @Published var historyCapWarning: String?
    @Published var sessionOnlyIDs: Set<String> = []
    var historySummary: String { HistoryText.summary(mode: appliedHistoryMode, count: history.count, sessionOnly: sessionOnlyIDs.count) }
    // Update checks (R12). Results are shown quietly in Settings only.
    @Published var updateChecksEnabled: Bool
    @Published var updateStatus = ""
    @Published var availableRelease: ReleaseInfo?
    @Published var checkingForUpdates = false
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    // Processing routes (R4) apply as soon as they change, after any disclosure is confirmed.
    // API keys (R5) save immediately to the Keychain; only their presence is published.
    @Published var transcriptionRoute: TranscriptionRoute
    @Published var cloudTranscriber: CloudTranscriber
    @Published var cleanupChoice: CleanupChoice
    @Published var localServerURL: String
    @Published var localServerModel: String
    @Published var localServerModels: [String] = []
    @Published var localServerMessage = ""
    @Published var findingModels = false
    @Published var savedKeys: Set<ProviderID> = []
    @Published var keyMessages: [ProviderID: String] = [:]
    var routeSettings: RouteSettings { RouteSettings(transcription: transcriptionRoute, cloudTranscriber: cloudTranscriber, cleanup: cleanupChoice, serverURL: localServerURL, serverModel: localServerModel) }
    var appliedTranscriptionIsLocal: Bool { appliedRoutes.transcription == .local }
    var appliedCleanupIsLocal: Bool { appliedRoutes.cleanup == .localRules }
    /// What a stage would send off this Mac with the settings as edited, or nil when nothing leaves.
    /// Reads no key (SwiftUI calls it on every render); the Apply alert uses the saved keys.
    func routeDisclosure(_ stage: ProcessingStage) -> String? { DisclosureText.summary(RoutePlan.make(routeSettings, cleanupSendsText: true) { _ in nil }, stage: stage) }
    var canCancelRequest: Bool { cloudRequest.isActive }
    var isBusy: Bool { phase == "Listening" || phase == "Processing" || (sessionAvailable && session.state != .idle) }
    var openSettings: (() -> Void)?
    var updateMenu: (() -> Void)?
    lazy var bubble = BubblePresenter(controller: self)
    private var store: HistoryStore?
    /// All history reads and writes; it keeps entries in memory only when history is off.
    private var records: HistoryRouter<HistoryEntry>?
    private var appliedHistoryMode: HistoryMode
    private var dataDirectory: URL?
    private let downloader: ModelDownloader?
    private var modelDownloadInFlight = false
    private var lastAutomaticUpdateAttempt: Date?
    // TODO(R12): UpdateConfiguration still defaults to Penguin0011/dictation; confirm the release repository before shipping.
    private lazy var updateChecker: UpdateChecker? = (try? UpdateConfiguration(currentVersion: currentVersion)).map { UpdateChecker(configuration: $0) }
    private var retry: RetryAudio?
    private var processing: ProcessingCoordinator?
    private var appliedRoutes: RouteSettings
    // Preview and the developer probe never touch the login Keychain.
    private lazy var credentials: CredentialStore = preview ? InMemoryCredentialStore() : KeychainCredentialStore(service: "Murmur")
    private let cloudRequest = CloudRequest()
    private var cloudDone: (() -> Void)?
    private var cloudStage: ProcessingStage?
    /// This session's cloud transcriber, chosen at start; nil means local Parakeet.
    private var sessionTranscriber: TranscriptionProvider?
    private var capture: Capture?
    private var destination: FocusSnapshot?
    private var destinationScreen: NSScreen?
    private var focusStable = true
    private var insertThisSession = true
    private var leadingSpaceThisSession = false
    private var shortcutGeneration = UUID()
    private var listener: ShortcutListener?
    private var source: CFRunLoopSource?
    private var tapThread: TapThread?
    private let prestart = PreStart()
    /// Recording continues this long after release so the last word survives.
    nonisolated static let releaseTail: TimeInterval = 0.4
    private let warm = WarmRunner()
    /// Chunk transcripts of local recordings, keyed by each recording's audio file.
    private var chunkJobs: [URL: ChunkJob] = [:]
    private var noNap: NSObjectProtocol?
    private var monitor: Timer?
    private var expiry: Timer?
    private var runner: Process?
    private var runnerOutput: URL?
    private var recordingFailed = false
    private var generation = UUID()
    private var appliedRetention: String
    private var activeModelDirectory = ""
    private var listeningStarted = Date()
    private var phaseBeforeEarly: (String, String)?
    private var statusShown = UUID()
    private var applyScheduled = false
    private var folderWatch: AnyCancellable?
    private var preview = false
    private var previewDirectory: URL?
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
                self.chunkJobs.removeValue(forKey: url)?.discard()
                self.setPhase("Error", "Recording was interrupted. Partial audio is saved for retry.")
                done()
            } else { self.transcribe(url, done: done) }
        })
    }()

    init(preview: Bool = false, isolatedStorage: Bool? = nil) {
        let defaults = UserDefaults.standard
        let defaultModel = ModelFacts.defaultDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
        modelDirectory = defaults.string(forKey: "modelDirectory") ?? defaultModel.path
        if let pins = Bundle.main.url(forResource: "artifact-pins", withExtension: "json"), let manifest = try? ModelManifest(contentsOf: pins) {
            downloader = ModelDownloader(manifest: manifest, target: defaultModel)
        } else { downloader = nil }
        shortcut = defaults.string(forKey: "shortcut") ?? "right-option"
        showMenuBar = defaults.object(forKey: "showMenuBar") as? Bool ?? true
        intelligentLeadingSpace = defaults.bool(forKey: "intelligentLeadingSpace")
        automaticInsertion = defaults.object(forKey: "automaticInsertion") as? Bool ?? true
        retention = defaults.string(forKey: "retention") ?? "30-days"
        appliedRetention = defaults.string(forKey: "retention") ?? "30-days"
        let processingSettings = ProcessingSettings.load(from: defaults)
        cleanupFillers = processingSettings.options.fillers
        cleanupCorrections = processingSettings.options.corrections
        cleanupLists = processingSettings.options.lists
        learningEnabled = processingSettings.learningEnabled
        historyMode = processingSettings.historyMode
        appliedHistoryMode = processingSettings.historyMode
        updateChecksEnabled = processingSettings.updateChecksEnabled
        let routes = RouteSettings.load(from: defaults)
        transcriptionRoute = routes.transcription; cloudTranscriber = routes.cloudTranscriber; cleanupChoice = routes.cleanup
        localServerURL = routes.serverURL; localServerModel = routes.serverModel; appliedRoutes = routes
        self.preview = preview
        let isolatedStorage = isolatedStorage ?? preview
        do {
            let base = isolatedStorage ? FileManager.default.temporaryDirectory.appendingPathComponent("Dictation-preview-" + UUID().uuidString) : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Dictation")
            if isolatedStorage { previewDirectory = base }
            dataDirectory = base
            store = try HistoryStore(directory: base.appendingPathComponent("history"))
            if let store { records = HistoryRouter(disk: historyDisk(store), persists: appliedHistoryMode.persistsTranscripts) }
            retry = try RetryAudio(directory: base.appendingPathComponent("retry-audio"))
            // Chunk files live only while their recording is transcribed; any left by a crash go now.
            let chunks = base.appendingPathComponent("chunks", isDirectory: true)
            try? FileManager.default.removeItem(at: chunks)
            if (try? FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil { Chunker.directory = chunks }
            // Dictionary/ledger corruption disables only cleanup and the dictionary: dictations are then held for review in History rather than blocking all dictation.
            do { processing = try ProcessingCoordinator(directory: base.appendingPathComponent("dictionary"), isCommonWord: isCommonEnglishWord) }
            catch { processing = nil; dictionaryMessage = "The dictionary could not be read. Dictations are held in History until it is repaired." }
            if let processing, processing.settings.route != routes.cleanup.processingRoute {
                var next = processing.settings; next.route = routes.cleanup.processingRoute; try? processing.update(next)
            }
            if let retry {
                for file in try FileManager.default.contentsOfDirectory(at: retry.directory, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix(".result-") {
                    try FileManager.default.removeItem(at: file)
                }
            }
            try store?.purge(retention: appliedRetention)
            historySaved(); refreshRecoveryAudio(); refreshDictionary()
        } catch { store = nil; records = nil; retry = nil; processing = nil; phase = "Error"; message = "Private storage is unavailable. Murmur cannot start." }
        modelStatus = downloader?.status() ?? .notDownloaded
        refreshKeys()
        // Choose Folder, Use Default and a finished download all change the folder, even with
        // Settings closed; apply each so the folder survives a relaunch.
        folderWatch = $modelDirectory.dropFirst().removeDuplicates().sink { [weak self] _ in self?.settingsChanged() }
    }
    func start() {
        // Writing to a warm helper that died must fail with EPIPE, not kill Murmur.
        signal(SIGPIPE, SIG_IGN)
        // App Nap would delay the shortcut; idle system sleep stays allowed.
        // Verify the model now so the first dictation does not hash 1.8 GB.
        if !preview, let manifest = Bundle.main.url(forResource: "artifact-pins", withExtension: "json") {
            let directory = URL(fileURLWithPath: modelDirectory)
            let warm = warm
            DispatchQueue.global(qos: .utility).async {
                guard (try? ModelVerificationCache.shared.verify(directory, manifest: manifest)) != nil,
                      let helper = Bundle.main.url(forAuxiliaryExecutable: "ModelBench"),
                      let fingerprint = try? ModelVerificationCache.fingerprint(directory, manifest: manifest) else { return }
                warm.prepare(helper: helper, models: directory, key: directory.path + "|" + fingerprint.joined(separator: ","))
            }
        }
        noNap = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Respond to the dictation shortcut without delay")
        refreshPermissions()
        if !preview { configureShortcut() }
        if !preview && updateChecksEnabled { runUpdateCheck(manual: false) }
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
                self.voiceLevel = self.capture?.queue.sync { self.capture?.level ?? 0 } ?? 0
                // A canceled or empty recording's audio is gone; drop its chunk transcripts.
                for (audio, job) in self.chunkJobs where !FileManager.default.fileExists(atPath: audio.path) { job.discard(); self.chunkJobs[audio] = nil }
                // Download progress and the verifying phase are sampled here, on the main thread.
                if self.modelDownloadInFlight, let status = self.downloader?.status(), status != self.modelStatus { self.modelStatus = status }
                if self.sessionAvailable && self.session.state == .listening, let capture = self.capture,
                   !capture.engine.isRunning || capture.queue.sync(execute: { capture.writeError != nil }) {
                    let running = capture.engine.isRunning, writeFailed = capture.queue.sync { capture.writeError != nil }
                    timingLog.notice("capture-interrupted engine-running=\(running, privacy: .public) write-error=\(writeFailed, privacy: .public)")
                    self.recordingFailed = true; self.stopRecording()
                }
                if self.isBusy, self.focusStable, let initial = self.destination {
                    let current = try? captureFocus()
                    let reason = current == nil ? "no-focus" : current!.pid != initial.pid ? "app" : !CFEqual(current!.element, initial.element) ? "element"
                        : current!.secure ? "secure" : current!.value != initial.value ? "value"
                        : current!.selection?.location != initial.selection?.location || current!.selection?.length != initial.selection?.length ? "selection" : nil
                    if let reason {
                        timingLog.notice("focus-unstable reason=\(reason, privacy: .public) app=\(initial.bundleID, privacy: .public)")
                        self.focusStable = false; return
                    }
                }
            }
        }
        if let monitor { RunLoop.main.add(monitor, forMode: .common) }
        expiry = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                do {
                    try self.retry?.purge(); try self.store?.purge(retention: self.appliedRetention)
                    if let cutoff = HistoryExpiry.cutoff(HistoryRetention(rawValue: self.appliedRetention) ?? .thirtyDays) { self.records?.purgeSessionOnly(recordedAtOrBefore: cutoff) }
                    try self.enforceHistoryCap(); self.refreshHistory(); self.refreshRecoveryAudio()
                }
                catch {
                    if self.isBusy { self.message = "Data expiry failed. Open History after this dictation to review saved data." }
                    else { self.setPhase("Error", "Data expiry failed. Open History to review saved data.") }
                }
                // Throttled to once a day by the checker's UserDefaults store; skipped checks make no request.
                if !self.preview && self.updateChecksEnabled { self.runUpdateCheck(manual: false) }
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
    /// Settings apply as soon as they change; there is no Apply button. Changes made in the same
    /// moment (Faithful Transcription flips three toggles) apply once. Confirmations still appear,
    /// and Cancel puts the control back.
    func settingsChanged() {
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyScheduled = false
            self.applySettings()
        }
    }
    /// Refreshes the permission rows and starts the shortcut if Input Monitoring was just allowed.
    func refreshPermissionsAndShortcut() {
        refreshPermissions()
        if !preview, listener == nil, !isBusy, CGPreflightListenEventAccess() { configureShortcut() }
    }
    func applySettings() {
        guard !isBusy else { message = "Finish the current dictation before changing settings."; return }
        let expired: [HistoryEntry]
        do { expired = try store?.expired(retention: retention) ?? [] }
        catch { message = "Could not review history retention. Settings were not applied."; return }
        if retention != appliedRetention, !expired.isEmpty {
            let alert = NSAlert(); alert.messageText = "Delete \(expired.count) expired transcripts?"
            alert.informativeText = "Applying this retention period permanently removes these older entries."
            alert.addButton(withTitle: "Apply and Delete"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { retention = appliedRetention; return }
        }
        if historyMode == .off && appliedHistoryMode == .on {
            let alert = NSAlert(); alert.messageText = "Turn history off?"
            alert.informativeText = HistoryMode.offDisclosure
            alert.addButton(withTitle: "Turn Off History"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { historyMode = appliedHistoryMode; return }
        }
        // R4: confirm what leaves this Mac before the first use of a route, provider or endpoint.
        let routes = routeSettings
        let plan = routePlan(routes, cleanupSendsText: cleanupFillers || cleanupCorrections || cleanupLists)
        let pending = DisclosureAcknowledgement.pending(plan, acknowledged: DisclosureAcknowledgement.acknowledged(.standard))
        if !pending.isEmpty {
            let text = DisclosureText.alert(pending)
            let alert = NSAlert(); alert.messageText = text.title; alert.informativeText = text.body
            alert.addButton(withTitle: "Send and Apply"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { revertRoutes(); return }
        }
        appliedRoutes = routes; routes.save(to: .standard); DisclosureAcknowledgement.record(plan, in: .standard)
        appliedRetention = retention
        appliedHistoryMode = historyMode; records?.persistsTranscripts = historyMode.persistsTranscripts
        let defaults = UserDefaults.standard
        defaults.set(modelDirectory, forKey: "modelDirectory"); defaults.set(shortcut, forKey: "shortcut")
        defaults.set(showMenuBar, forKey: "showMenuBar"); defaults.set(automaticInsertion, forKey: "automaticInsertion")
        defaults.set(intelligentLeadingSpace, forKey: "intelligentLeadingSpace")
        defaults.set(retention, forKey: "retention")
        if let processing {
            var next = processing.settings
            next.options = CleanupOptions(fillers: cleanupFillers, corrections: cleanupCorrections, lists: cleanupLists)
            next.learningEnabled = learningEnabled; next.route = routes.cleanup.processingRoute
            next.historyMode = historyMode; next.updateChecksEnabled = updateChecksEnabled
            do { try processing.update(next) } catch { setPhase("Error", "Could not save cleanup and learning settings.") }
        }
        // Also saved directly, so they persist when the dictionary (and so processing) is unavailable.
        defaults.set(historyMode.rawValue, forKey: ProcessingSettings.Key.historyMode)
        defaults.set(updateChecksEnabled, forKey: ProcessingSettings.Key.updateChecks)
        do { try store?.purge(retention: appliedRetention); try enforceHistoryCap(); refreshHistory() } catch { setPhase("Error", "Could not apply history retention.") }
        refreshPermissions(); if !preview { configureShortcut() }; updateMenu?()
    }
    private func revertRoutes() {
        transcriptionRoute = appliedRoutes.transcription; cloudTranscriber = appliedRoutes.cloudTranscriber; cleanupChoice = appliedRoutes.cleanup
        localServerURL = appliedRoutes.serverURL; localServerModel = appliedRoutes.serverModel
    }
    private func routePlan(_ routes: RouteSettings, cleanupSendsText: Bool) -> RoutePlan {
        RoutePlan.make(routes, cleanupSendsText: cleanupSendsText) { try? self.credentials.read($0) }
    }
    private func configureShortcut() {
        removeShortcut()
        guard sessionAvailable else { return }
        guard CGPreflightListenEventAccess() else { message = "Allow Input Monitoring, then click Refresh Permissions to enable the shortcut."; return }
        let binding: ShortcutBinding = shortcut == "fn" ? .fn : shortcut == "ctrl-option-space" ? .controlOptionSpace : .rightOption
        let token = shortcutGeneration
        let next = ShortcutListener(binding: binding, processingSeconds: 0, onAction: { [weak self] action, done in
            guard let self, self.shortcutGeneration == token else { done(); return }
            self.handle(action, done: done)
        })
        guard let tap = next.createTap(), let nextSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { message = "The shortcut could not start. Check Input Monitoring and Accessibility."; return }
        next.onEscapeWhileProcessing = { [weak self] in self?.cancelCloudRequest() }
        next.onCopyChord = { [weak self] in self?.copyLatestRawTranscript() }
        // A press while the previous dictation processes records right away; its events replay
        // into the machine when that dictation finishes, which adopts this capture.
        next.onQueuedPress = { [weak self] in
            guard let self, self.sessionAvailable else { return false }
            let shown = (self.phase, self.message)
            guard self.session.startEarly() else { return false }
            self.phaseBeforeEarly = shown; return true
        }
        next.onQueuedCancel = { [weak self] in
            guard let self else { return }
            self.session.cancelEarly()
            if self.session.state == .processing, let (phase, message) = self.phaseBeforeEarly { self.setPhase(phase, message) }
        }
        listener = next; source = nextSource
        // A stalled main thread must not keep recording after a hold's release.
        next.onHoldRelease = { released in Capture.current?.cut(after: released + AppController.releaseTail) }
        if let retry {
            next.onPressFromIdle = { [prestart] in prestart.begin(store: retry) }
            next.onPressWithoutStart = { [prestart] in prestart.discard(store: retry) }
        }
        let thread = TapThread(source: nextSource); thread.startAndWait(); tapThread = thread
        CGEvent.tapEnable(tap: tap, enable: true)
        // ponytail: fixed tail; measured: long dictations lost the last word at 0 s, kept it at 0.6 s.
        session.releaseTail = Self.releaseTail
        session.takePrestarted = { [weak self] in
            guard let self, let (capture, url) = self.prestart.take() else { return nil }
            self.capture = capture; return url
        }
        session.resumeCapture = { [weak self] in self?.setPhase("Listening", "Listening… Release to finish, or press Escape to cancel.") }
        session.finishRecording = { [weak self] in timingLog.notice("capture-cap reached"); guard let self, let listener = self.listener else { return }; listener.emit(listener.machine.finish()) }
        session.resetShortcut = { [weak self] in guard let self, let listener = self.listener else { return }; listener.emit(listener.machine.eventStreamLost()); listener.machine.processingFinished() }
    }
    private func removeShortcut() {
        shortcutGeneration = UUID()
        tapThread?.stop(); tapThread = nil
        if let tap = listener?.tap { CFMachPortInvalidate(tap) }
        source = nil; listener = nil
    }
    private func handle(_ action: ShortcutMachine.Action, done: @escaping () -> Void) {
        // A refused start never adopts the capture begun on the tap thread; delete it.
        defer { if action == .start, let retry { prestart.discard(store: retry) } }
        guard sessionAvailable else { done(); return }
        if action == .start {
            guard permission() == "authorized" else { session.resetShortcut?(); setPhase("Error", "Allow Microphone access in Settings before dictating."); done(); return }
            // An unconfigured or unconfirmed cloud route refuses; it never falls back to local.
            let plan = routePlan(appliedRoutes, cleanupSendsText: processing?.settings.options.anyEnabled ?? false)
            let unconfirmed = !DisclosureAcknowledgement.pending(plan, acknowledged: DisclosureAcknowledgement.acknowledged(.standard)).isEmpty
            if let refusal = plan.refusal ?? (unconfirmed ? DisclosureText.startRefusal : nil) {
                session.resetShortcut?(); setPhase("Error", refusal); done(); return
            }
            if plan.usesLocalModel, let refusal = ModelGate.startRefusal(modelAvailable: modelFilesAvailable(), runtimeAvailable: Bundle.main.url(forAuxiliaryExecutable: "ModelBench") != nil, downloadingActiveModel: modelDownloadInFlight && !usesCustomModelFolder) {
                session.resetShortcut?(); setPhase("Error", refusal); done(); return
            }
            sessionTranscriber = plan.transcriber; processing?.cloudCleaner = plan.cleaner
            destination = try? captureFocus()
            if destination?.secure == true { session.resetShortcut?(); setPhase("Error", "Password fields cannot receive dictation."); done(); return }
            if destination?.pid == getpid() { destination = nil }
            focusStable = true; insertThisSession = automaticInsertion; leadingSpaceThisSession = intelligentLeadingSpace; activeModelDirectory = modelDirectory
            listeningStarted = Date(); generation = UUID(); recoveryEntryID = nil; recordingFailed = false
            destinationScreen = screenForDestination(destination)
        }
        session.receive(action, completed: done)
        if action == .start, session.state == .listening, sessionTranscriber == nil, let capture, let audio = session.audio { attachChunks(capture, audio: audio) }
        if action == .cancel { destination = nil; setPhase("Ready", "Recording canceled."); bubble.hide() }
        else if action == .start && session.state == .idle { setPhase("Error", "The microphone could not start. Check the selected input device.") }
        else if action == .finish && session.state == .idle && phase == "Listening" {
            destination = nil; setPhase("Error", "No audio was captured. Check your microphone and try again.")
        }
    }
    /// Local route: transcribe this recording's chunks on the warm helper while it records.
    private func attachChunks(_ capture: Capture, audio: URL) {
        let models = URL(fileURLWithPath: activeModelDirectory)
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "ModelBench"), let manifest = Bundle.main.url(forResource: "artifact-pins", withExtension: "json"),
              let fingerprint = try? ModelVerificationCache.fingerprint(models, manifest: manifest) else { return }
        let key = models.path + "|" + fingerprint.joined(separator: ","), warm = warm
        let job = ChunkJob { url, done in
            DispatchQueue.global(qos: .userInitiated).async {
                guard (try? ModelVerificationCache.shared.verify(models, manifest: manifest)) != nil else { done(nil); return }
                warm.transcribe(url, helper: helper, models: models, key: key, completion: done)
            }
        }
        if capture.attachChunks({ job.receive($0) }) { chunkJobs[audio] = job }
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
    func cancelRecording() {
        if cloudRequest.isActive { cancelCloudRequest(); return }
        guard let listener else { return }; listener.emit(listener.machine.cancel())
    }
    /// Escape or Cancel during a cloud request cancels its Task (and HTTP request); nothing from
    /// this session is inserted. Audio is deleted, as for a canceled recording; a transcript that
    /// was already saved stays in History.
    func cancelCloudRequest() {
        guard cloudRequest.isActive, let done = cloudDone else { return }
        generation = UUID(); cloudRequest.cancel(); cloudDone = nil
        let stage = cloudStage; cloudStage = nil
        if stage == .transcription, let audio = session.audio { try? FileManager.default.removeItem(at: audio) }
        destination = nil
        setPhase("Ready", stage == .transcription ? CloudTranscription.message(.cancelled) ?? "Canceled." : "Canceled. The raw transcript is saved in History and was not inserted.")
        bubble.hide(); historySaved(); done()
    }
    func setPhase(_ phase: String, _ message: String) {
        self.phase = phase; self.message = message
        // "No speech" needs no action, so its popup leaves on its own after 2 s unless replaced.
        let shown = UUID(); statusShown = shown
        if phase == "Error" && message.hasPrefix("No speech was detected") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.statusShown == shown else { return }
                self.dismissStatus()
            }
        }
        // Errors raised while processing leave that session's audio retained for retry.
        // Audio already deleted after a usable transcript (e.g. a held cleanup) is not offered.
        recoveryAudio = phase == "Error" && sessionAvailable && session.state == .processing ? session.audio.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } : nil
        refreshRecoveryAudio()
        updateMenu?()
        bubble.show(phase: phase, message: message, screen: destinationScreen)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    private func transcribe(_ audio: URL, done: @escaping () -> Void) {
        if let provider = sessionTranscriber { transcribeInCloud(audio, with: provider, done: done); return }
        setPhase("Processing", "Transcribing on this Mac…")
        let token = generation; let models = URL(fileURLWithPath: activeModelDirectory)
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "ModelBench"), let manifest = Bundle.main.url(forResource: "artifact-pins", withExtension: "json"), let store = records else { setPhase("Error", "The model runtime is unavailable. Audio is saved for retry."); done(); return }
        let timestamp = listeningStarted
        let began = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { timingLog.notice("model-verify took=\(ProcessInfo.processInfo.systemUptime - began, format: .fixed(precision: 3))") }
            do { try ModelVerificationCache.shared.verify(models, manifest: manifest) }
            catch { DispatchQueue.main.async { guard let self, self.generation == token else { return }; self.setPhase("Error", "Model verification failed. Choose the pinned model folder. Audio is saved for retry."); done() }; return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.runTranscription(helper, models: models, manifest: manifest, audio: audio, store: store, timestamp: timestamp, token: token, done: done)
            }
        }
    }
    private struct NoSpeech: Error {}
    /// Warm helper first; if it cannot answer, the one-shot helper transcribes the same audio.
    private func runTranscription(_ helper: URL, models: URL, manifest: URL, audio: URL, store: HistoryRouter<HistoryEntry>, timestamp: Date, token: UUID, done: @escaping () -> Void) {
        // Chunks transcribed during recording; if any failed, the full WAV goes through below.
        if let job = chunkJobs.removeValue(forKey: audio) {
            if job.isEnded {
                let began = ProcessInfo.processInfo.systemUptime
                job.result { [weak self] text in
                    timingLog.notice("chunks took=\(ProcessInfo.processInfo.systemUptime - began, format: .fixed(precision: 3)) answered=\(text != nil, privacy: .public)")
                    if let text, let line = try? JSONSerialization.data(withJSONObject: ["text": text]) {
                        self?.handleTranscript(.success(line), audio: audio, store: store, timestamp: timestamp, token: token, done: done); return
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == token else { return }
                        self.runTranscription(helper, models: models, manifest: manifest, audio: audio, store: store, timestamp: timestamp, token: token, done: done)
                    }
                }
                return
            }
            job.discard()
        }
        let key = models.path + "|" + ((try? ModelVerificationCache.fingerprint(models, manifest: manifest))?.joined(separator: ",") ?? "")
        let began = ProcessInfo.processInfo.systemUptime
        warm.transcribe(audio, helper: helper, models: models, key: key) { [weak self] line in
            timingLog.notice("warm-runner took=\(ProcessInfo.processInfo.systemUptime - began, format: .fixed(precision: 3)) answered=\(line != nil, privacy: .public)")
            if let line { self?.handleTranscript(.success(line), audio: audio, store: store, timestamp: timestamp, token: token, done: done); return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.launchRunner(helper, models: models, audio: audio, store: store, timestamp: timestamp, token: token, done: done)
            }
        }
    }
    private func launchRunner(_ helper: URL, models: URL, audio: URL, store: HistoryRouter<HistoryEntry>, timestamp: Date, token: UUID, done: @escaping () -> Void) {
        let temp = audio.deletingLastPathComponent().appendingPathComponent(".result-" + UUID().uuidString)
        let fd = open(temp.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { setPhase("Error", "Could not prepare transcription. Audio is saved for retry."); done(); return }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let task = Process(); task.executableURL = helper; task.arguments = [models.path, audio.path, "--single"]
        task.standardOutput = output; task.standardError = FileHandle.nullDevice
        do { try task.run(); runner = task; runnerOutput = temp } catch { try? output.close(); try? FileManager.default.removeItem(at: temp); setPhase("Error", "Transcription could not start. Audio is saved for retry."); done(); return }
        let timeout = DispatchWorkItem { if task.isRunning { task.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if task.isRunning { kill(task.processIdentifier, SIGKILL) } } } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timeout)
        let launched = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            task.waitUntilExit(); timeout.cancel()
            timingLog.notice("runner took=\(ProcessInfo.processInfo.systemUptime - launched, format: .fixed(precision: 3)) status=\(task.terminationStatus)")
            defer { try? output.close(); try? FileManager.default.removeItem(at: temp) }
            let result = Result<Data, Error> {
                guard task.terminationStatus == 0 else { throw CaptureError("Transcription failed") }
                try output.synchronize(); try output.seek(toOffset: 0)
                return try output.readToEnd() ?? Data()
            }
            self?.handleTranscript(result, audio: audio, store: store, timestamp: timestamp, token: token, done: done)
        }
    }
    /// Shared by the warm and one-shot helpers: parse the last JSON line, save, then deliver. Runs off main.
    nonisolated private func handleTranscript(_ result: Result<Data, Error>, audio: URL, store: HistoryRouter<HistoryEntry>, timestamp: Date, token: UUID, done: @escaping () -> Void) {
        do {
            let data = try result.get()
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
                self.deliver(savedEntry, store: store, token: token, done: done)
            }
        } catch {
            let message = error is NoSpeech ? "No speech was detected. Check your microphone and try again." : "Transcription failed. Audio is saved for retry for up to 24 hours."
            DispatchQueue.main.async { [weak self] in guard let self, self.generation == token else { return }; self.runner = nil; self.runnerOutput = nil; self.setPhase("Error", message); done() }
        }
    }
    /// Cloud transcription (R4): one provider call in a cancellable Task, never the local model.
    /// The result then follows the local path: history save, processing, insertion.
    private func transcribeInCloud(_ audio: URL, with provider: TranscriptionProvider, done: @escaping () -> Void) {
        guard let store = records else { setPhase("Error", "Private storage is unavailable. Audio is saved for retry."); done(); return }
        let token = generation; let timestamp = listeningStarted
        cloudStage = .transcription; cloudDone = done
        cloudRequest.start({ await CloudTranscription.run(provider: provider, audioFile: audio) }) { [weak self] outcome in
            guard let self, self.generation == token else { return }
            self.cloudStage = nil; self.cloudDone = nil
            let text: String, held: Bool
            switch outcome {
            case .transcript(let value): text = value; held = false
            case .heldAnswerSuspected(let value): text = value; held = true
            case .noSpeech, .failed, .cancelled:
                // Audio stays for retry (until the 24-hour purge) unless the provider error discards it.
                if case .failed(_, false) = outcome { try? FileManager.default.removeItem(at: audio) }
                self.setPhase("Error", CloudTranscription.message(outcome) ?? CloudTranscription.unknownFailure); done(); return
            }
            // An answer-shaped LLM transcript is held like a failed cleanup: raw text only, never inserted.
            let entry = HistoryEntry(id: UUID().uuidString, recordedAt: timestamp, rawText: text, finalText: held ? "" : text, insertionStatus: held ? "held-transcript" : "saved-not-inserted")
            do { try store.save(entry) } catch { self.setPhase("Error", "Could not save the transcript. Audio is saved for retry for up to 24 hours."); done(); return }
            try? FileManager.default.removeItem(at: audio)
            guard !held else {
                self.recoveryEntryID = entry.id
                self.setPhase("Error", CloudTranscription.message(outcome) ?? ""); self.destination = nil; self.historySaved(); done(); return
            }
            self.deliver(entry, store: store, token: token, done: done)
        }
        setPhase("Processing", "Transcribing with \(provider.id.displayName)…")
    }
    /// Dictionary, then cleanup, for a transcript already saved to History. Local rules run here;
    /// any other cleanup route makes one provider call in a cancellable Task (no local fallback).
    private func deliver(_ savedEntry: HistoryEntry, store: HistoryRouter<HistoryEntry>, token: UUID, done: @escaping () -> Void) {
        recoveryEntryID = savedEntry.id
        let text = savedEntry.rawText
        guard let processing, processing.settings.route != .local else {
            complete(processing?.process(text) ?? .heldForRecovery(raw: text, reason: .cleanerFailed), entry: savedEntry, store: store, done: done); return
        }
        cloudStage = .cleanup; cloudDone = done
        cloudRequest.start({ await processing.processAsync(text) }) { [weak self] outcome in
            guard let self, self.generation == token else { return }
            self.cloudStage = nil; self.cloudDone = nil
            self.complete(outcome, entry: savedEntry, store: store, done: done)
        }
        setPhase("Processing", "Cleaning up with \(processing.cloudCleaner?.id.displayName ?? "the cleanup provider")…")
    }
    private func complete(_ outcome: ProcessingOutcome, entry savedEntry: HistoryEntry, store: HistoryRouter<HistoryEntry>, done: @escaping () -> Void) {
        var entry = savedEntry
        let text = entry.rawText
        let saved = HistoryText.saved(persists: !store.sessionOnlyIDs.contains(entry.id))
        // A held result keeps only the raw transcript and is never inserted.
        guard case .insert(let processed) = outcome else {
            let reason = processing?.lastProviderError.map { " " + $0.userMessage } ?? ""
            // Content-free: the guard's category, never the text.
            if case .heldForRecovery(_, let why) = outcome {
                timingLog.notice("cleanup-held reason=\(why.rawValue, privacy: .public) provider-error=\(self.processing?.lastProviderError != nil, privacy: .public)")
            }
            entry = HistoryEntry(id: entry.id, recordedAt: entry.recordedAt, rawText: entry.rawText, finalText: "", insertionStatus: "held-cleanup")
            do { try store.save(entry); setPhase("Error", "Cleanup was held for review.\(reason) The raw transcript is in History. Press ⌃⌘C to copy it.") }
            catch { setPhase("Error", "Cleanup was held for review.\(reason) The raw transcript is in History; its status could not be saved.") }
            destination = nil; historySaved(); done(); return
        }
        // Only filler words were heard: keep the raw transcript, insert nothing, show no error.
        if processed.isEmpty {
            entry = HistoryEntry(id: entry.id, recordedAt: entry.recordedAt, rawText: entry.rawText, finalText: "", insertionStatus: "saved-not-inserted")
            try? store.save(entry)
            setPhase("Ready", "Only filler words were heard, so nothing was inserted.")
            destination = nil; historySaved(); done(); return
        }
        if processed != text {
            entry = HistoryEntry(id: entry.id, recordedAt: entry.recordedAt, rawText: entry.rawText, finalText: processed, insertionStatus: entry.insertionStatus)
            do { try store.save(entry) } catch { setPhase("Error", "Could not save the processed transcript. The raw transcript is in History."); destination = nil; historySaved(); done(); return }
        }
        if insertThisSession, focusStable, let destination {
            // Persist uncertainty before the one permitted delivery attempt.
            let insertionText = textWithLeadingSpace(processed, value: destination.value, selection: destination.selection, enabled: leadingSpaceThisSession)
            entry = HistoryEntry(id: entry.id, recordedAt: entry.recordedAt, rawText: entry.rawText, finalText: insertionText, insertionStatus: "insertion-pending")
            do {
                try store.save(entry)
                // The text appearing is the signal; insertion's verification waits block the main
                // thread, so take the indicator down first instead of freezing it.
                bubble.hide()
                let inserting = ProcessInfo.processInfo.systemUptime
                let insertion = insertText(entry.finalText, into: destination, policy: .singleAttempt)
                timingLog.notice("insert app=\(destination.bundleID, privacy: .public) status=\(insertion.status.rawValue, privacy: .public) took=\(ProcessInfo.processInfo.systemUptime - inserting, format: .fixed(precision: 3)) detail=\(insertion.detail, privacy: .public)")
                entry.insertionStatus = insertion.status.rawValue
                try store.save(entry)
                switch insertion.status {
                case .verified: setPhase("Inserted", "Inserted.")
                case .unverified: setPhase("Saved", "\(saved) Delivery could not be verified; no retry was attempted.")
                case .failed:
                    entry.insertionStatus = copyToClipboard(processed) ? "copied" : entry.insertionStatus; try? store.save(entry)
                    setPhase("Saved", entry.insertionStatus == "copied" ? "This field could not take the text, so it was copied to the clipboard." : "\(saved) The text could not be inserted into this field, so nothing was typed.")
                }
            } catch { setPhase("Saved", "\(saved) Insertion status could not be saved.") }
        } else {
            timingLog.notice("insert skipped auto=\(self.insertThisSession, privacy: .public) focus-stable=\(self.focusStable, privacy: .public) destination=\(self.destination?.bundleID ?? "none", privacy: .public)")
            // No usable text field (none focused, or focus moved): the text goes to the clipboard instead.
            if insertThisSession, copyToClipboard(processed) {
                entry.insertionStatus = "copied"; try? store.save(entry)
                setPhase("Saved", "No text field was ready, so the text was copied to the clipboard.")
            } else { setPhase("Saved", "\(saved) The destination changed or automatic insertion is off.") }
        }
        destination = nil; historySaved(); done()
    }
    /// Leaves the dictation on the clipboard for the user to paste; replaces what was there.
    private func copyToClipboard(_ text: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        return board.setString(text, forType: .string)
    }
    // Explicit developer check of the production pipeline, using a synthetic file
    // and an exact disposable destination. Never enabled during ordinary launch.
    func checkSavedAudio(_ audio: URL, expectedApp: String, completion: @escaping () -> Void) {
        guard sessionAvailable, modelFilesAvailable(), let focused = try? captureFocus(),
              focused.bundleID == expectedApp, focused.pid != getpid(), !focused.secure else {
            fputs("app-check=refused destination-or-model-unavailable\n", stderr); completion(); return
        }
        guard !isBusy, let retry else { completion(); return }
        let ownedAudio: URL
        do { ownedAudio = try copyProbeAudio(audio, into: retry) } catch {
            fputs("app-check=refused audio-copy-failed\n", stderr); completion(); return
        }
        // The probe is local only: it never sends audio or text to a provider.
        sessionTranscriber = nil; processing?.cloudCleaner = nil
        destination = focused; focusStable = true; insertThisSession = true; leadingSpaceThisSession = intelligentLeadingSpace
        activeModelDirectory = modelDirectory; listeningStarted = Date(); generation = UUID()
        destinationScreen = screenForDestination(focused); recoveryEntryID = nil
        transcribe(ownedAudio) { [weak self] in
            print("app-check=complete state=\(self?.phase ?? "unknown")")
            fflush(stdout); completion()
        }
    }
    private func refreshRecoveryAudio() {
        guard let retry else { hasRecoveryAudio = false; return }
        hasRecoveryAudio = ((try? FileManager.default.contentsOfDirectory(at: retry.directory, includingPropertiesForKeys: nil)) ?? []).contains { $0.pathExtension == "wav" }
    }
    func refreshHistory() {
        do { history = try records?.entries() ?? []; sessionOnlyIDs = records?.sessionOnlyIDs ?? [] }
        catch { message = "Could not read saved history." }
    }
    func copyEntry(_ entry: HistoryEntry) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.finalText, forType: .string) }
    /// The explicit raw-text action for held cleanup (and any entry whose final text differs).
    /// ⌃⌘C anywhere: the latest dictation's raw transcript, so a held or uninserted one needs no
    /// trip to History. Does nothing when this launch has no transcript yet.
    func copyLatestRawTranscript() {
        guard let id = recoveryEntryID, let entry = history.first(where: { $0.id == id }) else { return }
        copyRawEntry(entry)
        if !isBusy { setPhase("Ready", "Raw transcript copied.") }
    }
    func copyRawEntry(_ entry: HistoryEntry) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.rawText, forType: .string) }
    /// Turns all three cleanup options off. Like other settings, it takes effect at once.
    func useFaithfulTranscription() { cleanupFillers = false; cleanupCorrections = false; cleanupLists = false }
    func refreshDictionary() { dictionaryEntries = processing?.dictionary.entries ?? [] }
    @discardableResult
    func addDictionaryEntry(preferred: String, variants: String) -> Bool {
        guard let processing else { dictionaryMessage = "The dictionary is unavailable."; return false }
        do { try processing.addEntry(preferred: preferred, variants: variants); dictionaryMessage = ""; refreshDictionary(); return true }
        catch { dictionaryMessage = (error as? DictionaryError)?.description ?? "Could not save the dictionary."; return false }
    }
    func deleteDictionaryEntry(_ entry: DictionaryEntry) {
        do { try processing?.deleteEntry(id: entry.id); dictionaryMessage = "" } catch { dictionaryMessage = "Could not delete this dictionary entry." }
        refreshDictionary()
    }
    func resetLearnedEntries() {
        let alert = NSAlert(); alert.messageText = "Reset learned dictionary entries?"
        alert.informativeText = "This removes every learned entry and all learning evidence. Entries you added stay."
        alert.addButton(withTitle: "Reset Learned"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try processing?.resetLearned(); dictionaryMessage = "" } catch { dictionaryMessage = "Could not reset learned entries." }
        refreshDictionary()
    }
    // TODO(observation): automatic post-insertion observation is not wired in. The spike's
    // Observation.swift is not part of the app; when it is, feed attributed corrections to
    // processing?.observe(_:) during the window and processing?.settle(sessionID:) when it closes,
    // then refreshDictionary(). Learning must stay off for fields where learningEligible is false.
    func deleteEntry(_ entry: HistoryEntry) { do { try records?.delete(entry); refreshHistory() } catch { message = "Could not delete this transcript." } }
    func clearHistory() {
        let alert = NSAlert(); alert.messageText = "Delete all saved transcripts?"; alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Delete All"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            do { for entry in history { try records?.delete(entry) } }
            catch { message = "Could not delete all transcripts. Remaining entries are shown in History." }
            refreshHistory()
        }
    }
    func dismissStatus() {
        guard !isBusy else { return }
        if sessionAvailable {
            setPhase("Ready", "Hold your shortcut to dictate, or double-press it to dictate until you press it again.")
        } else {
            phase = "Error"; message = "Private storage is unavailable. Murmur cannot start."
            updateMenu?()
        }
        bubble.hide()
    }
    func showSettings() { openSettings?() }
    /// Selects this error's retained audio when known; otherwise opens the retry folder holding older retained audio.
    func revealRecoveryAudio() {
        if let recoveryAudio, FileManager.default.fileExists(atPath: recoveryAudio.path) { NSWorkspace.shared.activateFileViewerSelecting([recoveryAudio]) }
        else if hasRecoveryAudio, let retry { NSWorkspace.shared.open(retry.directory) }
    }
    // MARK: Model download (R2)

    func downloadModel() {
        guard let downloader else { modelMessage = ModelDownloadError.invalidManifest.userMessage; return }
        if let refusal = ModelGate.downloadRefusal(isBusy: isBusy, preview: preview, downloading: modelDownloadInFlight) { modelMessage = refusal; return }
        // The license and size are shown before any byte is fetched.
        let text = ModelFacts.confirmation(downloadSize: downloader.downloadSize, license: downloader.license)
        let alert = NSAlert(); alert.messageText = text.title; alert.informativeText = text.body
        alert.addButton(withTitle: "Download"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // A dictation may have started while the alert was open.
        if let refusal = ModelGate.downloadRefusal(isBusy: isBusy, preview: preview, downloading: modelDownloadInFlight) { modelMessage = refusal; return }
        modelDownloadInFlight = true; modelMessage = ""
        modelStatus = .downloading(ModelDownloadProgress(bytesDone: 0, totalBytes: downloader.downloadSize))
        downloader.start { result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.modelDownloadInFlight = false
                self.modelStatus = downloader.status()
                self.modelMessage = ModelFacts.completionMessage(result)
                // Point dictation at the verified download right away (an explicit user action, like Apply).
                if case .success = result {
                    self.modelDirectory = downloader.target.path
                    UserDefaults.standard.set(downloader.target.path, forKey: "modelDirectory")
                }
            }
        }
    }
    func cancelModelDownload() { downloader?.cancel() }
    func removeModel() {
        guard let downloader else { return }
        if let refusal = ModelGate.removeRefusal(isBusy: isBusy, preview: preview, downloading: modelDownloadInFlight) { modelMessage = refusal; return }
        let alert = NSAlert(); alert.messageText = "Remove the downloaded model?"
        alert.informativeText = "Murmur cannot dictate until you download it again (\(ModelFacts.formatBytes(downloader.downloadSize))) or choose another model folder."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let refusal = ModelGate.removeRefusal(isBusy: isBusy, preview: preview, downloading: modelDownloadInFlight) { modelMessage = refusal; return }
        warm.stopNow() // Release the helper's open model files before deleting them.
        do { try downloader.remove(); modelMessage = "The model was removed." }
        catch { modelMessage = (error as? ModelDownloadError)?.userMessage ?? ModelDownloadError.fileSystem.userMessage }
        modelStatus = downloader.status()
    }
    func useDefaultModelDirectory() { if let downloader { modelDirectory = downloader.target.path } }
    func openLink(_ url: URL) { NSWorkspace.shared.open(url) }

    // MARK: History cap and Delete All Data (R9, §6)

    private func historyDisk(_ store: HistoryStore) -> HistoryDisk<HistoryEntry> {
        HistoryDisk(save: store.save, entries: store.entries, delete: store.delete)
    }
    /// Drops oldest disk entries over the 50 MB cap for finite retention; warns for Forever.
    private func enforceHistoryCap() throws {
        guard let store else { historyCapWarning = nil; return }
        let result = try HistoryCap.enforce(entries: store.entries(), directory: store.directory, retention: HistoryRetention(rawValue: appliedRetention) ?? .thirtyDays, delete: store.delete)
        historyCapWarning = appliedRetention == HistoryRetention.forever.rawValue ? result.status.warning : nil
    }
    /// Called once a dictation's last history save is done.
    private func historySaved() {
        do { try enforceHistoryCap() } catch { historyCapWarning = "Could not check the history size limit. Open History to review saved data." }
        refreshHistory()
    }
    func deleteAllData() {
        guard !isBusy else { message = "Finish the current dictation before deleting data."; return }
        guard let base = dataDirectory else { return }
        let alert = NSAlert(); alert.messageText = DeleteAllDataText.title; alert.informativeText = DeleteAllDataText.body
        alert.addButton(withTitle: "Delete All Data"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !isBusy else { message = "Finish the current dictation before deleting data."; return }
        let locations = MurmurDataLocations.standard(base: base)
        // Preview and the developer probe never touch the login Keychain.
        let removeKeys: () throws -> [String] = preview ? { [] } : {
            try KeychainCredentialStore(service: "Murmur").deleteAll()
            return ProviderID.allCases.map(\.rawValue)
        }
        let report = DataWipe.deleteAllData(locations, removeKeychainItems: removeKeys)
        // The old stores point at deleted directories or hold deleted data in memory: recreate them empty.
        let failed = PostWipeStep.run { step in
            switch step {
            case .discardInMemoryState:
                records?.clearSessionOnly(); records = nil; store = nil; retry = nil; processing = nil
                recoveryEntryID = nil; recoveryAudio = nil; historyCapWarning = nil
            case .recreateHistory:
                let next = try HistoryStore(directory: locations.history)
                store = next; records = HistoryRouter(disk: historyDisk(next), persists: appliedHistoryMode.persistsTranscripts)
            case .recreateRetryAudio:
                retry = try RetryAudio(directory: locations.retryAudio)
            case .reloadDictionary:
                do { processing = try ProcessingCoordinator(directory: locations.dictionary, isCommonWord: isCommonEnglishWord); dictionaryMessage = "" }
                catch { dictionaryMessage = "The dictionary could not be read. Dictations are held in History until it is repaired."; throw error }
            case .refreshViews:
                refreshHistory(); refreshRecoveryAudio(); refreshDictionary(); refreshKeys()
            }
        }
        let outcome = PostWipeStep.message(report: report, failedSteps: failed)
        if !sessionAvailable { phase = "Error"; message = outcome.text + " Private storage is unavailable. Restart Murmur."; updateMenu?(); return }
        setPhase(outcome.succeeded ? "Ready" : "Error", outcome.text)
    }

    // MARK: API keys (R5) and the local model server

    /// Publishes which providers have a key. The key itself never leaves the Keychain store.
    func refreshKeys() { savedKeys = Set(KeyText.providers.filter { credentials.exists($0) }) }
    @discardableResult
    func saveKey(_ provider: ProviderID, _ raw: String) -> Bool {
        guard let key = APIKey(raw) else { keyMessages[provider] = KeyText.invalid; return false }
        do { try credentials.save(key, for: provider); keyMessages[provider] = KeyText.saved }
        catch { keyMessages[provider] = KeyText.storeFailed; return false }
        refreshKeys(); return true
    }
    func removeKey(_ provider: ProviderID) {
        do { try credentials.delete(provider); keyMessages[provider] = KeyText.removed } catch { keyMessages[provider] = KeyText.removeFailed }
        refreshKeys()
    }
    func validateKey(_ provider: ProviderID) {
        let key: APIKey?
        do { key = try credentials.read(provider) } catch { keyMessages[provider] = KeyText.unreadable; return }
        keyMessages[provider] = KeyText.checking
        let server = localServerURL
        Task { @MainActor [weak self] in
            let message = await KeyCheck.run(provider, key: key, serverURL: server)
            self?.keyMessages[provider] = message
        }
    }
    /// Lists the local server's models (sends no transcript). Fills the model name if it is empty.
    func findLocalModels() {
        guard !findingModels else { return }
        let key = try? credentials.read(.localServer)
        findingModels = true; localServerMessage = KeyText.checking
        let server = localServerURL
        Task { @MainActor [weak self] in
            let result = await KeyCheck.discoverModels(serverURL: server, key: key)
            guard let self else { return }
            self.findingModels = false
            self.localServerMessage = KeyCheck.discoveryMessage(result)
            if case .success(let models) = result {
                self.localServerModels = models
                if self.localServerModel.isEmpty, let first = models.first { self.localServerModel = first }
            }
        }
    }

    // MARK: Update checks (R12)

    func checkForUpdates() { runUpdateCheck(manual: true) }
    private func runUpdateCheck(manual: Bool) {
        guard let checker = updateChecker else { if manual { updateStatus = "Update checks are unavailable in this build." }; return }
        guard !checkingForUpdates else { return }
        if !manual {
            guard UpdateSchedule.shouldAttemptAutomatic(lastAttempt: lastAutomaticUpdateAttempt) else { return }
            lastAutomaticUpdateAttempt = Date()
        }
        checkingForUpdates = true
        if manual { updateStatus = "Checking for updates…" }
        let version = currentVersion
        Task { @MainActor [weak self] in
            let result = await checker.check(manual: manual)
            guard let self else { return }
            self.checkingForUpdates = false
            if let text = UpdateText.status(result, manual: manual, currentVersion: version) { self.updateStatus = text }
            self.availableRelease = UpdateText.release(result, previous: self.availableRelease)
            self.updateMenu?()
        }
    }
    /// Opens the validated GitHub release page. Murmur never downloads or installs the update.
    func openReleasePage() { if let url = availableRelease?.pageURL { NSWorkspace.shared.open(url) } }

    func shutdown() {
        generation = UUID(); cloudRequest.cancel(); monitor?.invalidate(); expiry?.invalidate(); removeShortcut()
        downloader?.cancel()  // Verified and partial files stay staged; Retry resumes them.
        if sessionAvailable { session.shutdown() }
        if let runner, runner.isRunning {
            runner.terminate()
            // Closing the app cancels this one local helper; reap it before process exit.
            if runner.isRunning { kill(runner.processIdentifier, SIGKILL) }
            runner.waitUntilExit()
        }
        if let runnerOutput { try? FileManager.default.removeItem(at: runnerOutput) }
        warm.stopNow()
        bubble.hide()
        if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) }
    }
}

extension HistoryEntry: RetainedHistoryItem {}

/// The learning lexicon (PRD approved condition): a word is common when the English spell checker
/// finds no misspelling in it, so ordinary-word swaps (lunch→launch) are never learned.
/// CorrectionLedger calls it on the main thread only.
func isCommonEnglishWord(_ word: String) -> Bool {
    MainActor.assumeIsolated {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }
}

// Probe inputs belong to the caller; only the private copy follows retry cleanup.
func copyProbeAudio(_ audio: URL, into retry: RetryAudio) throws -> URL {
    let ownedAudio = try retry.create()
    do {
        let input = try FileHandle(forReadingFrom: audio)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: ownedAudio)
        defer { try? output.close() }
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { try output.write(contentsOf: data) }
        try output.synchronize()
        return ownedAudio
    } catch { try? retry.delete(ownedAudio); throw error }
}
