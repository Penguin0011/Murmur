import AppKit
import AVFoundation
import os

private let meetingLog = Logger(subsystem: "cc.clouddev.dictation", category: "meeting")

/// Records one meeting at a time (PRD 11.1–11.5): the microphone through a meeting-only Capture,
/// the call's audio through SystemAudioTap, both chunked into one MeetingPump that shares the warm
/// helper with dictation. Lines are saved as they arrive; audio chunks are deleted once transcribed.
@MainActor final class MeetingRecorder: ObservableObject {
    /// The meeting being recorded, or nil.
    @Published private(set) var live: Meeting?
    /// Finished meetings, newest first (from disk, or memory only with History off).
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var meLevel = 0.0
    @Published private(set) var themLevel = 0.0
    @Published private(set) var elapsed: TimeInterval = 0
    /// More than two minutes of audio waits for transcription.
    @Published private(set) var behind = false
    /// The 2 h 50 min warning, or a stream that stopped; shown in the live view.
    @Published private(set) var warning: String?
    /// Nothing heard on either stream for five minutes, or the call app stopped using the microphone.
    @Published private(set) var askEnded = false
    /// Meetings whose transcription is still running after Stop.
    @Published private(set) var finishing: Set<String> = []
    /// Meetings with chunk audio left over (a crash, or a chunk that failed twice).
    @Published private(set) var leftovers: [String: Int] = [:]
    /// A source waiting for the one-time consent sheet (Q8).
    @Published var consentPending: MeetingSource?
    /// Why the call's audio could not be recorded; the view offers "Record only my microphone".
    @Published var systemAudioProblem: String?
    @Published var message: String?

    /// Set by AppController: transcribe a 16 kHz WAV with the warm helper (text or nil).
    var transcribe: ((URL, @escaping (String?) -> Void) -> Void)?
    /// Set by AppController: the dictionary's spellings, applied to each line.
    var applyDictionary: (String) -> String = { $0 }
    /// Called whenever a meeting starts or stops, for the menu bar and the live panel.
    var onLiveChange: (() -> Void)?
    private(set) var store: MeetingStore?
    private(set) var audioRoot: URL?
    var persists = true
    private let defaults: UserDefaults

