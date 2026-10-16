import AppKit
import SwiftUI
import ApplicationServices
import AVFoundation
import os
import Combine
import CryptoKit
import Darwin
import Carbon
import ServiceManagement
@preconcurrency import Dispatch

/// Content-free timing and stop reasons, alongside the capture and shortcut timing.
private let timingLog = Logger(subsystem: "cc.clouddev.dictation", category: "timing")

private let helperOutputLimit = 4 * 1024 * 1024

/// Drain stdout while the helper runs; waiting for exit first can deadlock on a full pipe.
func readHelperOutput(_ handle: FileHandle) throws -> Data {
    var result = Data()
    while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
        guard chunk.count <= helperOutputLimit - result.count else { throw CaptureError("Transcription output is too large") }
        result.append(chunk)
    }
    return result
}

/// What the transcription helper loads: the model folder plus, when dictionary support is
/// installed and verified and the dictionary has enabled entries, `--ctc DIR --vocabulary FILE`.
/// `key` changes whenever any of those change, which restarts the warm helper. Built only by
/// `make`, so the warm helper, chunks and the one-shot fallback always agree.
struct HelperLaunch: Equatable {
    let models: URL
    let dictionaryArguments: [String]
    let key: String

    /// Off the main thread: verifying the dictionary model hashes it once per change.
    static func make(models: URL, manifest: URL, vocabulary: URL?, dictionaryModel: URL) -> HelperLaunch? {
        guard let fingerprint = try? ModelVerificationCache.fingerprint(models, manifest: manifest) else { return nil }
        var key = models.path + "|" + fingerprint.joined(separator: ",")
        var arguments: [String] = []
        if let vocabulary, let terms = try? Data(contentsOf: vocabulary), !terms.isEmpty,
           (try? ModelVerificationCache.shared.verify(dictionaryModel, manifest: manifest, repository: dictionaryModelRepository)) != nil,
           let ctc = try? ModelVerificationCache.fingerprint(dictionaryModel, manifest: manifest, repository: dictionaryModelRepository) {
            arguments = ["--ctc", dictionaryModel.path, "--vocabulary", vocabulary.path]
            key += "|" + ctc.joined(separator: ",") + "|" + SHA256.hash(data: terms).map { String(format: "%02x", $0) }.joined()
        }
        return HelperLaunch(models: models, dictionaryArguments: arguments, key: key)
    }
}

/// Keeps `ModelBench MODEL_DIRECTORY --serve` running with the model loaded, so a dictation skips
/// process launch and model load (about 0.4 s). One request at a time on a private queue. Any
/// failure (not ready, died, timed out) answers nil so the caller falls back to a one-shot helper;
/// the warm process restarts on the next request. A changed launch key restarts it.
final class WarmRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "murmur.warm-runner", qos: .userInitiated)
    private var task: Process?, input: FileHandle?, output: FileHandle?, key: String?
    private var buffered = Data()
    /// Called on the runner's queue after each start with dictionary arguments: true when the
    /// helper could not load dictionary support (it then transcribes without it).
    var onDictionaryStatus: ((Bool) -> Void)?

    func prepare(helper: URL, launch: HelperLaunch) { queue.async { [self] in _ = start(helper, launch) } }
    /// `boundary`: a clip spanning a chunk cut; the answer lists dictionary replacements, not text.
    func transcribe(_ audio: URL, helper: URL, launch: HelperLaunch, boundary: Bool = false, completion: @escaping (Data?) -> Void) {
        send(boundary ? (try? JSONSerialization.data(withJSONObject: ["boundary": audio.path])).map { String(decoding: $0, as: UTF8.self) } : audio.path,
             helper: helper, launch: launch, completion: completion)
    }
    /// 16 kHz mono samples held in memory (an undone cancel); the answer is like an audio path's.
    func transcribe(samples: [Float], helper: URL, launch: HelperLaunch, completion: @escaping (Data?) -> Void) {
        let encoded = samples.withUnsafeBytes { Data($0).base64EncodedString() }
        send(#"{"samples":""# + encoded + #""}"#, helper: helper, launch: launch, completion: completion)
    }
    private func send(_ line: String?, helper: URL, launch: HelperLaunch, completion: @escaping (Data?) -> Void) {
        queue.async { [self] in
            guard let line, !line.contains("\n"), start(helper, launch), let input,
                  (try? input.write(contentsOf: Data((line + "\n").utf8))) != nil,
                  let line = readLine(timeout: 300) else { stopLocked(); completion(nil); return }
            completion(line)
        }
    }
    func stop() { queue.async { [self] in stopLocked() } }
    func stopNow() { queue.sync { stopLocked() } }

    private func start(_ helper: URL, _ launch: HelperLaunch) -> Bool {
        if let task, task.isRunning, self.key == launch.key { return true }
        stopLocked()
        let next = Process(), toChild = Pipe(), fromChild = Pipe()
        next.executableURL = helper; next.arguments = [launch.models.path, "--serve"] + launch.dictionaryArguments
        next.standardInput = toChild; next.standardOutput = fromChild; next.standardError = FileHandle.nullDevice
        do { try next.run() } catch { return false }
        task = next; input = toChild.fileHandleForWriting; output = fromChild.fileHandleForReading; self.key = launch.key; buffered = Data()
        // The first load of dictionary support compiles its Core ML model (about 15 s).
        guard let ready = readLine(timeout: launch.dictionaryArguments.isEmpty ? 60 : 120),
              let status = try? JSONSerialization.jsonObject(with: ready) as? [String: Any],
              status["ready"] as? Bool == true else { stopLocked(); return false }
        if !launch.dictionaryArguments.isEmpty { onDictionaryStatus?(status["vocabulary_error"] as? Bool ?? false) }
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
            guard chunk.count <= helperOutputLimit - buffered.count else { return nil }
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
/// only for the last chunk. Chunks go to the helper one at a time; the first failure drops the
/// rest, so the full-WAV fallback never queues behind them.
final class ChunkJob: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String?] = [], sentenceEnds: [Bool] = []
    /// A boundary clip is keyed by the chunk before its cut; it repairs a dictionary term the cut split.
    private var queued: [(index: Int, url: URL, boundary: Bool)] = [], inFlight = false
    private var repairs: [Int: [(from: String, to: String)]] = [:], boundariesOpen = 0
    private var failed = false, ended = false, discarded = false
    private var waiter: ((String?) -> Void)?
    private let transcribe: (URL, Bool, @escaping (Data?) -> Void) -> Void

    /// `transcribe(url, boundary, completion)`; see WarmRunner.transcribe.
    init(transcribe: @escaping (URL, Bool, @escaping (Data?) -> Void) -> Void) { self.transcribe = transcribe }

    /// Called on the capture queue, in order.
    func receive(_ event: Chunker.Event) {
        switch event {
        case .failed: lock.withLock { failed = true }; settle()
        case .end: lock.withLock { ended = true }; settle()
        case .chunk(let url, let last, let sentenceEnd):
            let accepted: Bool = lock.withLock {
                guard !discarded, !failed else { return false }
                texts.append(nil); sentenceEnds.append(sentenceEnd); if last { ended = true }
                queued.append((texts.count - 1, url, false)); return true
            }
            guard accepted else { try? FileManager.default.removeItem(at: url); return }
            pump()
        case .boundary(let url):
            let accepted: Bool = lock.withLock {
                guard !discarded, !failed, !texts.isEmpty else { return false }
                boundariesOpen += 1; queued.append((texts.count - 1, url, true)); return true
            }
            guard accepted else { try? FileManager.default.removeItem(at: url); return }
            pump()
        }
    }
    private func pump() {
        let next: (index: Int, url: URL, boundary: Bool)? = lock.withLock {
            guard !inFlight, !queued.isEmpty else { return nil }
            inFlight = true; return queued.removeFirst()
        }
        guard let next else { return }
        transcribe(next.url, next.boundary) { [self] line in
            try? FileManager.default.removeItem(at: next.url)
            let answer = line.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if next.boundary {
                // A boundary that fails only skips its repair.
                let found = (answer?["replacements"] as? [[String: String]] ?? []).compactMap { r in r["from"].flatMap { f in r["to"].map { (f, $0) } } }
                lock.withLock { inFlight = false; boundariesOpen -= 1; if !found.isEmpty { repairs[next.index] = found } }
                settle(); pump(); return
            }
            let text = answer?["text"] as? String
            let dropped: [URL] = lock.withLock {
                inFlight = false
                if let text { texts[next.index] = text; return [] }
                failed = true; boundariesOpen = 0; defer { queued = [] }; return queued.map(\.url)
            }
            dropped.forEach { try? FileManager.default.removeItem(at: $0) }
            settle(); pump()
        }
    }
    /// Applies each cut's boundary replacements to the chunk texts on either side of it.
    static func repaired(_ texts: [String], _ repairs: [Int: [(from: String, to: String)]]) -> [String] {
        var texts = texts
        for (index, found) in repairs.sorted(by: { $0.key < $1.key }) where index + 1 < texts.count {
            for replacement in found {
                guard let fixed = Chunker.repair(tail: texts[index], head: texts[index + 1], from: replacement.from, to: replacement.to) else { continue }
                texts[index] = fixed.tail; texts[index + 1] = fixed.head
            }
        }
        return texts
    }
    /// Whether the last chunk arrived (or chunking failed), so `result` will answer.
    var isEnded: Bool { lock.withLock { ended || failed } }
    /// Answers once: the joined transcript, or nil on any failure.
    func result(_ completion: @escaping (String?) -> Void) { lock.withLock { waiter = completion }; settle() }
    /// A canceled or abandoned recording: later chunks are deleted unread.
    func discard() {
        let dropped: [URL] = lock.withLock { discarded = true; waiter = nil; defer { queued = [] }; return queued.map(\.url) }
        dropped.forEach { try? FileManager.default.removeItem(at: $0) }
    }
    private func settle() {
        let answer: (((String?) -> Void), String?)? = lock.withLock {
            guard let waiter, failed || (ended && boundariesOpen == 0 && !texts.contains(where: { $0 == nil })) else { return nil }
            self.waiter = nil
            return (waiter, failed ? nil : Chunker.join(Self.repaired(texts.map { $0! }, repairs), sentenceEnds: sentenceEnds))
        }
        if let (waiter, text) = answer { waiter(text) }
    }
}

/// Live words (gap #13): a second helper, `ModelBench LIVE_FOLDER --stream RATE`, that lives only
/// while one recording lasts, so its memory (about 0.5–1 GB wired) is held only then. Audio goes over
/// its stdin pipe from this object's own queue, never to disk; when the helper falls behind, buffers
/// are dropped rather than queued, so capture never waits. The text is display only.
final class LiveStream: @unchecked Sendable {
    private let queue = DispatchQueue(label: "murmur.live-words", qos: .userInitiated)
    private let task = Process()
    private let input: FileHandle
    private let lock = NSLock()
    private var backlog = 0
    /// Buffers waiting for the pipe (about 2 s of 1024-frame buffers at 48 kHz).
    private static let maxBacklog = 96

    /// `onText` runs on the main thread with the running transcript.
    init?(helper: URL, folder: URL, sampleRate: Double, onText: @escaping (String) -> Void) {
        let toChild = Pipe(), fromChild = Pipe()
        task.executableURL = helper; task.arguments = [folder.path, "--stream", String(Int(sampleRate))]
        task.standardInput = toChild; task.standardOutput = fromChild; task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        input = toChild.fileHandleForWriting
        let output = fromChild.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            var buffered = Data()
            while true {
                let chunk = output.availableData
                if chunk.isEmpty { return }
                buffered.append(chunk)
                while let newline = buffered.firstIndex(of: 0x0A) {
                    let line = buffered[buffered.startIndex..<newline]; buffered = Data(buffered[(newline + 1)...])
                    if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let text = object["partial"] as? String {
                        DispatchQueue.main.async { onText(text) }
                    }
                }
                if buffered.count > 1 << 20 { return }
            }
        }
    }

    /// Any thread: copies the first channel and sends it, or drops it when the helper is behind.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let data = Data(bytes: samples[0], count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
        let accepted: Bool = lock.withLock {
            guard !closed, backlog < Self.maxBacklog else { return false }
            backlog += 1; return true
        }
        guard accepted else { return }
        queue.async { [self] in
            if !lock.withLock({ closed }) { _ = try? input.write(contentsOf: data) }
            lock.withLock { backlog -= 1 }
        }
    }
    /// Lock-guarded.
    private var closed = false

    /// Ends the helper: closing its stdin makes it exit. The terminate watchdog is armed here, not
    /// behind the writes: a helper that stopped reading blocks the queue on a full pipe, and
    /// terminating it fails that write (EPIPE), so its memory is never held past the recording.
    func stop() {
        guard lock.withLock({ defer { closed = true }; return !closed }) else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [task] in if task.isRunning { task.terminate() } }
        queue.async { [input] in try? input.close() }
    }
}

