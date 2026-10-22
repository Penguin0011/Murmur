import AppKit
import SwiftUI
import Charts
import CoreText

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
struct UtilityGlass: ViewModifier {
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

/// The standalone design’s balanced palette, with a matching dark window appearance.
enum Palette {
    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light) }
    }
    static let paperNS = dynamic(light: 0xFAFAFA, dark: 0x181818)
    static let paper = Color(nsColor: paperNS)
    static let ink = Color(nsColor: dynamic(light: 0x141414, dark: 0xFAFAFA))
    static let ink80 = ink.opacity(0.8)
    static let ink70 = ink.opacity(0.7)
    static let ink64 = ink.opacity(0.64)
    static let ink45 = ink.opacity(0.45)
    static let ink20 = ink.opacity(0.2)
    static let accent = Color(red: 0x59 / 255, green: 0x95 / 255, blue: 0xC9 / 255)
    /// Same hue at 4.8:1 on paper: accent text.
    static let accentInk = Color(nsColor: dynamic(light: 0x2F6EA6, dark: 0x8DB6DC))
    static let accentDeep = Color(nsColor: dynamic(light: 0x285F90, dark: 0xA9C8E6))
    static let accent16 = accent.opacity(0.16)
}

/// Fonts ship with the app; the window never fetches typography from the network.
enum WindowType {
    private static let registered: Void = {
        for name in ["InstrumentSerif-Regular", "DMSans"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()
    static func display(_ size: CGFloat) -> Font {
        _ = registered
        return .custom("InstrumentSerif-Regular", size: size)
    }
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        _ = registered
        return .custom("DMSans-9ptRegular", size: size).weight(weight)
    }
}

/// The Murmur mark: five bars rising and falling like a voice, on the logo sheet's 96-unit grid.
enum Logo {
    static let bars: [CGRect] = [
        CGRect(x: 14, y: 36, width: 9, height: 24), CGRect(x: 29, y: 14, width: 9, height: 68),
        CGRect(x: 44, y: 30, width: 9, height: 36), CGRect(x: 59, y: 22, width: 9, height: 52),
        CGRect(x: 74, y: 38, width: 9, height: 20),
    ]
    static func path(in size: CGSize) -> Path {
        Path { path in bars.forEach { path.addRect($0.applying(CGAffineTransform(scaleX: size.width / 96, y: size.height / 96))) } }
    }
    /// Full-colour mark: bars stay literal ink on accent in both appearances.
    static func mark(size: CGFloat) -> some View {
        path(in: CGSize(width: size, height: size)).fill(Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255))
            .frame(width: size, height: size).background(Palette.accent).accessibilityHidden(true)
    }
    /// One-colour menu bar mark; the template tint follows the menu bar.
    static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            NSColor.black.setFill()
            bars.forEach { $0.applying(CGAffineTransform(scaleX: rect.width / 96, y: rect.height / 96)).fill() }
            return true
        }
        image.isTemplate = true; image.accessibilityDescription = "Murmur"
        return image
    }()
}

struct InkButtonStyle: ButtonStyle {
    enum Kind { case filled, outline, accent, plain }
    var kind: Kind = .filled
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WindowType.body(14, weight: .semibold)).lineLimit(1)
            .padding(.horizontal, kind == .plain ? 0 : 18).frame(minHeight: 36)
            .foregroundStyle(kind == .filled || kind == .accent ? Palette.paper : Palette.ink)
            .background(kind == .filled ? Palette.ink : kind == .accent ? Palette.accentInk : Color.clear, in: Capsule())
            .overlay { if kind == .outline { Capsule().strokeBorder(Palette.ink, lineWidth: 1) } }
            .contentShape(Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

/// A keyboard-focusable button draws the reference switch; VoiceOver receives a native toggle.
struct MurmurToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 24) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                Capsule().fill(configuration.isOn ? Palette.ink : Palette.ink.opacity(0.25))
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(Palette.paper).frame(width: 22, height: 22).padding(2)
                    }
                    .frame(width: 44, height: 26)
            }
            .frame(minHeight: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain).opacity(enabled ? 1 : 0.45)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// Light or Dark for this window only; nil follows the system.
private struct WindowAppearance: NSViewRepresentable {
    let name: NSAppearance.Name?
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        // The view joins its window after the first update.
        DispatchQueue.main.async { view.window?.appearance = name.flatMap { NSAppearance(named: $0) } }
    }
}

struct SettingsView: View {
    @ObservedObject var controller: AppController
    private enum Screen { case home, insights, meetings, settings, history, setup }
    @State private var screen = Screen.home
    /// The welcome guide's current step (gap #21), saved as it changes so the guide resumes there.
    @State private var guideStep = WelcomeGuide.Step.microphone
    @State private var section = 0
    @State private var showAdvanced = false
    /// The expanded History row.
    @State private var selectedID: String?
    @State private var copiedID: String?
    /// The History entry whose final text is being edited (gap #10), and the draft.
    @State private var editingTextID: String?
    @State private var textDraft = ""
    @State private var searchText = ""
    @State private var settingsQuery = ""
    @State private var settingsSearchOpen = false
    @State private var settingsTarget = "top"
    @State private var settingsNavigationID = UUID()
    @FocusState private var settingsSearchFocused: Bool
    @State private var newPreferred = ""
    @State private var newVariants = ""
    /// The dictionary row being edited, and its draft fields.
    @State private var editingEntryID: UUID?
    @State private var editPreferred = ""
    @State private var editVariants = ""
    @State private var openKey: ProviderID?
    @State private var keyDraft = ""
    @State private var checkedSetup = false
    /// The writing mode whose editor is open.
    @State private var editingModeID: UUID?
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @AppStorage("showDetailedSettingsInfo") private var showDetailedSettingsInfo = true
    /// System, light or dark (gap #20). A window preference only; the floating indicator keeps following
    /// the system appearance.
    @AppStorage("appearance") private var appearance = "system"
    /// API address and model apply when editing ends (Return or leaving the field), not per keystroke.
    @FocusState private var apiFieldFocused: Bool

    private static let sections = SettingsSearch.sections
    private static let sectionIcons = ["slider.horizontal.3", "waveform", "wand.and.stars", "switch.2", "character.book.closed", "hand.raised", "key", "arrow.triangle.2.circlepath", "gearshape.2"]
    private static let ledes = [
        "The shortcut, how text is inserted, and what Murmur is allowed to do.",
        "Where your voice is turned into text. On this Mac by default.",
        "Tidy the transcript before it is typed. Each option works on its own.",
        "Different cleanup for an app, a website or a word you say.",
        "Words Murmur should spell your way, in every mode.",
        "What Murmur saves, and for how long. Nothing leaves this Mac.",
        "Needed only for cloud routes. Stored in your Keychain.",
        "Verified updates from GitHub. Choose when they install.",
        "Where meeting audio is transcribed, apart from dictation, and how notes are written."
    ]

