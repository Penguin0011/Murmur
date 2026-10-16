// Meeting notes W7a checks (PRD section 11). No audio, no taps, no network.
// swiftc app/Retention.swift app/Meetings.swift app/MeetingSpeakers.swift app/check_meetings.swift -o /tmp/murmur-meetings-check && /tmp/murmur-meetings-check
import Foundation

nonisolated(unsafe) var failures = 0
func check(_ condition: @autoclosure () throws -> Bool, _ name: String) {
    if (try? condition()) == true { print("ok   \(name)") } else { failures += 1; print("FAIL \(name)") }
}

@main enum MeetingChecks {
    static func main() throws {
        // Echo suppression: a repeated run of the other side is hidden from Me, never from Them.
        do {
            check(MeetingEcho.shown(me: "Sounds good. The budget is due on Friday", them: ["the budget is due on Friday, right?"]) == "Sounds good.", "echoed run removed, own words kept")
            check(MeetingEcho.shown(me: "The budget is due on Friday.", them: ["The budget is due on Friday."]) == "", "fully echoed line is hidden")
            check(MeetingEcho.shown(me: "I think the budget works", them: ["the budget is late"]) == nil, "two shared words are not echo")
            check(MeetingEcho.shown(me: "Yes, let's ship it", them: []) == nil, "no Them lines, nothing hidden")

            var meeting = Meeting(id: UUID().uuidString, recordedAt: Date(), source: MeetingSource(name: "Zoom", bundleID: "us.zoom.xos"))
            meeting.insert(stream: .me, start: 16, end: 30, text: "Right. we should move the launch to next week")
            meeting.insert(stream: .them, start: 0, end: 15, text: "Hello everyone.")
            meeting.insert(stream: .them, start: 15, end: 29, text: "We should move the launch to next week.")
            check(meeting.lines.map(\.start) == [0, 15, 16], "lines ordered by capture time, not arrival")
            let me = meeting.lines.first { $0.stream == .me }!
            check(me.visibleText == "Right." && me.text.hasSuffix("next week"), "a later Them line hides echo in an earlier Me line; the text is kept")
            check(meeting.lines.first { $0.start == 15 }!.shown == nil, "Them is never changed")
            meeting.insert(stream: .me, start: 31, end: 32, text: "   ")
            check(meeting.lines.count == 3 && meeting.seconds == 30, "empty transcripts add no line")
            let far = Meeting(id: UUID().uuidString, recordedAt: Date(), source: .microphoneOnly)
            var farther = far
            farther.insert(stream: .them, start: 0, end: 10, text: "we should move the launch")
            farther.insert(stream: .me, start: 120, end: 130, text: "we should move the launch")
            check(farther.lines.first { $0.stream == .me }!.shown == nil, "echo needs the lines to be close in time")
        }

        // Store: owner-only files, newest first, damaged files moved aside, retention by start date.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-meetings-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try MeetingStore(directory: root.appendingPathComponent("meetings"))
            let old = Meeting(id: UUID().uuidString, recordedAt: Date().addingTimeInterval(-40 * 86400), source: .everything)
            var new = Meeting(id: UUID().uuidString, recordedAt: Date(), source: .microphoneOnly)
            new.insert(stream: .me, start: 0, end: 3, text: "Synthetic line.")
            try store.save(old); try store.save(new)
            try Data("not json".utf8).write(to: store.directory.appendingPathComponent(UUID().uuidString + ".json"))
            let listed = try store.meetings()
            check(listed.map(\.id) == [new.id, old.id], "newest first, damaged file skipped")
            check(((try? FileManager.default.contentsOfDirectory(atPath: store.unreadable.path)) ?? []).count == 1, "damaged file moved to unreadable/")
            let mode = (try FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent(new.id + ".json").path)[.posixPermissions] as? NSNumber)?.intValue
            check(mode == 0o600, "meeting file is owner-only")
            check(try store.meetings().first?.lines.first?.text == "Synthetic line.", "lines round-trip")
            let expired = try store.purge(cutoff: Date().addingTimeInterval(-30 * 86400))
            check(try expired == [old.id] && (store.meetings()).map(\.id) == [new.id], "30-day retention expires the old meeting")
            check(try store.purge(cutoff: nil).isEmpty, "Forever expires nothing")
            check((try? store.delete("../escape")) == nil, "ids must be UUIDs")

