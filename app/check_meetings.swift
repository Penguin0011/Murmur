import Foundation

// Meeting notetaker W7a (PRD section 11): queue priority, cap and silence timers, consent versioning,
// line ordering by capture time, echo masking, storage, retention, wipe and export. Synthetic text,
// temporary folders, no audio or network.
var failures = 0
func check(_ condition: Bool, _ message: String) { if !condition { failures += 1; print("FAIL: \(message)") } }
func line(_ id: Int, _ stream: MeetingStream, _ start: Double, _ text: String, end: Double? = nil) -> MeetingLine {
    MeetingLine(id: id, stream: stream, start: start, end: end ?? start + 15, text: text)
}
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-meetings-check-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: temp) }

// Queue priority (Q2): dictation jumps every queued meeting chunk; meeting chunks keep their order.
do {
    var lanes = HelperLanes<String>()
    lanes.push("them-1", urgent: false); lanes.push("me-1", urgent: false); lanes.push("them-2", urgent: false)
    check(lanes.pop() == "them-1", "the helper takes meeting chunks in order when no dictation waits")
    lanes.push("dictation-chunk", urgent: true); lanes.push("dictation-final", urgent: true)
    check(lanes.count == 4, "four jobs wait")
    check(lanes.pop() == "dictation-chunk" && lanes.pop() == "dictation-final", "a dictation runs ahead of the meeting backlog, in its own order")
    check(lanes.pop() == "me-1" && lanes.pop() == "them-2" && lanes.pop() == nil, "the meeting backlog resumes in order afterwards, nothing dropped")
}

// Cap and silence (Q7): warning at 2 h 50 min, stop at 3 h; ask at 5 min of silence, stop at 10.
do {
    check(MeetingClock.evaluate(elapsed: 60, silent: 0) == .init(), "a fresh meeting has no alerts")
    check(MeetingClock.evaluate(elapsed: 2 * 3600 + 49 * 60, silent: 0).warn == false, "no warning before 2 h 50 min")
    check(MeetingClock.evaluate(elapsed: 2 * 3600 + 50 * 60, silent: 0) == .init(warn: true), "warning at 2 h 50 min")
    check(MeetingClock.evaluate(elapsed: 3 * 3600, silent: 0).stop == .cap, "stops at the 3-hour cap")
    check(MeetingClock.evaluate(elapsed: 600, silent: 299).askEnded == false, "no question before 5 minutes of silence")
    check(MeetingClock.evaluate(elapsed: 600, silent: 300) == .init(askEnded: true), "asks “Call ended?” at 5 minutes of silence")
    check(MeetingClock.evaluate(elapsed: 900, silent: 599).stop == nil, "does not stop before 10 minutes of silence")
    check(MeetingClock.evaluate(elapsed: 900, silent: 600).stop == .silence, "stops after 10 minutes of silence on both streams")
    var tracker = SilenceTracker()
    tracker.hear(level: 0.5, at: 10)       // Me speaks
    tracker.hear(level: 0.001, at: 200)    // quiet room
    tracker.hear(level: 0.3, at: 250)      // Them speaks: either stream resets silence
    check(tracker.silent(at: 400) == 150, "silence counts from the last voice on either stream")
    tracker.hear(level: MeetingClock.voiceLevel / 2, at: 500)
    check(tracker.silent(at: 560) == 310, "noise under the voice level stays silence")
}

// Consent (Q8): asked once per version; a new version asks again.
do {
    let defaults = UserDefaults(suiteName: "murmur-meetings-check-" + UUID().uuidString)!
    check(MeetingConsent.needed(defaults), "the first meeting asks for the acknowledgement")
    MeetingConsent.acknowledge(defaults)
    check(!MeetingConsent.needed(defaults), "an acknowledged version does not ask again")
    defaults.set(MeetingConsent.version - 1, forKey: MeetingConsent.key)
    check(MeetingConsent.needed(defaults), "a changed text (older stored version) asks again")
    check(MeetingConsent.notice.contains("Murmur") && !MeetingConsent.notice.contains("consent"), "the notice is a short neutral sentence")
}

// Ordering by capture time, not by when transcription finished (11.4).
do {
    var lines: [MeetingLine] = []
    // Them's long chunk finishes late; Me's short ones arrive first.
    MeetingTranscript.insert(line(2, .me, 16.0, "second"), into: &lines)
    MeetingTranscript.insert(line(3, .me, 31.0, "fourth"), into: &lines)
    MeetingTranscript.insert(line(1, .them, 0.4, "first"), into: &lines)
    MeetingTranscript.insert(line(4, .them, 17.5, "third"), into: &lines)
    MeetingTranscript.insert(line(5, .them, 16.0, "same start"), into: &lines)
    check(lines.map(\.text) == ["first", "second", "same start", "third", "fourth"], "lines interleave by capture time; Me first on a tie")
    check(MeetingTranscript.sorted(lines.reversed()) == lines, "sorting a reversed file gives the same order")
    check(MeetingTranscript.clock(3725.9) == "01:02:05", "clock format")
}

