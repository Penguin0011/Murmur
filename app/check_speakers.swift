// Speaker separation W7d checks (PRD 11.8). No audio models, no network; the helper is a stand-in script.
// swiftc app/Retention.swift app/Meetings.swift app/MeetingSpeakers.swift app/check_speakers.swift -o /tmp/murmur-speakers-check && /tmp/murmur-speakers-check
import Foundation

nonisolated(unsafe) var failures = 0
func check(_ condition: @autoclosure () throws -> Bool, _ name: String) {
    if (try? condition()) == true { print("ok   \(name)") } else { failures += 1; print("FAIL \(name)") }
}

func segment(_ speaker: String, _ start: Double, _ end: Double) -> SpeakerSegment { SpeakerSegment(speaker: speaker, start: start, end: end) }

@main enum SpeakerChecks {
    static func main() throws {
        let call = MeetingSource(name: "Zoom", bundleID: "us.zoom.xos")

        // Line-to-speaker assignment: most overlap wins, numbering follows first speech, Me stays Me.
        do {
            var meeting = Meeting(id: UUID().uuidString, recordedAt: Date(), source: call)
            meeting.speakers = SpeakerSeparation(state: .pending, threshold: 0.6)
            meeting.insert(stream: .them, start: 0, end: 15, text: "Welcome to the synthetic review.")
            meeting.insert(stream: .me, start: 15, end: 20, text: "Thanks for having me.")
            meeting.insert(stream: .them, start: 20, end: 35, text: "Let me share the numbers.")
            meeting.insert(stream: .them, start: 40, end: 50, text: "Nothing overlaps this line.")
            // Raw ids are arbitrary; numbers follow the transcript: "k" owns the first line, so it is Speaker 1.
            MeetingSpeakers.apply([segment("z", 0, 4), segment("k", 4, 15), segment("z", 20, 33), segment("k", 33, 35), segment("k", 52, 60)], to: &meeting)
            let them = meeting.lines.filter { $0.stream == .them }
            check(them.map(\.speaker) == [1, 2, 1], "each Them line goes to the speaker with the most overlap; no overlap takes the nearest")
            check(meeting.lines.first { $0.stream == .me }?.speaker == nil, "Me lines are never assigned a speaker")
            check(MeetingSpeakers.label(them[1], in: meeting) == "Speaker 2" && MeetingSpeakers.label(meeting.lines[1], in: meeting) == "Me", "labels: Speaker N for Them, Me for the microphone")
            check(meeting.speakers?.state == .done && meeting.speakers?.threshold == 0.6, "separation done, threshold recorded")
            check(MeetingSpeakers.speaker(0, 1, [], nearest: true) == nil, "no segments: no speaker")
        }

        // Numbering is by first assigned line, so a speaker with no text leaves no gap.
        do {
            var meeting = Meeting(id: UUID().uuidString, recordedAt: Date(), source: call)
            meeting.speakers = SpeakerSeparation(state: .pending)
            meeting.insert(stream: .them, start: 10, end: 20, text: "Second voice speaks here.")
            MeetingSpeakers.apply([segment("a", 0, 5), segment("b", 10, 20)], to: &meeting)
            check(meeting.lines[0].speaker == 1, "a speaker with no line takes no number")
        }

        // Splitting at a voice change with word times; the first piece keeps the line id.
        do {
            var meeting = Meeting(id: UUID().uuidString, recordedAt: Date(), source: call)
            meeting.speakers = SpeakerSeparation(state: .pending)
            meeting.insert(stream: .them, start: 100, end: 115, text: "Can you send it? Yes I will.",
                           words: [[0, 0.4], [0.4, 0.7], [0.7, 1.0], [1.0, 1.5], [6.0, 6.3], [6.3, 6.5], [6.5, 7.0]])
            check(meeting.lines[0].words?.count == 7, "word times are kept while separation is pending")
            let id = meeting.lines[0].id
            MeetingSpeakers.apply([segment("a", 100, 102), segment("b", 105.5, 108)], to: &meeting)
            check(meeting.lines.map(\.text) == ["Can you send it?", "Yes I will."], "a line is split where the voice changes")
            check(meeting.lines.map(\.speaker) == [1, 2], "each piece goes to its own speaker")
            check(meeting.lines[0].id == id && meeting.lines[1].id != id, "the first piece keeps the cited line id")
            check(meeting.lines[0].start == 100 && meeting.lines[1].start == 106 && meeting.lines[1].end == 115, "piece times come from the word times")
            check(meeting.lines.allSatisfy { $0.words == nil }, "word times are dropped once used")

            var mixed = Meeting(id: UUID().uuidString, recordedAt: Date(), source: call)
            mixed.speakers = SpeakerSeparation(state: .pending)
            mixed.insert(stream: .them, start: 100, end: 115, text: "First voice talks. Second voice answers.",
                         words: [[0, 1], [1, 2], [2, 3], [6, 7], [7, 8], [8, 9]])
            mixed.insert(stream: .me, start: 103, end: 105, text: "Right.")
            MeetingSpeakers.apply([segment("b", 100, 103.5), segment("a", 105.5, 110)], to: &mixed)
            check(mixed.lines.map(\.start) == [100, 103, 106], "a split piece after a Me interjection stays in capture-time order")
            check(mixed.lines.map(\.speaker) == [1, nil, 2], "numbering follows that order")

            var cloud = Meeting(id: UUID().uuidString, recordedAt: Date(), source: call)
            cloud.speakers = SpeakerSeparation(state: .pending)
            cloud.insert(stream: .them, start: 0, end: 15, text: "Cloud lines have no word times at all.")
            MeetingSpeakers.apply([segment("a", 0, 6), segment("b", 6, 15)], to: &cloud)
            check(cloud.lines.count == 1 && cloud.lines[0].speaker == 1, "without word times a line goes whole to the speaker with most overlap")

            var changed = Meeting(id: UUID().uuidString, recordedAt: Date(), source: call)
            changed.insert(stream: .them, start: 0, end: 5, text: "three words here", words: [[0, 1], [1, 2]])
            check(changed.lines[0].words == nil, "word times that no longer match the text (dictionary) are not kept")
            check(MeetingSpeakers.split(changed.lines[0], words: [[0, 1]], segments: [segment("a", 0, 5)]).count == 1, "mismatched times never split")
        }

        // Renaming, merging and reassigning: per meeting, persisted, dated for notes (PRD 11.6).
        do {
            var meeting = Meeting(id: UUID().uuidString, recordedAt: Date(), source: call)
            meeting.speakers = SpeakerSeparation(state: .pending)
            meeting.insert(stream: .them, start: 0, end: 5, text: "First speaker.")
            meeting.insert(stream: .them, start: 5, end: 10, text: "Second speaker.")
            meeting.insert(stream: .them, start: 10, end: 15, text: "Third speaker.")
            MeetingSpeakers.apply([segment("a", 0, 5), segment("b", 5, 10), segment("c", 10, 15)], to: &meeting)
            check(meeting.speakers?.editedAt == nil, "no edit yet")
            meeting.renameSpeaker(2, to: "  Priya  ")
            check(MeetingSpeakers.label(meeting.lines[1], in: meeting) == "Priya" && meeting.speakers?.editedAt != nil, "rename trims, labels and marks the edit")
            meeting.renameSpeaker(2, to: "")
            check(MeetingSpeakers.label(meeting.lines[1], in: meeting) == "Speaker 2", "an empty name goes back to Speaker N")
            meeting.renameSpeaker(3, to: "Sam")
            meeting.mergeSpeaker(3, into: 1)
            check(meeting.lines.map(\.speaker) == [1, 2, 1] && meeting.speakers?.names[3] == nil, "merge moves every line and drops the merged name")
            check(MeetingSpeakers.numbers(meeting) == [1, 2], "numbers stay stable after a merge")
            meeting.reassignLine(meeting.lines[1].id, to: 1)
            check(meeting.lines[1].speaker == 1, "one line is reassigned")
            meeting.reassignLine(meeting.lines[1].id, to: 7)
            check(meeting.lines[1].speaker == 7, "a line can move to a new speaker")
            meeting.renameSpeaker(7, to: "Alex")
            let decoded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
            check(decoded == meeting && decoded.speakers?.names[7] == "Alex", "speaker names and assignments round-trip in the record")
            check(MeetingExport.transcript(meeting).contains("] Alex: Second speaker."), "the transcript export uses speaker names")
            check(MeetingExport.markdown(meeting).contains("- Speakers: Me, Speaker 1, Alex"), "Markdown lists the speakers")

            var off = Meeting(id: UUID().uuidString, recordedAt: Date(), source: call)
            off.insert(stream: .them, start: 0, end: 5, text: "No separation.")
            off.renameSpeaker(1, to: "X"); off.reassignLine(off.lines[0].id, to: 2)
            check(off.speakers == nil && off.lines[0].speaker == nil, "edits need a separated meeting")

            // Names expire with their meeting: they live only in its record.
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-speakers-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try MeetingStore(directory: root)
            var old = meeting
            old = Meeting(id: old.id, recordedAt: Date().addingTimeInterval(-40 * 86400), seconds: old.seconds, source: old.source, lines: old.lines, speakers: old.speakers)
            try store.save(old)
            try store.purge(cutoff: Date().addingTimeInterval(-30 * 86400))
            check(try store.meetings().isEmpty, "retention removes the meeting and its speaker names together")
        }

        // Older records (W7a) decode without the new fields.
        do {
            let w7a = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","recordedAt":0,"seconds":30,"source":{"name":"Zoom","bundleID":"us.zoom.xos","allApps":false,"micOnly":false},"lines":[{"id":1,"stream":"them","start":0,"end":5,"text":"Hello."}],"myNotes":"","gaps":[],"finished":true}"#
            let meeting = try JSONDecoder().decode(Meeting.self, from: Data(w7a.utf8))
            check(meeting.speakers == nil && meeting.lines[0].speaker == nil && MeetingSpeakers.label(meeting.lines[0], in: meeting) == "Them", "a W7a record still decodes and reads Them")
        }

        // Voice embeddings are never persisted: the reply parser keeps only ids and times.
        do {
            let reply = #"{"segments":[{"speaker":"S1","start":0.5,"end":3.0,"embedding":[0.1,0.2,0.3]},{"speaker":"S2","start":4,"end":3}],"speakerDatabase":{"S1":[0.4]}}"#
            let parsed = MeetingSpeakers.segments(Data(reply.utf8))
            check(parsed == [segment("S1", 0.5, 3.0)], "segments keep speaker and times; invalid ones are dropped")
            check(String(decoding: try JSONEncoder().encode(parsed), as: UTF8.self).contains("embedding") == false, "a parsed segment has nowhere to hold an embedding")
            var meeting = Meeting(id: UUID().uuidString, recordedAt: Date(), source: call)
            meeting.speakers = SpeakerSeparation(state: .pending)
            meeting.insert(stream: .them, start: 0, end: 4, text: "Hello there.", words: [[0, 1], [1, 2]])
            MeetingSpeakers.apply(parsed ?? [], to: &meeting)
            let saved = String(decoding: try JSONEncoder().encode(meeting), as: UTF8.self)
            check(!saved.contains("embedding") && !saved.contains("speakerDatabase") && !saved.contains("S1"), "the saved meeting holds no embedding, database or raw speaker id")
            check(MeetingSpeakers.segments(Data("not json".utf8)) == nil, "a broken reply is a failure, not an empty result")
        }

        // Kept Them audio: one 16 kHz mono 16-bit WAV, written at chunk times, gone after 24 h or when not pending.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-kept-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID().uuidString
            let file = SpeakerAudio.file(root, meeting: id)
            try SpeakerAudio.write([Int16](repeating: 1000, count: 16_000), at: 2, to: file)
            try SpeakerAudio.write([Int16](repeating: -5, count: 8_000), at: 0, to: file)
            try SpeakerAudio.finish(file)
            let data = try Data(contentsOf: file)
            check(data.count == 44 + 3 * 16_000 * 2, "chunks land at their own time; the gap reads as silence")
            func u32(_ at: Int) -> UInt32 { data.subdata(in: at..<(at + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
            check(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF" && u32(24) == 16_000 && u32(40) == UInt32(3 * 16_000 * 2), "the header says 16 kHz with the right data size")
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let folder = try FileManager.default.attributesOfItem(atPath: root.path)
            check((attributes[.posixPermissions] as? Int) == 0o600 && (folder[.posixPermissions] as? Int) == 0o700, "kept audio is owner-only")

            SpeakerAudio.purge(root, keep: [id])
            check(FileManager.default.fileExists(atPath: file.path), "audio waiting for separation is kept under 24 hours")
            SpeakerAudio.purge(root, keep: [id], now: Date().addingTimeInterval(RetryWindow.lifetime))
            check(!FileManager.default.fileExists(atPath: file.path), "and deleted at 24 hours")

            try SpeakerAudio.write([1], at: 0, to: file)
            SpeakerAudio.purge(root, keep: [], active: [id])
            check(FileManager.default.fileExists(atPath: file.path), "the live meeting's or a running separation's audio is never purged")
            SpeakerAudio.purge(root, keep: [])
            check(!FileManager.default.fileExists(atPath: file.path), "audio of a meeting no longer waiting (done, skipped, deleted) is removed")
            try Data("x".utf8).write(to: root.appendingPathComponent("stray.txt"))
            SpeakerAudio.purge(root, keep: ["stray"])
            check(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? ["?"]).isEmpty, "anything that is not kept audio is removed")
        }

        // Status text for the Meetings page.
        do {
            check(SpeakerFacts.status(SpeakerSeparation(state: .pending), running: true) == "Separating speakers…", "progress line while running")
            check(SpeakerFacts.status(SpeakerSeparation(state: .pending), running: false)?.contains("24 hours") == true, "waiting line names the 24-hour limit")
            check(SpeakerFacts.status(SpeakerSeparation(state: .done), running: false) == nil && SpeakerFacts.status(nil, running: false) == nil, "nothing to say once done or off")
            check(SpeakerFacts.credits.contains("pyannote") && SpeakerFacts.credits.contains("WeSpeaker") && SpeakerFacts.credits.contains("BUT Speech@FIT")
                  && SpeakerFacts.credits.contains("Fluid Inference") && SpeakerFacts.credits.contains("creativecommons.org/licenses/by/4.0") && SpeakerFacts.credits.contains("modified Core ML conversions"),
                  "attribution names every source, the license link and the modification")
        }

        // The helper runner: a stand-in script answers like ModelBench --diarize; cancel answers nothing.
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-runner-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let quick = dir.appendingPathComponent("quick"), slow = dir.appendingPathComponent("slow")
            try "#!/bin/sh\n[ \"$2\" = --diarize ] && echo '{\"segments\":[{\"speaker\":\"0\",\"start\":0,\"end\":1}]}'\n".write(to: quick, atomically: true, encoding: .utf8)
            try "#!/bin/sh\nsleep 20\n".write(to: slow, atomically: true, encoding: .utf8)
            for url in [quick, slow] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
            let runner = SpeakerRunner()
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var answer: [SpeakerSegment]?
            runner.run("a", helper: quick, models: dir, audio: dir, threshold: 0.6) { answer = $0; done.signal() }
            check(done.wait(timeout: .now() + 10) == .success && answer == [segment("0", 0, 1)], "the helper's segments come back")
            nonisolated(unsafe) var called = false
            runner.run("b", helper: slow, models: dir, audio: dir, threshold: 0.6) { _ in called = true }
            Thread.sleep(forTimeInterval: 0.3)
            check(runner.active == ["b"], "a running separation is active")
            runner.cancel("b")
            Thread.sleep(forTimeInterval: 0.5)
            check(runner.active.isEmpty && !called, "Skip terminates the helper and answers nothing")
            runner.run("c", helper: quick, models: dir, audio: dir, check: { false }, threshold: 0.6) { answer = $0; done.signal() }
            check(done.wait(timeout: .now() + 10) == .success && answer == nil, "a model that fails verification never runs")
        }

        print(failures == 0 ? "All speaker checks passed." : "\(failures) speaker check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
