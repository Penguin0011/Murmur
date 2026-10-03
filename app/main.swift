import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController(preview: CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--test-audio"))
    var window: NSWindow?
    var statusItem: NSStatusItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Murmur", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu; mainMenu.addItem(appItem); NSApp.mainMenu = mainMenu
        controller.openSettings = { [weak self] in self?.showWindow() }
        controller.updateMenu = { [weak self] in self?.refreshMenu() }
        controller.start(); refreshMenu()
        if let audioIndex = CommandLine.arguments.firstIndex(of: "--test-audio"), audioIndex + 1 < CommandLine.arguments.count,
           let expectedIndex = CommandLine.arguments.firstIndex(of: "--expected-app"), expectedIndex + 1 < CommandLine.arguments.count {
            controller.checkSavedAudio(URL(fileURLWithPath: CommandLine.arguments[audioIndex + 1]), expectedApp: CommandLine.arguments[expectedIndex + 1]) { NSApp.terminate(nil) }
        } else { showWindow() }
        if let i = CommandLine.arguments.firstIndex(of: "--quit-after"), i + 1 < CommandLine.arguments.count,
           let seconds = Double(CommandLine.arguments[i + 1]), seconds.isFinite, (0.1...60).contains(seconds) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
    }
    func showWindow() {
        if window == nil {
            let next = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 610), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            next.title = "Murmur"; next.contentView = NSHostingView(rootView: SettingsView(controller: controller))
            next.minSize = NSSize(width: 650, height: 500); next.center(); next.isReleasedWhenClosed = false
            window = next
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil); controller.refreshPermissions(); controller.refreshHistory()
    }
    func refreshMenu() {
        if !controller.showMenuBar { if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }; statusItem = nil; return }
        if statusItem == nil { statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength); statusItem?.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Murmur") }
        let menu = NSMenu()
        let state = NSMenuItem(title: controller.phase, action: nil, keyEquivalent: ""); state.isEnabled = false; menu.addItem(state)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings and History…", action: #selector(openSettings), keyEquivalent: "").target = self
        if controller.phase == "Listening" {
            menu.addItem(withTitle: "Finish Dictation", action: #selector(finish), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Cancel Recording", action: #selector(cancel), keyEquivalent: "").target = self
        }
        menu.addItem(.separator()); menu.addItem(withTitle: "Quit Murmur", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem?.menu = menu
    }
    @objc func openSettings() { showWindow() }
    @objc func finish() { controller.stopRecording() }
    @objc func cancel() { controller.cancelRecording() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) { controller.shutdown() }
}
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