    var body: some View {
        Group {
            if screen == .setup { setup } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        sidebar
                        VStack(spacing: 0) {
                            banners
                            switch screen {
                            case .home: home
                            case .insights: insightsView
                            case .meetings: MeetingsPage(controller: controller, recorder: controller.meetingRecorder)
                            case .settings: settings
                            default: history
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .disabled(settingsSearchOpen).accessibilityHidden(settingsSearchOpen)
        .foregroundStyle(Palette.ink)
        .background(Palette.paper)
        // System leaves the window's appearance alone, so SwiftUI follows macOS.
        .transformEnvironment(\.colorScheme) { if appearance == "dark" { $0 = .dark } else if appearance == "light" { $0 = .light } }
        // preferredColorScheme leaks app-wide and darkened the floating bubble; set only this window.
        .background(WindowAppearance(name: appearance == "dark" ? .darkAqua : appearance == "light" ? .aqua : nil))
        .overlay { if settingsSearchOpen { settingsSearchOverlay } }
        .onChange(of: sidebarCollapsed) { settingsSearchOpen = false; settingsQuery = "" }
        .frame(minWidth: 760, minHeight: 560)
        // Every setting applies as soon as it changes; attached here so hidden sections still apply.
        .modifier(AutoApplyGeneral(controller: controller))
        .modifier(AutoApplyRoutes(controller: controller, apiFieldFocused: apiFieldFocused))
        .onAppear {
            controller.refreshPermissions(); controller.refreshHistory(); controller.refreshInputDevices()
            if !checkedSetup {
                checkedSetup = true
                guideStep = WelcomeGuide.resumeStep(.standard)
                if WelcomeGuide.opensAtLaunch(.standard, alreadySetUp: setupComplete) { screen = .setup }
            }
            showRequestedScreen()
        }
        .onChange(of: controller.screenRequest) { showRequestedScreen() }
        .onChange(of: guideStep) { WelcomeGuide.save(guideStep, .standard) }
        // Permissions are granted in System Settings; re-read them on return.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in controller.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: .dictationShowError)) { _ in screen = .settings }
        .onReceive(NotificationCenter.default.publisher(for: .dictationShowHistory)) { _ in
            searchText = ""; screen = .history
            selectedID = controller.history.first(where: { $0.id == controller.recoveryEntryID })?.id ?? controller.history.first?.id
        }
    }

    /// A menu item (Welcome Guide…) or the UI fixture asked for a screen.
    private func showRequestedScreen() {
        guard let request = controller.screenRequest else { return }
        controller.screenRequest = nil
        switch request {
        case "settings-search":
            screen = .settings; section = 0
            settingsQuery = "meeting"; settingsSearchOpen = true
        case "guide": WelcomeGuide.replay(.standard); guideStep = .microphone; screen = .setup
        case "insights": screen = .insights
        case "meetings": screen = .meetings
        case "meeting-settings": section = 8; screen = .settings
        case "settings": screen = .settings
        case let value where value.hasPrefix("settings-"):
            if let index = Int(value.dropFirst("settings-".count)), Self.sections.indices.contains(index) {
                settingsTarget = "top"; section = index; screen = .settings
            }
        case "history": screen = .history
        default: screen = .home
        }
    }

    // MARK: Shared pieces

    private func mono(_ text: String, size: CGFloat = 12, color: Color = Palette.ink) -> some View {
        Text(text).font(.system(size: size, design: .monospaced)).tracking(size * 0.08).textCase(.uppercase).foregroundStyle(color)
    }

    private func eyebrow(_ text: String) -> some View { mono(text, size: 11, color: Palette.accentInk).id(text) }

    private var rule: some View { Rectangle().fill(Palette.ink20).frame(height: 1) }
    private var softRule: some View { Rectangle().fill(Palette.ink20).frame(height: 1) }

    private func help(_ text: String, color: Color = Palette.ink70) -> some View {
        Text(text).font(WindowType.body(13)).lineSpacing(2).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    private func titled(_ title: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).font(WindowType.body(15, weight: .semibold))
                if let detail, !showDetailedSettingsInfo { SettingInfoButton(text: detail) }
            }
            if let detail, showDetailedSettingsInfo { help(detail) }
        }
    }

    @ViewBuilder private func settingInfo(_ text: String) -> some View {
        if showDetailedSettingsInfo { help(text) }
        else { SettingInfoButton(text: text) }
    }

    private var microphonePicker: some View {
        let devices = controller.inputDevices
        let saved = controller.inputDeviceUID
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Microphone", selection: $controller.inputDeviceUID) {
                Text("System default").tag("")
                Text("Automatic").tag(MicrophoneChoice.automatic)
                ForEach(devices, id: \.uid) { device in Text(device.name).tag(device.uid) }
                if !saved.isEmpty && saved != MicrophoneChoice.automatic && !devices.contains(where: { $0.uid == saved }) { Text("Chosen microphone (not connected)").tag(saved) }
            }
            .labelsHidden()
            if saved == MicrophoneChoice.automatic {
                SettingInfoButton(text: "Uses the Mac’s built-in microphone instead of a Bluetooth headset’s while available, so AirPods keep full playback quality. Otherwise uses the system default.")
            }
            help("If the microphone changes while you dictate, recording continues on the new one and keeps what was already recorded.")
        }
    }

    private func toggleRow(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { titled(title, detail) }.toggleStyle(MurmurToggleStyle())
            .padding(.vertical, 10).id(title)
    }

    /// "Gemini 3.5 Transcribe (speech recognition, …)" → "Gemini 3.5 Transcribe" for segment labels.
    private func short(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "(,")).first?.trimmingCharacters(in: .whitespaces) ?? name
    }

    private func field(_ title: String, text: Binding<String>, secure: Bool = false) -> some View {
        Group {
            if secure { SecureField("", text: text) } else { TextField("", text: text) }
        }
        .textFieldStyle(.plain).font(WindowType.body(15)).accessibilityLabel(title)
        .overlay(alignment: .leading) {
            if text.wrappedValue.isEmpty {
                Text(title).font(WindowType.body(15)).foregroundStyle(Palette.ink64).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12).frame(height: 44)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.ink20, lineWidth: 1))
    }

    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geometry in
            Rectangle().fill(Palette.accent).frame(width: geometry.size.width * fraction)
        }
        .frame(height: 8).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.ink20, lineWidth: 1))
        .accessibilityElement().accessibilityLabel("Download progress").accessibilityValue("\(Int(fraction * 100)) percent")
    }

    private func wordmark(_ text: String, size: CGFloat) -> some View {
        Text(text).font(WindowType.display(size)).tracking(-size * 0.02)
    }

    private var setupComplete: Bool {
        controller.microphoneAuthorized && controller.accessibilityAuthorized && controller.inputMonitoringAuthorized && modelSatisfied
    }

    /// Cloud transcription does not need the local model.
    private var modelSatisfied: Bool { controller.modelRow.isReady || controller.transcriptionRoute == .cloud }

    // MARK: Window navigation

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { sidebarCollapsed.toggle() } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 16)).frame(width: 36, height: 36)
                    .foregroundStyle(Palette.ink70).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
            .accessibilityLabel(sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
            .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    navigationRow("Home", icon: "house", selected: screen == .home) { screen = .home }
                    navigationRow("Insights", icon: "chart.bar.xaxis", selected: screen == .insights) { screen = .insights }
                    navigationRow("Meetings", icon: "person.2", selected: screen == .meetings) { screen = .meetings }
                    navigationRow("History", icon: "clock.arrow.circlepath", selected: screen == .history) { screen = .history }
                    navigationRow("Search settings", icon: "magnifyingglass", selected: settingsSearchOpen) { settingsSearchOpen = true }
                    Color.clear.frame(height: 12)
                    ForEach(Self.sections.indices, id: \.self) { index in
                        navigationRow(index == 8 ? "Meeting Settings" : index == 5 ? "Privacy" : Self.sections[index],
                                      icon: Self.sectionIcons[index], selected: screen == .settings && section == index) { section = index; screen = .settings }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 7) {
                Circle().fill(controller.phase == "Error" ? Palette.ink : Palette.accentInk).frame(width: 6, height: 6)
                if !sidebarCollapsed { mono(controller.phase, size: 10, color: Palette.ink70) }
            }
            .accessibilityElement(children: .ignore).accessibilityLabel(controller.phase)
            .help(controller.phase + " · " + (controller.appliedTranscriptionIsLocal ? "Local transcription" : "Cloud transcription"))
            .padding(.leading, sidebarCollapsed ? 15 : 0)
            .padding(.top, 12).padding(.bottom, 16)
        }
        .padding(.horizontal, sidebarCollapsed ? 14 : 20).padding(.top, 16)
        .frame(width: sidebarCollapsed ? 64 : 216).frame(maxHeight: .infinity)
    }

    private var settingsSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.ink70).accessibilityHidden(true)
            TextField("Search settings", text: $settingsQuery)
                .textFieldStyle(.plain).font(WindowType.body(14))
                .accessibilityLabel("Search settings").focused($settingsSearchFocused)
                .onSubmit { if let result = SettingsSearch.matches(settingsQuery).first { openSetting(result) } }
                .onExitCommand { settingsSearchOpen = false; settingsQuery = "" }
        }
        .padding(8).background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private var settingsSearchResults: some View {
        let results = SettingsSearch.matches(settingsQuery)
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if results.isEmpty {
                    Text(settingsQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Type to find a setting." : "No matching settings.")
                        .font(WindowType.body(13)).foregroundStyle(Palette.ink70).padding(8)
                }
                ForEach(results) { result in
                    Button { openSetting(result) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.title).font(WindowType.body(14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                            Text(result.sectionName).font(WindowType.body(12)).foregroundStyle(Palette.ink70)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("\(result.title), \(result.sectionName)")
                }
            }
        }
        .frame(maxHeight: 300)
    }

    private var settingsSearchOverlay: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea().onTapGesture { settingsSearchOpen = false }
                .accessibilityHidden(true)
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    settingsSearchField
                    Button { settingsSearchOpen = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Close settings search")
                }
                settingsSearchResults
            }
            .padding(20).frame(width: 440)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
            .onAppear { DispatchQueue.main.async { settingsSearchFocused = true } }
            .onExitCommand { settingsSearchOpen = false }
            .accessibilityElement(children: .contain).accessibilityLabel("Settings search")
        }
    }

    private func openSetting(_ result: SettingsSearch.Result) {
        if result.target == "model-folder" { showAdvanced = true }
        settingsTarget = result.target; settingsNavigationID = UUID()
        section = result.section; screen = .settings
        settingsSearchOpen = false; settingsQuery = ""; settingsSearchFocused = false
    }

    private func navigationRow(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 15)).frame(width: 20)
                if !sidebarCollapsed { mono(title, size: 11, color: selected ? Palette.ink : Palette.ink70).lineLimit(1) }
            }
            .foregroundStyle(selected ? Palette.ink : Palette.ink70)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: sidebarCollapsed ? .center : .leading)
            .background(selected ? Palette.accent16 : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var banners: some View {
        if controller.hasStatusToShow && !controller.isBusy {
            HStack(alignment: .top, spacing: 12) {
                if controller.phase == "Error" { mono("Error", color: Palette.paper).padding(.top, 2) }
                Text(controller.message).font(WindowType.body(14)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer(minLength: 8)
                Button(action: controller.dismissStatus) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Dismiss status").accessibilityLabel("Dismiss status")
            }
            .foregroundStyle(Palette.paper).padding(.horizontal, 24).padding(.vertical, 12)
            .background(controller.phase == "Error" ? Palette.ink : Palette.accentDeep)
        }
        if !setupComplete {
            HStack {
                Text(controller.accessibilityAuthorized && controller.inputMonitoringAuthorized
                     ? (modelSatisfied ? "Murmur needs the microphone before you can dictate." : "Murmur needs the microphone and its speech model before you can dictate.")
                     : "Accessibility and Input Monitoring are needed before Murmur can type for you.")
                    .font(WindowType.body(14))
                Spacer(minLength: 12)
                Button { screen = .setup } label: {
                    Text("Finish Setup →").font(WindowType.body(14, weight: .semibold))
                        .underline(color: Palette.accent).frame(height: 44)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Palette.paper).padding(.horizontal, 24)
            .background(Palette.ink)
        }
    }

    // MARK: Settings

    private var settings: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Self.sections[section]).id("top").font(WindowType.display(40)).tracking(-0.8)
                    Text(Self.ledes[section]).font(WindowType.body(14)).foregroundStyle(Palette.ink70)
                        .lineSpacing(2).padding(.top, 6).padding(.bottom, 8)
                    sectionBody.disabled(controller.isBusy)
                    if controller.isBusy { help("Finish dictating to change settings.", color: Palette.ink64).padding(.top, 12) }
                }
                .padding(EdgeInsets(top: 16, leading: 24, bottom: 24, trailing: 24))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { DispatchQueue.main.async { proxy.scrollTo(settingsTarget, anchor: .top) } }
            .onChange(of: settingsNavigationID) { DispatchQueue.main.async { proxy.scrollTo(settingsTarget, anchor: .top) } }
            .id(section)
        }
    }

    @ViewBuilder private var sectionBody: some View {
        switch section {
        case 0: general
        case 1: transcription
        case 2: cleanup
        case 3: modes
        case 4: dictionary
        case 5: privacy
        case 6: apiKeys
        case 8: meetingSettings
        default: updates
        }
    }

    /// Settings → Meetings (decision of October 15, 2026, amending Q2): the meeting transcription route.
    private var meetingRoutes: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                eyebrow("Meeting transcription")
                SettingInfoButton(text: "A change applies to meetings started afterwards; a meeting in progress keeps its route. Dictation’s route is set separately in Transcription.\n\n" + (controller.meetingTranscription == .local
                    ? "Meeting audio is transcribed on this Mac and never leaves it. This is the default."
                    : controller.meetingCloudNote.map { $0.note + "\n\n" + $0.disclosure } ?? "Choose a cloud transcriber in Settings → Transcription."))
            }.padding(.top, 20)
            segmented([(MeetingTranscription.local, "On this Mac (Parakeet)"), (MeetingTranscription.cloud, "Cloud (\(controller.cloudTranscriber.displayName))")], $controller.meetingTranscription)
            if controller.meetingTranscription == .cloud && controller.meetingCloudNote == nil {
                help("No cloud transcriber is set up. Choose one and save its key in Settings → Transcription and API Keys.", color: Palette.ink)
            }
            HStack(spacing: 4) {
                eyebrow("Meeting notes")
                SettingInfoButton(text: controller.meetingNotesRoute == nil ? "Not chosen yet: Murmur asks after your first meeting." : "Notes are written after Stop from the transcript and your own notes. Every item cites the lines it rests on; items the transcript does not support are left out.")
            }.padding(.top, 20)
            MeetingNotesRoutePicker(controller: controller, tooltipDetails: true, selection: Binding(get: { controller.meetingNotesRoute ?? .none }, set: { controller.meetingNotesRoute = $0; controller.meetingRecorder.notesRouteChosen($0) }))
        }
    }

    private var meetingSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            meetingRoutes
            CallDetectionRows(presenter: controller.callOffers).id("call-detection")
            SpeakerSettingsSection(settings: controller.speakerSettings).id("speaker-separation")
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                eyebrow("Shortcut")
                SettingInfoButton(text: controller.pressToToggle ? "Press the shortcut to start recording and press it again to stop, or hold it and release. Escape cancels." : "Hold to record until you release. Double-press to keep recording until you press again. Escape cancels.")
                    .accessibilityLabel("How to use the shortcut")
            }.padding(.top, 12)
            VStack(alignment: .leading, spacing: 8) {
                segmented([("right-option", "Right Option"), ("fn", "Fn / Globe"), ("ctrl-option-space", "Control–Option–Space")], $controller.shortcut)
                ShortcutRecorder(controller: controller)
            }
            .padding(.vertical, 12).overlay(alignment: .top) { rule }.overlay(alignment: .bottom) { softRule }.padding(.top, 8)
            toggleRow("Press once to start, again to stop", "Holding still works: release to stop. Off means hold to record.", isOn: $controller.pressToToggle)
            toggleRow("Start and stop sounds", "A short sound when recording starts and when it stops or is canceled. No sound when text is inserted.", isOn: $controller.recordingSounds)
            toggleRow(LiveWordsFacts.displayName, LiveWordsFacts.explanation, isOn: $controller.liveWords).id("live-words")
            if controller.liveWords {
                liveWordsModel.padding(.vertical, 10)
                toggleRow("Show live words on cloud routes", "Off: when transcription runs in the cloud, the bubble shows only the level meter and the extra model does not start. The preview always runs on this Mac.", isOn: $controller.liveWordsOnCloud)
            }
            toggleRow("Insert at the cursor", "Types into whichever field has the cursor when dictation finishes. Press ⌃⌘V to paste the last dictation again if it is missing; check the field first to avoid a duplicate. The previous clipboard is restored unless you copy something newer. Automatic paste is marked transient; other software may still read or retain it. Murmur never sends a message.", isOn: $controller.automaticInsertion)
            toggleRow("Add a leading space when needed", "Separates dictation from existing text at the cursor. Existing whitespace, punctuation and selected text are left alone.", isOn: $controller.intelligentLeadingSpace)
            toggleRow("Show menu bar icon", "When hidden, reopen Murmur from Finder or Spotlight.", isOn: $controller.showMenuBar)
            toggleRow("Show in Dock", "Adds Murmur to the Dock and the app switcher. With both icons hidden, reopen Murmur from Finder or Spotlight.", isOn: $controller.showInDock)
            toggleRow("Open at login", "Starts Murmur in the background when you log in, so the shortcut is ready.", isOn: Binding(get: { controller.openAtLogin }, set: controller.setOpenAtLogin))

            eyebrow("Microphone").padding(.top, 20)
            microphonePicker.padding(.top, 8)

            eyebrow("Permissions").padding(.top, 20)
            VStack(spacing: 0) {
                permissionRow("Microphone", allowed: controller.microphoneAuthorized, actionTitle: "Allow", action: controller.requestMicrophone)
                permissionRow("Accessibility", allowed: controller.accessibilityAuthorized, actionTitle: "Open Settings…") { controller.openPermissionSettings("accessibility") }
                permissionRow("Input Monitoring", allowed: controller.inputMonitoringAuthorized, actionTitle: "Open Settings…") { controller.openPermissionSettings("input-monitoring") }
            }
            .overlay(alignment: .top) { rule }.padding(.top, 8)
            Button("Refresh Permissions", action: controller.refreshPermissionsAndShortcut)
                .buttonStyle(InkButtonStyle(kind: .outline)).padding(.top, 16)

            Toggle("Show detailed info", isOn: $showDetailedSettingsInfo)
                .font(WindowType.body(13)).toggleStyle(.checkbox).padding(.top, 12).id("detailed-info")

            eyebrow("Appearance").padding(.top, 20)
            segmented([("system", "System"), ("light", "Light"), ("dark", "Dark")], $appearance).padding(.top, 8)
            help("Murmur’s windows only. The dictation bubble always follows macOS.").padding(.top, 8)
        }
    }

    private func permissionRow(_ title: String, allowed: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Text(title).font(WindowType.body(15, weight: .semibold))
            Spacer()
            mono(allowed ? "Allowed ✓" : "Needed", color: allowed ? Palette.accentInk : Palette.ink)
            if !allowed { Button(actionTitle, action: action).buttonStyle(InkButtonStyle()) }
        }
        .frame(minHeight: 44).padding(.vertical, 18)
    }

    private var transcription: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(ModelFacts.displayName).font(WindowType.body(18, weight: .semibold))
                            ModelInfoIcons(license: controller.modelLicense.map(ModelFacts.licenseText), details: controller.modelSummary)
                        }
                        Group {
                            if controller.modelRow.isReady { mono("Model ready ✓", color: Palette.accentInk) }
                            else { Text(controller.modelRow.statusText).font(WindowType.body(14, weight: .semibold)).fixedSize(horizontal: false, vertical: true) }
                        }
                        .padding(.top, 5)
                    }
                    Spacer()
                    if controller.modelRow.actions.contains(.download) { Button("Download…", action: controller.downloadModel).buttonStyle(InkButtonStyle()) }
                    if controller.modelRow.actions.contains(.retry) { Button("Retry…", action: controller.downloadModel).buttonStyle(InkButtonStyle()) }
                    if controller.modelRow.actions.contains(.cancel) { Button("Cancel", action: controller.cancelModelDownload).buttonStyle(InkButtonStyle(kind: .outline)) }
                    if controller.modelRow.actions.contains(.remove) { Button("Remove…", role: .destructive, action: controller.removeModel).buttonStyle(InkButtonStyle(kind: .outline)) }
                }
                if let progress = controller.modelRow.progress { progressBar(progress) }
                if !controller.modelMessage.isEmpty { help(controller.modelMessage) }
            }
            .padding(.vertical, 18).padding(.top, 20)

            transcriptionRoutes

            Button { showAdvanced.toggle() } label: {
                mono((showAdvanced ? "▾" : "▸") + " Advanced", size: 13).frame(height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.top, 28)
            if showAdvanced {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model folder").id("model-folder").font(WindowType.body(16, weight: .semibold))
                        help((controller.usesCustomModelFolder ? "Custom folder" : "Default folder") + " · " + (controller.modelAvailable ? "model files found ✓" : "no model files in this folder"))
                        if !controller.modelDirectory.isEmpty {
                            Text(URL(fileURLWithPath: controller.modelDirectory).lastPathComponent)
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.ink64).lineLimit(1)
                                .textSelection(.enabled).help(controller.modelDirectory)
                        }
                    }
                    Spacer()
                    if controller.usesCustomModelFolder { Button("Use Default", action: controller.useDefaultModelDirectory).buttonStyle(InkButtonStyle(kind: .outline)) }
                    Button("Choose Folder…", action: controller.chooseModelDirectory).buttonStyle(InkButtonStyle(kind: .outline))
                }
                .padding(.vertical, 16).overlay(alignment: .top) { rule }
                help("A folder you choose takes effect at once.")
            }
        }
    }

    private var transcriptionRoutes: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow("Where transcription runs").padding(.top, 28)
            segmented([(TranscriptionRoute.local, "On this Mac (Parakeet)"), (TranscriptionRoute.cloud, "Cloud")], $controller.transcriptionRoute).padding(.top, 8)
            if controller.transcriptionRoute == .local {
                help("Audio stays on this Mac. Downloading the model uses the network once; dictation does not.").padding(.top, 12)
            } else {
                cloudTranscriptionSettings
                disclosure(controller.routeDisclosure(.transcription)).padding(.top, 16)
            }
        }
    }

    private var cloudTranscriptionSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            segmented(CloudTranscriber.allCases.map { ($0, $0.displayName) }, $controller.cloudTranscriber, size: 14).padding(.top, 16)
                .help(controller.cloudTranscriber.displayName)
            if controller.cloudTranscriber == .gemini {
                let modelHint = controller.geminiTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines) == GeminiTranscribeProvider.defaultModel
                    ? "Recommended: Gemini 3.5 Transcribe, dedicated speech recognition."
                    : "Other Gemini models may follow spoken instructions, skip words, or invent text."
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 4) {
                        Text("Gemini transcription model").font(WindowType.body(14, weight: .semibold))
                        settingInfo(modelHint)
                    }
                    field(GeminiTranscribeProvider.defaultModel, text: $controller.geminiTranscriptionModel)
                        .focused($apiFieldFocused).onSubmit(controller.settingsChanged)
                    keyRow(.gemini)
                }.padding(.top, 16)
            }
            if controller.cloudTranscriber == .customAPI {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Transcription API base URL").font(WindowType.body(14, weight: .semibold))
                    field("https://api.example.com/v1", text: $controller.customTranscriptionAPIBaseURL)
                        .focused($apiFieldFocused).onSubmit(controller.settingsChanged)
                    Text("Transcription model name").font(WindowType.body(14, weight: .semibold))
                    field("whisper-1", text: $controller.customTranscriptionModel)
                        .focused($apiFieldFocused).onSubmit(controller.settingsChanged)
                    keyRow(.customTranscription)
                    help("Needs an OpenAI-compatible /v1/audio/transcriptions endpoint. Separate from cleanup.")
                }.padding(.top, 16)
            }
        }
    }

    @ViewBuilder private func disclosure(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(WindowType.body(14)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.accent16)
        }
    }

    /// Faithful disables the edit toggles; choosing another style restores the standard edits.
    var cleanupStyle: Binding<Int> {
        Binding(get: {
            guard controller.cleanupFillers || controller.cleanupCorrections || controller.cleanupLists || controller.cleanupPunctuation || controller.cleanupSpoken else { return -1 }
            return controller.cleanupChoice == .localRules ? 0 : controller.cleanupProfessional ? 2 : controller.cleanupPolish ? 1 : 0
        }, set: { style in
            if style == -1 { controller.useFaithfulTranscription(); return }
            if self.cleanupStyle.wrappedValue == -1 {
                controller.cleanupFillers = true; controller.cleanupCorrections = true; controller.cleanupLists = true
                controller.cleanupPunctuation = true; controller.cleanupSpoken = true
            }
            controller.cleanupPolish = style >= 1; controller.cleanupProfessional = style == 2
        })
    }

    private var cleanupChoices: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow("Cleanup runs with").padding(.top, 28)
            segmented(CleanupChoice.allCases.map { ($0, short($0.displayName)) }, $controller.cleanupChoice, size: 14)
                .padding(.top, 8).help(controller.cleanupChoice.displayName)
            eyebrow("Cleanup style").padding(.top, 20)
            HStack(spacing: 4) {
                segmented(controller.cleanupChoice == .localRules
                          ? [(-1, "Faithful"), (0, "Strict")]
                          : [(-1, "Faithful"), (0, "Strict"), (1, "Polish"), (2, "Professional")], cleanupStyle, size: 14)
                SettingInfoButton(text: "Faithful keeps your words as dictated.\nStrict removes fillers and applies clear spoken corrections.\nPolish also resolves backtracks and small grammar slips, keeping your voice.\nProfessional rewrites into clear writing of what you meant.")
                    .accessibilityLabel("About Faithful")
            }.padding(.top, 8)
            help(cleanupStyle.wrappedValue == -1
                 ? "Keeps the words as dictated, apart from dictionary spellings: “Um, let’s meet Tuesday, no, I mean, Thursday, at the cafe.”"
                 : controller.cleanupChoice == .localRules
                 ? "Local rules use Strict: “Let’s meet Thursday at the cafe.” Choose an AI cleanup route above to enable Polish or Professional."
                 : controller.cleanupProfessional
                 ? "Rewrites into clear, professional writing of what you meant: “Let’s meet on Thursday at the café.” Names, numbers and “not” stay."
                 : controller.cleanupPolish
                 ? "Also resolves backtracks and false starts, and fixes small grammar slips, keeping your voice: “Let’s meet Thursday at the cafe.”"
                 : "Removes fillers and applies clear spoken corrections, otherwise keeping your wording: “Let’s meet Thursday at the cafe.”")
                .padding(.top, 8)
            if controller.cleanupChoice != .localRules && cleanupStyle.wrappedValue >= 1 {
                toggleRow("Protect what I said", "Murmur checks each AI edit against your words and keeps your original if a name, number or “not” changes, or if something you said goes missing or something new appears. Turn off to paste the AI’s version as-is.", isOn: Binding(get: { !controller.cleanupTrustModel }, set: { controller.cleanupTrustModel = !$0 }))
                    .padding(.top, 12)
            }
        }
    }

    private var cleanup: some View {
        VStack(alignment: .leading, spacing: 0) {
            cleanupChoices
            rule.padding(.top, 20)
            toggleRow("Remove filler words", "Takes out “um”, “uh” and similar.", isOn: $controller.cleanupFillers)
            toggleRow("Apply spoken corrections", "Uses your final wording for clear corrections, including “Monday. Actually, Thursday.” Ambiguous corrections stay.", isOn: $controller.cleanupCorrections)
            toggleRow("Format spoken lists", "Turns “one, two, three” into a numbered list.", isOn: $controller.cleanupLists)
            toggleRow("Fix punctuation and capitalization", "Adds commas, periods and capitals.", isOn: $controller.cleanupPunctuation)
            toggleRow("Spoken commands and numbers", "“comma”, “new paragraph”, “two hundred thousand” → 200,000, “at the rate” → @, and “write an email to…” layout.", isOn: $controller.cleanupSpoken)
            help("If an AI rewrite is rejected, clear spoken corrections can still apply. The raw transcript stays in History.").padding(.top, 16)

            if controller.cleanupChoice == .appleIntelligence, let reason = AppleSystemModel.status() {
                help(reason.userMessage + " Until then, local rules clean dictations.").padding(.top, 8)
            }
            toggleRow("Use screen context", "AI cleanup also gets the selected text, the clipboard and the focused window's text, as reference for spelling names and terms. Never read under Secure Input, in password fields, or from clipboard items marked as passwords. Not used by On this Mac. Modes can turn it on or off.", isOn: $controller.screenContext)
                .padding(.top, 12).disabled(controller.cleanupChoice == .localRules)
            if controller.cleanupChoice == .customAPI {
                customCleanupSettings
            }
        }
    }

    private var customCleanupSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cleanup API base URL").font(WindowType.body(14, weight: .semibold))
            field("https://api.cerebras.ai/v1", text: $controller.customAPIBaseURL)
                .focused($apiFieldFocused).onSubmit(controller.settingsChanged)
            Text("Model name").font(WindowType.body(14, weight: .semibold)).padding(.top, 4)
            field("gpt-oss-120b", text: $controller.customAPIModel)
                .focused($apiFieldFocused).onSubmit(controller.settingsChanged)
            keyRow(.customCleanup)
            help("This provider needs OpenAI-compatible POST /v1/chat/completions. Its address and API key are separate from transcription. Enter the provider's exact model ID. A key is sent only over HTTPS; local endpoints can be used without one.")
        }
        .padding(.top, 16)
    }

    // MARK: Writing modes (gaps #6-#8)

    private var modes: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("How modes are chosen").font(WindowType.body(14, weight: .semibold))
                SettingInfoButton(text: "A mode is picked by a trigger word said at the start or end of a dictation, then by the website, then by the app focused when you started. If two modes match the same way, the first in this list wins. Anything a mode leaves as “Same as Cleanup” follows the Cleanup settings.")
            }.padding(.top, 12)
            rule.padding(.top, 20)
            ForEach($controller.writingModes) { $mode in
                modeRow($mode).overlay(alignment: .bottom) { softRule }
            }
            if controller.writingModes.isEmpty { help("No modes yet.").padding(.vertical, 16) }
            Button("Add Mode") {
                let mode = WritingMode(); controller.writingModes.append(mode); editingModeID = mode.id
            }
            .buttonStyle(InkButtonStyle(kind: .outline)).fixedSize().padding(.top, 16)
        }
    }

    private func modeSummary(_ mode: WritingMode) -> String {
        var parts: [String] = []
        if !mode.triggers.isEmpty { parts.append("Said: " + mode.triggers.joined(separator: ", ")) }
        if !mode.websites.isEmpty { parts.append(mode.websites.joined(separator: ", ")) }
        if !mode.apps.isEmpty { parts.append(mode.apps.map(appName).joined(separator: ", ")) }
        return parts.isEmpty ? "Matches nothing yet" : parts.joined(separator: " · ")
    }

    private func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
    }

    /// Apps dictated into since launch, then running apps, without ones already in the mode.
    private func pickableApps(excluding chosen: [String]) -> [String] {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }.compactMap(\.bundleIdentifier)
        var seen = Set(chosen)
        return (controller.recentApps + running.sorted { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }).filter { seen.insert($0).inserted }
    }

    /// Same as Cleanup (-1), Faithful (0), Strict (1), Polish (2), Professional (3).
    private func modeStyle(_ mode: Binding<WritingMode>) -> Binding<Int> {
        Binding(get: {
            guard let o = mode.wrappedValue.options else { return -1 }
            return !o.anyEnabled ? 0 : o.professional ? 3 : o.polish ? 2 : 1
        }, set: { value in
            guard value >= 0 else { mode.wrappedValue.options = nil; return }
            guard value > 0 else { mode.wrappedValue.options = .faithful; return }
            let current = mode.wrappedValue.options.flatMap { $0.anyEnabled ? $0 : nil }
            var o = current ?? CleanupOptions(fillers: controller.cleanupFillers, corrections: controller.cleanupCorrections, lists: controller.cleanupLists,
                                              punctuation: controller.cleanupPunctuation, spoken: controller.cleanupSpoken)
            if !o.anyEnabled { o = .standard } // Over Faithful settings, start from the defaults.
            o.polish = value >= 2; o.professional = value == 3
            mode.wrappedValue.options = o
        })
    }

    private func modeFlag(_ mode: Binding<WritingMode>, _ key: WritableKeyPath<CleanupOptions, Bool>) -> Binding<Bool> {
        Binding(get: { mode.wrappedValue.options?[keyPath: key] ?? false }, set: { mode.wrappedValue.options?[keyPath: key] = $0 })
    }

    @ViewBuilder private func modeRow(_ mode: Binding<WritingMode>) -> some View {
        let m = mode.wrappedValue
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.name.isEmpty ? "Untitled mode" : m.name).font(WindowType.body(16, weight: .semibold))
                    help(m.enabled ? modeSummary(m) : "Off · " + modeSummary(m)).lineLimit(2)
                }
                Spacer()
                Button(editingModeID == m.id ? "Done" : "Edit") { editingModeID = editingModeID == m.id ? nil : m.id }
                    .buttonStyle(InkButtonStyle(kind: .outline)).fixedSize()
            }
            .padding(.vertical, 12)
            if editingModeID == m.id { modeEditor(mode).padding(.bottom, 16) }
        }
    }

    private func modeEditor(_ mode: Binding<WritingMode>) -> some View {
        let m = mode.wrappedValue
        return VStack(alignment: .leading, spacing: 0) {
            field("Mode name", text: mode.name)
            toggleRow("Mode on", "When off, this mode never matches.", isOn: mode.enabled)

            eyebrow("Apps").padding(.top, 20)
            ForEach(m.apps, id: \.self) { app in
                HStack {
                    Text(appName(app)).font(WindowType.body(15)); help(app, color: Palette.ink64).font(WindowType.body(12))
                    Spacer()
                    Button("Remove") { mode.wrappedValue.apps.removeAll { $0 == app } }.buttonStyle(InkButtonStyle(kind: .plain)).fixedSize()
                }
            }
            Menu("Add App") {
                ForEach(pickableApps(excluding: m.apps), id: \.self) { app in
                    Button(appName(app)) { mode.wrappedValue.apps.append(app) }
                }
            }
            .fixedSize().padding(.top, 8)

            eyebrow("Websites").padding(.top, 20)
            ModeListEditor(items: mode.websites, placeholder: "github.com, docs.google.com/document/*, *.slack.com", label: "Website")
            help("Matches the page open in the browser when recording starts. A site includes its subdomains; add a path to match only that part. The address is read through Accessibility, only while a mode lists a website, and is never saved or sent. A browser that does not show its page to Accessibility matches by app only.", color: Palette.ink64)
                .font(WindowType.body(12)).padding(.top, 6)

            eyebrow("Trigger words").padding(.top, 20)
            ModeListEditor(items: mode.triggers, placeholder: "email mode", label: "Trigger")
            help("Say one at the start or end of a dictation to use this mode; it is removed from the text. Pick a phrase you would not otherwise say there.", color: Palette.ink64)
                .font(WindowType.body(12)).padding(.top, 6)

            eyebrow("Cleanup").padding(.top, 20)
            segmented([(-1, "Same as Cleanup"), (0, "Faithful"), (1, "Strict"), (2, "Polish"), (3, "Professional")], modeStyle(mode), size: 13).padding(.top, 8)
            if let o = m.options, o.anyEnabled {
                toggleRow("Remove filler words", "Takes out “um”, “uh” and similar.", isOn: modeFlag(mode, \.fillers))
                toggleRow("Apply spoken corrections", "Uses your final wording for clear corrections, including “Monday. Actually, Thursday.” Ambiguous corrections stay.", isOn: modeFlag(mode, \.corrections))
                toggleRow("Format spoken lists", "Turns “one, two, three” into a numbered list.", isOn: modeFlag(mode, \.lists))
                toggleRow("Fix punctuation and capitalization", "Adds commas, periods and capitals.", isOn: modeFlag(mode, \.punctuation))
                toggleRow("Spoken commands and numbers", "“comma”, “new paragraph”, numbers as digits, “at the rate” → @.", isOn: modeFlag(mode, \.spoken))
            }

            eyebrow("Tone").padding(.top, 20)
            segmented(Tone.allCases.map { ($0, $0.displayName) }, mode.tone, size: 13).padding(.top, 8)
            help(m.tone == .formal ? "Text stays as cleanup wrote it."
                 : m.tone == .casual ? "Drops commas and the final period. Commas inside numbers stay."
                 : m.tone == .veryCasual ? "Casual, and sentences start in lowercase. “I” and words like “iPhone” keep their capitals."
                 : "The final period becomes “!”.", color: Palette.ink64)
                .font(WindowType.body(12)).padding(.top, 6)
            help("Applied by rules after cleanup, on every route. Never applied to an email laid out from “write an email to…”.", color: Palette.ink64)
                .font(WindowType.body(12))

            eyebrow("Screen context").padding(.top, 20)
            segmented([(Bool?.none, "Same as Cleanup"), (true, "On"), (false, "Off")], mode.screenContext, size: 13).padding(.top, 8)

            eyebrow("Custom instructions").padding(.top, 20)
            TextEditor(text: Binding(get: { m.instructions }, set: { mode.wrappedValue.instructions = String($0.prefix(WritingModeLimits.instructions)) }))
                .font(WindowType.body(15)).scrollContentBackground(.hidden)
                .frame(minHeight: 72).padding(8).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.ink20, lineWidth: 1))
                .accessibilityLabel("Custom instructions").padding(.top, 8)
            help("\(m.instructions.count) of \(WritingModeLimits.instructions) characters. Sent only to AI cleanup routes, never used by On this Mac. They cannot make cleanup add content: Murmur still checks the result against what you said.", color: Palette.ink64)
                .font(WindowType.body(12)).padding(.top, 6)

            Button("Delete Mode", role: .destructive) {
                controller.writingModes.removeAll { $0.id == m.id }; editingModeID = nil
            }
            .buttonStyle(InkButtonStyle(kind: .outline)).fixedSize().padding(.top, 20)
        }
    }

    /// Download row for live words (gap #13), shown while the setting is on.
    private var liveWordsModel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text("Parakeet Unified streaming").font(WindowType.body(14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                        ModelInfoIcons(license: controller.liveWordsLicense.map(ModelFacts.licenseText), details: controller.liveWordsSummary)
                    }
                    if controller.liveWordsRow.isReady { mono("Ready ✓", color: Palette.accentInk) }
                    else { Text(controller.liveWordsRow.statusText).font(WindowType.body(13)).foregroundStyle(Palette.ink70).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer()
                let row = controller.liveWordsRow
                if row.actions.contains(.download) { Button("Download…", action: controller.downloadLiveWords).buttonStyle(InkButtonStyle()).fixedSize() }
                if row.actions.contains(.retry) { Button("Retry…", action: controller.downloadLiveWords).buttonStyle(InkButtonStyle()).fixedSize() }
                if row.actions.contains(.cancel) { Button("Cancel", action: controller.cancelLiveWordsDownload).buttonStyle(InkButtonStyle(kind: .outline)).fixedSize() }
                if row.actions.contains(.remove) { Button("Remove…", role: .destructive, action: controller.removeLiveWords).buttonStyle(InkButtonStyle(kind: .outline)).fixedSize() }
            }
            if let progress = controller.liveWordsRow.progress { progressBar(progress) }
            if !controller.liveWordsMessage.isEmpty { help(controller.liveWordsMessage) }
        }
    }

    /// Download row for dictionary support in on-device transcription (the CTC model).
    private var dictionaryModel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(DictionaryModelFacts.displayName).font(WindowType.body(18, weight: .semibold))
                        ModelInfoIcons(license: controller.dictionaryModelLicense.map(ModelFacts.licenseText), details: controller.dictionaryModelSummary)
                    }
                    Group {
                        if controller.dictionaryModelRow.isReady && !controller.dictionarySupportFailed { mono("Ready ✓", color: Palette.accentInk) }
                        else if !controller.dictionaryModelRow.isReady { Text(controller.dictionaryModelRow.statusText).font(WindowType.body(14, weight: .semibold)).fixedSize(horizontal: false, vertical: true) }
                    }
                    .padding(.top, 5)
                }
                Spacer()
                let row = controller.dictionaryModelRow
                if row.actions.contains(.download) { Button("Download…", action: controller.downloadDictionaryModel).buttonStyle(InkButtonStyle()).fixedSize() }
                if row.actions.contains(.retry) { Button("Retry…", action: controller.downloadDictionaryModel).buttonStyle(InkButtonStyle()).fixedSize() }
                if row.actions.contains(.cancel) { Button("Cancel", action: controller.cancelDictionaryModelDownload).buttonStyle(InkButtonStyle(kind: .outline)).fixedSize() }
                if row.actions.contains(.remove) { Button("Remove…", role: .destructive, action: controller.removeDictionaryModel).buttonStyle(InkButtonStyle(kind: .outline)).fixedSize() }
            }
            help(DictionaryModelFacts.explanation)
            if let progress = controller.dictionaryModelRow.progress { progressBar(progress) }
            if controller.dictionarySupportFailed { Text(DictionaryModelFacts.unavailableMessage).font(WindowType.body(14, weight: .semibold)).fixedSize(horizontal: false, vertical: true) }
            if !controller.dictionaryModelMessage.isEmpty { help(controller.dictionaryModelMessage) }
        }
        .padding(.vertical, 18).padding(.top, 20)
    }

    private var dictionary: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                field("Preferred spelling", text: $newPreferred).frame(minWidth: 100, idealWidth: 180, maxWidth: 220).onSubmit(addEntry)
                field("Heard as (optional)", text: $newVariants).help("Separate alternate spellings with commas.").onSubmit(addEntry)
                Button("Add", action: addEntry)
                    .buttonStyle(InkButtonStyle(kind: newPreferred.trimmingCharacters(in: .whitespaces).isEmpty ? .outline : .filled)).fixedSize()
                    .disabled(newPreferred.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 20)
            if !controller.dictionaryMessage.isEmpty {
                Text(controller.dictionaryMessage).font(WindowType.body(14, weight: .semibold)).padding(.top, 10)
            }
            VStack(alignment: .leading, spacing: 0) {
                if controller.dictionaryEntries.isEmpty {
                    help("No words yet. Add names and jargon Murmur gets wrong.").padding(.vertical, 16)
                }
                ForEach(controller.dictionaryEntries) { entry in
                    Group { if editingEntryID == entry.id { dictionaryEditRow(entry) } else { dictionaryRow(entry) } }
                        .frame(minHeight: 56).padding(.vertical, 4).overlay(alignment: .bottom) { softRule }
                }
            }
            .overlay(alignment: .top) { rule }.padding(.top, 20)
            if !controller.blockedWords.isEmpty {
                eyebrow("Not learned").padding(.top, 24)
                help("Skipped because your fixes conflicted or were undone.").padding(.top, 4)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.blockedWords, id: \.self) { item in blockedRow(item).overlay(alignment: .bottom) { softRule } }
                }
                .overlay(alignment: .top) { rule }.padding(.top, 12)
            }
            HStack {
                help("“Heard as” forms are always replaced. With cleanup on, sound-alikes get fixed too. Edits save immediately.")
                Spacer()
                Button("Reset Learned…", role: .destructive, action: controller.resetLearnedEntries).buttonStyle(InkButtonStyle(kind: .outline))
                    .disabled(!controller.dictionaryEntries.contains { $0.source == .learned } && controller.blockedWords.isEmpty)
            }
            .padding(.top, 16)
            rule.padding(.top, 24)
            toggleRow("Learn from my corrections", "Fix a misheard word once, within a minute, and Murmur adds it to your dictionary and fixes it from your next dictation. Where an app hides its text, it follows your keys for that minute; raw keys stay in memory.", isOn: $controller.learningEnabled)
            toggleRow("Limit learning to readable fields", "No keystroke learning in editors Murmur can't read. Add those words by hand.", isOn: $controller.learningRequiresReadableField)
            DisclosureGroup("On-device dictionary support") {
                dictionaryModel
            }
            .font(WindowType.body(14)).padding(.top, 16)
        }
    }

    private func addEntry() {
        guard !newPreferred.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if controller.addDictionaryEntry(preferred: newPreferred, variants: newVariants) { newPreferred = ""; newVariants = "" }
    }

    private func dictionaryRow(_ entry: DictionaryEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.preferred).font(WindowType.body(16, weight: .semibold))
                if !entry.variants.isEmpty {
                    Text("Heard as " + entry.variants.joined(separator: ", ")).font(WindowType.body(13)).foregroundStyle(Palette.ink70).lineLimit(1)
                }
            }
            .opacity(entry.enabled ? 1 : 0.45)
            Spacer()
            mono(entry.source == .learned ? "Learned" : "Manual", size: 11, color: Palette.accentDeep)
                .padding(.horizontal, 8).padding(.vertical, 3).background(Palette.accent16)
            Toggle(isOn: Binding(get: { entry.enabled }, set: { on in
                controller.updateDictionaryEntry(entry, preferred: entry.preferred, variants: entry.variants.joined(separator: ", "), enabled: on)
            })) { EmptyView() }
                .toggleStyle(MurmurToggleStyle()).fixedSize().accessibilityLabel("Use \(entry.preferred)")
            Button("Edit") {
                editPreferred = entry.preferred; editVariants = entry.variants.joined(separator: ", ")
                controller.dictionaryMessage = ""; editingEntryID = entry.id
            }
            .buttonStyle(.plain).font(WindowType.body(14, weight: .semibold)).frame(height: 44).accessibilityLabel("Edit \(entry.preferred)")
            Button { controller.deleteDictionaryEntry(entry) } label: {
                Text("×").font(WindowType.body(18)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Delete \(entry.preferred)").accessibilityLabel("Delete \(entry.preferred)")
        }
    }

    private func blockedRow(_ item: CorrectionLedger.Blocked) -> some View {
        let (word, why): (String, String) = switch item {
        case .heard(let source): (source, "Fixes for this heard form are not learned")
        case .spelling(let target): (target, "This spelling is not learned")
        }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(word).font(WindowType.body(16, weight: .semibold))
                Text(why).font(WindowType.body(13)).foregroundStyle(Palette.ink70)
            }
            Spacer()
            Button("Unblock") { controller.unblockWord(item) }.buttonStyle(InkButtonStyle(kind: .outline)).fixedSize()
                .accessibilityLabel("Unblock \(word)")
        }
        .frame(minHeight: 56).padding(.vertical, 4)
    }

    private func dictionaryEditRow(_ entry: DictionaryEntry) -> some View {
        let save = {
            if controller.updateDictionaryEntry(entry, preferred: editPreferred, variants: editVariants, enabled: entry.enabled) { editingEntryID = nil }
        }
        return HStack(spacing: 8) {
            field("Preferred spelling", text: $editPreferred).frame(minWidth: 100, idealWidth: 160, maxWidth: 220).onSubmit(save)
            field("Heard as, comma-separated (optional)", text: $editVariants).onSubmit(save)
            Button("Save", action: save).buttonStyle(InkButtonStyle(kind: .filled)).fixedSize()
                .disabled(editPreferred.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { controller.dictionaryMessage = ""; editingEntryID = nil }.buttonStyle(InkButtonStyle(kind: .outline)).fixedSize()
                .keyboardShortcut(.cancelAction)
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow("Transcript history").padding(.top, 20)
            segmented([(HistoryMode.on, "Save on this Mac"), (HistoryMode.off, "Off")], $controller.historyMode).padding(.top, 8)
            help(controller.historyMode == .on
                 ? "Completed transcripts are saved before insertion, so you can copy them if typing fails. No cloud sync."
                 : HistoryMode.offDisclosure).padding(.top, 12)
            eyebrow("Keep transcripts for").padding(.top, 28)
            segmented([("30-days", "30 days"), ("six-months", "Six months"), ("forever", "Forever")], $controller.retention).padding(.top, 8)
            if let notice = controller.historyNotice {
                Text(notice).font(WindowType.body(14, weight: .semibold)).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            if let warning = controller.historyCapWarning {
                Text(warning).font(WindowType.body(14, weight: .semibold)).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            if controller.hasRecoveryAudio {
                Button("Show Retained Audio…", action: controller.revealRecoveryAudio)
                    .buttonStyle(InkButtonStyle(kind: .outline)).padding(.top, 20)
                help("Failed recordings stay on this Mac for up to 24 hours.").padding(.top, 8)
            }
            HStack(spacing: 20) {
                titled("Delete all data", DeleteAllDataText.explanation)
                Spacer()
                Button("Delete All Data…", role: .destructive, action: controller.deleteAllData).buttonStyle(InkButtonStyle())
            }
            .padding(.vertical, 18).padding(.top, 36).id("delete-data")
        }
    }

    private var apiKeys: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(KeyText.providers, id: \.self) { provider in keyRow(provider) }
            }
            .overlay(alignment: .top) { rule }.padding(.top, 20)
            help("Keys are stored in your Keychain and never shown again after saving. Custom transcription and cleanup use separate server addresses and API keys.").padding(.top, 16)
        }
    }

    private func keyRow(_ provider: ProviderID) -> some View {
        let has = controller.savedKeys.contains(provider), open = openKey == provider
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.displayName).font(WindowType.body(16, weight: .semibold))
                    mono(has ? "Saved in Keychain ✓" : KeyText.none, color: has ? Palette.accentInk : Palette.ink70)
                }
                Spacer()
                if has {
                    Button("Validate") { controller.validateKey(provider) }.buttonStyle(InkButtonStyle(kind: .outline))
                }
                if has { Button("Remove", role: .destructive) { controller.removeKey(provider) }.buttonStyle(InkButtonStyle(kind: .outline)) }
                Button(open ? "Cancel" : has ? "Replace" : "Add Key") { keyDraft = ""; openKey = open ? nil : provider }
                    .buttonStyle(InkButtonStyle())
            }
            if open {
                HStack(spacing: 8) {
                    field("Paste your \(provider.displayName) API key", text: $keyDraft, secure: true)
                    Button("Save Key") { if controller.saveKey(provider, keyDraft) { keyDraft = ""; openKey = nil } }
                        .buttonStyle(InkButtonStyle(kind: .accent)).disabled(keyDraft.isEmpty)
                }
            }
            if provider == .customTranscription || provider == .customCleanup {
                let address = provider == .customTranscription ? controller.customTranscriptionAPIBaseURL : controller.customAPIBaseURL
                help("Server address: \(address)")
                if controller.customAPIKeyNeedsConfirmation(provider) {
                    help("Save the API key again to confirm this server address. The existing key stays in Keychain and will not be sent until confirmed.", color: Palette.accentInk)
                }
            }
            if let message = controller.keyMessages[provider], !message.isEmpty { help(message) }
        }
        .padding(.vertical, 16).overlay(alignment: .bottom) { softRule }
    }

    private var updates: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Murmur " + controller.currentVersion).font(WindowType.body(18, weight: .semibold))
                    if !controller.updateStatus.isEmpty { help(controller.updateStatus) }
                }
                Spacer()
                Button("Check for Updates", action: controller.checkForUpdates).buttonStyle(InkButtonStyle())
            }
            .padding(.vertical, 18).padding(.top, 20)
            toggleRow("Check automatically", UpdateText.explanation, isOn: $controller.updateChecksEnabled)
            toggleRow("Install updates automatically", "Download verified updates in the background. Installation waits until dictation and meeting recording finish.", isOn: $controller.installUpdatesAutomatically)
        }
    }

    // MARK: History

    private var visibleHistory: [HistoryEntry] {
        controller.history.filter { entry in
            searchText.isEmpty || entry.finalText.localizedCaseInsensitiveContains(searchText) || entry.rawText.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Consecutive entries from the same day, in history order (newest first).
    private var historyGroups: [(day: String, entries: [HistoryEntry])] {
        var groups: [(day: String, entries: [HistoryEntry])] = []
        for entry in visibleHistory {
            let calendar = Calendar.current, date = entry.recordedAt
            // Grouped by the full date; the year shows only when it is not this year.
            let day = calendar.isDateInToday(date) ? "Today"
                : calendar.isDateInYesterday(date) ? "Yesterday"
                : calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? date.formatted(.dateTime.month(.abbreviated).day())
                : date.formatted(.dateTime.month(.abbreviated).day().year())
            if let last = groups.last?.entries.first, calendar.isDate(last.recordedAt, inSameDayAs: date) { groups[groups.count - 1].entries.append(entry) } else { groups.append((day, [entry])) }
        }
        return groups
    }

    private var history: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("History").font(WindowType.display(64)).tracking(-1.28)
                help(controller.historySummary)
                HStack(spacing: 8) {
                    field("Search transcripts", text: $searchText)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).foregroundStyle(Palette.ink70).accessibilityLabel("Clear search")
                    }
                }
            }
            .padding(EdgeInsets(top: 16, leading: 24, bottom: 16, trailing: 24))
            .overlay(alignment: .bottom) { rule }

            ScrollView {
                let groups = historyGroups
                LazyVStack(spacing: 0) {
                    if groups.isEmpty {
                        VStack(spacing: 8) {
                            Text(controller.history.isEmpty ? "Your dictation appears here" : "No matching transcripts").font(WindowType.body(26, weight: .semibold))
                            help(controller.history.isEmpty ? "Completed transcripts are saved here before they are inserted." : "Try a different search.")
                            if controller.history.isEmpty && !setupComplete {
                                Button("Set Up Murmur") { screen = .setup }.buttonStyle(InkButtonStyle()).padding(.top, 8)
                            }
                        }
                        .padding(.vertical, 80).frame(maxWidth: .infinity)
                    }
                    ForEach(groups.indices, id: \.self) { index in
                        let group = groups[index]
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                mono(group.day)
                                mono(group.entries.count == 1 ? "1 entry" : "\(group.entries.count) entries", color: Palette.ink64)
                            }
                            .frame(width: 80, alignment: .leading).padding(.top, 14)
                            VStack(spacing: 0) {
                                ForEach(group.entries) { entry in historyRow(entry) }
                            }
                        }
                        .padding(.vertical, 24).overlay(alignment: .bottom) { rule }
                    }
                }
                .padding(.horizontal, 24)
            }

            HStack {
                help(controller.historyMode == .on ? "Saved on this Mac only. \(retentionText)" : controller.historySummary)
                Spacer()
                Button("Clear History…", role: .destructive, action: controller.clearHistory).buttonStyle(InkButtonStyle(kind: .outline))
                    .disabled(controller.history.isEmpty)
            }
            .padding(.horizontal, 24).frame(height: 56).overlay(alignment: .top) { rule }
        }
    }

    private var retentionText: String {
        switch controller.retention {
        case "six-months": return "Kept for six months."
        case "forever": return "Kept forever."
        default: return "Kept for 30 days."
        }
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        let open = selectedID == entry.id, attention = Self.needsAttention(entry.insertionStatus)
        let note = controller.sessionOnlyIDs.contains(entry.id) ? HistoryText.sessionOnlyNote : Self.statusNote(entry.insertionStatus)
        return VStack(alignment: .leading, spacing: 0) {
            Button { selectedID = open ? nil : entry.id } label: {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink70)
                        .frame(width: 12).padding(.top, 5).accessibilityHidden(true)
                    Text(entry.recordedAt, format: .dateTime.hour().minute())
                        .font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.ink70).lineLimit(1).fixedSize().frame(width: 72, alignment: .leading).padding(.top, 2)
                    Text((entry.finalText.isEmpty ? entry.rawText : entry.finalText).replacingOccurrences(of: "\n", with: " "))
                        .font(WindowType.body(16)).lineSpacing(2).lineLimit(open ? 1 : 2).frame(maxWidth: .infinity, alignment: .leading)
                    if let label = Self.statusLabel(entry.insertionStatus) {
                        mono(label, size: 11, color: attention ? Palette.paper : Palette.accentDeep)
                            .lineLimit(1).fixedSize().padding(.horizontal, 8).padding(.vertical, 3)
                            .background(attention ? Palette.ink : Palette.accent16)
                    }
                }
                .padding(.vertical, 12).frame(minHeight: 56).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityAddTraits(open ? .isSelected : [])
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            .accessibilityHint("Show or hide transcript and recovery actions")
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    if let note {
                        Text(note).font(WindowType.body(14)).foregroundStyle(Palette.ink80).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.accent16).padding(.bottom, 16)
                    }
                    eyebrow("Final text")
                    if editingTextID == entry.id {
                        TextEditor(text: $textDraft).font(WindowType.body(16)).scrollContentBackground(.hidden)
                            .frame(minHeight: 88).padding(8).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.ink20, lineWidth: 1))
                            .accessibilityLabel("Final text").padding(.top, 6)
                        HStack(spacing: 8) {
                            Button("Save") { if controller.editEntryText(entry, to: textDraft) { editingTextID = nil } }
                                .buttonStyle(InkButtonStyle(kind: .filled)).fixedSize()
                                .disabled(textDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Cancel") { editingTextID = nil }.buttonStyle(InkButtonStyle(kind: .outline)).fixedSize()
                                .keyboardShortcut(.cancelAction)
                        }.padding(.top, 8)
                        Text("Murmur learns misheard words from your fix, as it does from edits after insertion.")
                            .font(WindowType.body(13)).foregroundStyle(Palette.ink64).padding(.top, 8)
                    } else {
                        Text(entry.finalText.isEmpty ? "No final text saved." : entry.finalText).font(WindowType.body(16)).lineSpacing(3)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }
                    if let line = Self.outcomeNote(entry) {
                        Text(line).font(WindowType.body(13)).foregroundStyle(Palette.ink64).padding(.top, 6)
                    }
                    if entry.rawText != entry.finalText {
                        eyebrow("Raw transcription").padding(.top, 16)
                        Text(entry.rawText).font(WindowType.body(15)).lineSpacing(3).foregroundStyle(Palette.ink70)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }
                    let actions = Group {
                        if !entry.finalText.isEmpty {
                            Button(copiedID == entry.id + "f" ? "Copied ✓" : "Copy Text") { controller.copyEntry(entry); flashCopied(entry.id + "f") }
                                .buttonStyle(InkButtonStyle())
                        }
                        if entry.rawText != entry.finalText {
                            Button(copiedID == entry.id + "r" ? "Copied ✓" : "Copy Raw") { controller.copyRawEntry(entry); flashCopied(entry.id + "r") }
                                .buttonStyle(InkButtonStyle(kind: .outline))
                        }
                        if !entry.finalText.isEmpty && editingTextID != entry.id {
                            Button("Edit") { textDraft = entry.finalText; editingTextID = entry.id }.buttonStyle(InkButtonStyle(kind: .outline))
                                .accessibilityLabel("Edit final text")
                        }
                        Button("Delete", role: .destructive) { controller.deleteEntry(entry) }.buttonStyle(InkButtonStyle(kind: .plain))
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { actions }.fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 8) { actions }
                    }
                    .padding(.top, 18)
                    Text("Copying never retries insertion or sends a message.").font(WindowType.body(13)).foregroundStyle(Palette.ink64).padding(.top, 10)
                }
                .padding(.top, 4).padding(.bottom, 20)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.ink45).frame(height: 1) }
    }

    private func flashCopied(_ id: String) {
        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copiedID == id { copiedID = nil } }
    }

    static func needsAttention(_ status: String) -> Bool {
        ["insertion-pending", "failed", "held-cleanup", "held-transcript"].contains(status)
    }

    static func statusLabel(_ status: String) -> String? {
        switch status {
        case "verified", "unverified": return nil
        case "insertion-pending": return "Saved"
        case "failed": return "Not inserted"
        case "copied": return "Copied"
        case "held-cleanup": return "Cleanup held"
        case "held-transcript": return "Held for review"
        default: return "Saved"
        }
    }

    static func statusNote(_ status: String) -> String? {
        switch status {
        case "insertion-pending": return "Murmur stopped before saving the delivery result. Check the destination before copying this text to avoid a duplicate."
        case "failed": return "Murmur could not paste this text. It is saved here so you can copy it."
        case "held-cleanup": return "Cleanup changed too much, so only the raw transcript was saved and nothing was inserted."
        case "held-transcript": return "The transcript was held for review, so nothing was inserted."
        default: return nil
        }
    }

    /// Which path wrote the final text, in one line; nil for entries saved before it was recorded.
    static func outcomeNote(_ entry: HistoryEntry) -> String? {
        guard let outcome = entry.cleanupOutcome else { return nil }
        let kind = entry.cleanupOptions?.professional == true ? "Professional rewrite" : entry.cleanupOptions?.polish == true ? "Polish" : "AI cleanup"
        let failed = entry.cleanupFallback == nil || entry.cleanupFallback == CleanupFailureReason.cleanerFailed.rawValue
        // "unexplainedDeletion" -> "unexplained deletion"
        let why = failed ? "" : " (" + (entry.cleanupFallback ?? "").map { $0.isUppercase ? " " + $0.lowercased() : String($0) }.joined() + ")"
        let edited = entry.edited == true ? " Edited since." : ""
        switch outcome {
        case .off: return "Cleanup off; dictionary only." + edited
        case .modelAccepted: return "\(kind) applied." + edited
        case .modelPunctuationOnLocal: return "\(kind) rejected\(why); AI punctuation applied to local cleanup." + edited
        case .localRules: return "\(kind) \(failed ? "failed" : "rejected")\(why); local cleanup used." + edited
        case .localRoute: return "Local cleanup on this Mac." + edited
        }
    }

    // MARK: Welcome guide (gap #21)

    private var shortcutName: String { controller.shortcutName }

    /// The guide's permission and model steps; the last step is the test dictation.
    private var guideSteps: [(title: String, detail: String, done: Bool, action: String, run: () -> Void)] {
        [
            ("Microphone", "So Murmur can hear you while the shortcut is held. Audio stays on this Mac unless you choose a cloud route.", controller.microphoneAuthorized, "Allow", controller.requestMicrophone),
            ("Accessibility", "So Murmur can paste into the field you are using. It never presses Return or sends a message.", controller.accessibilityAuthorized, "Open Settings…", { controller.openPermissionSettings("accessibility") }),
            ("Input Monitoring", "So the shortcut works in every app. Murmur listens only for the shortcut, Escape and its two ⌃⌘ chords.", controller.inputMonitoringAuthorized, "Open Settings…", { controller.openPermissionSettings("input-monitoring") }),
            ("Transcription", "Choose where dictation audio is transcribed. Cloud routes send audio to the provider shown below.", WelcomeGuide.isConfirmed(.transcription, .standard), "", {}),
            ("Cleanup", "Choose where cleanup runs and how much it changes your words. Faithful keeps cleanup off.", WelcomeGuide.isConfirmed(.cleanup, .standard), "", {}),
            ("Meetings", "Choose meeting transcription separately from dictation, then choose how meeting notes are written. None keeps only the transcript.", WelcomeGuide.isConfirmed(.meetings, .standard), "", {}),
            ("Speech model", controller.transcriptionRoute == .cloud && controller.meetingTranscription == .cloud && !controller.modelRow.isReady ? "Not needed while dictation and meeting transcription both run in the cloud." : ModelFacts.displayName, controller.modelRow.isReady || (controller.transcriptionRoute == .cloud && controller.meetingTranscription == .cloud),
             controller.modelRow.actions.contains(.retry) ? "Retry…" : "Download…", controller.downloadModel),
            ("Try it", "Press \(controller.shortcutName) and say a sentence. With this window in front, your words land in the field below instead of another app.", !controller.setupTestTranscript.isEmpty, "", {})
        ]
    }

    /// Test dictation uses the routes and cleanup style chosen earlier in the guide.
    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !setupComplete { help("Finish the earlier steps first; dictation needs all of them.", color: Palette.ink).padding(.bottom, 12) }
            TextEditor(text: $controller.setupTestTranscript)
                .font(WindowType.body(16)).scrollContentBackground(.hidden)
                .frame(minHeight: 96).padding(8)
                .overlay(alignment: .topLeading) {
                    if controller.setupTestTranscript.isEmpty {
                        Text("Waiting for your voice…").font(WindowType.body(16)).foregroundStyle(Palette.ink64)
                            .padding(.top, 8).padding(.leading, 13).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.ink20, lineWidth: 1))
                .accessibilityLabel("Test dictation")
        }
        .onAppear { controller.setupShowing = true }
        .onDisappear { controller.setupShowing = false }
    }

    private func finishGuide() {
        if let pending = WelcomeGuide.nextUnconfirmed(.standard) { guideStep = pending; return }
        WelcomeGuide.complete(.standard); guideStep = .microphone; screen = .home
    }

    private var setup: some View {
        let steps = guideSteps
        let index = WelcomeGuide.Step.allCases.firstIndex(of: guideStep)!, step = steps[index]
        let last = guideStep == .tryIt
        return GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    eyebrow("Welcome guide · Step \(index + 1) of \(steps.count)")
                    VStack(alignment: .leading, spacing: -8) {
                        Text("Set up").font(WindowType.display(64)).tracking(-1.28)
                        wordmark("Murmur", size: 48)
                    }
                    .accessibilityElement(children: .combine).padding(.top, 16)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(steps.indices, id: \.self) { i in
                                let on = i == index
                                Button { guideStep = WelcomeGuide.Step.allCases[i] } label: {
                                    HStack(spacing: 12) {
                                        mono(String(format: "%02d", i + 1), size: 12, color: Palette.ink70)
                                        mono(steps[i].title, size: 12, color: Palette.ink)
                                        Spacer()
                                        if steps[i].done { mono("✓", size: 12, color: Palette.accentInk) }
                                    }
                                    .frame(height: 40)
                                    .overlay(alignment: .bottom) { Rectangle().fill(on ? Palette.accentInk : Color.clear).frame(height: 2) }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                    }
                    .padding(.top, 28)
                    Spacer()
                    Logo.path(in: CGSize(width: 48, height: 48)).fill(Palette.ink)
                        .frame(width: 48, height: 48).accessibilityHidden(true)
                }
                .padding(24).frame(width: geometry.size.width * 5 / 12, alignment: .leading).frame(maxHeight: .infinity, alignment: .top)
                .background(Palette.paper)

                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            mono(String(format: "%02d", index + 1), size: 13, color: Palette.accentInk)
                            Text(step.title).font(WindowType.display(64)).tracking(-1.28).padding(.top, 8)
                            HStack(alignment: .top, spacing: 4) {
                                help(step.detail)
                                if guideStep == .model {
                                    ModelInfoIcons(license: controller.modelLicense.map(ModelFacts.licenseText), details: controller.modelSummary)
                                }
                            }.padding(.top, 10)
                            Group {
                                if guideStep == .transcription { transcriptionRoutes }
                                else if guideStep == .cleanup {
                                    cleanupChoices
                                    if controller.cleanupChoice == .customAPI { customCleanupSettings }
                                    if controller.cleanupChoice == .appleIntelligence, let reason = AppleSystemModel.status() { help(reason.userMessage).padding(.top, 12) }
                                    if controller.cleanupChoice == .gemini { keyRow(.gemini).padding(.top, 12) }
                                    disclosure(controller.routeDisclosure(.cleanup)).padding(.top, 12)
                                }
                                else if guideStep == .meetings {
                                    meetingRoutes
                                    if controller.meetingTranscription == .cloud {
                                        cloudTranscriptionSettings
                                        disclosure(controller.meetingCloudNote?.disclosure).padding(.top, 12)
                                    }
                                    help("Cloud meetings use the provider configured in the Transcription step. Notes use the cleanup provider configuration.").padding(.top, 12)
                                    if controller.meetingNotesRoute == .gemini { keyRow(.gemini).padding(.top, 12) }
                                    if controller.meetingNotesRoute == .customAPI { customCleanupSettings }
                                }
                                else if last { tryIt }
                                else {
                                    let working = guideStep == .model && controller.modelRow.isWorking
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack(spacing: 14) {
                                            if step.done { mono("Done ✓", color: Palette.accentInk) }
                                            else if working { Button("Cancel", action: controller.cancelModelDownload).buttonStyle(InkButtonStyle(kind: .outline)) }
                                            else { Button(step.action, action: step.run).buttonStyle(InkButtonStyle()) }
                                            Spacer()
                                        }
                                        if working {
                                            help(controller.modelRow.statusText)
                                            if let progress = controller.modelRow.progress { progressBar(progress) }
                                        }
                                        if guideStep == .model && !controller.modelMessage.isEmpty { help(controller.modelMessage) }
                                        if guideStep == .inputMonitoring || guideStep == .accessibility {
                                            help("After you allow Murmur in System Settings, come back here; this page updates on its own.", color: Palette.ink64)
                                        }
                                    }
                                }
                            }
                            .padding(.top, 24)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 8) {
                        if index > 0 { Button("← Back") { guideStep = WelcomeGuide.Step.allCases[index - 1] }.buttonStyle(InkButtonStyle(kind: .outline)) }
                        Button("Not Now") { screen = .home }.buttonStyle(InkButtonStyle(kind: .plain))
                        Spacer()
                        if last {
                            Button(WelcomeGuide.nextUnconfirmed(.standard) == nil ? "Finish" : "Review Choices →") { finishGuide() }.buttonStyle(InkButtonStyle(kind: .filled))
                        } else {
                            Button(guideStep.isConfiguration ? "Use These Settings →" : step.done ? "Continue →" : "Skip for Now →") {
                                if guideStep == .meetings && controller.meetingNotesRoute == nil { controller.meetingNotesRoute = MeetingNotesRoute.none }
                                WelcomeGuide.confirm(guideStep, .standard)
                                controller.settingsChanged()
                                guideStep = WelcomeGuide.Step.allCases[index + 1]
                            }
                                .buttonStyle(InkButtonStyle(kind: step.done ? .filled : .outline))
                        }
                    }
                    .padding(.top, 24)
                }
                .padding(24)
            }
        }
    }
}

