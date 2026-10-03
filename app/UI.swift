import AppKit
import SwiftUI

private extension Notification.Name {
    static let dictationShowHistory = Notification.Name("DictationShowHistory")
    static let dictationShowError = Notification.Name("DictationShowError")
}

// Only the isolated visual fixture supplies this override; production uses system preferences.
private struct UtilityOpaquePreviewKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var utilityOpaquePreview: Bool {
        get { self[UtilityOpaquePreviewKey.self] }
        set { self[UtilityOpaquePreviewKey.self] = newValue }
    }
}

// Glass belongs to the floating status and action layers; reading surfaces stay opaque.
private struct UtilityGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.utilityOpaquePreview) private var opaquePreview
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        if opaquePreview || reduceTransparency || contrast == .increased {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

private struct UtilityButton: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.utilityOpaquePreview) private var opaquePreview
    var prominent = false

    @ViewBuilder func body(content: Content) -> some View {
        if opaquePreview || reduceTransparency || contrast == .increased {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered) }
        } else {
            if prominent { content.buttonStyle(.glassProminent).tint(Color(nsColor: .controlAccentColor)).foregroundStyle(.white).font(.system(size: 14, weight: .bold)) }
            else { content.buttonStyle(.glass) }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State private var selectedTab = 0
    @State private var selectedID: String?
    @State private var searchText = ""
    @State private var newPreferred = ""
    @State private var newVariants = ""
    @State private var geminiKey = ""
    @State private var openrouterKey = ""
    @State private var serverKey = ""

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Murmur").font(.largeTitle.weight(.semibold))
                    Text("Your voice, on your Mac.").font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                }
                Spacer()
                Label(controller.appliedTranscriptionIsLocal ? "Local transcription" : "Cloud transcription", systemImage: controller.appliedTranscriptionIsLocal ? "desktopcomputer" : "cloud")
                    .font(.callout).padding(.horizontal, 14).padding(.vertical, 9)
                    .modifier(UtilityGlass())
            }
            TabView(selection: $selectedTab) {
                dictation.tabItem { Label("Dictation", systemImage: "mic") }.tag(0)
                history.tabItem { Label("History", systemImage: "clock") }.tag(1)
            }
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 680, minHeight: 520)
        .onAppear { controller.refreshPermissions(); controller.refreshHistory(); selectedID = controller.history.first?.id }
        .onChange(of: controller.history.map(\.id)) { _, _ in
            if !filteredHistory.contains(where: { $0.id == selectedID }) { selectedID = filteredHistory.first?.id }
        }
        .onChange(of: searchText) { _, _ in
            if !filteredHistory.contains(where: { $0.id == selectedID }) { selectedID = filteredHistory.first?.id }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dictationShowError)) { _ in selectedTab = 0 }
        .onReceive(NotificationCenter.default.publisher(for: .dictationShowHistory)) { _ in
            searchText = ""
            selectedTab = 1
            selectedID = controller.history.first(where: { $0.id == controller.recoveryEntryID })?.id
                ?? controller.history.first?.id
        }
    }

    private var dictation: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: controller.phase == "Error" ? "exclamationmark.triangle" : "waveform")
                    .font(.title2).foregroundStyle(controller.phase == "Error" ? Color.orange : Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.phase).font(.headline)
                    Text(controller.message).font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !controller.isBusy && controller.phase != "Ready" {
                    Button(action: controller.dismissStatus) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Dismiss status").accessibilityLabel("Dismiss status")
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(UtilityGlass())

            Form {
                Section {
                    Picker("Dictation shortcut", selection: $controller.shortcut) {
                        Text("Right Option").tag("right-option")
                        Text("Fn / Globe").tag("fn")
                        Text("Control–Option–Space").tag("ctrl-option-space")
                    }
                    Text("Hold to record until you release. Double-press to keep recording until you press again. Escape cancels.")
                        .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ModelFacts.displayName)
                                if !controller.modelSummary.isEmpty {
                                    Text(controller.modelSummary).font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                                }
                                Label(controller.modelRow.statusText, systemImage: controller.modelRow.isReady ? "checkmark.circle" : controller.modelRow.isWorking ? "arrow.down.circle" : "exclamationmark.circle")
                                    .font(.callout).foregroundStyle(controller.modelRow.isReady ? Color.primary.opacity(0.72) : Color.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if controller.modelRow.actions.contains(.download) { Button("Download…", action: controller.downloadModel) }
                            if controller.modelRow.actions.contains(.retry) { Button("Retry…", action: controller.downloadModel) }
                            if controller.modelRow.actions.contains(.cancel) { Button("Cancel", action: controller.cancelModelDownload) }
                            if controller.modelRow.actions.contains(.remove) { Button("Remove…", role: .destructive, action: controller.removeModel) }
                        }
                        if let progress = controller.modelRow.progress { ProgressView(value: progress) }
                        if !controller.modelMessage.isEmpty {
                            Text(controller.modelMessage).font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let license = controller.modelLicense {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("License").font(.callout.weight(.medium))
                            ForEach(license.declarations) { declaration in
                                Button { controller.openLink(declaration.url) } label: { Text(declaration.name + " · " + declaration.source) }
                                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).help(declaration.url.absoluteString)
                            }
                            Text(license.note).font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Advanced: model folder")
                            Label(controller.modelAvailable ? "Model files found" : "No model files in this folder", systemImage: controller.modelAvailable ? "checkmark.circle" : "exclamationmark.circle")
                                .font(.callout).foregroundStyle(controller.modelAvailable ? Color.primary.opacity(0.72) : Color.primary)
                            if !controller.modelDirectory.isEmpty {
                                Text(URL(fileURLWithPath: controller.modelDirectory).lastPathComponent)
                                    .font(.caption).foregroundStyle(Color.primary.opacity(0.72)).lineLimit(1).textSelection(.enabled)
                                    .help(controller.modelDirectory)
                            }
                        }
                        Spacer()
                        if controller.usesCustomModelFolder { Button("Use Default", action: controller.useDefaultModelDirectory) }
                        Button("Choose Folder…", action: controller.chooseModelDirectory)
                    }
                    Text("Local transcription runs on this Mac. Downloading the model uses the network once; dictation does not. A folder you choose takes effect on Apply Settings. Cloud transcription is chosen under Processing routes.")
                        .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                } header: { Text("Recording") }

                Section {
                    Picker("Transcription", selection: $controller.transcriptionRoute) {
                        Text("On this Mac (Parakeet)").tag(TranscriptionRoute.local)
                        Text("Cloud").tag(TranscriptionRoute.cloud)
                    }
                    if controller.transcriptionRoute == .cloud {
                        Picker("Cloud provider", selection: $controller.cloudTranscriber) {
                            ForEach(CloudTranscriber.allCases) { choice in Text(choice.displayName).tag(choice) }
                        }
                        if let disclosure = controller.routeDisclosure(.transcription) {
                            Text(disclosure).font(.callout).foregroundStyle(Color.primary.opacity(0.72)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Picker("Cleanup", selection: $controller.cleanupChoice) {
                        ForEach(CleanupChoice.allCases) { choice in Text(choice.displayName).tag(choice) }
                    }
                    if controller.cleanupChoice == .localServer {
                        placeholderField("Server address, e.g. \(RouteSettings.defaultServerURL)", text: $controller.localServerURL)
                        HStack(spacing: 8) {
                            placeholderField("Model name", text: $controller.localServerModel)
                            Button("Find Models", action: controller.findLocalModels).disabled(controller.findingModels)
                        }
                        if !controller.localServerModels.isEmpty {
                            Picker("Found models", selection: $controller.localServerModel) {
                                ForEach(controller.localServerModels, id: \.self) { model in Text(model).tag(model) }
                            }
                        }
                        if !controller.localServerMessage.isEmpty {
                            Text(controller.localServerMessage).font(.callout).foregroundStyle(Color.primary.opacity(0.72)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if controller.cleanupChoice != .localRules, let disclosure = controller.routeDisclosure(.cleanup) {
                        Text(disclosure).font(.callout).foregroundStyle(Color.primary.opacity(0.72)).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Routes take effect on Apply Settings, which first shows what leaves this Mac. Murmur never falls back to another route: if a provider fails, your audio or raw transcript stays here.")
                        .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                } header: { Text("Processing routes") }

                Section {
                    keyRow(.gemini, text: $geminiKey)
                    keyRow(.openrouter, text: $openrouterKey)
                    keyRow(.localServer, text: $serverKey)
                    Text("Keys are stored in your Keychain and shown only as saved. The local model server key is optional.")
                        .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                } header: { Text("API keys") }

                Section {
                    Toggle("Remove filler words", isOn: $controller.cleanupFillers)
                    Toggle("Apply spoken corrections", isOn: $controller.cleanupCorrections)
                    Toggle("Format spoken lists", isOn: $controller.cleanupLists)
                    HStack(spacing: 16) {
                        Text("Each option works on its own. Faithful transcription turns all three off; dictionary spellings still apply.")
                            .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                        Spacer()
                        Button("Faithful Transcription", action: controller.useFaithfulTranscription)
                            .disabled(!controller.cleanupFillers && !controller.cleanupCorrections && !controller.cleanupLists)
                    }
                    Text((controller.appliedCleanupIsLocal ? "Cleanup runs on this Mac." : "Cleanup uses the provider chosen under Processing routes.") + " If it fails or changes too much, Murmur keeps the raw transcript in History and does not insert it.")
                        .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                } header: { Text("Cleanup") }

                Section {
                    Toggle("Learn from my corrections", isOn: $controller.learningEnabled)
                    Text("Automatic learning from edits is not available in this build yet. Learned entries keep applying until you delete or reset them.")
                        .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                    ForEach(controller.dictionaryEntries) { entry in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.preferred)
                                if !entry.variants.isEmpty {
                                    Text(entry.variants.joined(separator: ", ")).font(.caption).foregroundStyle(Color.primary.opacity(0.72)).lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(entry.source == .learned ? "Learned" : "Manual")
                                .font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            Button { controller.deleteDictionaryEntry(entry) } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).help("Delete \(entry.preferred)").accessibilityLabel("Delete \(entry.preferred)")
                        }
                    }
                    HStack(spacing: 8) {
                        placeholderField("Preferred spelling", text: $newPreferred)
                        placeholderField("Heard as, comma-separated", text: $newVariants)
                        Button("Add") {
                            if controller.addDictionaryEntry(preferred: newPreferred, variants: newVariants) { newPreferred = ""; newVariants = "" }
                        }
                        .disabled(newPreferred.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !controller.dictionaryMessage.isEmpty {
                        Text(controller.dictionaryMessage).font(.callout).foregroundStyle(Color.orange)
                    }
                    HStack {
                        Text("Dictionary spellings apply in every mode. Edits save immediately.")
                            .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                        Spacer()
                        Button("Reset Learned…", role: .destructive, action: controller.resetLearnedEntries)
                            .disabled(!controller.dictionaryEntries.contains { $0.source == .learned })
                    }
                } header: { Text("Dictionary and learning") }

                Section {
                    Toggle("Insert into the original text field", isOn: $controller.automaticInsertion)
                    Text("Saved before insertion. If the destination changes or delivery is uncertain, copy the text from History. Murmur never sends a message.")
                        .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                    Toggle("Intelligently add a leading space", isOn: $controller.intelligentLeadingSpace)
                    Text("Separate dictation from existing text at the cursor. Existing whitespace, punctuation, and selected text are left alone.")
                        .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                    Picker("Keep transcripts", selection: $controller.retention) {
                        Text("30 days").tag("30-days")
                        Text("Six months").tag("six-months")
                        Text("Forever").tag("forever")
                    }
                    if let warning = controller.historyCapWarning {
                        Text(warning).font(.callout).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    Picker("Transcript history", selection: $controller.historyMode) {
                        Text("Save on this Mac").tag(HistoryMode.on)
                        Text("Off").tag(HistoryMode.off)
                    }
                    if controller.historyMode == .off {
                        Text(HistoryMode.offDisclosure).font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 16) {
                        Text(DeleteAllDataText.explanation).font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                        Spacer()
                        Button("Delete All Data…", role: .destructive, action: controller.deleteAllData)
                    }
                    Toggle("Show menu bar icon", isOn: $controller.showMenuBar)
                    Text("When hidden, reopen Murmur from Finder or Spotlight.")
                        .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                } header: { Text("Output and history") }

                Section {
                    Toggle("Check for updates automatically", isOn: $controller.updateChecksEnabled)
                    Text(UpdateText.explanation).font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                    HStack(spacing: 16) {
                        Text(controller.updateStatus.isEmpty ? "Murmur " + controller.currentVersion : controller.updateStatus)
                            .font(.callout).foregroundStyle(Color.primary.opacity(0.72)).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Check for Updates", action: controller.checkForUpdates).disabled(controller.checkingForUpdates)
                    }
                    if let release = controller.availableRelease {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(UpdateText.headline(release)).font(.headline)
                            if !release.notes.isEmpty {
                                Text(UpdateText.notesExcerpt(release.notes)).font(.callout).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack(spacing: 16) {
                                Text("Murmur never downloads or installs updates. Download the new version from GitHub and replace the app yourself.")
                                    .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                                Spacer()
                                Button("Open Release Page…", action: controller.openReleasePage)
                            }
                        }
                    }
                } header: { Text("Updates") }

                Section {
                    permissionRow("Microphone", allowed: controller.microphoneAuthorized, actionTitle: "Allow Microphone", action: controller.requestMicrophone)
                    permissionRow("Accessibility", allowed: controller.accessibilityAuthorized, actionTitle: "Open Settings…") { controller.openPermissionSettings("accessibility") }
                    permissionRow("Input Monitoring", allowed: controller.inputMonitoringAuthorized, actionTitle: "Open Settings…") { controller.openPermissionSettings("input-monitoring") }
                } header: { Text("Permissions") }
            }
            .formStyle(.grouped)
            .disabled(controller.isBusy)

            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button("Refresh Permissions", action: controller.refreshPermissions)
                        .modifier(UtilityButton())
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(controller.isBusy ? "Finish dictating to change settings." : "Apply to save your changes.")
                            .font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                    }
                    Button(action: controller.applySettings) { Text("Apply Settings").foregroundStyle(.white) }
                        .modifier(UtilityButton(prominent: true)).disabled(controller.isBusy)
                }
            }
        }
        .padding(.top, 14)
    }

    private func placeholderField(_ title: String, text: Binding<String>) -> some View {
        TextField("", text: text)
            .accessibilityLabel(title)
            .overlay(alignment: .leading) {
                if text.wrappedValue.isEmpty {
                    Text(title).foregroundStyle(Color.primary.opacity(0.72)).padding(.leading, 4)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }

    private func keyRow(_ provider: ProviderID, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(provider.displayName)
                Spacer()
                Text(controller.savedKeys.contains(provider) ? KeyText.saved : KeyText.none)
                    .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
            }
            HStack(spacing: 8) {
                SecureField("", text: text).accessibilityLabel("\(provider.displayName) API key")
                Button("Save") { if controller.saveKey(provider, text.wrappedValue) { text.wrappedValue = "" } }
                    .disabled(text.wrappedValue.isEmpty)
                Button("Validate") { controller.validateKey(provider) }
                    .disabled(!controller.savedKeys.contains(provider) && provider != .localServer)
                Button("Remove", role: .destructive) { controller.removeKey(provider) }
                    .disabled(!controller.savedKeys.contains(provider))
            }
            if let message = controller.keyMessages[provider], !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(Color.primary.opacity(0.72)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func permissionRow(_ title: String, allowed: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: allowed ? "checkmark.circle" : "exclamationmark.circle")
            Spacer()
            Text(allowed ? "Allowed" : "Needed").font(.callout).foregroundStyle(Color.primary.opacity(0.72))
            if !allowed { Button(actionTitle, action: action) }
        }
    }

    private var history: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("History").font(.title2.weight(.semibold))
                    Text(controller.historySummary)
                        .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                }
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.primary.opacity(0.72)).accessibilityHidden(true)
                    TextField("", text: $searchText).textFieldStyle(.plain)
                        .accessibilityLabel("Search transcripts")
                        .overlay(alignment: .leading) {
                            if searchText.isEmpty {
                                Text("Search transcripts").foregroundStyle(Color.primary.opacity(0.72))
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(Color.primary.opacity(0.72)).accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9).frame(width: 220)
                .modifier(UtilityGlass())
            }
            if controller.history.isEmpty {
                ContentUnavailableView {
                    Label("Your dictation appears here", systemImage: "text.bubble")
                } description: {
                    Text("Choose your local model and allow permissions in Murmur. Completed transcripts are saved here before insertion.")
                } actions: {
                    Button("Set Up Murmur") { selectedTab = 0 }.modifier(UtilityButton(prominent: true))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredHistory.isEmpty {
                ContentUnavailableView.search(text: searchText).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(filteredHistory, selection: $selectedID) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            // Explicit primary: the sidebar list style dims unstyled text below its own captions.
                            Text((entry.finalText.isEmpty ? entry.rawText : entry.finalText).trimmingCharacters(in: .whitespacesAndNewlines))
                                .foregroundStyle(Color.primary).lineLimit(2)
                            Label(statusLabel(entry.insertionStatus), systemImage: statusSymbol(entry.insertionStatus))
                                .font(.caption).foregroundStyle(selectedID == entry.id ? Color.primary : Color.primary.opacity(0.72)).lineLimit(2)
                            Text(entry.recordedAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(selectedID == entry.id ? Color.primary : Color.primary.opacity(0.72))
                        }.padding(.vertical, 7).tag(entry.id)
                    }
                    .listStyle(.sidebar).scrollContentBackground(.hidden)
                    .frame(minWidth: 210, idealWidth: 240, maxWidth: 300)
                    if let entry = filteredHistory.first(where: { $0.id == selectedID }) {
                        VStack(spacing: 0) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 20) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(entry.recordedAt, format: .dateTime.month().day().year().hour().minute())
                                            .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                                        Label(statusLabel(entry.insertionStatus), systemImage: statusSymbol(entry.insertionStatus))
                                            .font(.callout.weight(.medium))
                                        if controller.sessionOnlyIDs.contains(entry.id) {
                                            Text(HistoryText.sessionOnlyNote).font(.callout).foregroundStyle(Color.orange)
                                        }
                                    }
                                    transcript("Final text", entry.finalText)
                                    if entry.rawText != entry.finalText { transcript("Raw transcription", entry.rawText) }
                                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            GlassEffectContainer(spacing: 12) {
                                HStack(spacing: 12) {
                                    if !entry.finalText.isEmpty {
                                        Button { controller.copyEntry(entry) } label: { Label("Copy Text", systemImage: "doc.on.doc").foregroundStyle(.white) }
                                            .modifier(UtilityButton(prominent: true))
                                    }
                                    if entry.rawText != entry.finalText {
                                        Button { controller.copyRawEntry(entry) } label: { Label("Copy Raw", systemImage: "doc.on.clipboard") }
                                            .modifier(UtilityButton())
                                    }
                                    Spacer()
                                    Button("Delete", role: .destructive) { controller.deleteEntry(entry) }
                                        .modifier(UtilityButton())
                                }
                            }.padding(.horizontal, 20).padding(.top, 10)
                            Text("Copying never retries insertion or sends a message.")
                                .font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
                        }.frame(minWidth: 300)
                    } else {
                        ContentUnavailableView("Select a transcript", systemImage: "text.alignleft", description: Text("Inspect saved text, copy it, or delete it."))
                            .frame(minWidth: 300, maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            GlassEffectContainer(spacing: 12) {
                HStack {
                    Button("Refresh", action: controller.refreshHistory).modifier(UtilityButton())
                    Spacer()
                    Button("Clear History…", role: .destructive, action: controller.clearHistory)
                        .modifier(UtilityButton()).disabled(controller.history.isEmpty)
                }
            }
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        case "copied": return "Copied to clipboard · text saved"
        case "held-cleanup": return "Cleanup held · raw text saved"
        case "held-transcript": return "Transcript held for review · raw text saved"
        default: return "Saved · not inserted"
        }
    }

    private func statusSymbol(_ status: String) -> String {
        switch status {
        case "verified": return "checkmark.circle"
        case "unverified", "insertion-pending": return "questionmark.circle"
        case "failed": return "exclamationmark.circle"
        case "copied": return "doc.on.clipboard"
        case "held-cleanup", "held-transcript": return "pause.circle"
        default: return "tray"
        }
    }

    private func transcript(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(text.isEmpty ? "No text saved." : text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

func showsFloatingIndicator(phase: String) -> Bool {
    ["Listening", "Processing", "Error"].contains(phase)
}

private struct VoiceBubbles: View {
    @ObservedObject var controller: AppController
    let phase: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        // Every display frame: a 0.15 s floor stepped the pulse visibly after release.
        TimelineView(.animation(minimumInterval: nil, paused: phase != "Processing" || reduceMotion)) { context in
            HStack(spacing: 5) {
                ForEach(0..<5) { index in
                    let pulse = (sin(context.date.timeIntervalSinceReferenceDate * 4 - Double(index)) + 1) / 2
                    let level = phase == "Listening" ? controller.voiceLevel : phase == "Processing" ? (reduceMotion ? 0.35 : pulse * 0.45) : 0.15
                    Circle().fill(Color.primary.opacity(0.35))
                        .frame(width: 6 + level * Double(index == 2 ? 10 : 7), height: 6 + level * Double(index == 2 ? 10 : 7))
                        .modifier(VoiceDotGlass(opaque: reduceTransparency || contrast == .increased))
                }
            }
            .frame(width: 80, height: 24)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: controller.voiceLevel)
        }

        .accessibilityElement(children: .ignore).accessibilityLabel(phase)
        .help(phase == "Listening" ? "Release, or press the shortcut again after a double-press, to finish. Escape cancels." : phase)
    }
}

