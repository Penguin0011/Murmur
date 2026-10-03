// Explicit visual fixture: temporary storage, synthetic text, no capture or insertion.
import AppKit
import SwiftUI

@main struct UIFixture {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let controller = AppController(preview: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 610), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Dictation UI Check"
        window.contentView = NSHostingView(rootView: SettingsView(controller: controller))
        window.isReleasedWhenClosed = false
        window.center(); window.makeKeyAndOrderFront(nil)
        let entries = [
            HistoryEntry(id: UUID().uuidString, recordedAt: Date(), rawText: "Synthetic transcript for an uncertain destination.", finalText: "Synthetic transcript for an uncertain destination.", insertionStatus: "unverified"),
            HistoryEntry(id: UUID().uuidString, recordedAt: Date().addingTimeInterval(-3600), rawText: "Synthetic verified transcript.", finalText: "Synthetic verified transcript.", insertionStatus: "verified")
        ]
        DispatchQueue.main.async {
            controller.history = entries
            controller.recoveryEntryID = entries[0].id
            controller.phase = "Error"
            controller.message = "Model verification failed. Choose the pinned model folder."
            controller.bubble.show(phase: controller.phase, message: controller.message)
        }
        controller.openSettings = { application.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
        controller.updateMenu = {
            if controller.phase == "Ready" {
                precondition(controller.history.count == 2 && controller.recoveryEntryID == entries[0].id)
                print("UI dismissal preserved synthetic recovery history."); fflush(stdout)
            }
        }
        application.activate(ignoringOtherApps: true)
        withExtendedLifetime((controller, window)) { application.run() }
        controller.shutdown()
    }
}