// MARK: - Home and Insights (gap #19)

extension SettingsView {
    private func page<Content: View>(_ title: String, _ lede: String, @ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(WindowType.display(64)).tracking(-1.28)
                Text(lede).font(WindowType.body(16)).foregroundStyle(Palette.ink70).padding(.top, 10)
                content()
            }
            .padding(EdgeInsets(top: 16, leading: 24, bottom: 24, trailing: 24))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var home: some View {
        page("Home", "Dictate anywhere the cursor is.") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                help("Transcription: \(controller.transcriptionRoute == .local ? "On this Mac" : controller.cloudTranscriber.displayName) · Cleanup: \(controller.cleanupChoice.displayName)")
                SettingInfoButton(text: ([controller.routeDisclosure(.transcription), controller.routeDisclosure(.cleanup)].compactMap { $0 } + ["On-device routes process data on this Mac. Custom providers use the server configured in Settings."]).joined(separator: "\n\n"))
                    .accessibilityLabel("Where dictation data goes")
            }.padding(.top, 12)
            HStack(spacing: 4) {
                eyebrow("Shortcut")
                SettingInfoButton(text: controller.pressToToggle ? "Press to start, press again to stop. Escape cancels." : "Hold to record, or double-press to keep recording until you press again. Escape cancels.")
                    .accessibilityLabel("How to use the shortcut")
            }.padding(.top, 28)
            HStack(alignment: .center, spacing: 20) {
                Text(controller.shortcutName).font(WindowType.body(28, weight: .bold)).tracking(-0.8)
                Spacer()
                if controller.phase == "Listening" {
                    Button("Finish Dictation", action: controller.stopRecording).buttonStyle(InkButtonStyle(kind: .filled))
                } else {
                    Button("Start Dictation", action: controller.startDictationFromHome).buttonStyle(InkButtonStyle(kind: .filled))
                        .disabled(!setupComplete || controller.isBusy)
                        .help("Murmur steps aside so your words go to the app you were using. Press the shortcut to finish.")
                }
            }
            .padding(.vertical, 18).padding(.top, 8)
            HStack(alignment: .center, spacing: 20) {
                HStack(spacing: 4) {
                    Text("Meeting notes").font(WindowType.body(17, weight: .semibold))
                    SettingInfoButton(text: controller.meetingRecorder.live == nil ? "Transcribe a call on this Mac: your microphone as Me, the call’s audio as Them." : "Recording now. The live panel shows the transcript.")
                        .accessibilityLabel("About meeting notes")
                }
                Spacer()
                if controller.meetingRecorder.live == nil { MeetingStartMenu(controller: controller) }
                else { Button("Open Meetings") { screen = .meetings }.buttonStyle(InkButtonStyle(kind: .outline)) }
            }
            .padding(.vertical, 18).padding(.top, 16)

