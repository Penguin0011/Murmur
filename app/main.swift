import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    let controller: AppController
    init(options: LaunchOptions) {
        self.options = options
        controller = AppController(preview: options.preview || options.testAudio != nil, isolatedStorage: options.preview || options.testAudio != nil)
        super.init()
    }
    var window: NSWindow?
    var statusItem: NSStatusItem?
    lazy var meetingPanel = MeetingPanelPresenter(recorder: controller.meetingRecorder)
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(controller.showInDock ? .regular : .accessory)
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Welcome Guide…", action: #selector(openGuide), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Murmur", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu; mainMenu.addItem(appItem); mainMenu.addItem(standardEditMenuItem()); NSApp.mainMenu = mainMenu
        controller.openSettings = { [weak self] in self?.showWindow() }
        controller.updateMenu = { [weak self] in self?.refreshMenu() }
        // The live meeting panel shows whether or not the menu bar icon is visible (R6, PRD 11.3).
        controller.meetingPanelChanged = { [weak self] in self?.meetingPanel.update() }
        // Open at login is on by default once; after that the Settings toggle decides.
        if !options.preview && options.testAudio == nil && !UserDefaults.standard.bool(forKey: "openAtLoginDefaulted") {
            controller.setOpenAtLogin(true); UserDefaults.standard.set(true, forKey: "openAtLoginDefaulted")
        }
        // A login-item launch starts quietly; any launch the user makes opens Settings.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        controller.start(); refreshMenu()
        if let audio = options.testAudio, let expectedApp = options.expectedApp {
            controller.checkSavedAudio(URL(fileURLWithPath: audio), expectedApp: expectedApp) { NSApp.terminate(nil) }
        } else if options.preview || !launchedAtLogin { showWindow() }
        if let seconds = options.quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
    }
    func showWindow() {
        if window == nil {
            let next = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            next.title = "Murmur"; next.titleVisibility = .hidden; next.titlebarAppearsTransparent = true; next.backgroundColor = Palette.paperNS
            next.contentView = NSHostingView(rootView: SettingsView(controller: controller))
            next.contentMinSize = NSSize(width: 760, height: 560); next.center(); next.isReleasedWhenClosed = false
            window = next
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil); controller.refreshPermissions(); controller.refreshHistory()
    }
    func refreshMenu() {
        // Show in Dock (gap #20) applies at once. Leaving the Dock can drop the window behind others.
        let policy: NSApplication.ActivationPolicy = controller.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if window?.isVisible == true { NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
        }
        if !controller.showMenuBar { if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }; statusItem = nil; return }
        if statusItem == nil { statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }
        let recording = controller.meetingRecorder.live != nil
        statusItem?.button?.image = recording ? NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Murmur: recording meeting notes") : Logo.menuBarImage
        let menu = NSMenu()
        let state = NSMenuItem(title: controller.phase, action: nil, keyEquivalent: ""); state.isEnabled = false; menu.addItem(state)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings and History…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Welcome Guide…", action: #selector(openGuide), keyEquivalent: "").target = self
        menu.addItem(withTitle: recording ? "Stop Meeting Notes" : "Start Meeting Notes…", action: recording ? #selector(stopMeeting) : #selector(openMeetings), keyEquivalent: "").target = self
        menu.addItem(withTitle: UpdateText.menuTitle(controller.availableRelease), action: #selector(checkForUpdates), keyEquivalent: "").target = self
        if controller.phase == "Listening" {
            menu.addItem(withTitle: "Finish Dictation", action: #selector(finish), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Cancel Recording", action: #selector(cancel), keyEquivalent: "").target = self
        } else if controller.canCancelRequest {
            // A cloud request in flight; canceling it inserts nothing.
            menu.addItem(withTitle: "Cancel Request", action: #selector(cancel), keyEquivalent: "").target = self
        }
        menu.addItem(.separator()); menu.addItem(withTitle: "Quit Murmur", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem?.menu = menu
    }
    @objc func openSettings() { showWindow() }
    /// Replays the welcome guide from its first step (gap #21).
    @objc func openGuide() { controller.screenRequest = "guide"; showWindow() }
    /// Results appear quietly in Settings; a known release is shown there with its page link.
    @objc func checkForUpdates() { if controller.availableRelease == nil { controller.checkForUpdates() }; showWindow() }
    @objc func finish() { controller.stopRecording() }
    @objc func openMeetings() { controller.screenRequest = "meetings"; showWindow() }
    @objc func stopMeeting() { controller.meetingRecorder.stop() }
    @objc func cancel() { controller.cancelRecording() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) { controller.shutdown() }
}
MainActor.assumeIsolated {
    let options: LaunchOptions
    do { options = try LaunchOptions(arguments: Array(CommandLine.arguments.dropFirst())) }
    catch { fputs("Invalid launch options. Use --preview [--quit-after SECONDS], or --test-audio FILE --expected-app BUNDLE_ID.\n", stderr); exit(2) }
    let application = NSApplication.shared
    let delegate = AppDelegate(options: options)
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