    private var capture: Capture?
    private var tap: SystemAudioTap?
    private var pumps: [String: MeetingPump] = [:]
    private var started: TimeInterval = 0
    private var lastVoice: TimeInterval = 0
    private var lastSave: TimeInterval = 0
    private var lastTapRefresh: TimeInterval = 0
    private var callApp: String?
    private var callWasUsingMic = false
    private var micStopped = false
    private var tapStopped = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Points at `history/meetings` and `retry-audio/meetings`; finishes records a crash left open.
    func configure(store: MeetingStore?, audioRoot: URL?, persists: Bool) {
        self.store = store; self.audioRoot = audioRoot; self.persists = persists
        if let audioRoot { try? FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        if let store, let open = try? store.meetings().filter({ !$0.finished }) {
            for var meeting in open where meeting.id != live?.id { meeting.finished = true; try? store.save(meeting) }
        }
        reload()
    }

    func reload() {
        // With History off, finished meetings live only in memory, until Murmur quits.
        if persists { meetings = ((try? store?.meetings()) ?? nil)?.filter { $0.id != live?.id } ?? [] }
        purgeAudio()
    }

    // MARK: Start, stop, cancel

    /// Starts recording, or asks for consent first. Returns false when nothing started.
    @discardableResult
    func start(_ source: MeetingSource) -> Bool {
        guard live == nil else { message = "A meeting is already being recorded."; return false }
        if MeetingConsent.needed(defaults) { consentPending = source; return false }
        guard let audioRoot, transcribe != nil else { message = "Meeting notes are unavailable: private storage could not be opened."; return false }
        let meeting = Meeting(id: UUID().uuidString, recordedAt: Date(), source: source)
        let folder = MeetingAudio.folder(audioRoot, meeting: meeting.id)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { message = "Meeting notes could not create private storage."; return false }
        let pump = makePump(meeting.id)
        started = ProcessInfo.processInfo.systemUptime; lastVoice = started; lastSave = started
        systemAudioProblem = nil; warning = nil; askEnded = false; behind = false; elapsed = 0; message = nil
        callApp = source.bundleID; callWasUsingMic = false; micStopped = false; tapStopped = false
        live = meeting
        let me = Capture()
        let meFeed = MeetingStreamFeed(stream: .me, folder: folder, offset: 0, enqueue: pump.enqueue) { [weak self] in
            DispatchQueue.main.async { self?.streamFailed(.me) }
        }
        do {
            try me.start(url: nil, fixedFormat: SystemAudioTap.format, chunkFolder: folder, current: false)
            _ = me.attachChunks(meFeed.receive)
            capture = me
        } catch {
            live = nil; try? FileManager.default.removeItem(at: folder)
            message = "The microphone could not start. Check Microphone access in System Settings."
            return false
        }
        if !source.micOnly { startTap(source, folder: folder, pump: pump) }
        save(force: true)
        meetingLog.notice("meeting-started mic-only=\(source.micOnly, privacy: .public) all-apps=\(source.allApps, privacy: .public)")
        onLiveChange?()
        return true
    }

    private func startTap(_ source: MeetingSource, folder: URL, pump: MeetingPump) {
        let clients = AudioProcessList.all().map(\.bundleID)
        let target: TapTarget
        if let id = source.bundleID {
            let app = CallApp.app(id) ?? CallApp(bundleID: id, name: source.name, isBrowser: false, helpers: [])
            target = .only(app.tapBundleIDs(running: clients))
        } else {
            target = .allExcept(CallApp.ownBundleIDs(main: Bundle.main.bundleIdentifier, running: clients))
        }
        let tap = SystemAudioTap(chunkFolder: folder)
        let feed = MeetingStreamFeed(stream: .them, folder: folder, offset: ProcessInfo.processInfo.systemUptime - started, enqueue: pump.enqueue) { [weak self] in
            DispatchQueue.main.async { self?.streamFailed(.them) }
        }
        tap.attachChunks(feed.receive)
        do { try tap.start(target); self.tap = tap }
        catch {
            systemAudioProblem = "The call's audio could not be recorded (\(error)). Allow Murmur under System Audio Recording in System Settings → Privacy & Security, then start again."
        }
    }

    /// Continues with the microphone only after the call's audio failed.
    func continueWithMicrophoneOnly() {
        guard var meeting = live else { return }
        meeting.source.micOnly = true; live = meeting; systemAudioProblem = nil; save(force: true)
    }

    /// Stops capture; the last chunks are still transcribed into the saved meeting.
    func stop() {
        guard var meeting = live else { return }
        capture?.stop(); tap?.stop(); capture = nil; tap = nil
        meeting.seconds = max(meeting.seconds, ProcessInfo.processInfo.systemUptime - started)
        meeting.finished = true
        live = nil
        meetings.insert(meeting, at: 0)
        if persists { try? store?.save(meeting) }
        if pumps[meeting.id]?.isIdle == false { finishing.insert(meeting.id) } else { pumps[meeting.id] = nil }
        askEnded = false; warning = nil; meLevel = 0; themLevel = 0
        meetingLog.notice("meeting-stopped seconds=\(Int(meeting.seconds))")
        onLiveChange?(); refreshLeftovers()
    }

    /// Discards the meeting being recorded: capture, queued chunks, audio and record.
    func cancel() {
        guard let meeting = live else { return }
        capture?.stop(); tap?.stop(); capture = nil; tap = nil
        pumps.removeValue(forKey: meeting.id)?.stop()
        if let audioRoot { try? FileManager.default.removeItem(at: MeetingAudio.folder(audioRoot, meeting: meeting.id)) }
        try? store?.delete(meeting.id)
        live = nil; askEnded = false; warning = nil; systemAudioProblem = nil
        onLiveChange?()
    }

    /// Delete All Data: stop everything and forget every meeting in memory.
    func discardAll() {
        cancel()
        pumps.values.forEach { $0.stop() }; pumps = [:]
        meetings = []; finishing = []; leftovers = [:]; store = nil; audioRoot = nil
    }

    // MARK: Lines

    private func makePump(_ id: String) -> MeetingPump {
        let transcribe = transcribe
        let pump = MeetingPump(transcribe: { url, done in
            guard let transcribe else { done(nil); return }
            transcribe(url, done)
        }, deliver: { [weak self] job, text in
            DispatchQueue.main.async { self?.deliver(id, job, text) }
        })
        pumps[id] = pump
        return pump
    }

    private func deliver(_ id: String, _ job: MeetingPump.Job, _ text: String?) {
        guard let text else {
            meetingLog.notice("meeting-chunk-failed stream=\(job.stream.rawValue, privacy: .public)")
            refreshLeftovers(); settle(id); return
        }
        let spelled = applyDictionary(text)
        update(id) { $0.insert(stream: job.stream, start: job.start, end: job.start + job.duration, text: spelled) }
        try? FileManager.default.removeItem(at: job.url)
        settle(id)
    }

    private func settle(_ id: String) {
        guard live?.id != id, pumps[id]?.isIdle != false else { return }
        pumps[id] = nil; finishing.remove(id); refreshLeftovers()
    }

    /// Applies a change to the live meeting or a finished one, and saves it.
    private func update(_ id: String, _ change: (inout Meeting) -> Void) {
        if var meeting = live, meeting.id == id {
            change(&meeting); live = meeting; save(force: false)
        } else if let index = meetings.firstIndex(where: { $0.id == id }) {
            change(&meetings[index]); if persists { try? store?.save(meetings[index]) }
        }
    }

    /// The live record is saved at most every 2 s (and on every forced save), so a crash keeps it.
    private func save(force: Bool) {
        guard persists, let meeting = live else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastSave >= 2 else { return }
        lastSave = now
        try? store?.save(meeting)
    }

    func setNotes(_ text: String, for id: String) { update(id) { $0.myNotes = text } }

    private func streamFailed(_ stream: MeetingStream) {
        guard var meeting = live else { return }
        meeting.gaps.append(elapsed); live = meeting
        warning = stream == .me ? "Your microphone's transcript stopped: Murmur could not write its audio." : "The call's transcript stopped: Murmur could not write its audio."
    }

    // MARK: Ticks

    /// Called about four times a second while Murmur runs.
    func tick() {
        guard let meeting = live else { return }
        let now = ProcessInfo.processInfo.systemUptime
        elapsed = now - started
        meLevel = capture.map { c in c.queue.sync { c.level } } ?? 0
        themLevel = tap.map { t in t.queue.sync { t.level } } ?? 0
        if max(meLevel, themLevel) > MeetingLimits.silenceLevel { lastVoice = now; askEnded = false }
        // The meeting-only Capture is not the controller's; it restarts on a new device here (W5 rule).
        if let capture, !capture.engine.isRunning, !capture.restart(), !micStopped {
            micStopped = true
            var next = meeting; next.gaps.append(elapsed); live = next
            warning = "The microphone stopped. Check that it is connected."
        } else if micStopped, capture?.engine.isRunning == true { micStopped = false; warning = nil }
        behind = (pumps[meeting.id]?.backlog ?? 0) > MeetingLimits.behind
        // The aggregate device delivers buffers (silent or not) while the tap runs; none for 5 s means it stopped.
        // ponytail: flagged with a gap, not restarted; restart once if live tests show taps stopping.
        if let tap, let last = tap.queue.sync(execute: { tap.lastBuffer }), now - last > 5, !tapStopped {
            tapStopped = true
            var next = meeting; next.gaps.append(elapsed); live = next
            warning = "The call's audio stopped arriving. Stop and start meeting notes again to resume it."
        }
        if now - lastTapRefresh >= 2 {
            lastTapRefresh = now; tap?.refreshProcesses()
            if let callApp {
                let using = AudioProcessList.all().contains { $0.input && ($0.bundleID == callApp || $0.bundleID.hasPrefix(callApp + ".")) }
                if callWasUsingMic && !using { askEnded = true }
                callWasUsingMic = using
            }
        }
        switch MeetingLimits.action(elapsed: elapsed, silentFor: now - lastVoice) {
        case .stopCap: message = "Meeting notes stopped at the 3-hour limit."; stop()
        case .stopSilent: message = "Meeting notes stopped after 10 minutes of silence."; stop()
        case .warnCap: warning = "Meeting notes stop at 3 hours, in \(max(1, Int((MeetingLimits.cap - elapsed) / 60))) min."
        case .askEnded: askEnded = true
        case .none: break
        }
        save(force: false)
    }

    // MARK: Recovery, deletion, retention

    func refreshLeftovers() {
        guard let audioRoot else { leftovers = [:]; return }
        var found: [String: Int] = [:]
        for meeting in meetings where pumps[meeting.id] == nil {
            let count = MeetingAudio.leftovers(audioRoot, meeting: meeting.id).count
            if count > 0 { found[meeting.id] = count }
        }
        leftovers = found
    }

    /// Transcribes chunks a crash or a failed transcription left, into their meeting.
    func finishLeftovers(_ id: String) {
        guard let audioRoot, pumps[id] == nil else { return }
        let files = MeetingAudio.leftovers(audioRoot, meeting: id)
        guard !files.isEmpty else { return }
        let pump = makePump(id)
        finishing.insert(id); leftovers[id] = nil
        for url in files {
            guard let parsed = MeetingAudio.parse(url) else { continue }
            pump.enqueue(.init(stream: parsed.stream, url: url, start: parsed.start, duration: MeetingStreamFeed.seconds(url) ?? 0))
        }
    }

    func delete(_ id: String) {
        pumps.removeValue(forKey: id)?.stop(); finishing.remove(id)
        if persists, let store, FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(id + ".json").path) {
            do { try store.delete(id) } catch { message = "Could not delete this meeting."; return }
        }
        if let audioRoot { try? FileManager.default.removeItem(at: MeetingAudio.folder(audioRoot, meeting: id)) }
        meetings.removeAll { $0.id == id }; refreshLeftovers()
    }