            HStack(alignment: .firstTextBaseline) {
                eyebrow("Ready to dictate")
                Spacer()
                if !setupComplete { Button("Open Welcome Guide") { screen = .setup }.buttonStyle(InkButtonStyle(kind: .plain)) }
            }
            .padding(.top, 28)
            VStack(spacing: 0) {
                permissionRow("Microphone", allowed: controller.microphoneAuthorized, actionTitle: "Allow", action: controller.requestMicrophone)
                permissionRow("Accessibility", allowed: controller.accessibilityAuthorized, actionTitle: "Open Settings…") { controller.openPermissionSettings("accessibility") }
                permissionRow("Input Monitoring", allowed: controller.inputMonitoringAuthorized, actionTitle: "Open Settings…") { controller.openPermissionSettings("input-monitoring") }
                permissionRow("Speech model", allowed: modelSatisfied, actionTitle: "Open Transcription") { section = 1; screen = .settings }
            }
            .overlay(alignment: .top) { rule }.padding(.top, 8)

            HStack(alignment: .firstTextBaseline) {
                eyebrow("Recent dictations")
                Spacer()
                if !controller.history.isEmpty { Button("Show All in History →") { screen = .history }.buttonStyle(InkButtonStyle(kind: .plain)) }
            }
            .padding(.top, 28)
            VStack(spacing: 0) {
                if controller.history.isEmpty {
                    help(controller.historyMode == .on ? "Nothing yet. Your dictations appear here and in History." : "History is off, so dictations are kept only until Murmur quits.")
                        .padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(controller.history.prefix(5)) { entry in
                    Button { selectedID = entry.id; searchText = ""; screen = .history } label: {
                        HStack(alignment: .top, spacing: 16) {
                            Text(entry.recordedAt, format: .relative(presentation: .named))
                                .font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.ink70).lineLimit(1).frame(width: 120, alignment: .leading)
                            Text((entry.finalText.isEmpty ? entry.rawText : entry.finalText).replacingOccurrences(of: "\n", with: " "))
                                .font(WindowType.body(15)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            if let label = Self.statusLabel(entry.insertionStatus) { mono(label, size: 11, color: Palette.accentDeep) }
                        }
                        .padding(.vertical, 12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).overlay(alignment: .bottom) { softRule }
                }
            }
            .overlay(alignment: .top) { rule }.padding(.top, 8)
            Button("Replay Welcome Guide") { WelcomeGuide.replay(.standard); guideStep = .microphone; screen = .setup }
                .buttonStyle(InkButtonStyle(kind: .outline)).padding(.top, 28)
        }
    }

