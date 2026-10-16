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
    /// Meetings whose notes are being written (W7b).
    @Published private(set) var notesWriting: Set<String> = []
    /// Why notes could not be written, per meeting; the transcript is kept either way.
    @Published var notesProblem: [String: String] = [:]
    /// A meeting waiting for the first-Stop notes route question (Q3).
    @Published var notesChoicePending: String?

    /// Set by AppController: transcribe a 16 kHz WAV with the warm helper (text or nil).
    var transcribe: ((URL, @escaping (String?) -> Void) -> Void)?
    /// Set by AppController: the dictionary's spellings, applied to each line.
    var applyDictionary: (String) -> String = { $0 }
    /// Set by AppController: the notes route in Settings, nil until the first Stop asks (Q3).
    var notesRoute: () -> MeetingNotesRoute? = { nil }
    /// Set by AppController: writes notes with the route chosen now. Throws `NotesFailure`.
    var notesWriter: ((Meeting) async throws -> MeetingNotesWriter.Outcome)?
    /// Called when the notes question waits after a Stop the user clicked, to open the Meetings page.
    var onNotesChoiceNeeded: (() -> Void)?
    /// Meetings stopped by the user, whose notes question may open the Meetings page; automatic stops
    /// (cap, silence) only ask the next time the page is opened.
    private var askOnDone: Set<String> = []
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
    /// The live meeting's chunk folder, pump and source, for rebuilding a stream.
    private var folder: URL?
    private var livePump: MeetingPump?
    private var meWatch = StreamWatch(now: 0), themWatch = StreamWatch(now: 0)
    private var lastPlayingCheck: TimeInterval = 0
    private var themPlaying = true
    private var meScale = MeterScale(), themScale = MeterScale()
    /// The default output device when the tap was built; a change rebuilds the tap.
    private var outputUID: String?

    // MARK: Speaker separation state (W7d, PRD 11.8)

    /// Set by AppController: the verified diarizer folder while speaker separation is on; nil otherwise.
    /// Read when a meeting starts, so a change never affects a meeting in progress.
    var speakerModel: URL?
    /// Set by AppController: the ModelBench helper, which also runs diarization.
    var helper: URL?
    /// Set by SpeakerModelSettings: false once the switch is off or the model is removed. Finished
    /// meetings still waiting are then skipped, so their call audio is not kept for nothing.
    var speakersWanted = true
    /// Set by SpeakerModelSettings: checks the model folder against its pins (cached by fingerprint).
    var verifySpeakerModel: () -> Bool = { false }
    /// Set by AppController: transcribe a Them chunk with word times (the warm helper's timed request).
    var transcribeTimed: ((URL, @escaping (ChunkText?) -> Void) -> Void)?
    /// Meetings whose speakers are being separated now.
    @Published private(set) var separating: Set<String> = []
    private let speakerRunner = SpeakerRunner()
    /// `retry-audio/speakers`, beside the chunk folder, so Delete All Data's retry-audio step removes it.
    var speakerRoot: URL? { audioRoot?.deletingLastPathComponent().appendingPathComponent("speakers", isDirectory: true) }

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
    /// `cloud`: the meeting's cloud transcriber, fixed for this meeting (nil means this Mac).
    func start(_ source: MeetingSource, cloud: MeetingRoute.Cloud? = nil, cloudName: String? = nil) -> Bool {
        guard live == nil else { message = "A meeting is already being recorded."; return false }
        if MeetingConsent.needed(defaults) { consentPending = source; return false }
        guard let audioRoot, transcribe != nil else { message = "Meeting notes are unavailable: private storage could not be opened."; return false }
        var meeting = Meeting(id: UUID().uuidString, recordedAt: Date(), source: source)
        meeting.transcribedBy = cloud == nil ? nil : cloudName
        // Fixed when the meeting starts, like the route: keep the Them stream for diarization (Q4).
        if !source.micOnly, speakerModel != nil { meeting.speakers = SpeakerSeparation(state: .pending, threshold: MeetingSpeakers.threshold) }
        let folder = MeetingAudio.folder(audioRoot, meeting: meeting.id)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { message = "Meeting notes could not create private storage."; return false }
        let pump = makePump(meeting.id, cloud: cloud, timed: meeting.speakers != nil && cloud == nil)
        started = ProcessInfo.processInfo.systemUptime; lastVoice = started; lastSave = started
        systemAudioProblem = nil; warning = nil; askEnded = false; behind = false; elapsed = 0; message = nil
        callApp = source.bundleID; callWasUsingMic = false
        meWatch = StreamWatch(now: started); themWatch = StreamWatch(now: started)
        meScale = MeterScale(); themScale = MeterScale(); themPlaying = true; lastPlayingCheck = 0
        self.folder = folder; livePump = pump
        live = meeting
        if let error = startMe() {
            live = nil; self.folder = nil; livePump = nil; pumps[meeting.id] = nil; try? FileManager.default.removeItem(at: folder)
            meetingLog.notice("meeting-mic-start-failed error=\(String(describing: error), privacy: .public)")
            message = "The microphone could not start. Check Microphone access in System Settings."
            return false
        }
        if !source.micOnly, let error = startTap(source) {
            systemAudioProblem = "The call's audio could not be recorded (\(error)). Allow Murmur under System Audio Recording in System Settings → Privacy & Security, then start again."
        }
        save(force: true)
        meetingLog.notice("meeting-started mic-only=\(source.micOnly, privacy: .public) all-apps=\(source.allApps, privacy: .public)")
        onLiveChange?()
        return true
    }

    /// Starts (or, after a stall, rebuilds) the microphone stream; its chunks continue the same
    /// stream from the meeting's current time. The old capture is stopped first, which flushes its last chunk.
    private func startMe() -> Error? {
        guard let folder, let pump = livePump else { return CaptureError("No meeting") }
        capture?.stop(); capture = nil
        let me = Capture()
        let feed = MeetingStreamFeed(stream: .me, folder: folder, offset: ProcessInfo.processInfo.systemUptime - started, enqueue: pump.enqueue) { [weak self] in
            DispatchQueue.main.async { self?.streamFailed(.me) }
        }
        do {
            try me.start(url: nil, fixedFormat: SystemAudioTap.format, chunkFolder: folder, current: false)
            _ = me.attachChunks(feed.receive)
            capture = me
            return nil
        } catch { return error }
    }

    /// Starts (or rebuilds) the call's stream: a new tap and aggregate device on the current processes and output device.
    private func startTap(_ source: MeetingSource) -> Error? {
        guard let folder, let pump = livePump else { return CaptureError("No meeting") }
        tap?.stop(); tap = nil
        let clients = AudioProcessList.all().map(\.bundleID)
        let target: TapTarget
        if let id = source.bundleID {
            target = .only(CallApp.app(id) ?? CallApp(bundleID: id, name: source.name, isBrowser: false, helpers: []))
        } else {
            target = .allExcept(CallApp.ownBundleIDs(main: Bundle.main.bundleIdentifier, running: clients))
        }
        let tap = SystemAudioTap(chunkFolder: folder)
        let feed = MeetingStreamFeed(stream: .them, folder: folder, offset: ProcessInfo.processInfo.systemUptime - started, enqueue: pump.enqueue) { [weak self] in
            DispatchQueue.main.async { self?.streamFailed(.them) }
        }
        tap.attachChunks(feed.receive)
        outputUID = AudioProcessList.defaultOutputUID()
        do { try tap.start(target); self.tap = tap; return nil } catch { return error }
    }

    /// Continues with the microphone only after the call's audio failed.
    func continueWithMicrophoneOnly() {
        guard var meeting = live else { return }
        meeting.source.micOnly = true; meeting.speakers = nil; live = meeting; systemAudioProblem = nil; save(force: true)
        deleteKeptAudio(meeting.id)
    }

    /// Stops capture; the last chunks are still transcribed into the saved meeting.
    func stop() { finish(manual: true) }

    private func finish(manual: Bool) {
        guard var meeting = live else { return }
        capture?.stop(); tap?.stop(); capture = nil; tap = nil; folder = nil; livePump = nil
        meeting.seconds = max(meeting.seconds, ProcessInfo.processInfo.systemUptime - started)
        meeting.finished = true
        live = nil
        meetings.insert(meeting, at: 0)
        if persists { try? store?.save(meeting) }
        if manual { askOnDone.insert(meeting.id) }
        if pumps[meeting.id]?.isIdle == false { finishing.insert(meeting.id) } else { pumps[meeting.id] = nil; separate(meeting.id) }
        askEnded = false; warning = nil; meLevel = 0; themLevel = 0
        meetingLog.notice("meeting-stopped seconds=\(Int(meeting.seconds))")
        onLiveChange?(); refreshLeftovers()
        if pumps[meeting.id] == nil { transcriptDone(meeting.id) }
    }

    /// Discards the meeting being recorded: capture, queued chunks, audio and record.
    func cancel() {
        guard let meeting = live else { return }
        capture?.stop(); tap?.stop(); capture = nil; tap = nil; folder = nil; livePump = nil
        pumps.removeValue(forKey: meeting.id)?.stop()
        if let audioRoot { try? FileManager.default.removeItem(at: MeetingAudio.folder(audioRoot, meeting: meeting.id)) }
        deleteKeptAudio(meeting.id)
        try? store?.delete(meeting.id)
        live = nil; askEnded = false; warning = nil; systemAudioProblem = nil
        onLiveChange?()
    }

    /// Delete All Data: stop everything and forget every meeting in memory.
    func discardAll() {
        cancel()
        pumps.values.forEach { $0.stop() }; pumps = [:]
        speakerRunner.cancelAll(); separating = []
        meetings = []; finishing = []; leftovers = [:]; store = nil; audioRoot = nil
        notesProblem = [:]; notesChoicePending = nil; askOnDone = []
    }

    // MARK: Lines

    /// Leftovers are always finished on this Mac (`cloud` nil): nothing falls back to the cloud.
    /// `timed`: Them chunks ask the warm helper for word times too, so a line can be split where the
    /// voice changes (W7d). Only on this Mac; cloud lines are assigned whole.
    private func makePump(_ id: String, cloud: MeetingRoute.Cloud? = nil, timed: Bool = false) -> MeetingPump {
        let transcribe = transcribe
        let local: MeetingRoute.Local = { url, done in
            guard let transcribe else { done(nil); return }
            transcribe(url, done)
        }
        var transcriber = MeetingRoute.transcriber(cloud: cloud, local: local)
        if timed, let transcribeTimed {
            let base = transcriber
            transcriber = { url, done in MeetingAudio.parse(url)?.stream == .them ? transcribeTimed(url, done) : base(url, done) }
        }
        let pump = MeetingPump(transcribe: transcriber, deliver: { [weak self] job, text in
            DispatchQueue.main.async { self?.deliver(id, job, text) }
        })
        pumps[id] = pump
        return pump
    }

    private func deliver(_ id: String, _ job: MeetingPump.Job, _ chunk: ChunkText?) {
        guard let chunk else {
            meetingLog.notice("meeting-chunk-failed stream=\(job.stream.rawValue, privacy: .public)")
            refreshLeftovers(); settle(id); return
        }
        // Content-free: how many words a chunk gave, so an all-silent stream shows up as words=0.
        meetingLog.notice("meeting-line stream=\(job.stream.rawValue, privacy: .public) words=\(chunk.text.split(separator: " ").count) fallback=\(chunk.localFallback, privacy: .public)")
        let spelled = applyDictionary(chunk.text)
        update(id) {
            $0.insert(stream: job.stream, start: job.start, end: job.start + job.duration, text: spelled, localFallback: chunk.localFallback, words: chunk.words)
            // A leftover finished after notes were written: they no longer cover the whole transcript.
            if $0.notes != nil, !spelled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { $0.notes?.outdated = true }
        }
        if job.stream == .them { keepAudio(id, job) }
        try? FileManager.default.removeItem(at: job.url)
        settle(id)
    }

    private func settle(_ id: String) {
        guard live?.id != id, pumps[id]?.isIdle != false else { return }
        pumps[id] = nil; finishing.remove(id); refreshLeftovers()
        separate(id)
        transcriptDone(id)
    }

    // MARK: Notes (W7b, PRD 11.6)

    /// The transcript is complete: write notes on the chosen route, or ask for one the first time.
    /// Notes already written are left alone (a finished leftover marks them out of date instead).
    private func transcriptDone(_ id: String) {
        let manual = askOnDone.remove(id) != nil
        guard let meeting = meetings.first(where: { $0.id == id }), meeting.notes == nil,
              meeting.lines.contains(where: { !$0.isHidden }) else { return }
        switch notesRoute() {
        case nil:
            notesChoicePending = id
            if manual { onNotesChoiceNeeded?() }
        case .none?: break
        default: writeNotes(id)
        }
    }

    /// Writes (or rewrites: "Update Notes") a finished meeting's notes. Failure keeps the meeting and says why.
    func writeNotes(_ id: String) {
        guard let writer = notesWriter, !notesWriting.contains(id), !finishing.contains(id),
              let meeting = meetings.first(where: { $0.id == id }) else { return }
        guard meeting.lines.contains(where: { !$0.isHidden }) else { notesProblem[id] = "There is no transcript to write notes from."; return }
        notesWriting.insert(id); notesProblem[id] = nil
        Task { [weak self] in
            let result: Result<MeetingNotesWriter.Outcome, Error>
            do { result = .success(try await writer(meeting)) } catch { result = .failure(error) }
            guard let self else { return }
            self.notesWriting.remove(id)
            switch result {
            case .success(let outcome):
                // Content-free: counts and reasons only.
                let reasons = outcome.reasons.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ",")
                meetingLog.notice("meeting-notes points=\(outcome.notes.keyPoints.count) decisions=\(outcome.notes.decisions.count) actions=\(outcome.notes.actions.count) dropped=\(outcome.notes.dropped) reasons=\(reasons, privacy: .public)")
                self.update(id) { meeting in
                    var notes = outcome.notes
                    // Keep ticked action items that were written again word for word.
                    let ticked = Set((meeting.notes?.actions ?? []).filter { $0.done == true }.map(\.text))
                    for i in notes.actions.indices where ticked.contains(notes.actions[i].text) { notes.actions[i].done = true }
                    meeting.notes = notes
                }
            case .failure(let error):
                let reason: String
                switch error as? NotesFailure {
                case .failed(let text)?: reason = text
                case .tooLarge?: reason = "This meeting is too long for the notes route."
                case nil: reason = "Notes could not be written."
                }
                meetingLog.notice("meeting-notes-failed")
                self.notesProblem[id] = reason + " The transcript is saved."
            }
        }
    }

    /// The first-Stop question was answered (or the route changed in Settings).
    func notesRouteChosen(_ route: MeetingNotesRoute) {
        guard let id = notesChoicePending else { return }
        notesChoicePending = nil
        if route != .none { writeNotes(id) }
    }

    /// Ticks or unticks an action item's checkbox.
    func toggleAction(_ index: Int, of id: String) {
        update(id) { meeting in
            guard var notes = meeting.notes, notes.actions.indices.contains(index) else { return }
            notes.actions[index].done = !(notes.actions[index].done ?? false)
            meeting.notes = notes
        }
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

    /// The user's own notes. Changing them marks written notes out of date (PRD 11.6).
    func setNotes(_ text: String, for id: String) {
        update(id) { meeting in
            guard meeting.myNotes != text else { return }
            meeting.myNotes = text
            if meeting.notes != nil { meeting.notes?.outdated = true }
        }
    }

    /// A chunk file could not be written: mark the gap and rebuild the stream with a new chunker.
    private func streamFailed(_ stream: MeetingStream) {
        guard live != nil else { return }
        gap(stream, reason: "write-failed")
        rebuild(stream, reason: "write-failed")
    }

    private func gap(_ stream: MeetingStream, reason: String) {
        guard var meeting = live else { return }
        meeting.gaps.append(elapsed); live = meeting
        meetingLog.notice("meeting-gap stream=\(stream.rawValue, privacy: .public) reason=\(reason, privacy: .public) at=\(self.elapsed, format: .fixed(precision: 1))")
    }

    private func rebuild(_ stream: MeetingStream, reason: String) {
        guard let meeting = live else { return }
        let error: Error?
        if stream == .me { error = startMe(); meWatch.rebuilt(now: ProcessInfo.processInfo.systemUptime) }
        else { error = startTap(meeting.source); themWatch.rebuilt(now: ProcessInfo.processInfo.systemUptime) }
        meetingLog.notice("meeting-rebuild stream=\(stream.rawValue, privacy: .public) reason=\(reason, privacy: .public) ok=\(error == nil, privacy: .public) error=\(error.map { String(describing: $0) } ?? "-", privacy: .public)")
    }

    /// Applies one stream's watch result. A stall marks one gap and rebuilds; until audio flows
    /// again it rebuilds every few seconds; recovery clears the warning.
    private func watch(_ stream: MeetingStream, _ action: StreamWatch.Action) {
        let name = stream == .me ? "Your microphone" : "The call's audio"
        switch action {
        case .none: break
        case .stalled:
            gap(stream, reason: "no-audio-\(Int(StreamWatch.stallAfter))s")
            warning = "\(name) stopped arriving. Murmur is restarting it."
            rebuild(stream, reason: "no-audio")
        case .rebuild: rebuild(stream, reason: "still-no-audio")
        case .recovered(let after):
            meetingLog.notice("meeting-recovered stream=\(stream.rawValue, privacy: .public) after=\(after, format: .fixed(precision: 1))")
            if warning?.hasPrefix(name) == true { warning = nil }
        }
    }

    // MARK: Ticks

    /// Called about four times a second while Murmur runs.
    func tick() {
        guard let meeting = live else { return }
        let now = ProcessInfo.processInfo.systemUptime
        elapsed = now - started
        let meRaw = capture.map { c in c.queue.sync { c.level } } ?? 0
        let themRaw = tap.map { t in t.queue.sync { t.level } } ?? 0
        meLevel = meScale.display(meRaw); themLevel = themScale.display(themRaw)
        if max(meRaw, themRaw) > MeetingLimits.silenceLevel { lastVoice = now; askEnded = false }
        // The meeting-only Capture is not the controller's: it restarts in place on a device change
        // (W5 rule); if audio still stops, the watch rebuilds it with a new engine.
        if let capture, !capture.engine.isRunning, !capture.restart() {
            meetingLog.notice("meeting-mic-restart-failed at=\(self.elapsed, format: .fixed(precision: 1))")
        }
        watch(.me, meWatch.update(count: capture.map { c in c.queue.sync { Int64(c.frames) } } ?? 0, now: now))
        if live == nil { return }
        if meeting.source.micOnly == false && systemAudioProblem == nil {
            // A tap delivers nothing while no tapped app plays (YouTube paused, a call not yet connected): idle, not a stall.
            if now - lastPlayingCheck >= 1 { lastPlayingCheck = now; themPlaying = tap?.isPlaying(AudioProcessList.all()) ?? true }
            watch(.them, themWatch.update(count: tap.map { t in t.queue.sync { t.buffers } } ?? 0, now: now, idle: !themPlaying))
        }
        behind = (pumps[meeting.id]?.backlog ?? 0) > MeetingLimits.behind
        // A denied tap may deliver silence rather than an error (PRD 11.10): say so after 60 s without call audio.
        if let tap, systemAudioProblem == nil, elapsed > 60, !tap.queue.sync(execute: { tap.heardSignal }), warning == nil {
            warning = "No call audio yet. If the call is playing, check that Murmur is allowed under System Audio Recording in System Settings → Privacy & Security."
        } else if let tap, warning?.hasPrefix("No call audio") == true, tap.queue.sync(execute: { tap.heardSignal }) { warning = nil }
        if now - lastTapRefresh >= 2 {
            lastTapRefresh = now; tap?.refreshProcesses()
            // A call can switch the output device (a headset entering call mode); the aggregate is built on it.
            if tap != nil, let current = AudioProcessList.defaultOutputUID(), current != outputUID {
                gap(.them, reason: "output-device-changed"); rebuild(.them, reason: "output-device-changed")
            }
            if let callApp {
                let app = CallApp.app(callApp) ?? CallApp(bundleID: callApp, name: "", isBrowser: false, helpers: [])
                let using = AudioProcessList.all().contains { $0.input && app.matches($0.bundleID) }
                if callWasUsingMic && !using { askEnded = true }
                callWasUsingMic = using
            }
        }
        switch MeetingLimits.action(elapsed: elapsed, silentFor: now - lastVoice) {
        case .stopCap: message = "Meeting notes stopped at the 3-hour limit."; finish(manual: false)
        case .stopSilent: message = "Meeting notes stopped after 10 minutes of silence."; finish(manual: false)
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
        pumps.removeValue(forKey: id)?.stop(); finishing.remove(id); notesProblem[id] = nil
        if notesChoicePending == id { notesChoicePending = nil }
        speakerRunner.cancel(id); separating.remove(id); deleteKeptAudio(id)
        if persists, let store, FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(id + ".json").path) {
            do { try store.delete(id) } catch { message = "Could not delete this meeting."; return }
        }
        if let audioRoot { try? FileManager.default.removeItem(at: MeetingAudio.folder(audioRoot, meeting: id)) }
        meetings.removeAll { $0.id == id }; refreshLeftovers()
    }

    /// Expires meetings with History's retention, and chunk audio after 24 hours.
    /// Meetings the History cap already deleted from disk.
    func forget(_ ids: Set<String>) {
        for id in ids { pumps.removeValue(forKey: id)?.stop(); finishing.remove(id); speakerRunner.cancel(id); separating.remove(id) }
        meetings.removeAll { ids.contains($0.id) }; purgeAudio()
    }

    /// Uses the meetings in memory, so the minute timer never re-reads every file.
    func purge(cutoff: Date?) {
        if let cutoff {
            for meeting in meetings where meeting.recordedAt <= cutoff {
                pumps.removeValue(forKey: meeting.id)?.stop(); finishing.remove(meeting.id)
                speakerRunner.cancel(meeting.id); separating.remove(meeting.id)
                if persists { try? store?.delete(meeting.id) }
            }
            meetings.removeAll { $0.recordedAt <= cutoff }
            try? store?.purgeUnreadable(cutoff: cutoff)
        }
        purgeAudio()
    }

    private func purgeAudio() {
        guard let audioRoot else { return }
        var active = Set(pumps.keys); if let live { active.insert(live.id) }
        MeetingAudio.purge(audioRoot, keep: Set(meetings.map(\.id)), active: active)
        refreshLeftovers()
        // Kept Them audio: only for meetings still waiting for diarization, and never past 24 hours.
        if let speakerRoot {
            let pending = Set((meetings + (live.map { [$0] } ?? [])).filter { $0.speakers?.state == .pending }.map(\.id))
            SpeakerAudio.purge(speakerRoot, keep: pending, active: active.union(separating))
            // Resumes a separation that quitting interrupted, and fails one whose audio expired.
            for id in pending where !active.contains(id) { separate(id) }
        }
    }

    /// Murmur is quitting: never keep recording (PRD 11.3). Untranscribed chunks stay for 24 hours.
    func shutdown() {
        if live != nil { finish(manual: false) }
        pumps.values.forEach { $0.stop() }
        // A separation still pending runs again at the next launch while its audio is under 24 hours old.
        speakerRunner.cancelAll()
    }

    /// UI fixture only (check_ui.swift): synthetic meetings, and optionally a synthetic live one; no capture.
    func showFixture(_ finished: [Meeting], live: Meeting?, leftovers: [String: Int] = [:], separating: Set<String> = []) {
        meetings = finished; self.live = live; self.leftovers = leftovers; self.separating = separating
        meLevel = 0.55; themLevel = 0.35; elapsed = live?.seconds ?? 0
        onLiveChange?()
    }

    // MARK: Speaker separation (W7d, PRD 11.8)

    /// Writes a transcribed Them chunk into the meeting's kept stream, at its own time.
    private func keepAudio(_ id: String, _ job: MeetingPump.Job) {
        guard (live?.id == id ? live : meetings.first { $0.id == id })?.speakers?.state == .pending, let speakerRoot else { return }
        do {
            let file = try AVAudioFile(forReading: job.url, commonFormat: .pcmFormatInt16, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return }
            try file.read(into: buffer)
            guard file.processingFormat.sampleRate == Double(SpeakerAudio.sampleRate), let channel = buffer.int16ChannelData else { return }
            try SpeakerAudio.write(Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))), at: job.start, to: SpeakerAudio.file(speakerRoot, meeting: id))
        } catch { meetingLog.notice("meeting-keep-audio-failed") }
    }

    /// Runs diarization once a finished meeting has no chunks left to transcribe. Without the model
    /// (separation turned off or removed since), the audio waits, at most 24 hours.
    private func separate(_ id: String) {
        guard live?.id != id, pumps[id] == nil, !separating.contains(id), let speakerRoot,
              let meeting = meetings.first(where: { $0.id == id }), meeting.speakers?.state == .pending else { return }
        let audio = SpeakerAudio.file(speakerRoot, meeting: id)
        guard FileManager.default.fileExists(atPath: audio.path), (try? SpeakerAudio.finish(audio)) != nil else {
            finishSeparation(id, nil, reason: "no-call-audio"); return
        }
        guard let helper, let models = speakerModel else { if !speakersWanted { skipSeparation(id) }; return }
        separating.insert(id)
        meetingLog.notice("speakers-started")
        speakerRunner.run(id, helper: helper, models: models, audio: audio, check: verifySpeakerModel, threshold: meeting.speakers?.threshold ?? MeetingSpeakers.threshold) { [weak self] segments in
            DispatchQueue.main.async { self?.finishSeparation(id, segments, reason: "helper-failed") }
        }
    }

    private func finishSeparation(_ id: String, _ segments: [SpeakerSegment]?, reason: String) {
        separating.remove(id)
        guard meetings.first(where: { $0.id == id })?.speakers?.state == .pending else { return }
        update(id) { meeting in
            if let segments { MeetingSpeakers.apply(segments, to: &meeting) }
            else {
                meeting.speakers?.state = .failed; meeting.speakers?.failure = reason
                for i in meeting.lines.indices { meeting.lines[i].words = nil }
            }
        }
        deleteKeptAudio(id)
        let found = Set(meetings.first { $0.id == id }?.lines.compactMap(\.speaker) ?? []).count
        meetingLog.notice("speakers-finished ok=\(segments != nil, privacy: .public) speakers=\(found) reason=\(segments == nil ? reason : "-", privacy: .public)")
    }

    /// "Separating speakers" → Skip: stops the helper, deletes the kept audio, keeps the Them labels.
    func skipSeparation(_ id: String) {
        guard let meeting = live?.id == id ? live : meetings.first(where: { $0.id == id }), meeting.speakers?.state == .pending else { return }
        speakerRunner.cancel(id); separating.remove(id)
        update(id) { meeting in
            meeting.speakers?.state = .skipped
            for i in meeting.lines.indices { meeting.lines[i].words = nil }
        }
        deleteKeptAudio(id)
    }

    private func deleteKeptAudio(_ id: String) {
        guard let speakerRoot else { return }
        try? FileManager.default.removeItem(at: SpeakerAudio.file(speakerRoot, meeting: id))
    }

    // Renaming, merging and reassigning are per meeting and saved with it.
    // ponytail: notes are marked out of date through `speakers.editedAt`; W7b's notes record compares it (merge note).
    func renameSpeaker(_ number: Int, to name: String, in id: String) { update(id) { $0.renameSpeaker(number, to: name) } }
    func mergeSpeaker(_ from: Int, into: Int, in id: String) { update(id) { $0.mergeSpeaker(from, into: into) } }
    func reassignLine(_ line: Int, to speaker: Int, in id: String) { update(id) { $0.reassignLine(line, to: speaker) } }

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
    func copyNotes(_ meeting: Meeting) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(MeetingExport.notes(meeting), forType: .string)
    }
    func copyNotice() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(MeetingConsent.notice, forType: .string) }

    /// Running call apps and browsers, for the Start menu (Q1).
    static func runningCallApps() -> [CallApp] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return CallApp.catalog.filter { running.contains($0.bundleID) }
    }
}