            // The cap drops the oldest item of either kind, keeping the newest.
            let history = root.appendingPathComponent("history")
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
            let capStore = try MeetingStore(directory: history.appendingPathComponent("meetings"))
            var big = Meeting(id: UUID().uuidString, recordedAt: Date().addingTimeInterval(-3 * 86400), source: .everything)
            for i in 0..<200 { big.insert(stream: .them, start: Double(i * 20), end: Double(i * 20 + 15), text: String(repeating: "synthetic words ", count: 40)) }
            try capStore.save(big)
            let entryOld = (id: UUID().uuidString, recordedAt: Date().addingTimeInterval(-5 * 86400))
            let entryNew = (id: UUID().uuidString, recordedAt: Date())
            for entry in [entryOld, entryNew] { try Data(repeating: 65, count: 2000).write(to: history.appendingPathComponent(entry.id + ".json")) }
            var deletedEntries: [String] = []
            let capBytes = capStore.size(big.id) + 3000
            let result = try MeetingCap.enforce(entries: [entryOld, entryNew], meetings: [big], historyDirectory: history, meetingStore: capStore,
                                                retention: .thirtyDays, capBytes: capBytes) { deletedEntries.append($0) }
            check(try deletedEntries == [entryOld.id] && result.dropped.count == 1 && (capStore.meetings()).count == 1, "cap drops the oldest dictation first")
            let again = try MeetingCap.enforce(entries: [entryNew], meetings: [big], historyDirectory: history, meetingStore: capStore,
                                               retention: .thirtyDays, capBytes: 2500) { deletedEntries.append($0) }
            check(try again.dropped.map(\.isMeeting) == [true] && (capStore.meetings()).isEmpty, "then the oldest meeting, never the newest item")
            let forever = try MeetingCap.enforce(entries: [entryNew], meetings: [], historyDirectory: history, meetingStore: capStore,
                                                 retention: .forever, capBytes: 10) { _ in }
            check(forever.dropped.isEmpty, "Forever never drops")
        }

        // Chunk audio names and the 24-hour purge.
        do {
            check(MeetingAudio.name(.them, start: 12.3456) == "them-12346.wav", "chunk name carries stream and start")
            let parsed = MeetingAudio.parse(URL(fileURLWithPath: "/x/me-15000.wav"))
            check(parsed?.stream == .me && parsed?.start == 15, "chunk name parses")
            check(MeetingAudio.parse(URL(fileURLWithPath: "/x/boundary.wav")) == nil && MeetingAudio.parse(URL(fileURLWithPath: "/x/me--5.wav")) == nil, "other files are not chunks")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-meeting-audio-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let kept = UUID().uuidString, orphan = UUID().uuidString
            for id in [kept, orphan] { try FileManager.default.createDirectory(at: MeetingAudio.folder(root, meeting: id), withIntermediateDirectories: true) }
            let fresh = MeetingAudio.folder(root, meeting: kept).appendingPathComponent("me-15000.wav")
            let stale = MeetingAudio.folder(root, meeting: kept).appendingPathComponent("them-0.wav")
            let stray = MeetingAudio.folder(root, meeting: kept).appendingPathComponent("\(UUID().uuidString).wav")
            for url in [fresh, stale, stray] { try Data([1]).write(to: url) }
            try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-25 * 3600)], ofItemAtPath: stale.path)
            check(MeetingAudio.leftovers(root, meeting: kept).map(\.lastPathComponent).sorted() == ["me-15000.wav", "them-0.wav"], "leftovers are chunk files only")
            MeetingAudio.purge(root, keep: [kept])
            check(MeetingAudio.leftovers(root, meeting: kept).map(\.lastPathComponent) == ["me-15000.wav"], "chunks past 24 hours and stray files go")
            check(!FileManager.default.fileExists(atPath: MeetingAudio.folder(root, meeting: orphan).path), "a meeting without a record loses its audio")
            MeetingAudio.purge(root, keep: [])
            check(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty, "no record, no audio")

            // The live meeting's folder is never touched: not the chunker's file being written (not yet a
            // chunk name), not an empty folder, even though the live meeting has no saved record yet.
            let live = UUID().uuidString
            let liveFolder = MeetingAudio.folder(root, meeting: live)
            try FileManager.default.createDirectory(at: liveFolder, withIntermediateDirectories: true)
            MeetingAudio.purge(root, keep: [], active: [live])
            check(FileManager.default.fileExists(atPath: liveFolder.path), "an empty live folder survives the minute purge")
            let writing = liveFolder.appendingPathComponent(UUID().uuidString + ".wav")
            try Data([1]).write(to: writing)
            MeetingAudio.purge(root, keep: [], active: [live])
            check(FileManager.default.fileExists(atPath: writing.path), "the chunk being written survives the minute purge")
            MeetingAudio.purge(root, keep: [])
            check(!FileManager.default.fileExists(atPath: liveFolder.path), "once the meeting is gone, its folder goes")
        }

        // The pump: one chunk in flight, recording order across streams, retry once, then keep the file.
        do {
            var pending: [(URL, (ChunkText?) -> Void)] = []
            var delivered: [(MeetingStream, Double, String?)] = []
            let pump = MeetingPump(transcribe: { url, done in pending.append((url, { done($0) })) }, deliver: { job, text in delivered.append((job.stream, job.start, text?.text)) })
            func job(_ stream: MeetingStream, _ start: Double) -> MeetingPump.Job { .init(stream: stream, url: URL(fileURLWithPath: "/x/\(stream)-\(start)"), start: start, duration: 15) }
            pump.enqueue(job(.me, 0)); pump.enqueue(job(.them, 30)); pump.enqueue(job(.them, 15))
            check(pending.count == 1, "only one chunk is with the helper")
            check(pump.backlog == 45, "backlog counts queued and in-flight audio")
            pending.removeFirst().1(ChunkText(text: "first"))
            check(pending.count == 1 && pending[0].0.lastPathComponent == "them-15.0", "next is the earliest recorded, across streams")
            pending.removeFirst().1(nil)
            check(pending.count == 1 && pending[0].0.lastPathComponent == "them-15.0" && delivered.count == 1, "a failure is retried first")
            pending.removeFirst().1(nil)
            check(delivered.last.map { $0.2 == nil && $0.1 == 15 } == true, "a second failure is delivered as nil (file kept)")
            pending.removeFirst().1(ChunkText(text: "third"))
            check(delivered.map(\.1) == [0, 15, 30] && pump.isIdle, "everything delivered in order")
            pump.enqueue(job(.me, 45)); pump.stop()
            pending.removeFirst().1(ChunkText(text: "late"))
            check(delivered.count == 3 && pending.isEmpty, "after stop, answers are ignored and nothing new starts")
        }

        // Meeting transcription route (decision of October 15, 2026): local by default, fixed per meeting,
        // a failed cloud chunk goes to this Mac and is marked, and a local chunk never goes to the cloud.
        do {
            let defaults = UserDefaults(suiteName: "murmur-meeting-route-" + UUID().uuidString)!
            check(MeetingTranscription.load(defaults) == .local, "default is On this Mac")
            defaults.set("cloud", forKey: MeetingTranscription.key)
            check(MeetingTranscription.load(defaults) == .cloud, "Cloud is remembered")
            defaults.set("bogus", forKey: MeetingTranscription.key)
            check(MeetingTranscription.load(defaults) == .local, "an unknown value means local")

            var cloudCalls = 0, localCalls = 0
            var cloudAnswer = MeetingCloudResult.text("cloud words")
            let cloud: MeetingRoute.Cloud = { _, done in cloudCalls += 1; done(cloudAnswer) }
            let local: MeetingRoute.Local = { _, done in localCalls += 1; done("local words") }
            var got: ChunkText?
            let url = URL(fileURLWithPath: "/x/me-0.wav")
            let localOnly = MeetingRoute.transcriber(cloud: nil, local: local)
            localOnly(url) { got = $0 }
            check(got == ChunkText(text: "local words") && cloudCalls == 0, "On this Mac never calls the cloud")
            cloudAnswer = .failed
            localOnly(url) { got = $0 }
            check(cloudCalls == 0, "a local meeting stays local whatever the cloud would answer")
            // The route is captured when the meeting starts; the setting changing later does not matter.
            let cloudMeeting = MeetingRoute.transcriber(cloud: cloud, local: local)
            defaults.set("local", forKey: MeetingTranscription.key)
            cloudAnswer = .text("cloud words")
            cloudMeeting(url) { got = $0 }
            check(got == ChunkText(text: "cloud words") && cloudCalls == 1 && localCalls == 2, "a cloud meeting keeps its route after the setting changes")
            cloudAnswer = .failed
            cloudMeeting(url) { got = $0 }
            check(got == ChunkText(text: "local words", localFallback: true) && cloudCalls == 2 && localCalls == 3, "a failed cloud chunk falls back to this Mac, marked")
            cloudAnswer = .text("cloud again")
            cloudMeeting(url) { got = $0 }
            check(got == ChunkText(text: "cloud again"), "the next chunk tries the cloud again; the meeting is not switched")
            cloudAnswer = .noSpeech
            cloudMeeting(url) { got = $0 }
            check(got == ChunkText(text: "") && localCalls == 3, "silence skipped by the cloud adds no line and no local call")

            var meeting = Meeting(id: UUID().uuidString, recordedAt: Date(), source: .microphoneOnly)
            meeting.insert(stream: .me, start: 0, end: 5, text: "Fallback line.", localFallback: true)
            meeting.insert(stream: .me, start: 5, end: 9, text: "Cloud line.")
            check(meeting.lines.map(\.localFallback) == [true, nil], "fallback lines are marked; others carry nothing")
            let note = MeetingRoute.cloudNote(provider: "Gemini", host: "generativelanguage.googleapis.com", storesAudio: true)
            check(note.contains("other participants") && note.contains("generativelanguage.googleapis.com") && note.contains("230 MB") && note.contains("stores audio") && note.contains("cost"), "cloud note names the host, the voices, the volume, cost and Google's storage")
            check(!MeetingRoute.cloudNote(provider: "Custom Provider", host: "api.example.com", storesAudio: false).contains("Google"), "storage sentence only for Gemini")
        }

        // Stream health: a stall is reported once, rebuilt every few seconds, and recovery needs the new stream's own audio.
        do {
            var watch = StreamWatch(now: 0)
            check(watch.update(count: 100, now: 1) == .none && watch.update(count: 200, now: 2) == .none, "flowing audio: nothing to do")
            check(watch.update(count: 200, now: 4.9) == .none, "under 3 s without audio is not a stall")
            check(watch.update(count: 200, now: 5) == .stalled, "3 s without audio is a stall (one gap)")
            watch.rebuilt(now: 5)
            check(watch.update(count: 0, now: 6) == .none && watch.update(count: 0, now: 7.9) == .none, "no second gap, and no rebuild before 3 s")
            check(watch.update(count: 0, now: 8) == .rebuild, "still nothing: rebuild again")
            watch.rebuilt(now: 8)
            if case .recovered(let after) = watch.update(count: 50, now: 9) { check(abs(after - 7) < 0.001, "recovery reports how long the stream was stalled") } else { check(false, "the new stream's audio recovers it") }
            check(watch.update(count: 60, now: 10) == .none && watch.stalledSince == nil, "back to normal")
            var idle = StreamWatch(now: 0)
            check(idle.update(count: 0, now: 10, idle: true) == .none && idle.update(count: 0, now: 20, idle: true) == .none, "a tap with nothing playing is idle, never a stall")
            check(idle.update(count: 0, now: 22.9) == .none && idle.update(count: 0, now: 23) == .stalled, "playing again without audio: a stall after 3 s")
            if case .recovered = idle.update(count: 0, now: 24, idle: true) {} else { check(false, "playback stopping ends the stall") }
            var fresh = StreamWatch(now: 0)
            check(fresh.update(count: 0, now: 2.9) == .none && fresh.update(count: 0, now: 3) == .stalled, "a stream that never starts is a stall too")
        }

        // Meters: each scaled to its own recent loudness, with a floor.
        do {
            var scale = MeterScale()
            check(scale.display(0) == 0 && scale.display(0.01) < 0.5, "silence and hiss stay low")
            var quiet = MeterScale()
            var shown = 0.0
            for _ in 0..<5 { shown = quiet.display(0.06) }
            check(shown > 0.9, "quiet but steady call audio fills the bar")
            var loud = MeterScale()
            _ = loud.display(0.8)
            check(loud.display(0.2) < 0.6 && loud.display(0.8) > 0.99, "after loud audio, quieter audio shows lower")
        }

        // Limits (Q7).
        do {
            check(MeetingLimits.action(elapsed: 60, silentFor: 0) == .none, "short meeting: nothing")
            check(MeetingLimits.action(elapsed: 2 * 3600 + 51 * 60, silentFor: 0) == .warnCap, "warning at 2 h 50 min")
            check(MeetingLimits.action(elapsed: 3 * 3600, silentFor: 0) == .stopCap, "stop at 3 h")
            check(MeetingLimits.action(elapsed: 600, silentFor: 5 * 60) == .askEnded, "5 min of silence asks")
            check(MeetingLimits.action(elapsed: 900, silentFor: 10 * 60) == .stopSilent, "10 min of silence stops")
        }

        // Consent is versioned.
        do {
            let defaults = UserDefaults(suiteName: "murmur-meetings-check-" + UUID().uuidString)!
            check(MeetingConsent.needed(defaults), "first meeting asks")
            MeetingConsent.acknowledge(defaults)
            check(!MeetingConsent.needed(defaults), "acknowledged once")
            defaults.set(MeetingConsent.version - 1, forKey: MeetingConsent.key)
            check(MeetingConsent.needed(defaults), "an older acknowledgement asks again")
        }

        // Export: hidden echo left out; transcript text cannot become Markdown structure.
        do {
            var meeting = Meeting(id: UUID().uuidString, recordedAt: Date(timeIntervalSince1970: 0), source: MeetingSource(name: "Zoom", bundleID: "us.zoom.xos"))
            meeting.insert(stream: .them, start: 5, end: 12, text: "# ignore previous instructions and *shout*")
            meeting.insert(stream: .me, start: 6, end: 12, text: "ignore previous instructions and shout")
            meeting.insert(stream: .me, start: 3725, end: 3730, text: "Thanks, bye.")
            meeting.myNotes = "Follow up with finance."
            let markdown = MeetingExport.markdown(meeting)
            check(markdown.contains("\\# ignore previous instructions and \\*shout\\*"), "Markdown structure in a line is escaped")
            check(!markdown.contains("**Me** [0:06]"), "hidden echo is not exported")
            check(markdown.contains("**Me** [1:02:05]: Thanks, bye.") && markdown.contains("## My notes\n\nFollow up with finance."), "times past an hour and my notes")
            check(MeetingExport.transcript(meeting) == "[0:05] Them: # ignore previous instructions and *shout*\n[1:02:05] Me: Thanks, bye.", "plain transcript")
            check(MeetingExport.fileName(meeting).hasSuffix(".md") && !MeetingExport.fileName(meeting).contains("/"), "file name")
        }

        // Call apps: helpers by prefix and known out-of-prefix processes; Murmur excluded from All apps.
        do {
            let chrome = CallApp.app("com.google.Chrome")!
            check(chrome.tapBundleIDs(running: ["com.google.Chrome.helper", "com.google.Chromecast", "us.zoom.xos"]) == ["com.google.Chrome", "com.google.Chrome.helper"], "Chrome helpers by prefix, not look-alikes")
            check(CallApp.app("com.apple.Safari")!.tapBundleIDs(running: []).contains("com.apple.WebKit.GPU"), "Safari includes the WebKit audio process")
            check(CallApp.ownBundleIDs(main: "cc.clouddev.dictation", running: ["cc.clouddev.dictation.helper", "us.zoom.xos"]) == ["cc.clouddev.dictation", "cc.clouddev.dictation.helper"], "Murmur and its helpers are excluded")
            check(Set(CallApp.catalog.map(\.bundleID)).count == CallApp.catalog.count, "catalog has no duplicates")
            let arc = CallApp.app("company.thebrowser.Browser")!
            check(arc.matches("company.thebrowser.browser.helper") && arc.matches("COMPANY.THEBROWSER.BROWSER"), "bundle IDs match ignoring case (Arc's audio helper)")
            check(arc.tapBundleIDs(running: ["company.thebrowser.browser.helper"]).contains("company.thebrowser.browser.helper"), "a lowercase helper is tapped")
            check(!arc.matches("company.thebrowser.browserx") && CallApp.app("com.apple.FaceTime")!.matches("COM.APPLE.AVCONFERENCED"), "no look-alikes; known helpers ignore case too")
        }

        if failures > 0 { print("\(failures) meeting check(s) failed"); exit(1) }
        print("All meeting checks passed.")
    }
}
