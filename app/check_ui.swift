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
        item.submenu = appMenu; menu.addItem(item); application.mainMenu = menu
        application.appearance = NSAppearance(named: CommandLine.arguments.contains("--light") ? .aqua : .darkAqua)
        let controller = AppController(preview: true)
        delegate.controller = controller
        let compact = CommandLine.arguments.contains("--compact")
        let opaque = CommandLine.arguments.contains("--opaque")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: compact ? 700 : 820, height: compact ? 560 : 660), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Dictation UI Check"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: SettingsView(controller: controller).environment(\.utilityOpaquePreview, opaque))
        window.contentMinSize = NSSize(width: 700, height: 560)
        window.isReleasedWhenClosed = false
        window.center(); window.makeKeyAndOrderFront(nil)
        let entries = [
            HistoryEntry(id: UUID().uuidString, recordedAt: Date(), rawText: "Synthetic transcript for an uncertain destination.", finalText: "Synthetic transcript for an uncertain destination.", insertionStatus: "unverified"),
            HistoryEntry(id: UUID().uuidString, recordedAt: Date().addingTimeInterval(-3600), rawText: "Synthetic verified transcript.", finalText: "Synthetic verified transcript.", insertionStatus: "verified")
        ]
        DispatchQueue.main.async {
            controller.history = entries
            controller.recoveryEntryID = entries[0].id
            controller.minimalTranscriptionDisplay = CommandLine.arguments.contains("--minimal")
            controller.voiceLevel = 0.6
            controller.phase = CommandLine.arguments.contains("--processing") ? "Processing" : controller.minimalTranscriptionDisplay && !CommandLine.arguments.contains("--error") ? "Listening" : "Error"
            controller.message = "Model verification failed. Choose the pinned model folder."
            controller.bubble.show(phase: controller.phase, message: controller.message)
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