/// Starts capture on a dedicated queue as soon as the tap thread sees a shortcut press, so a slow
/// main thread does not delay the microphone. The session adopts it; anything unclaimed is deleted.
final class PreStart: @unchecked Sendable {
    private let queue = DispatchQueue(label: "murmur.prestart", qos: .userInteractive)
    private var pending: (capture: Capture, url: URL, id: UUID)?
    func begin(store: RetryAudio) {
        queue.async { [self] in
            guard pending == nil, !IsSecureEventInputEnabled(), permission() == "authorized", let url = try? store.create() else { return }
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
    /// A Dock icon (gap #20); off by default, as in PRD R6. Applies as soon as it changes.
    @Published var showInDock: Bool
    /// A screen the window should switch to ("guide", "insights", "settings"), set from a menu item or
    /// the UI fixture. The window clears it once shown.
    @Published var screenRequest: String?
    /// CoreAudio UID of the chosen microphone; empty means the system default.
    @Published var inputDeviceUID: String
    /// Connected microphones, cached: Settings re-renders with every voice-level tick.
    @Published private(set) var inputDevices = Capture.inputDevices()
    func refreshInputDevices() { inputDevices = Capture.inputDevices() }
    /// The system's login item state (SMAppService), not a stored setting; off until the user turns it on.
    @Published private(set) var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var permissionsSummary = ""
    @Published var hasRecoveryAudio = false
    var microphoneAuthorized: Bool { permission() == "authorized" }
    var accessibilityAuthorized: Bool { AXIsProcessTrusted() }
    var inputMonitoringAuthorized: Bool { CGPreflightListenEventAccess() }
    var modelAvailable: Bool { modelFilesAvailable() }
    @Published var intelligentLeadingSpace: Bool
    @Published var automaticInsertion: Bool
    /// One press starts recording and the next press stops it, instead of hold-to-record.
    @Published var pressToToggle: Bool
    /// Short system sounds when recording starts and stops (gap #15); none on insertion.
    @Published var recordingSounds: Bool
    /// Live words in the bubble while recording (gap #13); needs the optional download.
    @Published var liveWords: Bool
    /// Live words also while transcription runs in the cloud; off by default (user, Oct 15, 2026).
    @Published var liveWordsOnCloud: Bool
    /// The running preview transcript. Display only: never saved, logged, learned from or cleaned.
    @Published private(set) var liveText = ""
    @Published var liveWordsStatus: ModelStatus = .notDownloaded
    @Published var liveWordsMessage = ""
    var liveWordsRow: ModelRowPresentation { ModelRowPresentation.make(liveWordsDownloader == nil ? nil : liveWordsStatus) }
    var liveWordsSummary: String { liveWordsDownloader.map { LiveWordsFacts.summary(downloadSize: $0.downloadSize) } ?? "" }
    var liveWordsLicense: ModelLicenseInfo? { liveWordsDownloader?.license }
    /// Whether this recording's bubble shows live words.
    var liveWordsActive: Bool { live != nil || liveWordsFixture }
    /// The UI fixture's synthetic preview; never set in the app.
    private var liveWordsFixture = false
    func showLiveWordsFixture(_ text: String) { liveWordsFixture = true; liveText = text }
    @Published var retention: String
    // Cleanup and learning settings, applied as soon as they change like the others.
    @Published var cleanupFillers: Bool
    @Published var cleanupCorrections: Bool
    @Published var cleanupLists: Bool
    @Published var cleanupPunctuation: Bool
    /// Polish instead of strict cleanup (`CleanupOptions.polish`).
    @Published var cleanupPolish: Bool
    /// Professional above Polish (`CleanupOptions.professional`).
    @Published var cleanupProfessional: Bool
    @Published var cleanupSpoken: Bool
    /// Screen context for AI cleanup (gap #8), opt-in; a writing mode can override it.
    @Published var screenContext: Bool
    /// Writing modes (gap #6), saved as soon as they change and read at each recording start.
    @Published var writingModes: [WritingMode] { didSet { WritingModes.save(writingModes, to: .standard) } }
    /// Apps dictated into since launch, newest first, for the mode app picker. Memory only.
    @Published private(set) var recentApps: [String] = []
    @Published var learningEnabled: Bool
    @Published var learningRequiresReadableField: Bool
    // Dictionary edits apply immediately; dictionaryMessage reports the last edit error.
    @Published var dictionaryEntries: [DictionaryEntry] = []
    /// Forms and spellings learning skips (conflicting, undone or deleted fixes), for Settings.
    @Published var blockedWords: [CorrectionLedger.Blocked] = []
    @Published var dictionaryMessage = ""
    // Model download (R2). modelMessage reports the last download action, never interrupting dictation.
    @Published var modelStatus: ModelStatus = .notDownloaded
    @Published var modelMessage = ""
    var modelRow: ModelRowPresentation { ModelRowPresentation.make(downloader == nil ? nil : modelStatus) }
    var modelLicense: ModelLicenseInfo? { downloader?.license }
    var modelSummary: String { downloader.map { ModelFacts.summary(downloadSize: $0.downloadSize) } ?? "" }
    @Published var dictionaryModelStatus: ModelStatus = .notDownloaded
    @Published var dictionaryModelMessage = ""
    /// The helper could not start dictionary support and is transcribing without it.
    @Published var dictionarySupportFailed = false
    var dictionaryModelRow: ModelRowPresentation { ModelRowPresentation.make(dictionaryDownloader == nil ? nil : dictionaryModelStatus) }
    var dictionaryModelLicense: ModelLicenseInfo? { dictionaryDownloader?.license }
    var dictionaryModelSummary: String { dictionaryDownloader.map { DictionaryModelFacts.summary(downloadSize: $0.downloadSize) } ?? "" }
    var usesCustomModelFolder: Bool { downloader.map { URL(fileURLWithPath: modelDirectory).standardizedFileURL.path != $0.target.path } ?? false }
    // History-off mode and the size cap (R9, §6). History-off and update checks apply as soon as they change.
    @Published var historyMode: HistoryMode
    @Published var historyCapWarning: String?
    /// Set at launch when damaged history files were moved aside.
    @Published var historyNotice: String?
    /// While the first-run screen is open, a dictation made with Murmur in front lands here instead of being refused.
    var setupShowing = false
    @Published var setupTestTranscript = ""
    @Published var sessionOnlyIDs: Set<String> = []
    /// Home and Insights (gap #19), from the History kept on disk only.
    @Published private(set) var insights: Insights = .empty
    var historySummary: String { HistoryText.summary(mode: appliedHistoryMode, count: history.count, sessionOnly: sessionOnlyIDs.count) }
    // Update checks (R12). Results are shown quietly in Settings only.
    @Published var updateChecksEnabled: Bool
    @Published var updateStatus = ""
    @Published var availableRelease: ReleaseInfo?
    @Published var checkingForUpdates = false
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    // Processing routes (R4) apply as soon as they change.
    // API keys (R5) save immediately to the Keychain; only their presence is published.
    @Published var transcriptionRoute: TranscriptionRoute
    @Published var cloudTranscriber: CloudTranscriber
    @Published var cleanupChoice: CleanupChoice
    @Published var customAPIBaseURL: String
    @Published var customTranscriptionAPIBaseURL: String
    @Published var customAPIModel: String
    @Published var customTranscriptionModel: String
    @Published var geminiTranscriptionModel: String
    @Published var savedKeys: Set<ProviderID> = []
    @Published var keyMessages: [ProviderID: String] = [:]
    var routeSettings: RouteSettings { RouteSettings(transcription: transcriptionRoute, cloudTranscriber: cloudTranscriber, cleanup: cleanupChoice, customAPIBaseURL: customAPIBaseURL, customTranscriptionAPIBaseURL: customTranscriptionAPIBaseURL, customAPIModel: customAPIModel, customTranscriptionModel: customTranscriptionModel, geminiTranscriptionModel: geminiTranscriptionModel) }
    var appliedTranscriptionIsLocal: Bool { appliedRoutes.transcription == .local }
    var appliedCleanupIsLocal: Bool { appliedRoutes.cleanup == .localRules }
    /// What a stage would send off this Mac with the settings as edited, or nil when nothing leaves.
    /// Reads no key (SwiftUI calls it on every render); shows the configured route's disclosure.
    func routeDisclosure(_ stage: ProcessingStage) -> String? { DisclosureText.summary(RoutePlan.make(routeSettings, cleanupSendsText: true) { _ in nil }, stage: stage) }
    /// What screen context and writing modes add to the cleanup route's disclosure, or nil when that
    /// route sends nothing off this Mac or neither is in use (gaps #6, #8).
    var cleanupExtrasDisclosure: String? {
        guard routeDisclosure(.cleanup) != nil else { return nil }
        let modes = writingModes.filter(\.enabled)
        var items: [String] = []
        if screenContext || modes.contains(where: { $0.screenContext == true }) {
            items.append("with screen context on, the selected text, the clipboard (except items marked as passwords or private) and up to \(ScreenContext.windowLimit.formatted()) characters of the focused window's text, as reference only")
        }
        if modes.contains(where: { !$0.instructions.isEmpty }) { items.append("your writing modes' custom instructions") }
        guard !items.isEmpty else { return nil }
        return "Also sends " + items.joined(separator: "; and ") + ". Murmur never sends web page addresses; it uses them on this Mac to pick a mode."
    }
    var canCancelRequest: Bool { cloudRequest.isActive }
    var isBusy: Bool { phase == "Listening" || phase == "Processing" || (sessionAvailable && session.state != .idle) }
    var openSettings: (() -> Void)?
    var updateMenu: (() -> Void)?
    lazy var bubble = BubblePresenter(controller: self)
    /// Meeting notes (PRD section 11): its own capture and store, sharing the warm helper.
    let meetingRecorder = MeetingRecorder()
    private var store: HistoryStore?
    /// All history reads and writes; it keeps entries in memory only when history is off.
    private var records: HistoryRouter<HistoryEntry>?
    private var appliedHistoryMode: HistoryMode
    var dataDirectory: URL? // Internal so the isolated UI fixture can seed only its temporary history.
    private let downloader: ModelDownloader?
    private var modelDownloadInFlight = false
    /// Dictionary support for on-device transcription (the pinned CTC model) and the private
    /// vocabulary file the helper reads; see DictionaryModelFacts.
    private let dictionaryDownloader: ModelDownloader?
    private let liveWordsDownloader: ModelDownloader?
    private var liveWordsDownloadInFlight = false
    /// Set once the live folder's hashes were checked this launch (and the model compiled).
    private var liveWordsVerified = false
    private var live: LiveStream?
    private var dictionaryDownloadInFlight = false
    private var vocabularyFile: URL?
    /// Set by start(); until then dictionary refreshes do not pre-warm, so launch hashes the model once.
    private var started = false
    private let dictionaryModelDirectory = DictionaryModelFacts.directory(home: FileManager.default.homeDirectoryForCurrentUser)
    private var lastAutomaticUpdateAttempt: Date?
    // R12 uses the confirmed Penguin0011/Murmur release repository.
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
    /// The field focused when recording started. Clearing it ends the session's mode and context too.
    private var destination: FocusSnapshot? { didSet { if destination == nil { sessionMode = nil; sessionContext = nil } } }
    /// The app or website mode matched when recording started (a trigger word can still override it).
    /// Only the mode is kept: the page URL is read once at start and never stored or logged.
    private var sessionMode: WritingMode?
    /// Screen text captured at start, in memory only, for AI cleanup when the resolved mode allows it.
    private var sessionContext: ScreenContext?
    private var destinationScreen: NSScreen?
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
            self.setPhase("Listening", self.listeningMessage)
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
        if let pins = Bundle.main.url(forResource: "artifact-pins", withExtension: "json"),
           let manifest = try? ModelManifest(contentsOf: pins, repository: dictionaryModelRepository) {
            dictionaryDownloader = ModelDownloader(manifest: manifest, target: dictionaryModelDirectory)
        } else { dictionaryDownloader = nil }
        if let pins = Bundle.main.url(forResource: "artifact-pins", withExtension: "json"),
           let manifest = try? ModelManifest(contentsOf: pins, list: liveWordsFileList) {
            liveWordsDownloader = ModelDownloader(manifest: manifest, target: LiveWordsFacts.directory(home: FileManager.default.homeDirectoryForCurrentUser))
        } else { liveWordsDownloader = nil }
        shortcut = defaults.string(forKey: "shortcut") ?? "right-option"
        showMenuBar = defaults.object(forKey: "showMenuBar") as? Bool ?? true
        showInDock = defaults.bool(forKey: "showInDock")
        let inputDevice = defaults.string(forKey: "inputDeviceUID") ?? ""
        inputDeviceUID = inputDevice; Capture.preferredInputUID = inputDevice.isEmpty ? nil : inputDevice
        intelligentLeadingSpace = defaults.bool(forKey: "intelligentLeadingSpace")
        automaticInsertion = defaults.object(forKey: "automaticInsertion") as? Bool ?? true
        pressToToggle = defaults.bool(forKey: "pressToToggle")
        recordingSounds = defaults.object(forKey: "recordingSounds") as? Bool ?? true
        liveWords = defaults.object(forKey: "liveWords") as? Bool ?? true
        liveWordsOnCloud = defaults.bool(forKey: "liveWordsOnCloud")
        retention = defaults.string(forKey: "retention") ?? "30-days"
        appliedRetention = defaults.string(forKey: "retention") ?? "30-days"
        let processingSettings = ProcessingSettings.load(from: defaults)
        cleanupFillers = processingSettings.options.fillers
        cleanupCorrections = processingSettings.options.corrections
        cleanupLists = processingSettings.options.lists
        cleanupPunctuation = processingSettings.options.punctuation
        cleanupPolish = processingSettings.options.polish
        cleanupProfessional = processingSettings.options.professional
        cleanupSpoken = processingSettings.options.spoken
        screenContext = processingSettings.screenContext
        writingModes = WritingModes.load(from: defaults)
        learningEnabled = processingSettings.learningEnabled
        learningRequiresReadableField = processingSettings.learningRequiresReadableField
        historyMode = processingSettings.historyMode
        appliedHistoryMode = processingSettings.historyMode
        updateChecksEnabled = processingSettings.updateChecksEnabled
        let routes = RouteSettings.load(from: defaults)
        transcriptionRoute = routes.transcription; cloudTranscriber = routes.cloudTranscriber; cleanupChoice = routes.cleanup
        customAPIBaseURL = routes.customAPIBaseURL; customTranscriptionAPIBaseURL = routes.customTranscriptionAPIBaseURL; customAPIModel = routes.customAPIModel; customTranscriptionModel = routes.customTranscriptionModel; geminiTranscriptionModel = routes.geminiTranscriptionModel; appliedRoutes = routes
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
            vocabularyFile = base.appendingPathComponent("dictionary").appendingPathComponent("parakeet-vocabulary.json")
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
            // One damaged file must not stop Murmur: move it aside, say so, and still expire it on schedule.
            if let moved = try store?.quarantineUnreadable(), moved > 0 {
                historyNotice = "\(moved) damaged history \(moved == 1 ? "file was" : "files were") moved to the history/unreadable folder. \(moved == 1 ? "It" : "They") still expire with your retention setting."
            }
            try store?.purge(retention: appliedRetention)
            configureMeetings(base: base)
            historySaved(); refreshRecoveryAudio(); refreshDictionary()
        } catch { store = nil; records = nil; retry = nil; processing = nil; phase = "Error"; message = "Private storage is unavailable. Murmur cannot start." }
        modelStatus = downloader?.status() ?? .notDownloaded
        dictionaryModelStatus = dictionaryDownloader?.status() ?? .notDownloaded
        liveWordsStatus = liveWordsDownloader?.status() ?? .notDownloaded
        warm.onDictionaryStatus = { [weak self] failed in DispatchQueue.main.async { self?.dictionarySupportFailed = failed } }
        if !preview {
            do { try RouteSettings.migrateCustomAPI(in: defaults, credentials: credentials) }
            catch {
                keyMessages[.customTranscription] = KeyText.storeFailed
                keyMessages[.customCleanup] = KeyText.storeFailed
            }
        }
        refreshKeys()
        // Choose Folder, Use Default and a finished download all change the folder, even with
        // Settings closed; apply each so the folder survives a relaunch.
        folderWatch = $modelDirectory.dropFirst().removeDuplicates().sink { [weak self] _ in self?.settingsChanged() }
        if phase == "Ready" { message = idleMessage }
    }
    func start() {
        // Writing to a warm helper that died must fail with EPIPE, not kill Murmur.
        signal(SIGPIPE, SIG_IGN)
        // App Nap would delay the shortcut; idle system sleep stays allowed.
        // Verify the model now so the first dictation does not hash 1.8 GB.
        started = true; prewarm(); if liveWords { prepareLiveWords() }
        noNap = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Respond to the dictation shortcut without delay")
        refreshPermissions()
        if !preview { configureShortcut() }
        if !preview && updateChecksEnabled { runUpdateCheck(manual: false) }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refreshInputDevices() } }
        }
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
                self.meetingRecorder.tick()
                // A canceled or empty recording's audio is gone; drop its chunk transcripts.
                for (audio, job) in self.chunkJobs where !FileManager.default.fileExists(atPath: audio.path) { job.discard(); self.chunkJobs[audio] = nil }
                // Download progress and the verifying phase are sampled here, on the main thread.
                if self.modelDownloadInFlight, let status = self.downloader?.status(), status != self.modelStatus { self.modelStatus = status }
                if self.dictionaryDownloadInFlight, let status = self.dictionaryDownloader?.status(), status != self.dictionaryModelStatus { self.dictionaryModelStatus = status }
                if self.liveWordsDownloadInFlight, let status = self.liveWordsDownloader?.status(), status != self.liveWordsStatus { self.liveWordsStatus = status }
                if self.sessionAvailable && self.session.state == .listening, let capture = self.capture,
                   // A device change stops the engine; it restarts on the current device (gap #16) and only
                   // an engine that cannot restart counts as an interruption.
                   (!capture.engine.isRunning && !capture.restart()) || capture.queue.sync(execute: { capture.writeError != nil }) {
                    let running = capture.engine.isRunning, writeFailed = capture.queue.sync { capture.writeError != nil }
                    timingLog.notice("capture-interrupted engine-running=\(running, privacy: .public) write-error=\(writeFailed, privacy: .public)")
                    self.recordingFailed = true; self.stopRecording()
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
                    self.meetingRecorder.purge(cutoff: HistoryExpiry.cutoff(HistoryRetention(rawValue: self.appliedRetention) ?? .thirtyDays))
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
    func setOpenAtLogin(_ on: Bool) {
        guard !preview else { openAtLogin = on; return }
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { message = on ? "Murmur could not be added to Login Items. Add it in System Settings → General → Login Items." : "Murmur could not be removed from Login Items. Remove it in System Settings → General → Login Items." }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
    func refreshPermissions() {
        // Login Items can be changed in System Settings; this runs whenever Murmur is reactivated.
        if !preview { openAtLogin = SMAppService.mainApp.status == .enabled }
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
        let expiredMeetings = HistoryExpiry.cutoff(HistoryRetention(rawValue: retention) ?? .thirtyDays).map { cutoff in meetingRecorder.meetings.filter { $0.recordedAt <= cutoff }.count } ?? 0
        if retention != appliedRetention, !expired.isEmpty || expiredMeetings > 0 {
            let alert = NSAlert()
            alert.messageText = expiredMeetings == 0 ? "Delete \(expired.count) expired transcripts?" : "Delete \(expired.count) expired transcripts and \(expiredMeetings) \(expiredMeetings == 1 ? "meeting" : "meetings")?"
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
        let routes = routeSettings
        if routes.cleanup == .appleIntelligence && appliedRoutes.cleanup != .appleIntelligence { AppleCleanupProvider().prewarm() }
        appliedRoutes = routes; routes.save(to: .standard)
        appliedRetention = retention
        appliedHistoryMode = historyMode; records?.persistsTranscripts = historyMode.persistsTranscripts
        if meetingRecorder.persists != historyMode.persistsTranscripts { meetingRecorder.persists = historyMode.persistsTranscripts; meetingRecorder.reload() }
        let defaults = UserDefaults.standard
        defaults.set(modelDirectory, forKey: "modelDirectory"); defaults.set(shortcut, forKey: "shortcut")
        defaults.set(showMenuBar, forKey: "showMenuBar"); defaults.set(showInDock, forKey: "showInDock"); defaults.set(automaticInsertion, forKey: "automaticInsertion"); defaults.set(pressToToggle, forKey: "pressToToggle")
        defaults.set(recordingSounds, forKey: "recordingSounds")
        defaults.set(liveWordsOnCloud, forKey: "liveWordsOnCloud")
        defaults.set(liveWords, forKey: "liveWords"); if liveWords { prepareLiveWords() }
        defaults.set(intelligentLeadingSpace, forKey: "intelligentLeadingSpace")
        defaults.set(inputDeviceUID, forKey: "inputDeviceUID"); Capture.preferredInputUID = inputDeviceUID.isEmpty ? nil : inputDeviceUID
        defaults.set(retention, forKey: "retention")
        if let processing {
            if !learningEnabled || (learningRequiresReadableField && watch?.keys != nil) {
                if let watch { try? processing.ledger.revert(sessionID: watch.observation.sessionID) }
                stopWatching()
            }
            var next = processing.settings
            next.options = CleanupOptions(fillers: cleanupFillers, corrections: cleanupCorrections, lists: cleanupLists, punctuation: cleanupPunctuation, polish: cleanupPolish, professional: cleanupProfessional, spoken: cleanupSpoken)
            next.learningEnabled = learningEnabled; next.route = routes.cleanup.processingRoute
            next.learningRequiresReadableField = learningRequiresReadableField
            next.historyMode = historyMode; next.updateChecksEnabled = updateChecksEnabled
            next.screenContext = screenContext
            do { try processing.update(next) } catch { setPhase("Error", "Could not save cleanup and learning settings.") }
        }
        // Also saved directly, so they persist when the dictionary (and so processing) is unavailable.
        defaults.set(historyMode.rawValue, forKey: ProcessingSettings.Key.historyMode)
        defaults.set(learningRequiresReadableField, forKey: ProcessingSettings.Key.readableLearning)
        defaults.set(updateChecksEnabled, forKey: ProcessingSettings.Key.updateChecks)
        do { try store?.purge(retention: appliedRetention); meetingRecorder.purge(cutoff: HistoryExpiry.cutoff(HistoryRetention(rawValue: appliedRetention) ?? .thirtyDays)); try enforceHistoryCap(); refreshHistory() } catch { setPhase("Error", "Could not apply history retention.") }
        refreshPermissions(); if !preview { configureShortcut() }
        if phase == "Ready" { message = idleMessage }
        updateMenu?()
    }
    private func revertRoutes() {
        transcriptionRoute = appliedRoutes.transcription; cloudTranscriber = appliedRoutes.cloudTranscriber; cleanupChoice = appliedRoutes.cleanup
        customAPIBaseURL = appliedRoutes.customAPIBaseURL; customTranscriptionAPIBaseURL = appliedRoutes.customTranscriptionAPIBaseURL; customAPIModel = appliedRoutes.customAPIModel; customTranscriptionModel = appliedRoutes.customTranscriptionModel
        geminiTranscriptionModel = appliedRoutes.geminiTranscriptionModel
    }
    private func routePlan(_ routes: RouteSettings, cleanupSendsText: Bool) -> RoutePlan {
        var refusal: String?
        let plan = RoutePlan.make(routes, cleanupSendsText: cleanupSendsText) { provider in
            do {
                switch provider {
                case .customTranscription:
                    return try CustomAPIKeyBinding.read(at: routes.customTranscriptionAPIBaseURL, defaults: .standard, credentials: self.credentials, provider: provider)
                case .customCleanup:
                    return try CustomAPIKeyBinding.read(at: routes.customAPIBaseURL, defaults: .standard, credentials: self.credentials, provider: provider)
                default: return try self.credentials.read(provider)
                }
            } catch {
                refusal = (error as? CredentialError)?.description ?? KeyText.unreadable
                return nil
            }
        }
        return RoutePlan(transcriber: plan.transcriber, cleaner: refusal == nil ? plan.cleaner : nil, refusal: refusal ?? plan.refusal, stages: plan.stages)
    }
    private func configureShortcut() {
        removeShortcut()
        guard sessionAvailable else { return }
        guard CGPreflightListenEventAccess() else { message = "Allow Input Monitoring, then click Refresh Permissions to enable the shortcut."; return }
        let binding = ShortcutBinding(stored: shortcut)
        let token = shortcutGeneration
        let next = ShortcutListener(binding: binding, processingSeconds: 0, onAction: { [weak self] action, done in
            guard let self, self.shortcutGeneration == token else { done(); return }
            self.handle(action, done: done)
        })
        guard let tap = next.createTap(), let nextSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { message = "The shortcut could not start. Check Input Monitoring and Accessibility."; return }
        next.onEscapeWhileProcessing = { [weak self] in self?.cancelCloudRequest() }
        next.onCopyChord = { [weak self] in self?.copyLatestRawTranscript() }
        next.onPasteChord = { [weak self] in self?.pasteLastDictation() }
        next.pressToToggle = pressToToggle
        // A press while the previous dictation processes records right away; its events replay
        // into the machine when that dictation finishes, which adopts this capture.
        next.onQueuedPress = { [weak self] in
            guard let self, self.sessionAvailable, !IsSecureEventInputEnabled() else { return false }
            let shown = (self.phase, self.message)
            guard self.session.startEarly() else { return false }
            self.phaseBeforeEarly = shown; self.cue(.start); return true
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
        session.resumeCapture = { [weak self] in guard let self else { return }; self.setPhase("Listening", self.listeningMessage) }
        session.willDeleteCanceled = { [weak self] url in self?.holdForUndo(url) }
        session.finishRecording = { [weak self] in timingLog.notice("capture-cap reached"); guard let self, let listener = self.listener else { return }; listener.emit(listener.machine.finish()) }
        session.resetShortcut = { [weak self] in guard let self, let listener = self.listener else { return }; listener.emit(listener.machine.eventStreamLost()); listener.machine.processingFinished() }
    }
    private static let idleMessages = ["Press your shortcut to dictate and press it again to finish, or hold it and release.", "Hold your shortcut to dictate, or double-press it to dictate until you press it again."]
    private var idleMessage: String { Self.idleMessages[pressToToggle ? 0 : 1] }
    /// False only for the plain idle hint; failures that leave the phase at Ready still show.
    var hasStatusToShow: Bool { phase != "Ready" || !Self.idleMessages.contains(message) }
    private var listeningMessage: String { "Listening… \(listener?.pressToToggle == true ? "Release or press the shortcut again" : "Release") to finish, or press Escape to cancel." }
    /// The shortcut recorder needs the keys itself: the tap would swallow the current chord, and
    /// pressing it would start a dictation. `resume` restores the tap with whatever is saved.
    func pauseShortcutForRecorder() -> Bool {
        guard !isBusy else { message = "Finish the current dictation before recording a shortcut."; return false }
        removeShortcut(); return true
    }
    func resumeShortcutAfterRecorder() { if !preview && listener == nil { configureShortcut() } }
    /// What Settings and the setup screen call the shortcut.
    var shortcutName: String {
        switch ShortcutBinding(stored: shortcut) {
        case .rightOption: return "Right Option"
        case .fn: return "Fn / Globe"
        case .controlOptionSpace: return "Control–Option–Space"
        case .custom(let custom): return custom.label
        }
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
            undo.discard()
            guard !IsSecureEventInputEnabled() else { session.resetShortcut?(); setPhase("Error", "Dictation is unavailable while Secure Input is active."); done(); return }
            guard permission() == "authorized" else { session.resetShortcut?(); setPhase("Error", "Allow Microphone access in Settings before dictating."); done(); return }
            // An unconfigured cloud route refuses; it never falls back to local.
            // A mode may turn cleanup on even when the Cleanup settings have it all off.
            let sendsText = (processing?.settings.options.anyEnabled ?? false) || writingModes.contains { $0.enabled && $0.options?.anyEnabled == true }
            let plan = routePlan(appliedRoutes, cleanupSendsText: sendsText)
            if let refusal = plan.refusal {
                session.resetShortcut?(); setPhase("Error", refusal); done(); return
            }
            if plan.usesLocalModel, let refusal = ModelGate.startRefusal(modelAvailable: modelFilesAvailable(), runtimeAvailable: Bundle.main.url(forAuxiliaryExecutable: "ModelBench") != nil, downloadingActiveModel: modelDownloadInFlight && !usesCustomModelFolder) {
                session.resetShortcut?(); setPhase("Error", refusal); done(); return
            }
            sessionTranscriber = plan.transcriber; processing?.cloudCleaner = plan.cleaner
            (plan.cleaner as? AppleCleanupProvider)?.prewarm()
            destination = try? captureFocus()
            if destination?.secure == true { session.resetShortcut?(); setPhase("Error", "Password fields cannot receive dictation."); done(); return }
            if destination?.pid == getpid() { destination = nil }
            insertThisSession = automaticInsertion; leadingSpaceThisSession = intelligentLeadingSpace; activeModelDirectory = modelDirectory
            listeningStarted = Date(); generation = UUID(); recoveryEntryID = nil; recordingFailed = false
            destinationScreen = screenForDestination(destination)
            captureModeAndContext(aiCleanup: plan.cleaner != nil)
        }
        let wasListening = session.state == .listening
        // An early capture already played its start sound when it began (onQueuedPress).
        let adoptsEarly = session.early != nil
        session.receive(action, completed: done)
        if action == .start, session.state == .listening, !adoptsEarly { cue(.start) }
        if action == .start, session.state == .listening { startLiveWords() }
        if session.state != .listening { stopLiveWords() }
        if wasListening, action == .finish || (action == .cancel && listener?.cancelIsExplicit == true) { cue(.stop) }
        if action == .start, session.state == .listening, sessionTranscriber == nil, let capture, let audio = session.audio { attachChunks(capture, audio: audio) }
        if action == .cancel {
            destination = nil
            if undo.isOpen {
                setPhase("Ready", "Recording canceled. Undo is available for \(Int(undo.lifetime)) seconds.")
                bubble.showUndo(screen: destinationScreen)
                DispatchQueue.main.asyncAfter(deadline: .now() + undo.lifetime) { [weak self] in if self?.undo.isOpen == false { self?.undo.discard() } }
            } else { setPhase("Ready", "Recording canceled."); bubble.hide() }
        }
        else if action == .start && session.state == .idle { setPhase("Error", "The microphone could not start. Check the selected input device.") }
        else if action == .finish && session.state == .idle && phase == "Listening" {
            destination = nil; setPhase("Error", "No audio was captured. Check your microphone and try again.")
        }
    }
    /// Writing mode for the app (and page) focused at start, and screen context when an AI route will
    /// use it. The page URL is read through Accessibility (no Automation prompt), only when an enabled
    /// mode lists a website, and is used here and dropped. Screen text is read only with screen context
    /// on (globally or in a mode), never under Secure Input or in a secure field, and stays in memory.
    private func captureModeAndContext(aiCleanup: Bool) {
        sessionMode = nil; sessionContext = nil
        let front = NSWorkspace.shared.frontmostApplication
        let pid = destination?.pid ?? front?.processIdentifier
        guard let pid, pid != getpid() else { return }
        let modes = writingModes
        if modes.contains(where: \.enabled) {
            let url = WritingModes.needsURL(modes) ? focusedPageURL(pid: pid, from: destination?.element) : nil
            sessionMode = WritingModes.match(modes, bundleID: destination?.bundleID ?? front?.bundleIdentifier, url: url)
        }
        // Read only if this dictation could use it: the start mode (or the global setting) has it on,
        // or a mode that a trigger word could still pick does.
        let wanted = (sessionMode?.screenContext ?? screenContext) || modes.contains { $0.enabled && !$0.triggers.isEmpty && ($0.screenContext ?? screenContext) }
        guard aiCleanup, wanted,
              !IsSecureEventInputEnabled(), destination?.secure != true else { return }
        let pasteboard = NSPasteboard.general
        let types = pasteboard.types?.map(\.rawValue) ?? []
        // Never read the string of an item marked as a password or otherwise private.
        let clipboard = types.contains(where: ScreenContext.privateTypes.contains) ? nil : pasteboard.string(forType: .string)
        let selected = destination.flatMap { focusedSelectedText($0.element) }
        let token = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let window = focusedWindowText(pid: pid, limit: ScreenContext.windowLimit)
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.sessionContext = ScreenContext.make(selected: selected, clipboard: clipboard, clipboardTypes: types, window: window,
                                                         secureInput: IsSecureEventInputEnabled(), secureField: self.destination?.secure == true)
            }
        }
    }
    /// Local route: transcribe this recording's chunks on the warm helper while it records.
    private func attachChunks(_ capture: Capture, audio: URL) {
        let models = URL(fileURLWithPath: activeModelDirectory)
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "ModelBench"), let manifest = Bundle.main.url(forResource: "artifact-pins", withExtension: "json") else { return }
        let warm = warm, vocabulary = vocabularyFile, dictionaryModel = dictionaryModelDirectory
        let job = ChunkJob { url, boundary, done in
            DispatchQueue.global(qos: .userInitiated).async {
                guard (try? ModelVerificationCache.shared.verify(models, manifest: manifest)) != nil,
                      let launch = HelperLaunch.make(models: models, manifest: manifest, vocabulary: vocabulary, dictionaryModel: dictionaryModel) else { done(nil); return }
                // Without dictionary support there is nothing to repair at a cut.
                if boundary && launch.dictionaryArguments.isEmpty { done(nil); return }
                warm.transcribe(url, helper: helper, launch: launch, boundary: boundary, completion: done)
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
    /// The microphone level now, for the indicator's per-frame animation.
    func liveVoiceLevel() -> Double {
        guard let capture else { return 0 }
        return capture.queue.sync { capture.level }
    }
    /// Home's Start button (gap #19). Murmur hides first, so focus returns to the app you were in and
    /// the text pastes at its cursor on release, as with the shortcut; the next press or Finish ends it.
    func startDictationFromHome() {
        guard let listener, listener.machine.state == .idle, !isBusy else { return }
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let listener = self?.listener else { return }
            listener.emit(listener.machine.startToggled())
        }
    }
    func stopRecording() { guard let listener else { return }; listener.emit(listener.machine.finish()) }
    func cancelRecording() {
        if cloudRequest.isActive { cancelCloudRequest(); return }
        guard let listener else { return }; listener.cancelByUser()
    }
    /// A canceled recording kept for Undo (gap #18): 16 kHz mono samples in memory, never on disk,
    /// plus what its start captured, so Undo processes it as if it had finished normally.
    private struct Canceled {
        let samples: [Float]
        let destination: FocusSnapshot?, mode: WritingMode?, context: ScreenContext?, screen: NSScreen?
        let transcriber: TranscriptionProvider?, cleaner: CleanupProvider?
        let insert: Bool, leadingSpace: Bool, modelDirectory: String, started: Date
    }
    private let undo = UndoWindow<Canceled>()
    /// Only a cancel the user asked for (Escape, the menu) can be undone; a lone tap records nothing.
    private func holdForUndo(_ url: URL) {
        guard listener?.cancelIsExplicit == true, let samples = Self.samples16k(url), !samples.isEmpty else { return }
        undo.hold(Canceled(samples: samples, destination: destination, mode: sessionMode, context: sessionContext, screen: destinationScreen,
                           transcriber: sessionTranscriber, cleaner: processing?.cloudCleaner, insert: insertThisSession,
                           leadingSpace: leadingSpaceThisSession, modelDirectory: activeModelDirectory, started: listeningStarted))
    }
    /// The recording as 16 kHz mono floats, the helper's input rate (a five-minute recording is about 19 MB).
    static func samples16k(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil, let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return nil }
        // One call with a buffer for the whole clip returned only part of it; drain in blocks.
        var samples: [Float] = [], fed = false
        while let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_384) {
            let status = converter.convert(to: output, error: nil) { _, state in
                if fed { state.pointee = .endOfStream; return nil }
                fed = true; state.pointee = .haveData; return input
            }
            guard status != .error, let data = output.floatChannelData else { return nil }
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            if status != .haveData { return samples }
        }
        return nil
    }
    /// The Undo button: the held recording is transcribed, cleaned and inserted like any dictation.
    func undoCancel() {
        guard let listener, listener.machine.state == .idle, sessionAvailable, !isBusy, let item = undo.take() else { bubble.hide(); return }
        _ = listener.runAsProcessing { [weak self] done in
            guard let self else { done(); return }
            self.destination = item.destination; self.sessionMode = item.mode; self.sessionContext = item.context
            self.destinationScreen = item.screen; self.sessionTranscriber = item.transcriber; self.processing?.cloudCleaner = item.cleaner
            self.insertThisSession = item.insert; self.leadingSpaceThisSession = item.leadingSpace
            self.activeModelDirectory = item.modelDirectory; self.listeningStarted = item.started
            self.generation = UUID(); self.recoveryEntryID = nil
            self.transcribe(nil, held: item.samples, done: done)
        }
    }
    private enum Cue: String { case start = "Tink", stop = "Pop" }
    /// Measured October 15, 2026: both cues mixed at full level into a recording added no words,
    /// and a recording of only the cues transcribed as empty, so the stop cue can play at release.
    private func cue(_ cue: Cue) { if recordingSounds && !preview { NSSound(named: cue.rawValue)?.play() } }
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
    /// A dictation that could not be pasted, shown in the bubble with Copy (gap #17). Any other status replaces it.
    /// `title` names why: a failed paste, or a paste Murmur did not attempt.
    struct PasteFailure: Equatable { let entryID: String?; let text: String; var title = "Couldn’t paste here" }
    @Published private(set) var pasteFailure: PasteFailure?
    func setPhase(_ phase: String, _ message: String, announcement: String? = nil, pasteFailure: PasteFailure? = nil) {
        self.phase = phase; self.message = message; self.pasteFailure = pasteFailure
        // Every finished status leaves on its own unless replaced: text stays in History and retry audio
        // stays on disk. "No speech" needs no action (2 s); errors get longer to read (8 s); a text to
        // copy 30 s; the rest 5 s.
        let shown = UUID(); statusShown = shown
        let dismissAfter: TimeInterval? = phase == "Listening" || phase == "Processing" || !hasStatusToShow ? nil :
            pasteFailure != nil ? 30 : phase != "Error" ? 5 : message.hasPrefix("No speech was detected") ? 2 : 8
        if let dismissAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter) { [weak self] in
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
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: announcement ?? message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    /// This dictation's recording length, kept with its History entry for Insights (gap #19).
    private var sessionSeconds: Double?
    nonisolated static func audioSeconds(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }
    /// `held`: an undone cancel's samples (gap #18), in memory only. There is then no file: no chunks,
    /// no one-shot fallback and no retry audio.
    private func transcribe(_ audio: URL?, held: [Float]? = nil, done: @escaping () -> Void) {
        sessionSeconds = held.map { Double($0.count) / 16_000 } ?? audio.flatMap(Self.audioSeconds)
        if let provider = sessionTranscriber { transcribeInCloud(audio, held: held, with: provider, done: done); return }
        setPhase("Processing", "Transcribing on this Mac…")
        let token = generation; let models = URL(fileURLWithPath: activeModelDirectory)
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "ModelBench"), let manifest = Bundle.main.url(forResource: "artifact-pins", withExtension: "json"), let store = records else { setPhase("Error", "The model runtime is unavailable. Audio is saved for retry."); done(); return }
        let timestamp = listeningStarted
        let began = ProcessInfo.processInfo.systemUptime
        let vocabulary = vocabularyFile, dictionaryModel = dictionaryModelDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { timingLog.notice("model-verify took=\(ProcessInfo.processInfo.systemUptime - began, format: .fixed(precision: 3))") }
            guard (try? ModelVerificationCache.shared.verify(models, manifest: manifest)) != nil,
                  let launch = HelperLaunch.make(models: models, manifest: manifest, vocabulary: vocabulary, dictionaryModel: dictionaryModel)
            else { DispatchQueue.main.async { guard let self, self.generation == token else { return }; self.setPhase("Error", "Model verification failed. Choose the pinned model folder. \(audio == nil ? Self.heldDiscarded : "Audio is saved for retry.")"); done() }; return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                if let audio { self.runTranscription(helper, launch: launch, audio: audio, store: store, timestamp: timestamp, token: token, done: done); return }
                self.warm.transcribe(samples: held ?? [], helper: helper, launch: launch) { [weak self] line in
                    self?.handleTranscript(line.map { .success($0) } ?? .failure(CaptureError("Transcription failed")), audio: nil, store: store, timestamp: timestamp, token: token, done: done)
                }
            }
        }
    }
    private struct NoSpeech: Error {}
    /// Warm helper first; if it cannot answer, the one-shot helper transcribes the same audio.
    private func runTranscription(_ helper: URL, launch: HelperLaunch, audio: URL, store: HistoryRouter<HistoryEntry>, timestamp: Date, token: UUID, done: @escaping () -> Void) {
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
                        self.runTranscription(helper, launch: launch, audio: audio, store: store, timestamp: timestamp, token: token, done: done)
                    }
                }
                return
            }
            job.discard()
        }
        let began = ProcessInfo.processInfo.systemUptime
        warm.transcribe(audio, helper: helper, launch: launch) { [weak self] line in
            timingLog.notice("warm-runner took=\(ProcessInfo.processInfo.systemUptime - began, format: .fixed(precision: 3)) answered=\(line != nil, privacy: .public)")
            if let line { self?.handleTranscript(.success(line), audio: audio, store: store, timestamp: timestamp, token: token, done: done); return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.launchRunner(helper, launch: launch, audio: audio, store: store, timestamp: timestamp, token: token, done: done)
            }
        }
    }
    private func launchRunner(_ helper: URL, launch: HelperLaunch, audio: URL, store: HistoryRouter<HistoryEntry>, timestamp: Date, token: UUID, done: @escaping () -> Void) {
        let pipe = Pipe(), output = pipe.fileHandleForReading
        let task = Process(); task.executableURL = helper; task.arguments = [launch.models.path, audio.path, "--single"] + launch.dictionaryArguments
        task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        do { try task.run(); runner = task; try? pipe.fileHandleForWriting.close() } catch { try? output.close(); try? pipe.fileHandleForWriting.close(); setPhase("Error", "Transcription could not start. Audio is saved for retry."); done(); return }
        let timeout = DispatchWorkItem { if task.isRunning { task.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if task.isRunning { kill(task.processIdentifier, SIGKILL) } } } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timeout)
        let launched = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { timeout.cancel(); try? output.close() }
            let result = Result<Data, Error> {
                let data: Data
                do { data = try readHelperOutput(output) }
                catch {
                    if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                    task.waitUntilExit()
                    throw error
                }
                task.waitUntilExit()
                timingLog.notice("runner took=\(ProcessInfo.processInfo.systemUptime - launched, format: .fixed(precision: 3)) status=\(task.terminationStatus)")
                guard task.terminationStatus == 0 else { throw CaptureError("Transcription failed") }
                return data
            }
            self?.handleTranscript(result, audio: audio, store: store, timestamp: timestamp, token: token, done: done)
        }
    }
    /// Shared by the warm and one-shot helpers: parse the last JSON line, save, then deliver. Runs off main.
    nonisolated static let heldDiscarded = "The canceled recording was discarded."
    nonisolated private func handleTranscript(_ result: Result<Data, Error>, audio: URL?, store: HistoryRouter<HistoryEntry>, timestamp: Date, token: UUID, done: @escaping () -> Void) {
        do {
            let data = try result.get()
            guard let last = String(data: data, encoding: .utf8)?.split(separator: "\n").last,
                  let result = try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any],
                  let text = result["text"] as? String else { throw CaptureError("No usable transcript") }
            // The model ran and answered, but heard nothing; audio stays until the 24-hour purge.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NoSpeech() }
            let savedEntry = HistoryEntry(id: UUID().uuidString, recordedAt: timestamp, rawText: text, finalText: text, insertionStatus: "saved-not-inserted")
            try store.save(savedEntry)
            if let audio { try? FileManager.default.removeItem(at: audio) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.runner = nil
                self.deliver(savedEntry, store: store, token: token, done: done)
            }
        } catch {
            let message = error is NoSpeech ? "No speech was detected. Check your microphone and try again."
                : audio == nil ? "Transcription failed. \(Self.heldDiscarded)" : "Transcription failed. Audio is saved for retry for up to 24 hours."
            DispatchQueue.main.async { [weak self] in guard let self, self.generation == token else { return }; self.runner = nil; self.setPhase("Error", message); done() }
        }
    }
    /// Cloud transcription (R4): one provider call in a cancellable Task, never the local model.
    /// The result then follows the local path: history save, processing, insertion.
    private func transcribeInCloud(_ audio: URL?, held: [Float]?, with provider: TranscriptionProvider, done: @escaping () -> Void) {
        guard let store = records else { setPhase("Error", "Private storage is unavailable. \(audio == nil ? Self.heldDiscarded : "Audio is saved for retry.")"); done(); return }
        let token = generation; let timestamp = listeningStarted
        cloudStage = .transcription; cloudDone = done
        let vocabulary = processing?.dictionary.vocabularyTerms ?? []
        let heldWAV = held.map { WAVAudio.encodePCM16($0, sampleRate: 16_000) }
        cloudRequest.start({
            if let heldWAV { return await CloudTranscription.run(provider: provider, audioData: heldWAV, vocabulary: vocabulary) }
            return await CloudTranscription.run(provider: provider, audioFile: audio ?? URL(fileURLWithPath: "/dev/null"), vocabulary: vocabulary)
        }) { [weak self] outcome in
            guard let self, self.generation == token else { return }
            self.cloudStage = nil; self.cloudDone = nil
            let text: String, held: Bool
            switch outcome {
            case .transcript(let value): text = value; held = false
            case .heldAnswerSuspected(let value): text = value; held = true
            case .noSpeech, .failed, .cancelled:
                // Audio stays for retry (until the 24-hour purge) unless the provider error discards it.
                if case .failed(_, false) = outcome, let audio { try? FileManager.default.removeItem(at: audio) }
                var message = CloudTranscription.message(outcome) ?? CloudTranscription.unknownFailure
                // Held audio has no file to keep for retry.
                if audio == nil, case .failed(let reason, _) = outcome { message = reason + " " + Self.heldDiscarded }
                self.setPhase("Error", message); done(); return
            }
            // An answer-shaped LLM transcript is held like a failed cleanup: raw text only, never inserted.
            let entry = HistoryEntry(id: UUID().uuidString, recordedAt: timestamp, rawText: text, finalText: held ? "" : text, insertionStatus: held ? "held-transcript" : "saved-not-inserted")
            do { try store.save(entry) } catch { self.setPhase("Error", "Could not save the transcript. \(audio == nil ? Self.heldDiscarded : "Audio is saved for retry for up to 24 hours.")"); done(); return }
            if let audio { try? FileManager.default.removeItem(at: audio) }
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
        // Saved with the next write of this entry; no extra disk write before insertion.
        var savedEntry = savedEntry; savedEntry.seconds = sessionSeconds
        recoveryEntryID = savedEntry.id
        // A trigger word beats the app or website matched at start; it is cut from the text, not from History's raw transcript.
        let trigger = WritingModes.trigger(writingModes, in: savedEntry.rawText)
        let text = trigger?.text ?? savedEntry.rawText
        let style = processing.map { DictationStyle(mode: trigger?.mode ?? sessionMode, settings: $0.settings, context: sessionContext) }
        sessionContext = nil
        guard let processing, processing.settings.route != .local else {
            complete(processing?.process(text, style: style) ?? .heldForRecovery(raw: text, reason: .cleanerFailed), entry: savedEntry, store: store, done: done); return
        }
        cloudStage = .cleanup; cloudDone = done
        cloudRequest.start({ await processing.processAsync(text, style: style) }) { [weak self] outcome in
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
                timingLog.notice("cleanup-held reason=\(why.rawValue, privacy: .public) provider-error=\(self.processing?.lastProviderError.map { Mirror(reflecting: $0).children.first?.label ?? "\($0)" } ?? "none", privacy: .public)")
            }
            entry = entry.with(finalText: "", status: "held-cleanup")
            do { try store.save(entry); setPhase("Error", "Cleanup was held for review.\(reason) The raw transcript is in History. Press ⌃⌘C to copy it.") }
            catch { setPhase("Error", "Cleanup was held for review.\(reason) The raw transcript is in History; its status could not be saved.") }
            destination = nil; historySaved(); done(); return
        }
        // Content-free: why the full cleanup was not used (the punctuation transfer or local rules was).
        let fallback = processing?.lastFallback?.rawValue, rejected = processing?.lastRejectedOutput
        if let why = processing?.lastFallback {
            timingLog.notice("cleanup-fallback entry=\(savedEntry.id, privacy: .public) reason=\(why.rawValue, privacy: .public) provider-error=\(self.processing?.lastProviderError.map { Mirror(reflecting: $0).children.first?.label ?? "\($0)" } ?? "none", privacy: .public)")
        }
        // Only filler words were heard: keep the raw transcript, insert nothing, show no error.
        if processed.isEmpty {
            entry = entry.with(finalText: "", status: "saved-not-inserted", fallback: fallback, rejected: rejected)
            try? store.save(entry)
            setPhase("Ready", "Only filler words were heard, so nothing was inserted.")
            destination = nil; historySaved(); done(); return
        }
        if processed != text || fallback != nil {
            entry = entry.with(finalText: processed, status: entry.insertionStatus, fallback: fallback, rejected: rejected)
            do { try store.save(entry) } catch { setPhase("Error", "Could not save the processed transcript. The raw transcript is in History."); destination = nil; historySaved(); done(); return }
        }
        // First-run test dictation: Murmur never types into itself, so show the result on the setup screen.
        if setupShowing && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            // ⌃⌘V still works if this flag was left on with no setup window visible.
            setupTestTranscript = processed; lastDictationText = processed; setPhase("Ready", "Test dictation worked."); bubble.hide()
            destination = nil; historySaved(); done(); return
        }
        lastDictationText = processed
        if insertThisSession {
            watchTick(ending: true)
            // Insert where the cursor is now, even if focus moved while recording or processing.
            let target = (try? captureFocus()).flatMap { $0.pid == getpid() ? nil : $0 }
            // Persist uncertainty before the one permitted delivery attempt.
            let insertionText = textWithLeadingSpace(processed, value: target?.value, selection: target?.selection, enabled: leadingSpaceThisSession)
            entry = entry.with(finalText: insertionText, status: "insertion-pending", fallback: fallback, rejected: rejected)
            var attempted = false
            do {
                try store.save(entry)
                // The text appearing is the signal; insertion's verification waits block the main
                // thread, so take the indicator down first instead of freezing it.
                bubble.hide()
                let inserting = ProcessInfo.processInfo.systemUptime
                // A readable text field is pasted into and read back; anything else (a web editor, a
                // custom text view, no accessible focus) gets a plain paste.
                let readable = target.map { insertionTextRole($0.role) && $0.value != nil && $0.selection != nil } ?? false
                let insertion = readable ? insertText(entry.finalText, into: target!) : pasteIntoFrontmostApp(entry.finalText)
                timingLog.notice("insert app=\(target?.bundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none", privacy: .public) role=\(target?.role ?? "none", privacy: .public) status=\(insertion.status.rawValue, privacy: .public) took=\(ProcessInfo.processInfo.systemUptime - inserting, format: .fixed(precision: 3)) detail=\(insertion.detail, privacy: .public)")
                attempted = true
                if let app = target?.bundleID, !app.isEmpty { recentApps = [app] + recentApps.filter { $0 != app }.prefix(9) }
                lastDictationText = entry.finalText
                entry.insertionStatus = insertion.status.rawValue
                if insertion.status != .failed { entry.app = target?.bundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
                try store.save(entry)
                watchCorrections(insertion, text: entry.finalText, at: target?.selection?.location, pid: target?.pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier)
                showInsertionResult(insertion, entryID: entry.id, text: entry.finalText)
                // A provider failure is not silent: a bad key or quota would otherwise degrade every dictation.
                if insertion.status != .failed, let error = processing?.lastProviderError {
                    setPhase("Ready", "Inserted with local cleanup. \(error.userMessage)")
                }
            } catch {
                // After an attempt the paste may have landed, so no card offers the text again.
                if attempted { setPhase("Error", "\(saved) Delivery status could not be saved. Check the destination before pasting again.") }
                else { showNotPasted(.unsaved, saved: saved, entryID: entry.id, text: processed) }
            }
        } else {
            try? store.save(entry) // Records the recording length, which only later saves would carry.
            showNotPasted(.insertionOff, saved: saved, entryID: entry.id, text: processed)
        }
        destination = nil; historySaved(); done()
    }
    /// Latest insertable dictation, including verified deliveries, kept in memory for ⌃⌘V.
    var lastDictationText: String?
    /// ⌃⌘V explicitly pastes again; never triggered by a read-back mismatch.
    /// Keep the last usable text through canceled, empty, or failed recordings.
    func pasteLastDictation() {
        guard let text = lastDictationText, !isBusy else { return }
        watchTick(ending: true)
        let result = pasteIntoFrontmostApp(text)
        timingLog.notice("paste-chord status=\(result.status.rawValue, privacy: .public) detail=\(result.detail, privacy: .public)")
        showInsertionResult(result, entryID: nil, text: text)
    }
    /// Read-back is diagnostic evidence, not a reason to warn or paste twice.
    func showInsertionResult(_ result: InsertionResult, entryID: String?, text: String) {
        switch result.status {
        case .verified, .unverified: setPhase("Ready", idleMessage, announcement: "Dictation finished.")
        case .failed: setPhase("Error", "Could not paste the dictation. Copy it here, select a text field and press ⌃⌘V, or copy it from History. Check the field first to avoid a duplicate.",
                               pasteFailure: PasteFailure(entryID: entryID, text: text))
        }
    }
    enum NotPasted { case insertionOff, unsaved }
    /// Murmur deliberately did not paste: the card shows the text with Copy (gap #17, Oct 15 follow-up).
    /// Failed pastes go through `showInsertionResult`; a posted but unconfirmed paste stays quiet.
    func showNotPasted(_ why: NotPasted, saved: String, entryID: String?, text: String) {
        switch why {
        case .insertionOff:
            setPhase("Saved", "\(saved) Press ⌃⌘V to paste it where your cursor is.", pasteFailure: PasteFailure(entryID: entryID, text: text, title: "Saved, not pasted"))
        case .unsaved:
            setPhase("Error", "\(saved) Could not save the text for insertion, so nothing was pasted. Copy it here or from History.", pasteFailure: PasteFailure(entryID: entryID, text: text))
        }
    }
    /// The card's Copy button: the text goes to the clipboard and its History entry is marked copied.
    func copyPasteFailure() {
        guard let failure = pasteFailure else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(failure.text, forType: .string)
        if let id = failure.entryID, var entry = history.first(where: { $0.id == id }) {
            entry.insertionStatus = "copied"; try? records?.save(entry); refreshHistory()
        }
        setPhase("Ready", "Copied. Press ⌘V to paste it.", announcement: "Dictation copied.")
    }
    // Explicit developer check of the production pipeline, using a synthetic file
    // and an exact disposable destination. Never enabled during ordinary launch.
    func checkSavedAudio(_ audio: URL, expectedApp: String, completion: @escaping () -> Void) {
        // Canvas editors (Google Docs) expose no focused field; the frontmost app must still match.
        let focused = try? captureFocus()
        guard sessionAvailable, modelFilesAvailable(), let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == expectedApp, front.processIdentifier != getpid(), focused?.secure != true,
              focused == nil || focused?.pid == front.processIdentifier else {
            fputs("app-check=refused destination-or-model-unavailable\n", stderr); completion(); return
        }
        guard !isBusy, let retry else { completion(); return }
        let ownedAudio: URL
        do { ownedAudio = try copyProbeAudio(audio, into: retry) } catch {
            fputs("app-check=refused audio-copy-failed\n", stderr); completion(); return
        }
        // The probe is local only: it never sends audio or text to a provider.
        if let processing {
            var local = processing.settings; local.route = .local
            do { try processing.update(local, persist: false) }
            catch { fputs("app-check=refused local-settings-failed\n", stderr); completion(); return }
        }
        sessionTranscriber = nil; processing?.cloudCleaner = nil
        destination = focused; insertThisSession = true; leadingSpaceThisSession = intelligentLeadingSpace
        activeModelDirectory = modelDirectory; listeningStarted = Date(); generation = UUID()
        destinationScreen = screenForDestination(focused); recoveryEntryID = nil
        transcribe(ownedAudio) { [weak self] in
            print("app-check=complete state=\(self?.phase ?? "unknown")")
            fflush(stdout)
            // Stay up through the correction window so the probe can exercise learning.
            @MainActor func waitForWatch() {
                guard let self, self.watch != nil else { print("app-check=watch-ended"); fflush(stdout); completion(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { waitForWatch() } }
            }
            waitForWatch()
        }
    }
    private func refreshRecoveryAudio() {
        guard let retry else { hasRecoveryAudio = false; return }
        hasRecoveryAudio = ((try? FileManager.default.contentsOfDirectory(at: retry.directory, includingPropertiesForKeys: nil)) ?? []).contains { $0.pathExtension == "wav" }
    }
    func refreshHistory() {
        do { history = try records?.entries() ?? []; sessionOnlyIDs = records?.sessionOnlyIDs ?? [] }
        catch { message = "Could not read saved history." }
        // Once per change, not per render: Settings re-renders with every voice-level tick.
        insights = Insights.compute(history.filter { !sessionOnlyIDs.contains($0.id) }.map {
            InsightsItem(recordedAt: $0.recordedAt, rawText: $0.rawText, finalText: $0.finalText, seconds: $0.seconds, app: $0.app)
        }, historyOn: appliedHistoryMode == .on, now: Date(), calendar: .current)
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
    func useFaithfulTranscription() { cleanupFillers = false; cleanupCorrections = false; cleanupLists = false; cleanupPunctuation = false; cleanupSpoken = false }
    /// Every dictionary change ends here: it rewrites the helper's vocabulary file and restarts
    /// the warm helper with it, so a wipe or edit never leaves old terms loaded.
    func refreshDictionary() {
        dictionaryEntries = processing?.dictionary.entries ?? []
        blockedWords = processing?.ledger.blocked ?? []
        writeHelperVocabulary()
        if started { prewarm() }
    }
    /// FluidAudio's vocabulary JSON: enabled entries (not command targets), preferred spelling plus "heard as" aliases.
    /// Owner-only, beside dictionary.json; absent when nothing is enabled.
    private func writeHelperVocabulary() {
        guard let vocabularyFile else { return }
        let terms: [[String: Any]] = dictionaryEntries.filter { $0.enabled && !DictionaryStore.isCommandTarget($0) }.map { entry in
            entry.variants.isEmpty ? ["text": entry.preferred] : ["text": entry.preferred, "aliases": entry.variants]
        }
        if terms.isEmpty { try? FileManager.default.removeItem(at: vocabularyFile); return }
        guard let data = try? JSONSerialization.data(withJSONObject: ["terms": terms], options: [.sortedKeys]) else { return }
        try? PrivateFiles.write(data, to: vocabularyFile)
    }
    /// Starts (or restarts, when what it loads changed) the warm helper in the background, so the
    /// next dictation does not wait for a model load.
    private func prewarm() {
        guard !preview, let helper = Bundle.main.url(forAuxiliaryExecutable: "ModelBench"),
              let manifest = Bundle.main.url(forResource: "artifact-pins", withExtension: "json") else { return }
        let models = URL(fileURLWithPath: modelDirectory), vocabulary = vocabularyFile, dictionaryModel = dictionaryModelDirectory, warm = warm
        DispatchQueue.global(qos: .utility).async {
            guard (try? ModelVerificationCache.shared.verify(models, manifest: manifest)) != nil,
                  let launch = HelperLaunch.make(models: models, manifest: manifest, vocabulary: vocabulary, dictionaryModel: dictionaryModel) else { return }
            warm.prepare(helper: helper, launch: launch)
        }
    }
    @discardableResult
    func addDictionaryEntry(preferred: String, variants: String) -> Bool {
        guard let processing else { dictionaryMessage = "The dictionary is unavailable."; return false }
        do { try processing.addEntry(preferred: preferred, variants: variants); dictionaryMessage = ""; refreshDictionary(); return true }
        catch { dictionaryMessage = (error as? DictionaryError)?.description ?? "Could not save the dictionary."; return false }
    }
    @discardableResult
    func updateDictionaryEntry(_ entry: DictionaryEntry, preferred: String, variants: String, enabled: Bool) -> Bool {
        guard let processing else { dictionaryMessage = "The dictionary is unavailable."; return false }
        defer { refreshDictionary() }
        do { try processing.updateEntry(id: entry.id, preferred: preferred, variants: variants, enabled: enabled); dictionaryMessage = ""; return true }
        catch { dictionaryMessage = (error as? DictionaryError)?.description ?? "Could not save the dictionary."; return false }
    }
    func deleteDictionaryEntry(_ entry: DictionaryEntry) {
        do { try processing?.deleteEntry(id: entry.id); dictionaryMessage = "" } catch { dictionaryMessage = "Could not delete this dictionary entry." }
        refreshDictionary()
    }
    func unblockWord(_ item: CorrectionLedger.Blocked) {
        do { try processing?.ledger.unblock(item); dictionaryMessage = "" } catch { dictionaryMessage = "Could not save the learning data." }
        refreshDictionary()
    }
    func resetLearnedEntries() {
        let alert = NSAlert(); alert.messageText = "Reset learned dictionary entries?"
        alert.informativeText = "This removes every learned entry and all learning evidence, and unblocks every word under Not learned. Entries you added stay."
        alert.addButton(withTitle: "Reset Learned"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try processing?.resetLearned(); dictionaryMessage = "" } catch { dictionaryMessage = "Could not reset learned entries." }
        refreshDictionary()
    }
    // Learning from corrections (PRD R10): after an insertion, watch the dictated span until focus
    // leaves, 60 seconds pass, attribution is lost or the next insertion; each change goes to the
    // ledger, which settles when the watch ends or once the edited span has been stable for
    // `stableSettleDelay` with an accepted reading (gap #9); the watch then goes on, and a later
    // edit or undo replaces or withdraws what that early settle learned. A field that reads back the dictated text is read
    // through AX; any other field (VS Code's stub, web canvases) is followed by the keys typed in
    // that app during the window, which are never stored or logged.
    private struct Watch {
        var observation: DictationObservation
        let pid: pid_t
        let field: FocusSnapshot?
        var keyFocus: LearningFocusIdentity? = nil
        var keys: KeystrokeSpan?
        var current: String
        /// When `current` last changed (system uptime), and whether its reading is unsettled ledger evidence.
        var changedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
        var pending = false
        var settledEarly = false
    }
    static let stableSettleDelay: TimeInterval = 2
    /// Gap #9: an accepted reading unchanged for `stableSettleDelay` settles before the window closes.
    static func settlesEarly(pending: Bool, changedAt: TimeInterval, now: TimeInterval) -> Bool {
        pending && now - changedAt >= stableSettleDelay
    }
    private var watch: Watch?
    private var watchTimer: Timer?
    private var keyTap: CFMachPort?
    private func watchCorrections(_ insertion: InsertionResult, text: String, at offset: Int?, pid: pid_t?) {
        guard processing?.settings.learningEnabled == true else { timingLog.notice("watch route=none why=learning-off"); return }
        guard insertion.status != .failed else { timingLog.notice("watch route=none why=insert-failed"); return }
        let now = ProcessInfo.processInfo.systemUptime
        // A snapshot exists only when the same field read back the dictated text (verified, or a
        // browser paste whose read-back is not trusted for delivery but is for observation).
        // Why the field route was not taken, content-free, for the log.
        let length = (text as NSString).length
        let axMiss: String
        if let field = insertion.snapshot, field.readableText, let value = field.value, let offset {
            if NSMaxRange(NSRange(location: offset, length: length)) <= (value as NSString).length,
               (value as NSString).substring(with: NSRange(location: offset, length: length)) == text {
                axMiss = DictationObservation(value: value, insertedRange: NSRange(location: offset, length: length), now: now) == nil ? "span-cuts-word" : ""
            } else { axMiss = "text-not-at-offset" }
        } else { axMiss = insertion.snapshot == nil ? "no-readback" : insertion.snapshot!.readableText ? "no-offset" : "unreadable" }
        if axMiss.isEmpty, let field = insertion.snapshot, let value = field.value, let offset,
           let observation = DictationObservation(value: value, insertedRange: NSRange(location: offset, length: length), now: now) {
            watch = Watch(observation: observation, pid: field.pid, field: field, keys: nil, current: text)
            timingLog.notice("watch route=ax")
        } else if processing?.settings.learningRequiresReadableField != true, !IsSecureEventInputEnabled(),
                  let pid, CGPreflightListenEventAccess(), startKeyTap(),
                  let observation = DictationObservation(value: text, insertedRange: NSRange(location: 0, length: length), now: now) {
            var keys = KeystrokeSpan(text)
            keys.resolve = { CorrectionFilter.plausibleEdit(original: text, candidates: $0, isCommonWord: isCommonEnglishWord) }
            let identity = LearningFocusIdentity.capture(pid: pid)
            guard !identity.secure else { stopWatching(); return }
            watch = Watch(observation: observation, pid: pid, field: nil, keyFocus: identity, keys: keys, current: text)
            timingLog.notice("watch route=keys ax-miss=\(axMiss, privacy: .public)")
        } else {
            timingLog.notice("watch route=none ax-miss=\(axMiss, privacy: .public) input-monitoring=\(CGPreflightListenEventAccess(), privacy: .public)")
            stopWatching(); return
        }
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchTick() }
        }
    }
    private func watchTick(ending: Bool = false) {
        guard var w = watch else { return }
        let same: Bool, readable: Bool, value: String, selection: NSRange
        if var keys = w.keys {
            keys.refresh(); w.keys = keys; watch?.keys = keys
            let identity = LearningFocusIdentity.capture(pid: w.pid)
            same = keys.state != .departed && NSWorkspace.shared.frontmostApplication?.processIdentifier == w.pid && w.keyFocus?.matches(identity) == true
            readable = keys.state != .lost && !IsSecureEventInputEnabled() && !identity.secure
            value = keys.value; selection = keys.selection
        } else if let field = w.field {
            let focus = try? captureFocus()
            // captureFocus spins the run loop; a shortcut handled there may already have ended this watch.
            guard watch?.observation.sessionID == w.observation.sessionID else { return }
            same = focus.map { $0.pid == field.pid && CFEqual($0.element, field.element) } ?? false
            // Access is about the dictated field; another app's unreadable focus is a departure, not lost access.
            // Chromium turns Secure Event Input on in password fields, a backstop for unflagged ones.
            readable = AXIsProcessTrusted() && !IsSecureEventInputEnabled() && (same ? focus?.readableText == true : true)
            value = focus?.value ?? ""
            selection = focus?.selection.map { NSRange(location: $0.location, length: $0.length) } ?? NSRange(location: 0, length: 0)
        } else { return }
        let now = ProcessInfo.processInfo.systemUptime
        _ = w.observation.observe(value: value, selection: selection, now: now,
                                  sameFocusedField: same, readableNonsecure: readable)
        if ending { w.observation.finish() }
        let session = w.observation.sessionID, current = w.observation.edited ?? w.observation.initial
        do {
            if current != w.current {
                let outcome = try processing?.observeSpan(sessionID: session, original: w.observation.initial, current: current)
                // Shape only (word and letter counts, similarity), never the words themselves.
                let shape: String
                switch CorrectionFilter.replacements(w.observation.initial, current) {
                case .failure(let why): shape = "\(why)"
                case .success(let changes): shape = changes.map { change in
                    let from = CorrectionFilter.letters(change.source), to = CorrectionFilter.letters(change.targets[0])
                    return "\(TermText.tokens(change.source).count)w\(from.count)l->\(TermText.tokens(change.targets[0]).count)w\(to.count)l sim=\(String(format: "%.2f", CorrectionFilter.similarity(from, to)))"
                }.joined(separator: ",")
                }
                timingLog.notice("watch edit outcome=\(outcome.map { "\($0)" } ?? "reverted", privacy: .public) changes=\(shape, privacy: .public)")
                w.current = current; w.changedAt = now; w.pending = outcome == .provisional
                // After an early settle, an edit or undo may have withdrawn what it learned.
                if w.settledEarly && outcome != .sessionClosed { refreshDictionary() }
            }
            watch = w
            if w.observation.stopped {
                stopWatching()
                // Settling can also delete learned entries (reversal, conflict), so always refresh.
                defer { refreshDictionary() }
                let learned = try processing?.settle(sessionID: session) ?? []
                timingLog.notice("watch end reason=\(w.observation.stopReason ?? "unknown", privacy: .public) keys=\(w.keys.map { "\($0.state)" } ?? "-", privacy: .public) learned=\(learned.count, privacy: .public)")
                if let entry = learned.last { announceLearned(entry) }
            } else if Self.settlesEarly(pending: w.pending, changedAt: w.changedAt, now: now) {
                w.pending = false; w.settledEarly = true; watch = w
                defer { refreshDictionary() }
                let learned = try processing?.settle(sessionID: session) ?? []
                timingLog.notice("watch early-settle learned=\(learned.count, privacy: .public)")
                if let entry = learned.last { announceLearned(entry) }
            }
        } catch { stopWatching(); try? processing?.ledger.revert(sessionID: session) }
    }
    private func announceLearned(_ entry: DictionaryEntry) {
        bubble.showLearned(entry.preferred, screen: destinationScreen)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: "Added \(entry.preferred) to your dictionary.", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    private func stopWatching() {
        watchTimer?.invalidate(); watchTimer = nil; watch = nil
        if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: false); CFMachPortInvalidate(keyTap) }
        keyTap = nil
    }
    /// Listen-only (Input Monitoring is enough); runs on the main run loop only while a keystroke watch is open.
    private func startKeyTap() -> Bool {
        let mask = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, context in
                if let context {
                    let controller = Unmanaged<AppController>.fromOpaque(context).takeUnretainedValue()
                    MainActor.assumeIsolated { controller.watchKey(type, event) }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        keyTap = tap
        return true
    }
    private func watchKey(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: true) }; return }
        guard let w = watch, var keys = w.keys else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == w.pid, !IsSecureEventInputEnabled(),
              w.keyFocus?.matches(LearningFocusIdentity.capture(pid: w.pid)) == true else { watchTick(ending: true); return }
        if type == .keyDown { keys.apply(Self.watchedKey(event)) } else { keys.click() }
        watch?.keys = keys
    }
    nonisolated static func watchedKey(_ event: CGEvent) -> KeystrokeSpan.Key {
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return .other }
        let word = flags.contains(.maskAlternate), extend = flags.contains(.maskShift)
        switch event.getIntegerValueField(.keyboardEventKeycode) {
        case 51: return .backspace(word: word)
        case 117: return .forwardDelete
        case 123: return .left(word: word, extend: extend)
        case 124: return .right(word: word, extend: extend)
        default:
            var length = 0
            var units = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &units)
            let text = String(utf16CodeUnits: units, count: length)
            // Hardware events carry the shifted character; synthetic ones may carry only the Shift flag.
            let shifted = extend || flags.contains(.maskAlphaShift)
            return .text(shifted && text.allSatisfy(\.isLetter) ? text.uppercased() : text)
        }
    }
    private func deleteTranscript(_ entry: HistoryEntry) throws {
        try records?.delete(entry)
        if lastDictationText == entry.finalText { lastDictationText = nil }
        if setupTestTranscript == entry.finalText { setupTestTranscript = "" }
        if recoveryEntryID == entry.id { recoveryEntryID = nil }
    }
    /// Gap #10: saves an edited final text (the raw transcript is kept) and learns from the edit
    /// through the same filter and ledger as automatic observation. Returns false if it could not save.
    @discardableResult
    func editEntryText(_ entry: HistoryEntry, to text: String) -> Bool {
        guard text != entry.finalText else { return true }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { message = "The final text cannot be empty."; return false }
        var edited = entry; edited.finalText = text
        do { try records?.update(edited) } catch { message = "Could not save this transcript."; return false }
        if lastDictationText == entry.finalText { lastDictationText = text }
        refreshHistory()
        if let processing {
            let learned = (try? processing.ledger.learnFromEdit(original: entry.finalText, edited: text)) ?? []
            refreshDictionary()
            if let learned = learned.last { announceLearned(learned) }
        }
        return true
    }
    func deleteEntry(_ entry: HistoryEntry) { do { try deleteTranscript(entry); refreshHistory() } catch { message = "Could not delete this transcript." } }
    func clearHistory() {
        let alert = NSAlert(); alert.messageText = "Delete all saved transcripts?"; alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Delete All"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            do { for entry in history { try deleteTranscript(entry) } }
            catch { message = "Could not delete all transcripts. Remaining entries are shown in History." }
            refreshHistory()
        }
    }
    func dismissStatus() {
        guard !isBusy else { return }
        if sessionAvailable {
            setPhase("Ready", idleMessage)
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
        downloader.start { [weak self] result in
            DispatchQueue.main.async {
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
    func downloadDictionaryModel() {
        guard let dictionaryDownloader else { dictionaryModelMessage = ModelDownloadError.invalidManifest.userMessage; return }
        if let refusal = ModelGate.downloadRefusal(isBusy: isBusy, preview: preview, downloading: dictionaryDownloadInFlight) { dictionaryModelMessage = refusal; return }
        let text = DictionaryModelFacts.confirmation(downloadSize: dictionaryDownloader.downloadSize, license: dictionaryDownloader.license, folder: dictionaryDownloader.target)
        let alert = NSAlert(); alert.messageText = text.title; alert.informativeText = text.body
        alert.addButton(withTitle: "Download"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let refusal = ModelGate.downloadRefusal(isBusy: isBusy, preview: preview, downloading: dictionaryDownloadInFlight) { dictionaryModelMessage = refusal; return }
        dictionaryDownloadInFlight = true; dictionaryModelMessage = ""; dictionarySupportFailed = false
        dictionaryModelStatus = .downloading(ModelDownloadProgress(bytesDone: 0, totalBytes: dictionaryDownloader.downloadSize))
        dictionaryDownloader.start { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.dictionaryDownloadInFlight = false
                self.dictionaryModelStatus = dictionaryDownloader.status()
                self.dictionaryModelMessage = DictionaryModelFacts.completionMessage(result)
                self.prewarm() // Compiles the new model now, not on the next dictation.
            }
        }
    }
    func cancelDictionaryModelDownload() { dictionaryDownloader?.cancel() }
    func removeDictionaryModel() {
        guard let dictionaryDownloader else { return }
        if let refusal = ModelGate.removeRefusal(isBusy: isBusy, preview: preview, downloading: dictionaryDownloadInFlight) { dictionaryModelMessage = refusal; return }
        let alert = NSAlert(); alert.messageText = DictionaryModelFacts.removeTitle
        alert.informativeText = DictionaryModelFacts.removeBody(folder: dictionaryDownloader.target)
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let refusal = ModelGate.removeRefusal(isBusy: isBusy, preview: preview, downloading: dictionaryDownloadInFlight) { dictionaryModelMessage = refusal; return }
        warm.stopNow()
        do { try dictionaryDownloader.remove(); dictionaryModelMessage = "Dictionary support was removed." }
        catch { dictionaryModelMessage = (error as? ModelDownloadError)?.userMessage ?? ModelDownloadError.fileSystem.userMessage }
        dictionaryModelStatus = dictionaryDownloader.status(); dictionarySupportFailed = false
        prewarm()
    }
    // MARK: Live words (gap #13)

    /// Checks the live folder's hashes once per launch, then loads the model once with no audio, so
    /// its first compile (about 10 s) happens now rather than in a recording. Off the main thread.
    private var preparingLiveWords = false
    private func prepareLiveWords() {
        guard !preview, !liveWordsVerified, !preparingLiveWords, liveWordsRow.isReady, let folder = liveWordsDownloader?.target,
              let helper = Bundle.main.url(forAuxiliaryExecutable: "ModelBench"),
              let manifest = Bundle.main.url(forResource: "artifact-pins", withExtension: "json") else { return }
        preparingLiveWords = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard (try? ModelVerificationCache.shared.verify(folder, manifest: manifest, list: liveWordsFileList)) != nil else {
                DispatchQueue.main.async { self?.preparingLiveWords = false; self?.liveWordsMessage = "Live words failed verification. Remove them and download again." }
                return
            }
            let compile = Process(); compile.executableURL = helper; compile.arguments = [folder.path, "--stream", "16000"]
            compile.standardInput = FileHandle.nullDevice; compile.standardOutput = FileHandle.nullDevice; compile.standardError = FileHandle.nullDevice
            if (try? compile.run()) != nil { compile.waitUntilExit() }
            DispatchQueue.main.async { self?.preparingLiveWords = false; self?.liveWordsVerified = true }
        }
    }
    private func startLiveWords() {
        stopLiveWords()
        guard LiveWordsFacts.starts(enabled: liveWords, ready: liveWordsVerified, cloudTranscription: sessionTranscriber != nil, onCloud: liveWordsOnCloud),
              !preview, let capture, let rate = capture.recordingFormat?.sampleRate,
              let helper = Bundle.main.url(forAuxiliaryExecutable: "ModelBench"), let folder = liveWordsDownloader?.target else { return }
        let token = generation
        liveText = ""
        guard let stream = LiveStream(helper: helper, folder: folder, sampleRate: rate, onText: { [weak self] text in
            guard let self, self.generation == token, self.live != nil else { return }
            self.liveText = text
        }) else { return }
        live = stream
        capture.setTee { stream.feed($0) }
        bubble.show(phase: phase, message: message, screen: destinationScreen)
    }
    /// Keeps the last text up until the Processing bubble replaces it; the next start clears it.
    private func stopLiveWords() {
        capture?.setTee(nil)
        live?.stop(); live = nil
    }
    func downloadLiveWords() {
        guard let liveWordsDownloader else { liveWordsMessage = ModelDownloadError.invalidManifest.userMessage; return }
        if let refusal = ModelGate.downloadRefusal(isBusy: isBusy, preview: preview, downloading: liveWordsDownloadInFlight) { liveWordsMessage = refusal; return }
        let text = LiveWordsFacts.confirmation(downloadSize: liveWordsDownloader.downloadSize, license: liveWordsDownloader.license, folder: liveWordsDownloader.target)
        let alert = NSAlert(); alert.messageText = text.title; alert.informativeText = text.body
        alert.addButton(withTitle: "Download"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let refusal = ModelGate.downloadRefusal(isBusy: isBusy, preview: preview, downloading: liveWordsDownloadInFlight) { liveWordsMessage = refusal; return }
        liveWordsDownloadInFlight = true; liveWordsMessage = ""; liveWordsVerified = false
        liveWordsStatus = .downloading(ModelDownloadProgress(bytesDone: 0, totalBytes: liveWordsDownloader.downloadSize))
        liveWordsDownloader.start { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.liveWordsDownloadInFlight = false
                self.liveWordsStatus = liveWordsDownloader.status()
                self.liveWordsMessage = LiveWordsFacts.completionMessage(result)
                self.prepareLiveWords()
            }
        }
    }
    func cancelLiveWordsDownload() { liveWordsDownloader?.cancel() }
    func removeLiveWords() {
        guard let liveWordsDownloader else { return }
        if let refusal = ModelGate.removeRefusal(isBusy: isBusy, preview: preview, downloading: liveWordsDownloadInFlight) { liveWordsMessage = refusal; return }
        let alert = NSAlert(); alert.messageText = LiveWordsFacts.removeTitle
        alert.informativeText = LiveWordsFacts.removeBody(folder: liveWordsDownloader.target)
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let refusal = ModelGate.removeRefusal(isBusy: isBusy, preview: preview, downloading: liveWordsDownloadInFlight) { liveWordsMessage = refusal; return }
        do { try liveWordsDownloader.remove(); liveWordsMessage = "Live words were removed." }
        catch { liveWordsMessage = (error as? ModelDownloadError)?.userMessage ?? ModelDownloadError.fileSystem.userMessage }
        liveWordsStatus = liveWordsDownloader.status(); liveWordsVerified = false
    }
    func useDefaultModelDirectory() { if let downloader { modelDirectory = downloader.target.path } }
    func openLink(_ url: URL) { NSWorkspace.shared.open(url) }

    // MARK: Meeting notes (PRD section 11)

    /// Meetings are stored in `history/meetings` and their chunk audio in `retry-audio/meetings`, so
    /// History's retention and Delete All Data cover them. They transcribe on this Mac only (Q2).
    private func configureMeetings(base: URL) {
        let recorder = meetingRecorder
        recorder.configure(store: try? MeetingStore(directory: base.appendingPathComponent("history").appendingPathComponent("meetings")),
                           audioRoot: base.appendingPathComponent("retry-audio").appendingPathComponent("meetings"),
                           persists: appliedHistoryMode.persistsTranscripts)
        recorder.applyDictionary = { [weak self] text in self?.processing?.dictionary.apply(to: text, isCommonWord: isCommonEnglishWord) ?? text }
        recorder.onLiveChange = { [weak self] in self?.updateMenu?(); self?.meetingPanelChanged?() }
        recorder.notesRoute = { [weak self] in self?.meetingNotesRoute }
        recorder.notesWriter = { [weak self] meeting in
            guard let self else { throw NotesFailure.failed("Murmur is closing.") }
            return try await self.writeMeetingNotes(meeting)
        }
        recorder.onNotesChoiceNeeded = { [weak self] in self?.screenRequest = "meetings"; self?.openSettings?() }
        guard !preview, let helper = Bundle.main.url(forAuxiliaryExecutable: "ModelBench"), let manifest = Bundle.main.url(forResource: "artifact-pins", withExtension: "json") else { return }
        let warm = warm
        recorder.transcribe = { [weak self] url, done in
            guard let self else { done(nil); return }
            let models = URL(fileURLWithPath: self.modelDirectory), vocabulary = self.vocabularyFile, dictionaryModel = self.dictionaryModelDirectory
            DispatchQueue.global(qos: .utility).async {
                guard (try? ModelVerificationCache.shared.verify(models, manifest: manifest)) != nil,
                      let launch = HelperLaunch.make(models: models, manifest: manifest, vocabulary: vocabulary, dictionaryModel: dictionaryModel) else { done(nil); return }
                warm.transcribe(url, helper: helper, launch: launch) { line in
                    let answer = line.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    done(answer?["text"] as? String)
                }
            }
        }
    }
    /// Settings → Meetings: where meeting audio is transcribed (decision of October 15, 2026). Applies
    /// to meetings started after it changes; a meeting keeps the route it started with.
    @Published var meetingTranscription = MeetingTranscription.load(.standard) {
        didSet { UserDefaults.standard.set(meetingTranscription.rawValue, forKey: MeetingTranscription.key) }
    }
    /// The disclosure, volume and cost note for Cloud, or nil when no cloud transcriber is configured.
    var meetingCloudNote: (disclosure: String, note: String)? {
        var routes = routeSettings; routes.transcription = .cloud
        let plan = RoutePlan.make(routes, cleanupSendsText: false) { _ in nil }
        guard let disclosure = plan.stages.first(where: { $0.disclosure.stage == .transcription })?.disclosure else { return nil }
        return (disclosure.summary, MeetingRoute.cloudNote(provider: disclosure.provider.displayName, host: disclosure.destinationHost, storesAudio: routes.cloudTranscriber == .gemini))
    }
    /// Settings → Meetings → Meeting notes (Q3). Nil until the first Stop asks, with None preselected.
    @Published var meetingNotesRoute = MeetingNotesRoute.load(.standard) {
        didSet {
            if let route = meetingNotesRoute { UserDefaults.standard.set(route.rawValue, forKey: MeetingNotesRoute.key) }
            else { UserDefaults.standard.removeObject(forKey: MeetingNotesRoute.key) }
        }
    }

    /// The notes route's provider, built from the applied settings and the Keychain like cleanup's,
    /// or why it cannot run. Never falls back to another route.
    func meetingNotesProvider(_ route: MeetingNotesRoute) -> (provider: CleanupProvider?, refusal: String?) {
        let choice: CleanupChoice
        switch route {
        case .none: return (nil, "Meeting notes are off. Choose a notes route in Settings → Meetings.")
        case .appleIntelligence:
            let apple = AppleCleanupProvider()
            return apple.status().map { (nil, $0.userMessage) } ?? (apple, nil)
        case .gemini: choice = .gemini
        case .customAPI: choice = .customAPI
        }
        var routes = appliedRoutes; routes.transcription = .local; routes.cleanup = choice
        let plan = routePlan(routes, cleanupSendsText: true)
        guard let cleaner = plan.cleaner else { return (nil, (plan.refusal ?? "\(route.label) is not set up.") + " Set it up in Settings → Cleanup and API Keys.") }
        // A whole meeting takes longer than a dictation: allow the longest wait each route permits.
        if var gemini = cleaner as? GeminiCleanupProvider { gemini.timeout = 120; return (gemini, nil) }
        if var custom = cleaner as? OpenAICompatibleCleanupProvider { custom.timeout = OpenAICompatibleCleanupProvider.maximumTimeout; return (custom, nil) }
        return (cleaner, nil)
    }

    /// Who receives the transcript on a notes route, for Settings and the first-Stop question.
    func meetingNotesDisclosure(_ route: MeetingNotesRoute) -> String {
        guard route == .gemini || route == .customAPI else { return MeetingNotesRoute.disclosure(route, host: nil, local: true, retention: nil) }
        var routes = appliedRoutes; routes.transcription = .local; routes.cleanup = route == .gemini ? .gemini : .customAPI
        let disclosure = RoutePlan.make(routes, cleanupSendsText: true) { _ in APIKey("disclosure-only") }.stages.first?.disclosure
        let local = disclosure?.staysOnThisMac ?? false
        let warning = disclosure?.warning.map { " " + $0 } ?? ""
        return MeetingNotesRoute.disclosure(route, host: disclosure?.destinationHost, local: local, retention: (disclosure?.retentionNote ?? "") + warning)
    }

    /// Writes notes for a finished meeting on the route chosen now (PRD 11.6).
    func writeMeetingNotes(_ meeting: Meeting) async throws -> MeetingNotesWriter.Outcome {
        let route = meetingNotesRoute ?? .none
        let built = meetingNotesProvider(route)
        guard let provider = built.provider else { throw NotesFailure.failed(built.refusal ?? "Notes could not be written.") }
        let name = route == .appleIntelligence ? "Apple Intelligence (on-device, less accurate)" : provider.id.displayName
        let structured = route == .appleIntelligence
        return try await MeetingNotesWriter.write(meeting, route: route, routeName: name, structured: structured) { system, user in
            do { return structured ? try await AppleSystemModel.notes(system: system, user: user) : try await provider.cleanup(CleanupMessages(system: system, user: user)) }
            catch ProviderError.payloadTooLarge { throw NotesFailure.tooLarge }
            catch let error as ProviderError { throw NotesFailure.failed(error.userMessage) }
            catch { throw NotesFailure.failed("Notes could not be written.") }
        }
    }

    /// Shows or hides the live meeting panel; set by the app delegate.
    var meetingPanelChanged: (() -> Void)?
    /// Start from the Meetings page, Home or the menu bar. Meetings need the local model (Q2).
    func startMeeting(_ source: MeetingSource) {
        var cloud: MeetingRoute.Cloud?, cloudName: String?
        if meetingTranscription == .cloud {
            // The configured cloud transcriber with its existing key; an unconfigured one refuses, never falls back.
            var routes = appliedRoutes; routes.transcription = .cloud
            let plan = routePlan(routes, cleanupSendsText: false)
            guard let provider = plan.transcriber else {
                meetingRecorder.message = (plan.refusal ?? "The cloud transcriber is not set up.") + " Set it up in Settings → Transcription, or choose On this Mac in Settings → Meetings."
                screenRequest = "meetings"; openSettings?(); return
            }
            let vocabulary = processing?.dictionary.vocabularyTerms ?? []
            cloudName = provider.id.displayName
            cloud = { url, done in
                Task {
                    switch await CloudTranscription.run(provider: provider, audioFile: url, vocabulary: vocabulary) {
                    case .transcript(let text): done(.text(text))
                    case .noSpeech: done(.noSpeech)
                    case .heldAnswerSuspected, .failed, .cancelled: done(.failed)
                    }
                }
            }
        } else if !modelRow.isReady {
            meetingRecorder.message = "Meeting notes transcribe on this Mac. Download the speech model in Settings → Transcription first."
            screenRequest = "meetings"; openSettings?(); return
        }
        if !meetingRecorder.start(source, cloud: cloud, cloudName: cloudName), meetingRecorder.consentPending != nil { screenRequest = "meetings"; openSettings?() }
    }

    // MARK: History cap and Delete All Data (R9, §6)

    private func historyDisk(_ store: HistoryStore) -> HistoryDisk<HistoryEntry> {
        HistoryDisk(save: store.save, entries: store.entries, delete: store.delete)
    }
    /// Drops oldest disk entries over the 50 MB cap for finite retention; warns for Forever.
    private func enforceHistoryCap() throws {
        guard let store else { historyCapWarning = nil; return }
        // Meetings live inside the History folder, so they share the cap's oldest-first list.
        let entries = try store.entries()
        // The recorder's list mirrors the saved meetings (the live one excluded); no files are re-read.
        let meetings = meetingRecorder.persists ? meetingRecorder.meetings : []
        let result: HistoryCapResult<CappedHistoryItem>
        if let meetingStore = meetingRecorder.store {
            result = try MeetingCap.enforce(entries: entries.map { ($0.id, $0.recordedAt) }, meetings: meetings, historyDirectory: store.directory, meetingStore: meetingStore,
                                            retention: HistoryRetention(rawValue: appliedRetention) ?? .thirtyDays) { id in
                if let entry = entries.first(where: { $0.id == id }) { try store.delete(entry) }
            }
            if result.dropped.contains(where: \.isMeeting) { meetingRecorder.forget(Set(result.dropped.filter(\.isMeeting).map(\.id))) }
        } else {
            let plain = try HistoryCap.enforce(entries: entries, directory: store.directory, retention: HistoryRetention(rawValue: appliedRetention) ?? .thirtyDays, delete: store.delete)
            result = HistoryCapResult(status: plain.status, dropped: [])
        }
        historyCapWarning = appliedRetention == HistoryRetention.forever.rawValue ? result.status.warning : nil
    }
    /// Called once a dictation's last history save is done.
    private func historySaved() {
        do { try enforceHistoryCap() } catch { historyCapWarning = "Could not check the history size limit. Open History to review saved data." }
        refreshHistory()
    }
    func deleteAllData() {
        guard !isBusy else { message = "Finish the current dictation before deleting data."; return }
        let alert = NSAlert(); alert.messageText = DeleteAllDataText.title; alert.informativeText = DeleteAllDataText.body
        alert.addButton(withTitle: "Delete All Data"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        deleteConfirmedData()
    }
    /// Confirmation is kept outside the wipe so checks exercise the same reset as the UI.
    func deleteConfirmedData() {
        guard !isBusy else { message = "Finish the current dictation before deleting data."; return }
        guard let base = dataDirectory else { return }
        stopWatching()
        meetingRecorder.discardAll()
        if let retry { prestart.discard(store: retry) }
        chunkJobs.values.forEach { $0.discard() }; chunkJobs.removeAll()
        warm.stop()
        generation = UUID()
        lastDictationText = nil; setupTestTranscript = ""
        destination = nil; sessionTranscriber = nil
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
                records?.clearSessionOnly(); records = nil; store = nil; retry = nil; processing = nil; stopWatching()
                recoveryEntryID = nil; recoveryAudio = nil; historyCapWarning = nil; historyNotice = nil
            case .recreateHistory:
                let next = try HistoryStore(directory: locations.history)
                store = next; records = HistoryRouter(disk: historyDisk(next), persists: appliedHistoryMode.persistsTranscripts)
                configureMeetings(base: base)
            case .recreateRetryAudio:
                retry = try RetryAudio(directory: locations.retryAudio)
                try FileManager.default.createDirectory(at: locations.chunks, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                Chunker.directory = locations.chunks
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

    // MARK: API keys (R5) and custom API provider

    /// Publishes which providers have a key. The key itself never leaves the Keychain store.
    func refreshKeys() { savedKeys = Set(KeyText.providers.filter { credentials.exists($0) }) }
    func customAPIKeyNeedsConfirmation(_ provider: ProviderID) -> Bool {
        let address = provider == .customTranscription ? customTranscriptionAPIBaseURL : customAPIBaseURL
        guard savedKeys.contains(provider), let destination = try? CustomAPIKeyBinding.endpoint(address) else { return false }
        return UserDefaults.standard.string(forKey: CustomAPIKeyBinding.preference(provider)) != destination
    }
    private func customAPIAddress(_ provider: ProviderID) -> String? {
        switch provider {
        case .customTranscription: return customTranscriptionAPIBaseURL
        case .customCleanup: return customAPIBaseURL
        default: return nil
        }
    }
    @discardableResult
    func saveKey(_ provider: ProviderID, _ raw: String) -> Bool {
        guard let key = APIKey(raw) else { keyMessages[provider] = KeyText.invalid; return false }
        do {
            if let address = customAPIAddress(provider) { try CustomAPIKeyBinding.save(key, at: address, defaults: .standard, credentials: credentials, provider: provider) }
            else { try credentials.save(key, for: provider) }
            keyMessages[provider] = KeyText.saved
        }
        catch { keyMessages[provider] = KeyText.storeFailed; return false }
        refreshKeys(); return true
    }
    func removeKey(_ provider: ProviderID) {
        do {
            try credentials.delete(provider)
            if customAPIAddress(provider) != nil { UserDefaults.standard.removeObject(forKey: CustomAPIKeyBinding.preference(provider)) }
            keyMessages[provider] = KeyText.removed
        } catch { keyMessages[provider] = KeyText.removeFailed }
        refreshKeys()
    }
    func validateKey(_ provider: ProviderID) {
        let key: APIKey?
        do {
            if let address = customAPIAddress(provider) {
                key = try CustomAPIKeyBinding.read(at: address, defaults: .standard, credentials: credentials, provider: provider)
            } else { key = try credentials.read(provider) }
        } catch { keyMessages[provider] = (error as? CredentialError)?.description ?? KeyText.unreadable; return }
        keyMessages[provider] = KeyText.checking
        let endpoint = customAPIAddress(provider) ?? customAPIBaseURL
        Task { @MainActor [weak self] in
            let message = await KeyCheck.run(provider, key: key, apiBaseURL: endpoint)
            self?.keyMessages[provider] = message
        }
    }

    // MARK: Update checks (R12)

    func checkForUpdates() { runUpdateCheck(manual: true) }
    private func runUpdateCheck(manual: Bool) {
        guard let checker = updateChecker else { if manual { updateStatus = "Update checks are unavailable in this build." }; return }
        guard !checkingForUpdates else { return }
        if !manual {
            // No automatic network request while a meeting records (PRD 11.10).
            guard meetingRecorder.live == nil else { return }
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
        undo.discard(); stopLiveWords(); liveWordsDownloader?.cancel()
        generation = UUID(); cloudRequest.cancel(); monitor?.invalidate(); expiry?.invalidate(); removeShortcut()
        watchTick(ending: true)
        downloader?.cancel()  // Verified and partial files stay staged; Retry resumes them.
        dictionaryDownloader?.cancel()
        if sessionAvailable { session.shutdown() }
        meetingRecorder.shutdown()
        if let runner, runner.isRunning {
            runner.terminate()
            // Closing the app cancels this one local helper; reap it before process exit.
            if runner.isRunning { kill(runner.processIdentifier, SIGKILL) }
            runner.waitUntilExit()
        }
        warm.stopNow()
        bubble.hide()
        if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) }
    }
}

extension HistoryEntry: RetainedHistoryItem {}

/// The learning lexicon (PRD approved condition): a word is common when the English spell checker
/// finds no misspelling in it, so ordinary-word swaps (lunch→launch) are never learned.
/// CorrectionLedger calls it on the main thread only.
// MARK: - Screen reading for writing modes and screen context (gaps #6, #8)

private func axCopy(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
private func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let raw = axCopy(element, name), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(raw, to: AXUIElement.self)
}
private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    guard let raw = axCopy(element, kAXChildrenAttribute), CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
    return (raw as? [AnyObject] ?? []).compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil }
}
private func axSecure(_ element: AXUIElement) -> Bool {
    let role = axCopy(element, kAXRoleAttribute) as? String, subrole = axCopy(element, kAXSubroleAttribute) as? String
    return role == kAXSecureTextFieldSubrole || subrole == kAXSecureTextFieldSubrole
        || (axCopy(element, "AXDOMInputType") as? String)?.lowercased() == "password" || axCopy(element, "AXProtectedContent") as? Bool == true
}

/// The page URL in a known browser, from its web area's AXURL: first up from the focused field,
/// then a short search of the focused window. Never forces accessibility modes on the browser.
/// The result is for mode matching only; callers never store or log it.
func focusedPageURL(pid: pid_t, from element: AXUIElement?) -> URL? {
    guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, browserBundleIDs.contains(bundle) else { return nil }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.25)
    func pageURL(_ e: AXUIElement) -> URL? {
        guard axCopy(e, kAXRoleAttribute) as? String == "AXWebArea", let raw = axCopy(e, kAXURLAttribute),
              CFGetTypeID(raw) == CFURLGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: CFURL.self) as URL
    }
    // The messaging timeout covers only the app element, so a time budget bounds the whole search.
    let deadline = ProcessInfo.processInfo.systemUptime + 0.3
    var current = element
    for _ in 0..<40 {
        guard let e = current, ProcessInfo.processInfo.systemUptime < deadline else { break }
        if let url = pageURL(e) { return url }
        current = axElement(e, kAXParentAttribute)
    }
    // ponytail: breadth-first, 400 nodes; a page whose web area sits deeper is not matched.
    var queue = axElement(app, kAXFocusedWindowAttribute).map { [$0] } ?? [], seen = 0
    while !queue.isEmpty, seen < 400, ProcessInfo.processInfo.systemUptime < deadline {
        let e = queue.removeFirst(); seen += 1
        if let url = pageURL(e) { return url }
        queue += axChildren(e)
    }
    return nil
}

/// The focused field's selected text, unless it is a secure field.
func focusedSelectedText(_ element: AXUIElement) -> String? {
    axSecure(element) ? nil : axCopy(element, kAXSelectedTextAttribute) as? String
}

/// Visible text of the app's focused window through Accessibility, up to `limit` characters,
/// skipping secure fields. Bounded by node count and time so a large page cannot stall a dictation.
func focusedWindowText(pid: pid_t, limit: Int) -> String {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.25)
    guard let window = axElement(app, kAXFocusedWindowAttribute) else { return "" }
    let deadline = ProcessInfo.processInfo.systemUptime + 0.5
    var queue = [window], seen = 0, out = ""
    while !queue.isEmpty, seen < 2_000, out.count < limit, ProcessInfo.processInfo.systemUptime < deadline {
        let e = queue.removeFirst(); seen += 1
        if axSecure(e) { continue }
        let role = axCopy(e, kAXRoleAttribute) as? String
        if ["AXStaticText", "AXTextField", "AXTextArea", "AXHeading"].contains(role ?? ""),
           let text = axCopy(e, kAXValueAttribute) as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += (out.isEmpty ? "" : "\n") + text
        }
        queue += axChildren(e)
    }
    return String(out.prefix(limit))
}

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