    /// Expires meetings with History's retention, and chunk audio after 24 hours.
    /// Meetings the History cap already deleted from disk.
    func forget(_ ids: Set<String>) {
        for id in ids { pumps.removeValue(forKey: id)?.stop(); finishing.remove(id) }
        meetings.removeAll { ids.contains($0.id) }; purgeAudio()
    }

    /// Uses the meetings in memory, so the minute timer never re-reads every file.
    func purge(cutoff: Date?) {
        if let cutoff {
            for meeting in meetings where meeting.recordedAt <= cutoff {
                pumps.removeValue(forKey: meeting.id)?.stop(); finishing.remove(meeting.id)
                if persists { try? store?.delete(meeting.id) }
            }
            meetings.removeAll { $0.recordedAt <= cutoff }
            try? store?.purgeUnreadable(cutoff: cutoff)
        }
        purgeAudio()
    }

    private func purgeAudio() {
        guard let audioRoot else { return }
        var keep = Set(meetings.map(\.id)); if let live { keep.insert(live.id) }
        keep.formUnion(pumps.keys)
        MeetingAudio.purge(audioRoot, keep: keep)
        refreshLeftovers()
    }

    /// Murmur is quitting: never keep recording (PRD 11.3). Untranscribed chunks stay for 24 hours.
    func shutdown() {
        if live != nil { stop() }
        pumps.values.forEach { $0.stop() }
    }

    /// UI fixture only (check_ui.swift): synthetic meetings, and optionally a synthetic live one; no capture.
    func showFixture(_ finished: [Meeting], live: Meeting?, leftovers: [String: Int] = [:]) {
        meetings = finished; self.live = live; self.leftovers = leftovers
        meLevel = 0.55; themLevel = 0.35; elapsed = live?.seconds ?? 0
        onLiveChange?()
    }

    // MARK: Export

    func copyTranscript(_ meeting: Meeting) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(MeetingExport.transcript(meeting), forType: .string)
    }
    func saveMarkdown(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MeetingExport.fileName(meeting)
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(MeetingExport.markdown(meeting).utf8).write(to: url, options: .atomic) }
        catch { message = "Could not save the Markdown file." }
    }
    func copyNotice() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(MeetingConsent.notice, forType: .string) }

    /// Running call apps and browsers, for the Start menu (Q1).
    static func runningCallApps() -> [CallApp] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return CallApp.catalog.filter { running.contains($0.bundleID) }
    }
}