    private var keptFor: String {
        switch controller.retention {
        case "six-months": return "six months"
        case "forever": return "until you delete them"
        default: return "30 days"
        }
    }

    var insightsView: some View {
        page("Insights", "Counted on this Mac from the dictations History keeps. Nothing is sent anywhere.") {
            switch controller.insights {
            case .historyOff:
                insightsNotice("History is off", "Insights counts only what History keeps on this Mac, so there is nothing to count. Turn History on in History & Privacy to see your words, pace and streaks.")
            case .empty:
                insightsNotice("Nothing to count", "History keeps dictations for \(keptFor). It has none right now: either you have not dictated yet, or older dictations have expired. Insights counts only what History still has.")
            case .stats(let stats):
                insightsStats(stats)
            }
        }
    }

    private func insightsNotice(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(WindowType.body(22, weight: .semibold))
            help(detail)
            Button("Open History & Privacy") { section = 5; screen = .settings }.buttonStyle(InkButtonStyle(kind: .outline))
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading).background(Palette.accent16).padding(.top, 28)
    }

    private func insightsStats(_ s: Insights.Stats) -> some View {
        let timed = "Based on \(s.timedDictations) of \(s.dictations) dictations with a recorded duration. Includes pauses."
        return VStack(alignment: .leading, spacing: 24) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                insightMetric("Words dictated", s.words.formatted(), "Words in the final transcripts still in History.")
                insightMetric("Dictations", s.dictations.formatted(), "Dictations with a nonempty final transcript.")
                insightMetric("Recording time", s.recordingSeconds.map(Insights.duration) ?? "—", timed)
                insightMetric("Speaking pace", s.wordsPerMinute.map { "\(Int($0.rounded())) WPM" } ?? "—", "Five-character words per minute. " + timed)
                insightMetric("Est. time saved", s.secondsSaved.map(Insights.duration) ?? "—", "Estimated against typing at \(Int(Insights.typingWPM.rounded())) WPM; not your measured typing speed. " + timed)
                insightMetric("Words / dictation", s.averageWords.formatted(.number.precision(.fractionLength(1))), "Average final word count per dictation.")
                insightMetric("Words changed", s.wordsChanged.formatted(), "Differences between raw and final text, including cleanup, dictionary spellings and History edits. Not an accuracy score.")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), alignment: .top)], alignment: .leading, spacing: 28) {
                dailyActivity(s).frame(height: 300, alignment: .top)
                VStack(alignment: .leading, spacing: 12) {
                    insightHeading("Streak", "Calendar shows the last five weeks. A day counts after one dictation in this Mac’s time zone. Streak totals use all retained History.")
                    HStack(spacing: 24) {
                        VStack(alignment: .leading) {
                            Text("\(s.currentStreak) \(s.currentStreak == 1 ? "day" : "days")").font(WindowType.body(22, weight: .bold))
                            mono("Current", size: 11, color: Palette.ink70)
                        }
                        VStack(alignment: .leading) {
                            Text("\(s.longestStreak) \(s.longestStreak == 1 ? "day" : "days")").font(WindowType.body(22, weight: .bold))
                            mono("Longest retained", size: 11, color: Palette.ink70)
                        }
                    }
                    StreakCalendar(days: s.days, weeks: 5,
                                   cutoff: HistoryExpiry.cutoff(HistoryRetention(rawValue: controller.retention) ?? .thirtyDays))
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 300, alignment: .top)
                hourlyActivity(s).frame(height: 300, alignment: .top)
                VStack(alignment: .leading, spacing: 12) {
                    insightHeading("Top apps", "Ranked by words in retained History. \(s.withoutApp) dictations have no destination app recorded.")
                    if s.apps.isEmpty { help("App usage appears after a destination app is recorded.") }
                    ForEach(s.apps.prefix(6), id: \.app) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(appName(item.app)).font(WindowType.body(14)).lineLimit(1)
                                Spacer()
                                Text("\(item.words.formatted()) words").font(WindowType.body(12)).foregroundStyle(Palette.ink70)
                            }
                            GeometryReader { geometry in
                                Rectangle().fill(Palette.accent).frame(width: geometry.size.width * Double(item.words) / Double(max(s.apps.first?.words ?? 1, 1)))
                            }.frame(height: 5).background(Palette.ink20)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(appName(item.app)), \(item.words) words, \(item.count) dictations")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 300, alignment: .top)
            }
            help("Based on retained History · kept for \(keptFor). Older entries may lack duration or app data.", color: Palette.ink64)
        }.padding(.top, 20)
    }

    private func insightMetric(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            insightHeading(title, detail)
            Text(value).font(WindowType.body(28, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
        .overlay(alignment: .bottom) { softRule }
    }

    private func insightHeading(_ title: String, _ detail: String) -> some View {
        HStack(spacing: 4) {
            eyebrow(title)
            SettingInfoButton(text: detail).accessibilityLabel("About " + title)
        }
    }

    private func dailyActivity(_ s: Insights.Stats) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = (0..<30).compactMap { calendar.date(byAdding: .day, value: $0 - 29, to: today) }
        return VStack(alignment: .leading, spacing: 12) {
            insightHeading("Daily activity", "Words per day over the last 30 days, in this Mac’s time zone. Counts include only retained History.")
            Chart(days, id: \.self) { day in
                BarMark(x: .value("Day", day, unit: .day), y: .value("Words", s.dailyWords[day, default: 0]))
                    .foregroundStyle(Palette.accent)
                    .accessibilityLabel(day.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityValue("\(s.dailyWords[day, default: 0]) words")
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 10)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            .frame(height: 264)
        }
    }

    private func hourlyActivity(_ s: Insights.Stats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            insightHeading("Busiest hours", "Dictations started in each hour, using this Mac’s current time zone. Includes all retained History; not recording duration.")
            Chart(0..<24, id: \.self) { hour in
                BarMark(x: .value("Hour", hour), y: .value("Dictations", s.hourlyDictations[hour]))
                    .foregroundStyle(Palette.accent)
                    .accessibilityLabel("\(hour):00–\(hour):59")
                    .accessibilityValue("\(s.hourlyDictations[hour]) dictations")
            }
            .chartXScale(domain: -0.5...23.5)
            .chartXAxis { AxisMarks(values: [0, 6, 12, 18]) { value in
                AxisValueLabel { if let hour = value.as(Int.self) { Text(hour == 0 ? "12am" : hour < 12 ? "\(hour)am" : hour == 12 ? "12pm" : "\(hour - 12)pm") } }
            } }
            .frame(height: 264)
        }
    }

}

