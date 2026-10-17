// Explicit visual fixture: temporary storage, synthetic text, no capture or insertion.
import AppKit
import SwiftUI

/// Keeps the fixture's live meeting panel alive.
@MainActor var fixtureMeetingPanel: MeetingPanelPresenter?

@MainActor final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var controller: AppController?
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !CommandLine.arguments.contains("--bubble-only") }
    func applicationWillTerminate(_ notification: Notification) { controller?.shutdown() }
}

@main struct UIFixture {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = FixtureDelegate()
        application.delegate = delegate
        let menu = NSMenu(); let item = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit UI Check", action: #selector(FixtureDelegate.quit), keyEquivalent: "q").target = delegate
        item.submenu = appMenu; menu.addItem(item); menu.addItem(standardEditMenuItem()); application.mainMenu = menu
        let light = CommandLine.arguments.contains("--light")
        let args = CommandLine.arguments
        UserDefaults.standard.set(args.contains("--sidebar-collapsed"), forKey: "sidebarCollapsed")
        // --system-appearance leaves the app's appearance alone, so the bubble shows it follows macOS
        // while the window uses the stored choice.
        if args.contains("--system-appearance") {
            // With --light or --dark the window stores that choice; the app (and so the bubble) follows macOS.
            UserDefaults.standard.set(light ? "light" : args.contains("--dark") ? "dark" : "system", forKey: "appearance")
        } else {
            UserDefaults.standard.set(light ? "light" : "dark", forKey: "appearance")
            application.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        }
        // The fixture's defaults persist between runs: set the guide and History mode every time.
        UserDefaults.standard.set(args.contains("--history-off") ? "off" : "on", forKey: "historyMode")
        if let flag = args.firstIndex(of: "--guide") {
            let step = args.indices.contains(flag + 1) ? Int(args[flag + 1]) ?? 0 : 0
            UserDefaults.standard.set(0, forKey: WelcomeGuide.completedKey); UserDefaults.standard.set(step, forKey: WelcomeGuide.stepKey)
        } else {
            WelcomeGuide.complete(.standard)
        }
        // Catch missing bundled typography instead of silently accepting a system-font fallback.
        _ = WindowType.display(64); _ = WindowType.body(14)
        precondition(NSFont(name: "InstrumentSerif-Regular", size: 64) != nil)
        precondition(NSFont(name: "DMSans-9ptRegular", size: 14) != nil)
        let controller = AppController(preview: true)
        if CommandLine.arguments.contains("--custom-transcription") {
            controller.transcriptionRoute = .cloud
            controller.cloudTranscriber = .customAPI
        }
        delegate.controller = controller
        // Exercise the style binding without capture, providers, or saved user data.
        let styleView = SettingsView(controller: controller)
        let savedChoice = controller.cleanupChoice
        controller.cleanupChoice = .localRules
        styleView.cleanupStyle.wrappedValue = -1
        precondition(styleView.cleanupStyle.wrappedValue == -1)
        precondition(!controller.cleanupFillers && !controller.cleanupCorrections && !controller.cleanupLists && !controller.cleanupPunctuation && !controller.cleanupSpoken)
        styleView.cleanupStyle.wrappedValue = 0
        precondition(styleView.cleanupStyle.wrappedValue == 0 && controller.cleanupFillers && controller.cleanupPunctuation)
        controller.cleanupChoice = .customAPI
        styleView.cleanupStyle.wrappedValue = 2
        precondition(styleView.cleanupStyle.wrappedValue == 2 && controller.cleanupPolish && controller.cleanupProfessional)
        styleView.cleanupStyle.wrappedValue = -1
        precondition(styleView.cleanupStyle.wrappedValue == -1)
        styleView.cleanupStyle.wrappedValue = 1
        precondition(styleView.cleanupStyle.wrappedValue == 1 && controller.cleanupPolish && !controller.cleanupProfessional && controller.cleanupSpoken)
        styleView.cleanupStyle.wrappedValue = 0
        controller.cleanupChoice = savedChoice
        let compact = CommandLine.arguments.contains("--compact")
        let opaque = CommandLine.arguments.contains("--opaque")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: compact ? 760 : 1000, height: compact ? 560 : args.contains("--tall") ? 1100 : 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Murmur UI Check"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.backgroundColor = Palette.paperNS
        window.contentView = NSHostingView(rootView: SettingsView(controller: controller).environment(\.utilityOpaquePreview, opaque))
        window.contentMinSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        window.center(); window.makeKeyAndOrderFront(nil)
        var entries = [
            HistoryEntry(id: UUID().uuidString, recordedAt: Date(), rawText: "Synthetic transcript pasted into an unreadable field. Long text wraps for visual inspection.\nSecond synthetic paragraph keeps this fixture free of real transcript content.", finalText: "Synthetic transcript pasted into an unreadable field. Long text wraps for visual inspection.\nSecond synthetic paragraph keeps this fixture free of real transcript content.", insertionStatus: "unverified"),
            HistoryEntry(id: UUID().uuidString, recordedAt: Date().addingTimeInterval(-3600), rawText: "Synthetic verified transcript.", finalText: "Synthetic verified transcript.", insertionStatus: "verified")
        ]
        if CommandLine.arguments.contains("--empty") { entries = [] }
        // Insights (gap #19): timed dictations into a few apps on most of the last 24 days.
        if args.contains("--insights") && !args.contains("--empty") {
            let apps = ["com.apple.TextEdit", "com.apple.mail", "com.apple.Notes", "com.apple.Safari"]
            let text = "Synthetic dictation about the quarterly plan with um enough words to measure a speaking pace."
            for day in 0..<24 where day % 7 != 5 && day != 9 {
                for n in 0..<(1 + day % 3) {
                    var entry = HistoryEntry(id: UUID().uuidString, recordedAt: Date().addingTimeInterval(-Double(day) * 86400 - Double(n) * 1800),
                                             rawText: text, finalText: text.replacingOccurrences(of: "um ", with: ""), insertionStatus: "unverified")
                    entry.seconds = 6.5 + Double(n); entry.app = apps[(day + n) % apps.count]
                    entries.append(entry)
                }
            }
        }
        if CommandLine.arguments.contains("--matrix") && !CommandLine.arguments.contains("--empty") {
            entries += [
                HistoryEntry(id: UUID().uuidString, recordedAt: Date().addingTimeInterval(-7200), rawText: "Synthetic failed paste before cleanup.", finalText: "Synthetic failed paste.", insertionStatus: "failed"),
                HistoryEntry(id: UUID().uuidString, recordedAt: Date().addingTimeInterval(-10800), rawText: "Synthetic pending delivery. Check the target before recovering this text.\nSecond line for wrapping.", finalText: "Synthetic pending delivery. Check the target before recovering this text.\nSecond line for wrapping.", insertionStatus: "insertion-pending"),
                HistoryEntry(id: UUID().uuidString, recordedAt: Date().addingTimeInterval(-14400), rawText: "Synthetic saved output.", finalText: "Synthetic saved output.", insertionStatus: "saved-not-inserted"),
                HistoryEntry(id: UUID().uuidString, recordedAt: Date().addingTimeInterval(-18000), rawText: "Synthetic cleanup hold.", finalText: "", insertionStatus: "held-cleanup"),
                HistoryEntry(id: UUID().uuidString, recordedAt: Date().addingTimeInterval(-21600), rawText: "Synthetic transcript hold.", finalText: "", insertionStatus: "held-transcript")
            ]
        }
        let sessionOnlyID = entries.first(where: { $0.insertionStatus == "saved-not-inserted" })?.id
        do {
            guard let dataDirectory = controller.dataDirectory else { fatalError("Missing isolated fixture storage.") }
            let store = try HistoryStore(directory: dataDirectory.appendingPathComponent("history"))
            for entry in entries { try store.save(entry) }
        } catch { fatalError("Could not seed isolated History fixture.") }
        DispatchQueue.main.async {
            controller.refreshHistory()
            controller.recoveryEntryID = entries.first?.id
            controller.sessionOnlyIDs = sessionOnlyID.map { Set([$0]) } ?? []
            if CommandLine.arguments.contains("--dictionary") {
                controller.addDictionaryEntry(preferred: "Kubernetes", variants: "")
                controller.addDictionaryEntry(preferred: "kubectl", variants: "cube cuddle, cube control")
                controller.addDictionaryEntry(preferred: "Siobhan", variants: "shivon")
                if let entry = controller.dictionaryEntries.last { controller.updateDictionaryEntry(entry, preferred: entry.preferred, variants: "shivon", enabled: false) }
                controller.blockedWords = [.heard("versel"), .spelling("Akme")]
            }
            if CommandLine.arguments.contains("--history") { NotificationCenter.default.post(name: Notification.Name("DictationShowHistory"), object: nil) }
            if args.contains("--insights") || args.contains("--history-off") { controller.screenRequest = "insights" }
            if args.contains("--history") { controller.screenRequest = "history" }
            if args.contains("--settings") { controller.screenRequest = "settings" }
            if args.contains("--dictionary") { controller.screenRequest = "settings-4" }
            if let flag = args.firstIndex(of: "--section"), args.indices.contains(flag + 1) {
                controller.screenRequest = "settings-" + args[flag + 1]
            }
            if args.contains("--speaker-settings") { controller.speakerSettings.showFixture(enabled: true, status: args.contains("--ready") ? .ready : .notDownloaded) }
            if args.contains("--meeting-settings") { controller.meetingTranscription = args.contains("--cloud") ? .cloud : .local; controller.screenRequest = "meeting-settings" }
            controller.voiceLevel = 0.6
            controller.phase = CommandLine.arguments.contains("--processing") ? "Processing" : CommandLine.arguments.contains("--listening") ? "Listening" : CommandLine.arguments.contains("--saved") ? "Saved" : "Error"
            controller.message = CommandLine.arguments.contains("--credential-warning")
                ? "Save the API key again for this server address."
                : "Model verification failed. Choose the pinned model folder."
            if args.contains("--quiet") { controller.dismissStatus() }
            if CommandLine.arguments.contains("--recovery") { controller.hasRecoveryAudio = true }
            if CommandLine.arguments.contains("--live-words") {
                controller.showLiveWordsFixture("Synthetic live words keep the newest tail of a long dictation on two lines, with only the last word dimm")
            }
            controller.bubble.show(phase: controller.phase, message: controller.message)
            if CommandLine.arguments.contains("--paste-failed") {
                controller.showInsertionResult(InsertionResult(status: .failed, detail: "fixture", snapshot: nil), entryID: entries.first?.id,
                                               text: "Synthetic dictation that could not be pasted because the target app closed. It wraps to show the card's three-line limit and keeps going past it.")
            }
            if CommandLine.arguments.contains("--not-pasted") {
                controller.showNotPasted(.insertionOff, saved: "Saved to History.", entryID: entries.first?.id, text: "Synthetic dictation saved with Insert at the cursor off.")
            }
            if CommandLine.arguments.contains("--undo") { controller.bubble.showUndo(screen: nil) }
            if CommandLine.arguments.contains("--learned") { controller.bubble.showLearned("Aakash", entryID: UUID(), screen: nil) }
            // Meeting detection (PRD 11.7): --call-offer shows Zoom's offer, --call-offer-browser Arc's. The fixture's
            // defaults persist, so the switch and Never list are reset every run; --never seeds the list.
            UserDefaults.standard.removeObject(forKey: CallDetectionSettings.enabledKey)
            UserDefaults.standard.set(args.contains("--never") ? ["us.zoom.xos", "company.thebrowser.Browser"] : [], forKey: CallDetectionSettings.neverKey)
            controller.callOffers.enabled = true; controller.callOffers.removeNever("")
            if let id = args.contains("--call-offer") ? "us.zoom.xos" : args.contains("--call-offer-browser") ? "company.thebrowser.Browser" : nil,
               let app = CallDetector.app(for: id) { controller.callOffers.show(CallOffer(app: app)) }
            if CommandLine.arguments.contains("--keep-notice") {
                Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                    MainActor.assumeIsolated { controller.bubble.showLearned("Aakash", entryID: UUID(), screen: nil) }
                }
            }
            // Meeting notes (PRD 11.9): --meetings shows the page, --meeting-live the live panel, --consent the sheet.
            // The fixture's defaults persist: set the panel's minimized state every time (--collapsed).
            UserDefaults.standard.set(args.contains("--collapsed"), forKey: MeetingPanelPresenter.collapsedKey)
            UserDefaults.standard.removeObject(forKey: MeetingPanelPresenter.cornerKey)
            if args.contains("--meetings") || args.contains("--meeting-live") || args.contains("--consent") {
                var call = Meeting(id: UUID().uuidString, recordedAt: Date().addingTimeInterval(-7200), source: MeetingSource(name: "Zoom", bundleID: "us.zoom.xos"))
                call.insert(stream: .them, start: 2, end: 16, text: "Thanks for joining. Let's go over the synthetic launch plan for next week.")
                call.insert(stream: .me, start: 3, end: 17, text: "Sure. let's go over the synthetic launch plan for next week")
                call.insert(stream: .me, start: 18, end: 31, text: "I can draft the checklist by Thursday if that works for everyone.")
                call.insert(stream: .them, start: 30, end: 44, text: "That works. Send it to the team channel when it's ready.")
                call.myNotes = "Synthetic note: checklist due Thursday."
                call.seconds = 1834; call.finished = true
                // Speaker separation (W7d): --speakers shows separated, renamed speakers; --separating the progress line with Skip.
                if args.contains("--speakers") || args.contains("--separating") {
                    call.speakers = SpeakerSeparation(state: .pending, threshold: MeetingSpeakers.threshold)
                    call.insert(stream: .them, start: 45, end: 58, text: "I can review it on Friday before the synthetic launch.")
                    if args.contains("--speakers") {
                        MeetingSpeakers.apply([SpeakerSegment(speaker: "a", start: 2, end: 16), SpeakerSegment(speaker: "b", start: 30, end: 44),
                                               SpeakerSegment(speaker: "c", start: 45, end: 58)], to: &call)
                    }
                }
                // --meeting-notes: synthetic notes, as the notes route would write them (W7b).
                if args.contains("--meeting-notes") {
                    let ids = call.lines.map(\.id)
                    // With --speakers the notes name the speaker ("Speaker 2"), and the rename below relabels them.
                    let them = MeetingSpeakers.label(call.lines[3], in: call)
                    var notes = MeetingNotes(title: "Synthetic launch checklist plan", summary: "The call went over the synthetic launch plan for next week. Me offered to draft the checklist by Thursday, and \(them) asked for it in the team channel.",
                                             route: "Apple Intelligence (on-device)", writtenAt: Date())
                    notes.keyPoints = [NoteItem(text: "The synthetic launch plan is for next week", lines: [ids[0]])]
                    notes.decisions = [NoteItem(text: "Share the checklist in the team channel", lines: [ids[2], ids[3]])]
                    notes.actions = [NoteItem(text: "Draft the checklist", lines: [ids[2], ids[3]], owner: "Me", due: "Thursday", done: false),
                                     NoteItem(text: "Send it to the team channel when ready", lines: [ids[3]], owner: "Me", done: true)]
                    notes.dropped = 1
                    notes.outdated = args.contains("--outdated") ? true : nil
                    call.notes = notes
                }
                if args.contains("--speakers") { call.renameSpeaker(2, to: "Priya") }
                var solo = Meeting(id: UUID().uuidString, recordedAt: Date().addingTimeInterval(-86400 * 2), source: .microphoneOnly)
                solo.insert(stream: .me, start: 0, end: 12, text: "Synthetic voice memo recorded with only the microphone.")
                solo.finished = true
                var live = Meeting(id: UUID().uuidString, recordedAt: Date(), source: MeetingSource(name: "Google Chrome", bundleID: "com.google.Chrome"))
                live.insert(stream: .them, start: 0, end: 14, text: "Synthetic participant line in a live meeting.")
                live.insert(stream: .me, start: 14, end: 28, text: "Synthetic reply that wraps onto a second line in the narrow live panel.")
                live.seconds = 754
                let recorder = controller.meetingRecorder
                let panel = MeetingPanelPresenter(recorder: recorder)
                recorder.onLiveChange = { panel.update() }
                recorder.showFixture([call, solo], live: args.contains("--meeting-live") ? live : nil, leftovers: [solo.id: 2], separating: args.contains("--separating") ? [call.id] : [])
                if args.contains("--consent") { recorder.consentPending = .everything }
                if args.contains("--notes-choice") { recorder.notesChoicePending = call.id }
                if args.contains("--transcript") { MeetingsPage.initialTab = .transcript }
                controller.screenRequest = "meetings"
                fixtureMeetingPanel = panel
            }
            if CommandLine.arguments.contains("--bubble-only") { window.orderOut(nil) }
            // --snapshot PATH renders the window offscreen to a PNG and quits; works with the screen locked.
            if let flag = args.firstIndex(of: "--snapshot"), args.indices.contains(flag + 1) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if let view = args.contains("--meeting-live") ? fixtureMeetingPanel?.view : window.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: image)
                        try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[flag + 1]))
                    }
                    application.terminate(nil)
                }
            }
            print("Fixture content: \(window.contentLayoutRect.size), full window: \(window.frame.size)"); fflush(stdout)
        }
        controller.openSettings = { application.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
        controller.updateMenu = {
            if controller.phase == "Ready" {
                precondition(controller.history.count == entries.count && controller.recoveryEntryID == entries.first?.id)
                print("UI dismissal preserved synthetic recovery history."); fflush(stdout)
            }
        }
        application.activate(ignoringOtherApps: true)
        withExtendedLifetime((controller, window, delegate)) { application.run() }
        controller.shutdown()
    }
}
