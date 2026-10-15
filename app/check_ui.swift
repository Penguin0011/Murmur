// Explicit visual fixture: temporary storage, synthetic text, no capture or insertion.
import AppKit
import SwiftUI

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
        UserDefaults.standard.set(light ? "light" : "dark", forKey: "appearance")
        application.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let controller = AppController(preview: true)
        if CommandLine.arguments.contains("--custom-transcription") {
            controller.transcriptionRoute = .cloud
            controller.cloudTranscriber = .customAPI
        }
        delegate.controller = controller
        let compact = CommandLine.arguments.contains("--compact")
        let opaque = CommandLine.arguments.contains("--opaque")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: compact ? 760 : 1000, height: compact ? 560 : 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
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
        if CommandLine.arguments.contains("--matrix") && !CommandLine.arguments.contains("--empty") {
            entries += [
                HistoryEntry(id: UUID().uuidString, recordedAt: Date().addingTimeInterval(-7200), rawText: "Synthetic failed paste.", finalText: "Synthetic failed paste.", insertionStatus: "failed"),
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
            controller.voiceLevel = 0.6
            controller.phase = CommandLine.arguments.contains("--processing") ? "Processing" : CommandLine.arguments.contains("--listening") ? "Listening" : CommandLine.arguments.contains("--saved") ? "Saved" : "Error"
            controller.message = CommandLine.arguments.contains("--credential-warning")
                ? "Save the API key again for this server address."
                : "Model verification failed. Choose the pinned model folder."
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
            if CommandLine.arguments.contains("--learned") { controller.bubble.showLearned("Aakash", screen: nil) }
            if CommandLine.arguments.contains("--keep-notice") {
                Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                    MainActor.assumeIsolated { controller.bubble.showLearned("Aakash", screen: nil) }
                }
            }
            if CommandLine.arguments.contains("--bubble-only") { window.orderOut(nil) }
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