/// Weeks as rows, Monday to Sunday across; days before History's cutoff are faded
/// out, since their dictations have expired.
private struct StreakCalendar: View {
    let days: Set<Date>
    let weeks: Int
    let cutoff: Date?
    var body: some View {
        var calendar = Calendar.current; calendar.firstWeekday = 2
        let today = calendar.startOfDay(for: Date())
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let first = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) ?? thisWeek
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
            ForEach(0..<7, id: \.self) { weekday in
                Text(calendar.shortStandaloneWeekdaySymbols[(weekday + 1) % 7])
                    .font(WindowType.body(11)).foregroundStyle(Palette.ink70)
                    .frame(maxWidth: .infinity).padding(.bottom, 4)
            }
            ForEach(0..<(weeks * 7), id: \.self) { offset in
                let day = calendar.date(byAdding: .day, value: offset, to: first) ?? first
                let on = days.contains(day)
                Text("\(calendar.component(.day, from: day))")
                    .font(WindowType.body(11, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Color(nsColor: .black) : Palette.ink70)
                    .frame(maxWidth: .infinity).frame(height: 26)
                    .background(on ? Palette.accent : Palette.ink.opacity(0.06), in: Capsule())
                    .overlay(Capsule().strokeBorder(day == today ? Palette.ink : Color.clear, lineWidth: 1.5))
                    .opacity(day > today || cutoff.map { day < calendar.startOfDay(for: $0) } == true ? 0.3 : 1)
                    .help(day.formatted(date: .abbreviated, time: .omitted) + (on ? ": dictated" : ": no retained dictation"))
            }
        }
        .accessibilityElement().accessibilityLabel("Dictation days")
        .accessibilityValue("\(days.filter { $0 >= first && $0 <= today }.count) days with dictation in the last \(weeks) weeks")
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

/// Shared license and storage affordances for every downloadable model.
struct ModelInfoIcons: View {
    let license: String?
    let details: String

