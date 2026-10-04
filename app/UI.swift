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
    /// Server address and model apply when editing ends (Return or leaving the field), not per keystroke.
    @FocusState private var serverFieldFocused: Bool

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
                    Toggle("Press once to start, again to stop", isOn: $controller.pressToToggle)
                    Text(controller.pressToToggle ? "Press the shortcut to start recording and press it again to stop, or hold it and release. Escape cancels." : "Hold to record until you release. Double-press to keep recording until you press again. Escape cancels.")
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
                    Text("Local transcription runs on this Mac. Downloading the model uses the network once; dictation does not. A folder you choose takes effect at once. Cloud transcription is chosen under Processing routes.")
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
                            .focused($serverFieldFocused).onSubmit(controller.settingsChanged)
                        HStack(spacing: 8) {
                            placeholderField("Model name", text: $controller.localServerModel)
                                .focused($serverFieldFocused).onSubmit(controller.settingsChanged)
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
                    Text("Routes take effect as soon as you choose them; a route that sends data off this Mac first shows what leaves it. Murmur never falls back to another route: if a provider fails, your audio or raw transcript stays here.")
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
                    Toggle("Fix punctuation and capitalization", isOn: $controller.cleanupPunctuation)
                    HStack(spacing: 16) {
                        Text("Each option works on its own. Faithful transcription turns them all off; dictionary spellings still apply.")
                            .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                        Spacer()
                        Button("Faithful Transcription", action: controller.useFaithfulTranscription)
                            .disabled(!controller.cleanupFillers && !controller.cleanupCorrections && !controller.cleanupLists && !controller.cleanupPunctuation)
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
                    Toggle("Insert at the cursor", isOn: $controller.automaticInsertion)
                    Text("Types into whichever field has the cursor when dictation finishes. Saved first; if a field cannot take the text, it goes to the clipboard. Murmur never sends a message.")
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
            // Every setting applies as soon as it changes; there is no Apply button to forget.
            .modifier(AutoApplyGeneral(controller: controller))
            .modifier(AutoApplyRoutes(controller: controller, serverFieldFocused: serverFieldFocused))

            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button("Refresh Permissions", action: controller.refreshPermissionsAndShortcut)
                        .modifier(UtilityButton())
                    Spacer()
                    Text(controller.isBusy ? "Finish dictating to change settings." : "Changes apply as soon as you make them.")
                        .font(.caption).foregroundStyle(Color.primary.opacity(0.72))
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
                // A visible box and prompt: an unstyled field drew nothing, so there was nowhere obvious to click or paste.
                SecureField("", text: text, prompt: Text("Paste your \(provider.displayName) API key"))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("\(provider.displayName) API key")
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

/// Text fields receive ⌘X/⌘C/⌘V/⌘A/⌘Z through the Edit menu; without it, pasting an API key does nothing.
func standardEditMenuItem() -> NSMenuItem {
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    item.submenu = edit
    return item
}

/// Split in two so the compiler can type-check the chains.
private struct AutoApplyGeneral: ViewModifier {
    @ObservedObject var controller: AppController
    func body(content: Content) -> some View {
        content
            .onChange(of: controller.shortcut) { controller.settingsChanged() }
            .onChange(of: controller.automaticInsertion) { controller.settingsChanged() }
            .onChange(of: controller.pressToToggle) { controller.settingsChanged() }
            .onChange(of: controller.intelligentLeadingSpace) { controller.settingsChanged() }
            .onChange(of: controller.showMenuBar) { controller.settingsChanged() }
            .onChange(of: controller.retention) { controller.settingsChanged() }
            .onChange(of: controller.historyMode) { controller.settingsChanged() }
            .onChange(of: controller.updateChecksEnabled) { controller.settingsChanged() }
    }
}

private struct AutoApplyRoutes: ViewModifier {
    @ObservedObject var controller: AppController
    let serverFieldFocused: Bool
    func body(content: Content) -> some View {
        content
            .onChange(of: controller.cleanupFillers) { controller.settingsChanged() }
            .onChange(of: controller.cleanupCorrections) { controller.settingsChanged() }
            .onChange(of: controller.cleanupLists) { controller.settingsChanged() }
            .onChange(of: controller.cleanupPunctuation) { controller.settingsChanged() }
            .onChange(of: controller.learningEnabled) { controller.settingsChanged() }
            .onChange(of: controller.transcriptionRoute) { controller.settingsChanged() }
            .onChange(of: controller.cloudTranscriber) { controller.settingsChanged() }
            .onChange(of: controller.cleanupChoice) { controller.settingsChanged() }
            // Typing in a server field waits for Return or focus loss; the Found models picker applies at once.
            .onChange(of: controller.localServerModel) { if !serverFieldFocused { controller.settingsChanged() } }
            .onChange(of: controller.localServerURL) { if !serverFieldFocused { controller.settingsChanged() } }
            .onChange(of: serverFieldFocused) { _, focused in if !focused { controller.settingsChanged() } }
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
    /// Centre bars swing most, like a synth's level meter.
    private static let weights = [0.6, 0.85, 1, 0.85, 0.6]
    var body: some View {
        // Every display frame: a 0.15 s floor stepped the pulse visibly after release.
        TimelineView(.animation(minimumInterval: nil, paused: phase == "Error" || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Clear Liquid Glass capsules that stretch vertically with the voice.
            GlassEffectContainer(spacing: 2) {
                HStack(spacing: 0) {
                    ForEach(0..<5) { index in
                        let wobble = reduceMotion ? 1 : 0.65 + 0.35 * sin(t * 9 + Double(index) * 1.7)
                        // Read the microphone every frame (the published level updates every 0.15 s);
                        // the square root lifts quiet speech so the bars react to it.
                        let voice = reduceMotion ? controller.voiceLevel : controller.liveVoiceLevel()
                        let level = phase == "Listening" ? voice.squareRoot() * wobble
                            : phase == "Processing" ? (reduceMotion ? 0.35 : (sin(t * 4 - Double(index)) + 1) / 2 * 0.45) : 0.15
                        // Rests as a short pill (9 × 13 pt) and stretches up to the full 40 pt.
                        Color.clear.frame(width: 9, height: 13 + 27 * level * Self.weights[index])
                            .modifier(VoiceDotGlass(opaque: reduceTransparency || contrast == .increased))
                            .frame(width: 14, height: 40)
                    }
                }
            }
            .frame(width: 80, height: 40)
        }
        // The indicator's panel never becomes key; render its glass as active so it refracts
        // instead of falling back to the flat inactive look.
        .environment(\.appearsActive, true)
        .accessibilityElement(children: .ignore).accessibilityLabel(phase)
        .help(phase == "Listening" ? "Release, or press the shortcut again after a double-press, to finish. Escape cancels." : phase)
    }
}

private struct VoiceDotGlass: ViewModifier {
    let opaque: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if opaque { content.overlay(Capsule().fill(Color.primary.opacity(0.65))) }
        // A #5995C9 fill under clear glass: glass tint alone rendered gray and vanished on white.
        else {
            content.background(Capsule().fill(Color(red: 0x59 / 255, green: 0x95 / 255, blue: 0xC9 / 255).opacity(0.55)))
                .glassEffect(.clear, in: Capsule())
        }
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
            // These keep only the pop-up; saved audio stays reachable from Murmur's window.
            if controller.recoveryAudio != nil || controller.hasRecoveryAudio,
               !["No speech was detected", "No audio was captured", "Transcription failed"].contains(where: message.hasPrefix) {
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