// Echo (11.2): a Me run repeating Them within a few seconds is hidden, never deleted.
do {
    let them = line(1, .them, 10, "We should ship the release on Thursday after the review.")
    let echo = line(2, .me, 11, "we should ship the release on Thursday")
    let mixed = line(3, .me, 12, "Sure. We should ship the release on Thursday. I'll write the notes.")
    let later = line(4, .me, 40, "we should ship the release on Thursday")
    let common = line(5, .me, 12, "yeah I think so")
    let themCommon = line(6, .them, 12, "yeah I think so too")
    let short = line(7, .me, 12, "the release", end: 13)
    let lines = [them, echo, mixed, later, common, themCommon, short]
    let hidden = EchoMask.hidden(lines)
    check(EchoMask.visibleText(echo, hidden: hidden[2]) == nil, "a Me line that only echoes Them is hidden")
    check(EchoMask.visibleText(mixed, hidden: hidden[3]) == "Sure. I'll write the notes.", "the user's own words around an echo stay visible")
    check(hidden[4] == nil, "the same words long after Them said them are the user's own")
    check(hidden[7] == nil, "a run shorter than \(EchoMask.minRun) words is never hidden")
    check(hidden[1] == nil && hidden[6] == nil, "Them is never altered")
    check(EchoMask.visibleText(common, hidden: hidden[5]) == nil, "a four-word common phrase right after Them said it is treated as echo (counted in the 1% bar)")
    check(echo.text == "we should ship the release on Thursday", "hiding never changes the stored text")
    let meeting = Meeting(record: MeetingRecord(id: UUID().uuidString, startedAt: Date(timeIntervalSince1970: 1_800_000_000), sourceApp: "Zoom", them: .app), lines: MeetingTranscript.sorted(lines))
    let text = MeetingExport.transcript(meeting)
    check(!text.contains("Me: we should ship the release on Thursday\n") && text.contains("Me: Sure. I'll write the notes."), "export leaves hidden echo out")
}

// Storage, crash recovery, retention, manual delete and History off (11.5).
do {
    let store = try MeetingStore(directory: temp.appendingPathComponent("history/meetings"), persists: true)
    let old = MeetingRecord(id: UUID().uuidString, startedAt: Date().addingTimeInterval(-31 * 86400), sourceApp: nil, them: .allApps, seconds: 60, ended: true)
    var live = MeetingRecord(id: UUID().uuidString, startedAt: Date().addingTimeInterval(-600), sourceApp: "Zoom", sourceBundleID: "us.zoom.xos", them: .app)
    try store.save(old); try store.save(live)
    try store.append(line(2, .them, 20, "later line"), to: live.id)
    try store.append(line(1, .me, 2, "earlier line"), to: live.id)
    live.myNotes = "my own note"; try store.save(live)
    // A crash mid-write leaves half a line at the end.
    let handle = try FileHandle(forWritingTo: store.directory.appendingPathComponent(live.id + ".jsonl"))
    handle.seekToEndOfFile(); handle.write(Data("{\"line\":{\"id\":3,\"str".utf8)); try handle.close()
    let loaded = try store.load(live.id)
    check(loaded?.lines.map(\.text) == ["earlier line", "later line"], "lines come back in capture order; a cut-off last line is skipped")
    check(loaded?.record.myNotes == "my own note", "the last record wins")
    let attrs = try FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent(live.id + ".jsonl").path)
    check((attrs[.posixPermissions] as? Int) == 0o600, "meeting files are owner-only")
    check(store.closeInterrupted() == [live.id], "a meeting left recording by a crash is closed at launch")
    let closed = try store.load(live.id)?.record
    check(closed?.ended == true && closed?.interrupted == true && closed?.seconds == 35, "it is marked interrupted, with its length from the last line")
    check(store.count(recordedAtOrBefore: Date().addingTimeInterval(-30 * 86400)) == 1, "the retention preview counts meetings that would go")
    check(try store.purge(recordedAtOrBefore: Date().addingTimeInterval(-30 * 86400)) == [old.id], "30-day retention removes by start time")
    check(try store.purge(recordedAtOrBefore: nil).isEmpty, "Forever removes nothing")
    check(store.all().map(\.record.id) == [live.id], "the newer meeting stays")
    try store.delete(live.id)
    check(store.all().isEmpty, "manual delete removes the record and its transcript")
    // History off: kept in memory only, gone after quit (a new store) or clearMemory.
    store.persists = false
    let offRecord = MeetingRecord(id: UUID().uuidString, startedAt: Date(), sourceApp: nil, them: .none)
    try store.save(offRecord); try store.append(line(1, .me, 0, "memory only"), to: offRecord.id)
    check(store.all().first?.lines.first?.text == "memory only", "History off keeps the meeting in memory")
    check(((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []).isEmpty, "History off writes nothing to disk")
    store.clearMemory()
    check(store.all().isEmpty, "quitting (or the wipe) drops it")
    check((try? store.load("../escape")) == nil, "ids must be UUIDs")
} catch { check(false, "storage threw: \(error)") }

