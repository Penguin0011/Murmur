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
        application.appearance = NSAppearance(named: CommandLine.arguments.contains("--light") ? .aqua : .darkAqua)
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
        let entries = [
            HistoryEntry(id: UUID().uuidString, recordedAt: Date(), rawText: "Synthetic transcript pasted into an unreadable field.", finalText: "Synthetic transcript pasted into an unreadable field.", insertionStatus: "unverified"),
            HistoryEntry(id: UUID().uuidString, recordedAt: Date().addingTimeInterval(-3600), rawText: "Synthetic verified transcript.", finalText: "Synthetic verified transcript.", insertionStatus: "verified")
        ]
        DispatchQueue.main.async {
            controller.history = entries
            controller.recoveryEntryID = entries[0].id
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
            controller.bubble.show(phase: controller.phase, message: controller.message)
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
                precondition(controller.history.count == 2 && controller.recoveryEntryID == entries[0].id)
                print("UI dismissal preserved synthetic recovery history."); fflush(stdout)
            }
        }
        application.activate(ignoringOtherApps: true)
        withExtendedLifetime((controller, window, delegate)) { application.run() }
        controller.shutdown()
    }
}