    var body: some View {
        HStack(spacing: 4) {
            if let license {
                SettingInfoButton(text: license).accessibilityLabel("Model license")
            }
            if !details.isEmpty {
                SettingInfoButton(text: details, systemImage: "internaldrive")
                    .accessibilityLabel("Model size and details")
            }
        }
    }
}

/// Split in two so the compiler can type-check the chains.
struct SettingInfoButton: View {
    let text: String
    var systemImage = "questionmark.circle"
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            Image(systemName: systemImage)
                .font(WindowType.body(14))
                .foregroundStyle(Palette.ink70)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel("More information")
        .accessibilityHint(text)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            Text(text).font(WindowType.body(13)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                .padding(16).frame(width: 300, alignment: .leading)
        }
    }
}

/// Records a custom shortcut (gap #14). While it waits, the global tap is off so the current
/// shortcut can't start a dictation or be swallowed. Escape stops waiting; a refused key says why.
private struct ShortcutRecorder: View {
    @ObservedObject var controller: AppController
    @State private var monitor: Any?
    @State private var refusal: String?
    private var custom: CustomShortcut? { if case .custom(let shortcut) = ShortcutBinding(stored: controller.shortcut) { return shortcut }; return nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(monitor != nil ? "Press the keys…" : custom.map { "Custom: \($0.label)" } ?? "Or record your own")
                    .font(WindowType.body(14, weight: .medium)).accessibilityAddTraits(.updatesFrequently)
                Spacer(minLength: 8)
                Button(monitor != nil ? "Stop" : "Record Shortcut…") { monitor != nil ? stop() : start() }.buttonStyle(InkButtonStyle(kind: .outline))
                if custom != nil && monitor == nil {
                    Button("Reset") { refusal = nil; controller.shortcut = "right-option" }.buttonStyle(InkButtonStyle(kind: .outline))
                }
            }
            if let refusal { Text(refusal).font(WindowType.body(13)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            else if monitor != nil {
                Text("Use ⌘, ⌥ or ⌃ with a key, or an F-key. Built-in F1–F12 work only with fn held or with “Use F1, F2, etc. keys as standard function keys” on. Escape stops.")
                    .font(WindowType.body(13)).foregroundStyle(Palette.ink70).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stop() }
    }
    private func start() {
        guard monitor == nil, controller.pauseShortcutForRecorder() else { return }
        refusal = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = (event.cgEvent?.flags ?? []).intersection(CustomShortcut.relevant)
            let code = Int64(event.keyCode)
            if code == 53 && flags.isEmpty { stop(); return nil }
            if let reason = CustomShortcut.refusal(keyCode: code, modifiers: flags) { refusal = reason; return nil }
            controller.shortcut = CustomShortcut(keyCode: code, modifiers: flags, key: Self.keyName(event)).stored
            refusal = nil; stop(); return nil
        }
    }
    private func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor); self.monitor = nil
        controller.resumeShortcutAfterRecorder()
    }
    private static let named: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 117: "Forward Delete", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
    static func keyName(_ event: NSEvent) -> String {
        // Control characters (keypad Enter, Clear) have no printable name; CustomShortcut falls back to the key code.
        named[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "").uppercased().filter { !$0.isWhitespace && !($0.asciiValue.map { $0 < 32 || $0 == 127 } ?? false) }
    }
}

