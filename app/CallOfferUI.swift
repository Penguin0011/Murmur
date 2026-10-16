import AppKit
import SwiftUI
import os

// The meeting-detection offer (PRD 11.7) in its own floating panel at the bubble's spot. It has its own
// panel because the dictation bubble hides itself on every status change. The panel never becomes key,
// so clicking it leaves the user's app (and its cursor) in front.

private let detectionLog = Logger(subsystem: "cc.clouddev.dictation", category: "meeting")

private final class OfferPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class CallOfferPresenter: ObservableObject {
    @Published var enabled = CallDetectionSettings.enabled(.standard) {
        didSet { UserDefaults.standard.set(enabled, forKey: CallDetectionSettings.enabledKey); if !enabled { hide() } }
    }
    @Published private(set) var never = CallDetectionSettings.never(.standard)
    @Published private(set) var offer: CallOffer?

    private weak var controller: AppController?
    private var detector = CallDetector()
    private var lastPoll: TimeInterval = 0
    private var shownAt: TimeInterval = 0
    private let panel = OfferPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)

    init(controller: AppController) {
        self.controller = controller
        panel.title = "Murmur meeting offer"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
    }

    /// Called from the controller's 0.15 s timer; reads Core Audio's process list about once a second.
    /// ponytail: polls at 1 Hz instead of per-process property listeners; listeners if the poll shows up in CPU.
    func tick() {
        guard let controller else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let meetingLive = controller.meetingRecorder.live != nil, dictating = controller.isBusy
        if offer != nil, meetingLive || dictating || now - shownAt >= CallDetector.offerLifetime { hide() }
        guard now - lastPoll >= 1 else { return }
        lastPoll = now
        // With the switch off nothing is read at all.
        guard enabled else { return }
        let inputs = AudioProcessList.all().filter(\.input).map(\.bundleID)
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let conditions = CallDetector.Conditions(enabled: enabled, never: never, meetingLive: meetingLive, dictating: dictating,
                                                 ownBundleID: Bundle.main.bundleIdentifier, running: running)
        if let found = detector.update(inputs: inputs, now: now, conditions) { show(found) }
    }

    func show(_ found: CallOffer) {
        offer = found; shownAt = ProcessInfo.processInfo.systemUptime
        // Content-free: which app, never what it is doing.
        detectionLog.notice("call-offer app=\(found.app.bundleID, privacy: .public)")
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(340, max(220, frame.width - 32))
        let host = NSHostingView(rootView: CallOfferCard(offer: found, presenter: self).frame(width: width))
        panel.contentView = host
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.minY + 24, width: width, height: host.fittingSize.height), display: true)
        panel.orderFrontRegardless()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "\(found.text) \(found.question)", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func hide() { offer = nil; panel.orderOut(nil) }

    /// Starts the normal meeting flow (consent sheet the first time) with this app as the source.
    func takeNotes() {
        guard let offer else { return }
        hide(); controller?.startMeeting(offer.source)
    }
    func neverFor() {
        guard let offer else { return }
        CallDetectionSettings.addNever(offer.app.bundleID, .standard); never = CallDetectionSettings.never(.standard); hide()
    }
    func removeNever(_ bundleID: String) {
        CallDetectionSettings.removeNever(bundleID, .standard); never = CallDetectionSettings.never(.standard)
    }
    /// The Never list's display name for a bundle ID.
    static func name(_ bundleID: String) -> String { CallDetector.app(for: bundleID)?.name ?? bundleID }
}

private struct CallOfferCard: View {
    let offer: CallOffer
    @ObservedObject var presenter: CallOfferPresenter
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(offer.text).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button { presenter.hide() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Not now")
            }
            Text(offer.question).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button(offer.neverLabel) { presenter.neverFor() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Not now") { presenter.hide() }.controlSize(.small)
                Button("Take Notes") { presenter.takeNotes() }.buttonStyle(.borderedProminent).controlSize(.small)
                    .accessibilityHint("Starts meeting notes with \(offer.app.name) as the call's audio.")
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .modifier(UtilityGlass(radius: 18))
    }
}