private struct VoiceDotGlass: ViewModifier {
    let opaque: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if opaque { content.overlay(Circle().fill(Color.primary.opacity(0.65))) }
        else { content.glassEffect(.regular, in: Circle()) }
    }
}

private struct BubbleView: View {
    @ObservedObject var controller: AppController
    let message: String

    private var summary: String {
        message.components(separatedBy: ". ").first ?? "Dictation failed."
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange).accessibilityHidden(true).allowsHitTesting(false)
                Text(summary).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    .help(message).allowsHitTesting(false).accessibilityHidden(true)
                Spacer(minLength: 4)
                Button(action: controller.dismissStatus) { Image(systemName: "xmark").font(.system(size: 11)) }
                    .buttonStyle(.plain).help("Dismiss error").accessibilityLabel("Dismiss error")
            }
            if controller.recoveryAudio != nil || controller.hasRecoveryAudio {
                Button("Audio…", action: controller.revealRecoveryAudio)
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Button {
                controller.showSettings()
                DispatchQueue.main.async { NotificationCenter.default.post(name: .dictationShowError, object: nil) }
            } label: {
                Color.clear.contentShape(RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summary)
            .accessibilityHint("Open Murmur to view the full error.")
        }
        .accessibilityElement(children: .contain)
        .modifier(UtilityGlass(radius: 18))
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
        panel.title = "Murmur status"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
    }

    func show(phase: String, message: String, screen: NSScreen? = nil) {
        guard showsFloatingIndicator(phase: phase) else { hide(); return }
        let frame = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let minimal = phase != "Error"
        panel.hasShadow = !minimal
        let width = minimal ? 80 : min(240, max(180, frame.width - 32))
        let content = minimal ? AnyView(VoiceBubbles(controller: controller, phase: phase)) : AnyView(BubbleView(controller: controller, message: message))
        let host = NSHostingView(rootView: content.frame(width: width))
        panel.contentView = host
        let height = host.fittingSize.height
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.minY + 24, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}
