import AppKit
import SwiftUI

private extension Notification.Name {
    static let dictationShowHistory = Notification.Name("DictationShowHistory")
}

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State private var selectedTab = 0
    @State private var selectedID: String?
    @State private var searchText = ""

    var body: some View {
        TabView(selection: $selectedTab) {
            dictation.tabItem { Label("Dictation", systemImage: "mic") }.tag(0)
            history.tabItem { Label("History", systemImage: "clock") }.tag(1)
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 520)
        .onAppear { controller.refreshPermissions(); controller.refreshHistory(); selectedID = controller.history.first?.id }
        .onChange(of: controller.history.map(\.id)) { _, ids in
            if selectedID == nil || !ids.contains(selectedID!) { selectedID = controller.history.first?.id }
        }
        .onChange(of: searchText) { _, _ in
            if !filteredHistory.contains(where: { $0.id == selectedID }) { selectedID = filteredHistory.first?.id }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dictationShowHistory)) { _ in
            searchText = ""
            selectedTab = 1
            selectedID = controller.history.first(where: { $0.id == controller.recoveryEntryID })?.id
                ?? controller.history.first?.id
        }
    }

    private var dictation: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: controller.phase == "Error" ? "exclamationmark.triangle" : "waveform")
                    .font(.title2).foregroundStyle(controller.phase == "Error" ? Color.orange : Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.phase).font(.headline)
                    Text(controller.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !controller.isBusy && controller.phase != "Ready" {
                    Button("Dismiss", action: controller.dismissStatus)
                }
            }.padding(.horizontal, 8)
            Form {
                Section {
                    Picker("Dictation shortcut", selection: $controller.shortcut) {
                        Text("Right Option").tag("right-option")
                        Text("Fn / Globe").tag("fn")
                        Text("Control–Option–Space").tag("ctrl-option-space")
                    }
                    Text("Tap to start, tap again to finish. Hold to record until release. Escape cancels.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Local transcription model")
                            Label(controller.modelAvailable ? "Model files found" : "Model folder needs attention", systemImage: controller.modelAvailable ? "checkmark.circle" : "exclamationmark.circle")
                                .font(.callout).foregroundStyle(controller.modelAvailable ? Color.secondary : Color.orange)
                            Text(controller.modelDirectory.isEmpty ? "Choose a downloaded model folder" : URL(fileURLWithPath: controller.modelDirectory).lastPathComponent)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                                .help(controller.modelDirectory)
                        }
                        Spacer()
                        Button("Choose Folder…", action: controller.chooseModelDirectory)
                    }
                    Text("Uses the downloaded Parakeet model locally. Model downloads, cloud transcription, and text cleanup are not available in this build.")
                        .font(.callout).foregroundStyle(.secondary)
                } header: { Text("Recording") }

                Section {
                    Toggle("Automatically insert into the original text field", isOn: $controller.automaticInsertion)
                    Text("Text is saved before insertion. If the destination changes or insertion cannot be verified, recover it from History. Dictation never sends a message.")
                        .font(.callout).foregroundStyle(.secondary)
                    Toggle("Show menu bar icon", isOn: $controller.showMenuBar)
                    Text("When hidden, reopen Dictation from Finder or Spotlight to return to settings.")
                        .font(.callout).foregroundStyle(.secondary)
                    Picker("Keep transcripts", selection: $controller.retention) {
                        Text("30 days").tag("30-days")
                        Text("Six months").tag("six-months")
                        Text("Forever").tag("forever")
                    }
                } header: { Text("Output and history") }

                Section {
                    permissionRow("Microphone", allowed: controller.microphoneAuthorized, actionTitle: "Allow Microphone", action: controller.requestMicrophone)
                    permissionRow("Accessibility", allowed: controller.accessibilityAuthorized, actionTitle: "Open Settings…") { controller.openPermissionSettings("accessibility") }
                    permissionRow("Input Monitoring", allowed: controller.inputMonitoringAuthorized, actionTitle: "Open Settings…") { controller.openPermissionSettings("input-monitoring") }
                    Button("Refresh Permissions", action: controller.refreshPermissions)
                } header: { Text("Permissions") }
            }
            .formStyle(.grouped)
            HStack {
                Text("Changes take effect when applied.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Apply Settings", action: controller.applySettings).buttonStyle(.borderedProminent)
                    .disabled(controller.isBusy)
            }.padding(.horizontal, 8)
        }
    }

    private func permissionRow(_ title: String, allowed: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: allowed ? "checkmark.circle" : "exclamationmark.circle")
            Spacer()
            Text(allowed ? "Allowed" : "Needed").foregroundStyle(.secondary)
            if !allowed { Button(actionTitle, action: action) }
        }
    }

    private var history: some View {
        VStack(spacing: 12) {
            HStack {
                Text("History").font(.title2.weight(.semibold))
                Spacer()
                TextField("Search transcripts", text: $searchText).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            }
            if controller.history.isEmpty {
                ContentUnavailableView {
                    Label("Your dictation appears here", systemImage: "text.bubble")
                } description: {
                    Text("Choose a downloaded model in Dictation, allow the required permissions, then use your shortcut. Completed transcripts are saved here before insertion.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredHistory.isEmpty {
                ContentUnavailableView.search(text: searchText).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(filteredHistory, selection: $selectedID) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.finalText.isEmpty ? entry.rawText : entry.finalText).lineLimit(2)
                            Text(statusLabel(entry.insertionStatus)).font(.caption).foregroundStyle(.secondary)
                            Text(entry.recordedAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(entry.id)
                    }.frame(minWidth: 220, idealWidth: 260)
                    if let entry = controller.history.first(where: { $0.id == selectedID }) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                HStack {
                                    Text(entry.recordedAt, format: .dateTime.month().day().year().hour().minute())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                Text(statusLabel(entry.insertionStatus)).font(.callout).foregroundStyle(.secondary)
                                transcript("Final text", entry.finalText)
                                if entry.rawText != entry.finalText { transcript("Raw transcription", entry.rawText) }
                                HStack {
                                    Button("Copy Text") { controller.copyEntry(entry) }.buttonStyle(.borderedProminent)
                                    Button("Delete", role: .destructive) { controller.deleteEntry(entry) }
                                }
                                Text("Copying does not retry insertion or send a message.").font(.caption).foregroundStyle(.secondary)
                            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(minWidth: 320)
                    } else {
                        ContentUnavailableView("Select a transcript", systemImage: "text.alignleft", description: Text("Inspect saved text, copy it, or delete it."))
                            .frame(minWidth: 320, maxWidth: .infinity)
                    }
                }
            }
            Divider()
            HStack {
                Text("Saved locally · \(controller.history.count) transcripts").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh", action: controller.refreshHistory)
                Button("Clear History…", role: .destructive, action: controller.clearHistory).disabled(controller.history.isEmpty)
            }.padding(.top, 12)
        }

    }

    private var filteredHistory: [HistoryEntry] {
        guard !searchText.isEmpty else { return controller.history }
        return controller.history.filter { $0.finalText.localizedCaseInsensitiveContains(searchText) || $0.rawText.localizedCaseInsensitiveContains(searchText) }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "verified": return "Inserted and verified"
        case "unverified", "insertion-pending": return "Delivery uncertain · text saved"
        case "failed": return "Could not insert · text saved"
        default: return "Saved · not inserted"
        }
    }

    private func transcript(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(text.isEmpty ? "No text saved." : text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct BubbleView: View {
    @ObservedObject var controller: AppController
    let phase: String
    let message: String
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var recovery: Bool { phase == "Saved" || phase == "Error" || message.localizedCaseInsensitiveContains("unverified") }
    private var symbol: String {
        switch phase {
        case "Listening": return "mic.fill"
        case "Processing": return "waveform"
        case "Inserted": return "checkmark"
        case "Error": return "exclamationmark.triangle"
        default: return "text.bubble"
        }
    }
    var body: some View {
        let content = HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(phase).font(.headline)
                if !message.isEmpty { Text(message).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true) }
            }
            if phase == "Listening" {
                Button("Stop", action: controller.stopRecording)
                Button(action: controller.cancelRecording) { Image(systemName: "xmark") }.help("Cancel recording")
                    .accessibilityLabel("Cancel recording")
            } else if recovery {
                if let entry = controller.history.first(where: { $0.id == controller.recoveryEntryID }) {
                    Button("Copy") { controller.copyEntry(entry) }
                }
                Button("History") {
                    controller.showSettings()
                    DispatchQueue.main.async { NotificationCenter.default.post(name: .dictationShowHistory, object: nil) }
                }
                if phase == "Error" {
                    Button("Settings", action: controller.showSettings)
                    if controller.hasRecoveryAudio { Button("Audio", action: controller.revealRecoveryAudio) }
                }
            }
            if !controller.isBusy {
                Button(action: controller.dismissStatus) { Image(systemName: "xmark") }
                    .help("Dismiss status").accessibilityLabel("Dismiss status")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14).frame(maxWidth: 600)
        .accessibilityElement(children: .contain)
        if reduceTransparency || contrast == .increased {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 24))
        } else {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
        }
    }
}

private final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class BubblePresenter {
    private let controller: AppController
    private let panel = DictationPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)

    init(controller: AppController) {
        self.controller = controller
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
    }

    func show(phase: String, message: String, screen: NSScreen? = nil) {
        let host = NSHostingView(rootView: BubbleView(controller: controller, phase: phase, message: message))
        panel.contentView = host
        let size = host.fittingSize
        let frame = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(max(size.width, 280), min(640, frame.width - 32))
        let height = max(size.height, 70)
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.minY + 24, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}