/// Settings → Meetings → speaker separation (W7d): the switch and the optional pinned download.
/// It tells the recorder which verified model folder to use; nil while off, missing or unverified.
@MainActor final class SpeakerModelSettings: ObservableObject {
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: SpeakerFacts.key); refresh() } }
    @Published private(set) var status: ModelStatus = .notDownloaded
    @Published var message = ""
    let downloader: ModelDownloader?
    var row: ModelRowPresentation { ModelRowPresentation.make(downloader == nil && !fixture ? nil : status) }
    var summary: String { Self.summary(downloadSize: downloader?.downloadSize ?? 21_599_417) }
    private let defaults: UserDefaults
    private let manifest = Bundle.main.url(forResource: "artifact-pins", withExtension: "json")
    private var inFlight = false, verified = false, verifying = false, fixture = false
    private weak var recorder: MeetingRecorder?
    private var isBusy: () -> Bool = { false }
    private var preview = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: SpeakerFacts.key)
        if let manifest, let pins = try? ModelManifest(contentsOf: manifest, repository: SpeakerFacts.repository) {
            downloader = ModelDownloader(manifest: pins, target: SpeakerFacts.directory(home: FileManager.default.homeDirectoryForCurrentUser))
        } else { downloader = nil }
        status = downloader?.status() ?? .notDownloaded
    }

    func attach(_ recorder: MeetingRecorder, preview: Bool, isBusy: @escaping () -> Bool) {
        self.recorder = recorder; self.preview = preview; self.isBusy = isBusy
        let manifest = manifest, folder = downloader?.target
        recorder.verifySpeakerModel = {
            guard let manifest, let folder else { return false }
            return (try? ModelVerificationCache.shared.verify(folder, manifest: manifest, repository: SpeakerFacts.repository)) != nil
        }
        refresh()
    }

    /// Hashes the folder once (off the main thread), then hands it to the recorder while enabled.
    func refresh() {
        guard let recorder, !preview else { return }
        recorder.speakerModel = enabled && verified ? downloader?.target : nil
        let wanted = enabled && (row.isReady || inFlight)
        if recorder.speakersWanted != wanted { recorder.speakersWanted = wanted; if !wanted { recorder.reload() } }
        guard enabled, !verified, !verifying, !inFlight, row.isReady else { return }
        verifying = true
        let check = recorder.verifySpeakerModel
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ok = check()
            DispatchQueue.main.async {
                guard let self else { return }
                self.verifying = false; self.verified = ok
                if !ok { self.message = "Speaker separation failed verification. Remove it and download it again." }
                self.refresh(); recorder.reload()
            }
        }
    }

    func download() {
        guard let downloader else { message = ModelDownloadError.invalidManifest.userMessage; return }
        if let refusal = ModelGate.downloadRefusal(isBusy: isBusy(), preview: preview, downloading: inFlight) { message = refusal; return }
        let text = Self.confirmation(downloadSize: downloader.downloadSize, folder: downloader.target)
        let alert = NSAlert(); alert.messageText = text.title; alert.informativeText = text.body
        alert.addButton(withTitle: "Download"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        inFlight = true; message = ""; verified = false; refresh()
        status = .downloading(ModelDownloadProgress(bytesDone: 0, totalBytes: downloader.downloadSize))
        downloader.start(progress: { [weak self] progress in
            DispatchQueue.main.async { if self?.inFlight == true { self?.status = .downloading(progress) } }
        }) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                self.status = downloader.status()
                self.message = Self.completionMessage(result)
                self.refresh()
            }
        }
    }

    func cancelDownload() { downloader?.cancel() }

    func remove() {
        guard let downloader else { return }
        if let refusal = ModelGate.removeRefusal(isBusy: isBusy(), preview: preview, downloading: inFlight) { message = refusal; return }
        if recorder?.separating.isEmpty == false { message = "Speakers are being separated now. Remove the model when that finishes, or Skip it."; return }
        let alert = NSAlert(); alert.messageText = Self.removeTitle
        alert.informativeText = Self.removeBody(folder: downloader.target)
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        verified = false; refresh()
        do { try downloader.remove(); message = "Speaker separation was removed." }
        catch { message = (error as? ModelDownloadError)?.userMessage ?? ModelDownloadError.fileSystem.userMessage }
        status = downloader.status(); refresh()
    }

    // Download text; the credits come from SpeakerFacts.
    nonisolated static func summary(downloadSize: Int64) -> String { "pyannote community-1 · \(ModelFacts.formatBytes(downloadSize)) download · \(ModelFacts.location)" }
    nonisolated static func confirmation(downloadSize: Int64, folder: URL) -> (title: String, body: String) {
        ("Download speaker separation (\(ModelFacts.formatBytes(downloadSize)))?",
         "Murmur downloads \(ModelFacts.formatBytes(downloadSize)) from Hugging Face and checks every file against its pinned checksum. It is saved in \(folder.path).\n\n\(SpeakerFacts.credits)\n\nWith speaker separation on, the call’s audio from each meeting is kept until separation finishes after Stop, at most 24 hours.")
    }
    nonisolated static let removeTitle = "Remove speaker separation?"
    nonisolated static func removeBody(folder: URL) -> String { "New meetings label the call’s side as Them until you download it again. This deletes \(folder.path)." }
    nonisolated static func completionMessage(_ result: Result<Void, ModelDownloadError>) -> String {
        switch result {
        case .success: return "Speaker separation is downloaded and verified."
        case .failure(.cancelled): return "The download was cancelled. Retry continues from the files already downloaded."
        case .failure(let error): return error.userMessage
        }
    }
    /// UI fixture only (check_ui.swift).
    func showFixture(enabled: Bool, status: ModelStatus) { fixture = true; self.enabled = enabled; self.status = status }
}
