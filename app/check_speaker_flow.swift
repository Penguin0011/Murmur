// Speaker separation W7d through the real MeetingRecorder (PRD 11.8, 11.10): a stand-in helper
// script answers like `ModelBench --diarize`. No capture, no models, no network.
// swiftc -swift-version 5 spike/Shortcut.swift module-one/capture/Capture.swift module-one/session/Session.swift app/History.swift app/Retention.swift app/ModelDownload.swift app/Updates.swift app/AppServices.swift app/Cleanup.swift app/Meetings.swift app/MeetingNotes.swift app/MeetingSpeakers.swift app/MeetingCapture.swift app/MeetingRecorder.swift app/check_speaker_flow.swift -o /tmp/murmur-speaker-flow-check && /tmp/murmur-speaker-flow-check
import AppKit
import Foundation

nonisolated(unsafe) var failures = 0
func check(_ condition: @autoclosure () throws -> Bool, _ name: String) {
    if (try? condition()) == true { print("ok   \(name)") } else { failures += 1; print("FAIL \(name)") }
}

@MainActor func spin(until done: () -> Bool, seconds: Double = 10) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}

@main enum SpeakerFlowChecks {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("murmur-speaker-flow-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let models = base.appendingPathComponent("models", isDirectory: true)
        try fm.createDirectory(at: models, withIntermediateDirectories: true)
        let helper = base.appendingPathComponent("helper")
        try "#!/bin/sh\n[ \"$2\" = --diarize ] && [ -f \"$3\" ] && echo '{\"segments\":[{\"speaker\":\"x\",\"start\":0,\"end\":5},{\"speaker\":\"y\",\"start\":5,\"end\":10}]}'\n"
            .write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let store = try MeetingStore(directory: base.appendingPathComponent("history/meetings"))
        let audioRoot = base.appendingPathComponent("retry-audio/meetings", isDirectory: true)
        let speakerRoot = base.appendingPathComponent("retry-audio/speakers", isDirectory: true)

        /// A finished meeting waiting for separation, with its kept call audio.
        func pending(days: Double = 0, audio: Bool = true) throws -> Meeting {
            var meeting = Meeting(id: UUID().uuidString, recordedAt: Date().addingTimeInterval(-days * 86400), source: MeetingSource(name: "Zoom", bundleID: "us.zoom.xos"))
            meeting.speakers = SpeakerSeparation(state: .pending, threshold: MeetingSpeakers.threshold)
            meeting.insert(stream: .them, start: 0, end: 5, text: "First voice.")
            meeting.insert(stream: .them, start: 5, end: 10, text: "Second voice.")
            meeting.finished = true
            try store.save(meeting)
            if audio { try SpeakerAudio.write([Int16](repeating: 1, count: 160_000), at: 0, to: SpeakerAudio.file(speakerRoot, meeting: meeting.id)) }
            return meeting
        }
        func kept(_ m: Meeting) -> Bool { fm.fileExists(atPath: SpeakerAudio.file(speakerRoot, meeting: m.id).path) }

        let recorder = MeetingRecorder(defaults: UserDefaults(suiteName: "murmur-speaker-flow-\(UUID().uuidString)")!)
        recorder.transcribe = { _, done in done(nil) }
        recorder.verifySpeakerModel = { true }
        // Notes are written by the real writer; the stand-in model records what it was sent.
        var prompts: [String: String] = [:], states: [String: SpeakerSeparation.State?] = [:]
        recorder.notesRoute = { .customAPI }
        recorder.notesWriter = { meeting in
            states[meeting.id] = meeting.speakers?.state
            return try await MeetingNotesWriter.write(meeting, route: .customAPI, routeName: "Stand-in") { _, user in
                prompts[meeting.id] = user; return "POINT | L1 | First voice"
            }
        }
        func notes(_ m: Meeting) -> MeetingNotes? { recorder.meetings.first { $0.id == m.id }?.notes }

        // Without the model yet (still verifying at launch), a pending meeting waits with its audio.
        let waiting = try pending()
        recorder.configure(store: store, audioRoot: audioRoot, persists: true)
        check(recorder.meetings.first { $0.id == waiting.id }?.speakers?.state == .pending && kept(waiting), "without the model, separation waits and the audio stays")
        recorder.writeNotes(waiting.id)
        spin(until: { false }, seconds: 0.3)
        check(states[waiting.id] == nil && !recorder.notesWriting.contains(waiting.id) && notes(waiting) == nil, "no notes while speakers wait to be separated, even on Write Notes")

        // With the model: separation runs, labels apply and saved, the audio is deleted.
        recorder.helper = helper; recorder.speakerModel = models
        recorder.reload()
        spin { recorder.meetings.first { $0.id == waiting.id }?.speakers?.state != .pending }
        let done = recorder.meetings.first { $0.id == waiting.id }
        check(done?.speakers?.state == .done && done?.lines.map(\.speaker) == [1, 2], "the helper's segments label the lines")
        check(!kept(waiting), "the call audio is deleted once diarization finishes")
        spin { notes(done!) != nil }
        check(states[waiting.id] == .done && prompts[waiting.id]?.contains("[L1 Speaker 1 0:00] First voice.") == true && prompts[waiting.id]?.contains("[L2 Speaker 2 0:05]") == true && notes(waiting)?.keyPoints.count == 1, "notes are written after separation, with speaker labels")
        check((try store.meetings().first { $0.id == waiting.id })?.lines.map(\.speaker) == [1, 2], "the labels are saved with the meeting")
        recorder.renameSpeaker(2, to: "Priya", in: waiting.id)
        check((try store.meetings().first { $0.id == waiting.id })?.speakers?.names[2] == "Priya", "a rename is saved")

        // A missing kept file fails cleanly (Them labels kept).
        let missing = try pending(audio: false)
        recorder.reload()
        spin { recorder.meetings.first { $0.id == missing.id }?.speakers?.state != .pending }
        check(recorder.meetings.first { $0.id == missing.id }?.speakers?.state == .failed, "no kept audio: separation fails, the transcript stays")
        spin { notes(missing) != nil }
        check(states[missing.id] == .failed && prompts[missing.id]?.contains("[L1 Them 0:00]") == true, "after a failed separation, notes are written with Me and Them")

        // Skip, delete and retention each remove the audio. Without a model nothing runs, so each acts on a waiting meeting.
        recorder.speakerModel = nil
        let skipped = try pending(), deleted = try pending(), expired = try pending(days: 40)
        recorder.reload()
        recorder.skipSeparation(skipped.id)
        check(recorder.meetings.first { $0.id == skipped.id }?.speakers?.state == .skipped && !kept(skipped), "Skip marks the meeting and deletes its audio")
        spin { notes(skipped) != nil }
        check(states[skipped.id] == .skipped && prompts[skipped.id]?.contains("[L2 Them 0:05]") == true && states[deleted.id] == nil, "Skip writes the notes then, with Them; meetings still waiting have none")
        recorder.delete(deleted.id)
        check(!kept(deleted) && recorder.meetings.allSatisfy { $0.id != deleted.id }, "deleting a meeting deletes its kept audio")
        recorder.purge(cutoff: Date().addingTimeInterval(-30 * 86400))
        check(!kept(expired) && recorder.meetings.allSatisfy { $0.id != expired.id }, "retention deletes the meeting and its kept audio")

        // Turning the switch off (or removing the model) skips finished meetings still waiting.
        let abandoned = try pending()
        recorder.reload()
        check(kept(abandoned), "still waiting while separation is wanted")
        recorder.speakersWanted = false
        recorder.reload()
        check(recorder.meetings.first { $0.id == abandoned.id }?.speakers?.state == .skipped && !kept(abandoned), "switch off: waiting meetings are skipped and their audio deleted")

        // Delete All Data stops everything.
        recorder.discardAll()
        check(recorder.separating.isEmpty && recorder.meetings.isEmpty, "Delete All Data forgets separations")

        print(failures == 0 ? "All speaker flow checks passed." : "\(failures) speaker flow check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
