// Meeting notes W7a checks (PRD section 11). No audio, no taps, no network.
// swiftc app/Retention.swift app/Meetings.swift app/check_meetings.swift -o /tmp/murmur-meetings-check && /tmp/murmur-meetings-check
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
        }

        // The pump: one chunk in flight, recording order across streams, retry once, then keep the file.
        do {
            var pending: [(URL, (String?) -> Void)] = []
            var delivered: [(MeetingStream, Double, String?)] = []
            let pump = MeetingPump(transcribe: { url, done in pending.append((url, done)) }, deliver: { job, text in delivered.append((job.stream, job.start, text)) })
            func job(_ stream: MeetingStream, _ start: Double) -> MeetingPump.Job { .init(stream: stream, url: URL(fileURLWithPath: "/x/\(stream)-\(start)"), start: start, duration: 15) }
            pump.enqueue(job(.me, 0)); pump.enqueue(job(.them, 30)); pump.enqueue(job(.them, 15))
            check(pending.count == 1, "only one chunk is with the helper")
            check(pump.backlog == 45, "backlog counts queued and in-flight audio")
            pending.removeFirst().1("first")
            check(pending.count == 1 && pending[0].0.lastPathComponent == "them-15.0", "next is the earliest recorded, across streams")
            pending.removeFirst().1(nil)
            check(pending.count == 1 && pending[0].0.lastPathComponent == "them-15.0" && delivered.count == 1, "a failure is retried first")
            pending.removeFirst().1(nil)
            check(delivered.last.map { $0.2 == nil && $0.1 == 15 } == true, "a second failure is delivered as nil (file kept)")
            pending.removeFirst().1("third")
            check(delivered.map(\.1) == [0, 15, 30] && pump.isIdle, "everything delivered in order")
            pump.enqueue(job(.me, 45)); pump.stop()
            pending.removeFirst().1("late")
            check(delivered.count == 3 && pending.isEmpty, "after stop, answers are ignored and nothing new starts")
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
        }

        if failures > 0 { print("\(failures) meeting check(s) failed"); exit(1) }
        print("All meeting checks passed.")
    }
}