private struct AutoApplyGeneral: ViewModifier {
    @ObservedObject var controller: AppController
    func body(content: Content) -> some View {
        content
            .onChange(of: controller.shortcut) { controller.settingsChanged() }
            .onChange(of: controller.automaticInsertion) { controller.settingsChanged() }
            .onChange(of: controller.pressToToggle) { controller.settingsChanged() }
            .onChange(of: controller.recordingSounds) { controller.settingsChanged() }
            .onChange(of: controller.liveWords) { controller.settingsChanged() }
            .onChange(of: controller.liveWordsOnCloud) { controller.settingsChanged() }
            .onChange(of: controller.intelligentLeadingSpace) { controller.settingsChanged() }
            .onChange(of: controller.showMenuBar) { controller.settingsChanged() }
            .onChange(of: controller.showInDock) { controller.settingsChanged() }
            .onChange(of: controller.inputDeviceUID) { controller.settingsChanged() }
            .onChange(of: controller.retention) { controller.settingsChanged() }
            .onChange(of: controller.historyMode) { controller.settingsChanged() }
            .onChange(of: controller.updateChecksEnabled) { controller.settingsChanged() }
            .onChange(of: controller.installUpdatesAutomatically) { controller.settingsChanged() }
    }
}

/// A list of short strings with an add field and remove buttons (mode websites and trigger words).
private struct ModeListEditor: View {
    @Binding var items: [String]
    let placeholder: String
    let label: String
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack {
                    Text(item).font(WindowType.body(15))
                    Spacer()
                    Button("Remove") { items.removeAll { $0 == item } }.buttonStyle(InkButtonStyle(kind: .plain)).fixedSize()
                }
            }
            HStack(spacing: 8) {
                TextField(placeholder, text: $draft).textFieldStyle(.plain).font(WindowType.body(15)).accessibilityLabel(label)
                    .padding(.horizontal, 12).frame(height: 44).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.ink20, lineWidth: 1))
                    .onSubmit(add)
                Button("Add", action: add).buttonStyle(InkButtonStyle(kind: .outline)).fixedSize()
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.top, 8)
    }
    private func add() {
        // Several at once, separated by commas.
        for item in draft.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !item.isEmpty && !items.contains(item) { items.append(item) }
        draft = ""
    }
}

private struct AutoApplyRoutes: ViewModifier {
    @ObservedObject var controller: AppController
    let apiFieldFocused: Bool
    func body(content: Content) -> some View {
        content
            .onChange(of: controller.cleanupFillers) { controller.settingsChanged() }
            .onChange(of: controller.cleanupCorrections) { controller.settingsChanged() }
            .onChange(of: controller.cleanupLists) { controller.settingsChanged() }
            .onChange(of: controller.cleanupPunctuation) { controller.settingsChanged() }
            .onChange(of: controller.cleanupSpoken) { controller.settingsChanged() }
            .onChange(of: controller.cleanupPolish) { controller.settingsChanged() }
            .onChange(of: controller.cleanupProfessional) { controller.settingsChanged() }
            .onChange(of: controller.cleanupTrustModel) { controller.settingsChanged() }
            .onChange(of: controller.screenContext) { controller.settingsChanged() }
            .onChange(of: controller.learningEnabled) { controller.settingsChanged() }
            .onChange(of: controller.learningRequiresReadableField) { controller.settingsChanged() }
            .onChange(of: controller.transcriptionRoute) { controller.settingsChanged() }
            .onChange(of: controller.cloudTranscriber) { controller.settingsChanged() }
            .onChange(of: controller.cleanupChoice) { controller.settingsChanged() }
            // Typing in a provider field waits for Return or focus loss.
            .onChange(of: controller.customAPIModel) { if !apiFieldFocused { controller.settingsChanged() } }
            .onChange(of: controller.customTranscriptionModel) { if !apiFieldFocused { controller.settingsChanged() } }
            .onChange(of: controller.geminiTranscriptionModel) { if !apiFieldFocused { controller.settingsChanged() } }
            .onChange(of: controller.customAPIBaseURL) { if !apiFieldFocused { controller.settingsChanged() } }
            .onChange(of: controller.customTranscriptionAPIBaseURL) { if !apiFieldFocused { controller.settingsChanged() } }
            .onChange(of: apiFieldFocused) { _, focused in if !focused { controller.settingsChanged() } }
    }
}

/// Settings → Meetings: meeting detection's switch and "Never" list (PRD 11.7, Q6).
private struct CallDetectionRows: View {
    @ObservedObject var presenter: CallOfferPresenter
    private func help(_ text: String, color: Color = Palette.ink70) -> some View {
        Text(text).font(WindowType.body(13)).lineSpacing(2).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Call detection").font(.system(size: 11, design: .monospaced)).tracking(0.88).textCase(.uppercase).foregroundStyle(Palette.accentInk).padding(.top, 20)
            Toggle(isOn: $presenter.enabled) {
                HStack(spacing: 4) {
                    Text("Offer to take notes when a call starts").font(WindowType.body(16, weight: .semibold))
                    SettingInfoButton(text: "When a call app or a browser uses the microphone for a few seconds, Murmur offers meeting notes. It never starts recording on its own. It checks only which apps use the microphone, on this Mac; it reads no windows or web addresses.")
                }
            }
            .toggleStyle(MurmurToggleStyle())
            if !presenter.never.isEmpty {
                Text("Never offer for").font(WindowType.body(14, weight: .semibold))
                ForEach(presenter.never, id: \.self) { id in
                    HStack {
                        Text(CallOfferPresenter.name(id)).font(WindowType.body(14))
                        Spacer()
                        Button("Remove") { presenter.removeNever(id) }.buttonStyle(InkButtonStyle(kind: .outline))
                            .accessibilityLabel("Offer again for \(CallOfferPresenter.name(id))")
                    }
                }
            }
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange).accessibilityHidden(true).allowsHitTesting(false)
            Text(summary).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                .help(message).allowsHitTesting(false).accessibilityHidden(true)
            Spacer(minLength: 4)
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture { openError() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
        .accessibilityHint("Open Murmur to view the full error.")
        .accessibilityAction { openError() }
        .modifier(UtilityGlass(radius: 18))
    }

    private func openError() {
        controller.showSettings()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .dictationShowError, object: nil) }
    }
}

/// Gap #17: the dictation could not be pasted, so the bubble shows it with Copy. History and ⌃⌘V
/// still work. The panel never becomes key, so clicking leaves the user's app in front.
private struct PasteFailureCard: View {
    @ObservedObject var controller: AppController
    let failure: AppController.PasteFailure
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 12)).foregroundStyle(.orange).accessibilityHidden(true)
                Text(failure.title).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Button { controller.dismissStatus() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss")
            }
            Text(failure.text).font(.system(size: 12)).lineLimit(3).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel("Dictation: \(failure.text)")
            HStack {
                Text("⌃⌘V pastes it too").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Copy") { controller.copyPasteFailure() }.buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .modifier(UtilityGlass(radius: 18))
    }
}

/// Gap #13: the level meter plus the words heard so far, at most two lines (the newest tail).
/// Settled words are bright; the last word, which can still grow, is dimmed. Display only.
private struct LiveWordsBubble: View {
    @ObservedObject var controller: AppController
    var body: some View {
        let parts = LiveWordsFacts.split(controller.liveText)
        HStack(spacing: 6) {
            VoiceBubbles(controller: controller, phase: "Listening")
            Group {
                if parts.settled.isEmpty && parts.guess.isEmpty { Text("Listening…").foregroundStyle(.secondary) }
                else { Text(parts.settled).foregroundStyle(.primary) + Text(parts.guess).foregroundStyle(.secondary) }
            }
            .font(.system(size: 13, weight: .medium)).lineLimit(2).truncationMode(.head)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .accessibilityHidden(true)
        }
        .padding(.trailing, 12).padding(.vertical, 2)
        .modifier(UtilityGlass(radius: 22))
    }
}

/// Gap #18: shown for a few seconds after Escape cancels a recording. Undo processes it as normal.
private struct UndoCancelCard: View {
    @ObservedObject var controller: AppController
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Recording canceled").font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 4)
            Button("Undo") { controller.undoCancel() }.buttonStyle(.borderedProminent).controlSize(.small)
                .accessibilityHint("Transcribes and inserts the canceled recording.")
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .modifier(UtilityGlass(radius: 18))
    }
}

/// A short notice with Undo, which removes what was learned and blocks it; learned entries can
/// also be removed in Settings → Dictionary.
private struct LearnedNotice: View {
    let controller: AppController
    let word: String
    let entryID: UUID
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.book.closed").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Added “\(word)” to dictionary").font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 4)
            Button("Undo") { controller.undoLearned(entryID) }.buttonStyle(.borderedProminent).controlSize(.small)
                .accessibilityHint("Stops replacing this word and does not learn it again.")
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
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
        // An idle status change leaves a learned-word notice up; anything shown replaces it.
        // A card holding text not pasted shows in any phase (Saved included).
        guard showsFloatingIndicator(phase: phase) || controller.pasteFailure != nil else { if notice == nil { hide() }; return }
        notice = nil
        let frame = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let minimal = phase != "Error" && controller.pasteFailure == nil
        panel.hasShadow = !minimal
        let card = controller.pasteFailure
        let live = phase == "Listening" && controller.liveWordsActive
        let width = live ? min(420, max(240, frame.width - 32)) : minimal ? 80 : card != nil ? min(320, max(200, frame.width - 32)) : min(240, max(180, frame.width - 32))
        let content = live ? AnyView(LiveWordsBubble(controller: controller))
            : minimal ? AnyView(VoiceBubbles(controller: controller, phase: phase))
            : card.map { AnyView(PasteFailureCard(controller: controller, failure: $0)) } ?? AnyView(BubbleView(controller: controller, message: message))
        let host = NSHostingView(rootView: content.frame(width: width))
        panel.contentView = host
        let height = host.fittingSize.height
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.minY + 24, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { notice = nil; panel.orderOut(nil) }
    /// Whether the bubble shows anything (a status, Undo, a card); the meeting offer waits for it.
    var isVisible: Bool { panel.isVisible }

    private var notice: UUID?
    /// The Undo card; it leaves with the "Recording canceled" status (5 s) or when anything else is shown.
    func showUndo(screen: NSScreen?) {
        let frame = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(260, max(200, frame.width - 32))
        let host = NSHostingView(rootView: UndoCancelCard(controller: controller).frame(width: width))
        panel.contentView = host
        panel.hasShadow = true
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.minY + 24, width: width, height: host.fittingSize.height), display: true)
        panel.orderFrontRegardless()
        notice = UUID()
    }
    /// The learned-word notice; leaves after 5 s unless something else took the panel first.
    func showLearned(_ word: String, entryID: UUID, screen: NSScreen?) {
        let frame = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(320, max(200, frame.width - 32))
        let shown = UUID()
        let host = NSHostingView(rootView: LearnedNotice(controller: controller, word: word, entryID: entryID).frame(width: width))
        panel.contentView = host
        panel.hasShadow = true
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.minY + 24, width: width, height: host.fittingSize.height), display: true)
        panel.orderFrontRegardless()
        notice = shown
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.notice == shown else { return }
            self.hide()
        }
    }
}

func segmented<T: Hashable>(_ options: [(T, String)], _ selection: Binding<T>, size: CGFloat = 15) -> some View {
    HStack(spacing: 12) {
        ForEach(options.indices, id: \.self) { index in
            let (value, label) = options[index]
            let on = selection.wrappedValue == value
            Button { selection.wrappedValue = value } label: {
                Text(label).font(WindowType.body(size, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity).frame(minHeight: 40)
                    .foregroundStyle(on ? Palette.ink : Palette.ink70)
                    .overlay(alignment: .bottom) { Rectangle().fill(on ? Palette.accentInk : Color.clear).frame(height: 2) }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
        }
    }
}