// Delete All Data covers meetings: they live in history/, their audio in retry-audio/ (11.5).
do {
    let base = temp.appendingPathComponent("wipe")
    let locations = MurmurDataLocations.standard(base: base)
    let store = try MeetingStore(directory: locations.history.appendingPathComponent("meetings"), persists: true)
    let record = MeetingRecord(id: UUID().uuidString, startedAt: Date(), sourceApp: nil, them: .allApps)
    try store.save(record)
    let audio = MeetingAudio.folder(locations.retryAudio.appendingPathComponent("meetings"), meeting: record.id)
    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: audio.appendingPathComponent(MeetingAudio.name(.them, start: 1.5)).path, contents: Data([0]))
    let report = DataWipe.deleteAllData(locations) { [] }
    check(report.succeeded && !FileManager.default.fileExists(atPath: store.directory.path) && !FileManager.default.fileExists(atPath: audio.path), "the wipe removes meeting records and meeting audio")
    check(PostWipeStep.allCases.first == .stopMeeting, "an active meeting is stopped and discarded before anything else")
    check(DeleteAllDataText.body.contains("meeting") && DeleteAllDataText.explanation.contains("meeting"), "the wipe text names meetings")
} catch { check(false, "wipe threw: \(error)") }

// Meeting audio: names keep stream and start; leftovers are found in order; 24 h purge.
do {
    check(MeetingAudio.name(.them, start: 75.25) == "them-75250.wav", "chunk names carry stream and start")
    check(MeetingAudio.parse("me-1500.wav").map { "\($0.stream)\($0.start)" } == "me1.5", "names parse back")
    check(MeetingAudio.parse("../x.wav") == nil && MeetingAudio.parse("me--1.wav") == nil, "other names are ignored")
    let root = temp.appendingPathComponent("audio")
    let id = UUID().uuidString, dir = MeetingAudio.folder(root, meeting: id)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in ["them-30000.wav", "me-2000.wav", "me-16000.wav"] { FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data([0])) }
    check(MeetingAudio.leftovers(root)[id]?.map(\.lastPathComponent) == ["me-2000.wav", "me-16000.wav", "them-30000.wav"], "leftover chunks come back in capture order")
    MeetingAudio.purge(root, now: Date().addingTimeInterval(23 * 3600))
    check(MeetingAudio.leftovers(root)[id]?.count == 3, "leftovers stay for 24 hours")
    MeetingAudio.purge(root, now: Date().addingTimeInterval(24 * 3600 + 1), active: id)
    check(MeetingAudio.leftovers(root)[id]?.count == 3, "the recording meeting's chunks are never purged")
    MeetingAudio.purge(root, now: Date().addingTimeInterval(24 * 3600 + 1))
    check(MeetingAudio.leftovers(root).isEmpty && !FileManager.default.fileExists(atPath: dir.path), "after 24 hours they and their folder are gone")
} catch { check(false, "audio threw: \(error)") }

// Apps and export.
do {
    check(MeetingApps.owns("com.google.Chrome", process: "com.google.Chrome.helper"), "browser helpers belong to the browser")
    check(MeetingApps.owns("com.apple.Safari", process: "com.apple.WebKit.GPU"), "Safari's sound comes from WebKit's GPU process")
    check(MeetingApps.owns("com.apple.FaceTime", process: "com.apple.avconferenced"), "FaceTime's sound comes from avconferenced")
    check(!MeetingApps.owns("us.zoom.xos", process: "com.google.Chrome.helper"), "other apps are not captured")
    check(MeetingApps.note(.allApps)?.contains("music") == true, "All apps says it includes music and notifications")
    let record = MeetingRecord(id: UUID().uuidString, startedAt: Date(timeIntervalSince1970: 1_800_000_000), sourceApp: "Zoom", them: .app, seconds: 3720, myNotes: "Ask about budget", ended: true)
    let meeting = Meeting(record: record, lines: [line(1, .me, 1, "Hello there."), MeetingLine(id: 2, stream: .them, start: 9, end: 12, text: "", gap: true), line(3, .them, 12, "Hi.")])
    let markdown = MeetingExport.markdown(meeting)
    check(markdown.hasPrefix("# Meeting with Zoom, ") && markdown.contains("- Length: 1 h 2 min") && markdown.contains("## My notes\n\nAsk about budget"), "Markdown has title, length and the user's notes")
    check(markdown.contains("[00:00:01] Me: Hello there.") && markdown.contains("(gap in recording)") && markdown.contains("Them: Hi."), "Markdown has the labelled transcript with gaps marked")
    check(MeetingExport.length(20) == "1 min" && MeetingExport.length(0) == "0 min", "short lengths")
}

if failures > 0 { print("\(failures) meeting check(s) failed"); exit(1) }
print("Meeting checks passed.")
