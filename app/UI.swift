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

/// The window's paper-and-ink palette (clouddev design system). Dark appearance swaps paper and ink
/// and lifts the accent text colors so they stay readable on ink.
enum Palette {
    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light) }
    }
    static let paperNS = dynamic(light: 0xF4F2ED, dark: 0x141414)
    static let paper = Color(nsColor: paperNS)
    static let ink = Color(nsColor: dynamic(light: 0x141414, dark: 0xF4F2ED))
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

/// The Murmur mark: five bars falling from loud to quiet, on the logo sheet's 96-unit grid.
enum Logo {
    static let bars: [CGRect] = [
        CGRect(x: 14, y: 16, width: 9, height: 64), CGRect(x: 29, y: 28, width: 9, height: 40),
        CGRect(x: 44, y: 35, width: 9, height: 26), CGRect(x: 59, y: 40, width: 9, height: 16),
        CGRect(x: 74, y: 44, width: 9, height: 8),
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

private struct InkButtonStyle: ButtonStyle {
    enum Kind { case filled, outline, accent, plain }
    var kind: Kind = .filled
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold)).lineLimit(1)
            .padding(.horizontal, kind == .plain ? 0 : 16).frame(height: 44)
            .foregroundStyle(kind == .filled || kind == .accent ? Palette.paper : Palette.ink)
            .background(kind == .filled ? (configuration.isPressed ? Palette.accentDeep : Palette.ink) : kind == .accent ? Palette.accentInk : Color.clear)
            .overlay { if kind == .outline { Rectangle().strokeBorder(Palette.ink, lineWidth: 1.5) } }
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.45)
    }
}

/// A square switch; VoiceOver still sees a native toggle.
private struct SquareToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 24) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Rectangle().fill(configuration.isOn ? Palette.accent : Color.clear)
                Rectangle().fill(Palette.ink).frame(width: 17, height: 17).padding(.horizontal, 2.5)
            }
            .frame(width: 48, height: 24).overlay(Rectangle().strokeBorder(Palette.ink, lineWidth: 1.5))
            .frame(height: 44)
        }
        .contentShape(Rectangle())
        .onTapGesture { if enabled { configuration.isOn.toggle() } }
        .opacity(enabled ? 1 : 0.45)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

private struct WindowAppearance: NSViewRepresentable {
    let dark: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let name: NSAppearance.Name = dark ? .darkAqua : .aqua
        // The view joins its window after the first update.
        DispatchQueue.main.async { view.window?.appearance = NSAppearance(named: name) }
    }
}

struct SettingsView: View {
    @ObservedObject var controller: AppController
    private enum Screen { case settings, history, setup }
    @State private var screen = Screen.settings
    @State private var section = 0
    @State private var showAdvanced = false
    /// The expanded History row.
    @State private var selectedID: String?
    @State private var copiedID: String?
    @State private var searchText = ""
    @State private var attentionOnly = false
    @State private var newPreferred = ""
    @State private var newVariants = ""
    /// The dictionary row being edited, and its draft fields.
    @State private var editingEntryID: UUID?
    @State private var editPreferred = ""
    @State private var editVariants = ""
    @State private var openKey: ProviderID?
    @State private var keyDraft = ""
    @State private var customAPIKeyDraft = ""
    @State private var checkedSetup = false
    /// A window preference only; the floating indicator keeps following the system appearance.
    @AppStorage("appearance") private var appearance = "light"
    /// API address and model apply when editing ends (Return or leaving the field), not per keystroke.
    @FocusState private var apiFieldFocused: Bool

    private static let sections = ["General", "Transcription", "Cleanup", "Dictionary", "History & Privacy", "API Keys", "Updates"]
    private static let ledes = [
        "The shortcut, how text is inserted, and what Murmur is allowed to do.",
        "Where your voice is turned into text. On this Mac by default.",
        "Tidy the transcript before it is typed. Each option works on its own.",
        "Words Murmur should spell your way, in every mode.",
        "What Murmur saves, and for how long. Nothing leaves this Mac.",
        "Needed only for cloud routes. Stored in your Keychain.",
        "Murmur checks for new versions. You install them yourself."
    ]

    var body: some View {
        VStack(spacing: 0) {
            if screen == .setup { setup } else {
                header
                banners
                if screen == .settings { settings } else { history }
            }
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.paper)
        .environment(\.colorScheme, appearance == "dark" ? .dark : .light)
        // preferredColorScheme leaks app-wide and darkened the floating bubble; set only this window.
        .background(WindowAppearance(dark: appearance == "dark"))
        .frame(minWidth: 760, minHeight: 560)
        // Every setting applies as soon as it changes; attached here so hidden sections still apply.
        .modifier(AutoApplyGeneral(controller: controller))
        .modifier(AutoApplyRoutes(controller: controller, apiFieldFocused: apiFieldFocused))
        .onAppear {
            controller.refreshPermissions(); controller.refreshHistory(); controller.refreshInputDevices()
            if !checkedSetup { checkedSetup = true; if !setupComplete { screen = .setup } }
        }
        // Permissions are granted in System Settings; re-read them on return.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in controller.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: .dictationShowError)) { _ in screen = .settings }
        .onReceive(NotificationCenter.default.publisher(for: .dictationShowHistory)) { _ in
            searchText = ""; attentionOnly = false; screen = .history
            selectedID = controller.history.first(where: { $0.id == controller.recoveryEntryID })?.id ?? controller.history.first?.id
        }
    }

    // MARK: Shared pieces

    private func mono(_ text: String, size: CGFloat = 12, color: Color = Palette.ink) -> some View {
        Text(text).font(.system(size: size, design: .monospaced)).tracking(size * 0.08).textCase(.uppercase).foregroundStyle(color)
    }

    private func eyebrow(_ text: String) -> some View { mono(text, size: 11, color: Palette.accentInk) }

    private var rule: some View { Rectangle().fill(Palette.ink).frame(height: 1.5) }
    private var softRule: some View { Rectangle().fill(Palette.ink20).frame(height: 1) }

    private func help(_ text: String, color: Color = Palette.ink70) -> some View {
        Text(text).font(.system(size: 14)).lineSpacing(2).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    private func titled(_ title: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 16, weight: .semibold))
            if let detail { help(detail) }
        }
    }

    private var microphonePicker: some View {
        let devices = controller.inputDevices
        let saved = controller.inputDeviceUID
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Microphone", selection: $controller.inputDeviceUID) {
                Text("System default").tag("")
                ForEach(devices, id: \.uid) { device in Text(device.name).tag(device.uid) }
                if !saved.isEmpty && !devices.contains(where: { $0.uid == saved }) { Text("Chosen microphone (not connected)").tag(saved) }
            }
            .labelsHidden()
            help("Used for the next dictation. If the chosen microphone is not connected, Murmur uses the system default.")
        }
    }

    private func toggleRow(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { titled(title, detail) }.toggleStyle(SquareToggleStyle())
            .padding(.vertical, 12).overlay(alignment: .bottom) { softRule }
    }

    private func segmented<T: Hashable>(_ options: [(T, String)], _ selection: Binding<T>, size: CGFloat = 15) -> some View {
        HStack(spacing: -1.5) {
            ForEach(options.indices, id: \.self) { index in
                let (value, label) = options[index]
                let on = selection.wrappedValue == value
                Button { selection.wrappedValue = value } label: {
                    Text(label).font(.system(size: size, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
                        .padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: 44)
                        .foregroundStyle(on ? Palette.paper : Palette.ink).background(on ? Palette.ink : Color.clear)
                        .overlay(Rectangle().strokeBorder(Palette.ink, lineWidth: 1.5)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    /// "Gemini 3.5 Transcribe (speech recognition, …)" → "Gemini 3.5 Transcribe" for segment labels.
    private func short(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "(,")).first?.trimmingCharacters(in: .whitespaces) ?? name
    }

    private func field(_ title: String, text: Binding<String>, secure: Bool = false) -> some View {
        Group {
            if secure { SecureField("", text: text) } else { TextField("", text: text) }
        }
        .textFieldStyle(.plain).font(.system(size: 15)).accessibilityLabel(title)
        .overlay(alignment: .leading) {
            if text.wrappedValue.isEmpty {
                Text(title).font(.system(size: 15)).foregroundStyle(Palette.ink64).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12).frame(height: 44)
        .overlay(Rectangle().strokeBorder(Palette.ink, lineWidth: 1.5))
    }

    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geometry in
            Rectangle().fill(Palette.accent).frame(width: geometry.size.width * fraction)
        }
        .frame(height: 8).overlay(Rectangle().strokeBorder(Palette.ink, lineWidth: 1.5))
        .accessibilityElement().accessibilityLabel("Download progress").accessibilityValue("\(Int(fraction * 100)) percent")
    }

    /// The name with the accent square; a drawn square, since the ■ glyph renders rounded in the system font.
    private func wordmark(_ text: String, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.06) {
            Text(text).font(.system(size: size, weight: .bold)).tracking(-size * 0.045)
            Rectangle().fill(Palette.accent).frame(width: size * 0.5, height: size * 0.5)
        }
    }

    private var setupComplete: Bool {
        controller.microphoneAuthorized && controller.accessibilityAuthorized && controller.inputMonitoringAuthorized && modelSatisfied
    }

    /// Cloud transcription does not need the local model.
    private var modelSatisfied: Bool { controller.modelRow.isReady || controller.transcriptionRoute == .cloud }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 32) {
            HStack(spacing: 12) {
                Logo.mark(size: 32)
                wordmark("Murmur", size: 24)
            }
            HStack(spacing: 4) {
                tab("Settings", .settings, count: nil)
                tab("History", .history, count: controller.history.count)
            }
            Spacer()
            HStack(spacing: 16) {
                mono(controller.appliedTranscriptionIsLocal ? "Local transcription" : "Cloud transcription", color: Palette.ink70)
                HStack(spacing: 7) {
                    Rectangle().fill(controller.phase == "Error" ? Palette.ink : Palette.accent).frame(width: 9, height: 9)
                    mono(controller.phase)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 24).frame(height: 64)
        .overlay(alignment: .bottom) { rule }
    }

    private func tab(_ title: String, _ target: Screen, count: Int?) -> some View {
        Button { screen = target } label: {
            HStack(spacing: 6) {
                mono(title, size: 13)
                if let count { mono("\(count)", size: 13, color: Palette.ink64) }
            }
            .padding(.horizontal, 14).frame(height: 44)
            .overlay(alignment: .bottom) { Rectangle().fill(screen == target ? Palette.accent : Color.clear).frame(height: 2) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityAddTraits(screen == target ? .isSelected : [])
    }

    @ViewBuilder private var banners: some View {
        if controller.hasStatusToShow && !controller.isBusy {
            HStack(alignment: .top, spacing: 12) {
                if controller.phase == "Error" { mono("Error", color: Palette.paper).padding(.top, 2) }
                Text(controller.message).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
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
                    .font(.system(size: 14))
                Spacer(minLength: 12)
                Button { screen = .setup } label: {
                    Text("Finish Setup →").font(.system(size: 14, weight: .semibold))
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
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.sections.indices, id: \.self) { index in
                    let on = section == index
                    Button { section = index } label: {
                        HStack(spacing: 12) {
                            mono(String(format: "%02d", index + 1), size: 13, color: on ? Palette.paper : Palette.ink).opacity(0.7)
                            mono(Self.sections[index], size: 13, color: on ? Palette.paper : Palette.ink)
                        }
                        .padding(.horizontal, 24).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(on ? Palette.ink : Color.clear).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                }
                Spacer()
                help(controller.isBusy ? "Finish dictating to change settings." : "Changes apply as soon as you make them.", color: Palette.ink64)
                    .font(.system(size: 12)).padding(.horizontal, 24)
            }
            .padding(.vertical, 16).frame(width: 216)
            .overlay(alignment: .trailing) { Rectangle().fill(Palette.ink).frame(width: 1.5) }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Self.sections[section]).font(.system(size: 36, weight: .bold)).tracking(-1.4)
                    Text(Self.ledes[section]).font(.system(size: 16)).foregroundStyle(Palette.ink70).padding(.top, 10).padding(.bottom, 8)
                    sectionBody.disabled(controller.isBusy)
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(EdgeInsets(top: 32, leading: 40, bottom: 40, trailing: 40))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var sectionBody: some View {
        switch section {
        case 0: general
        case 1: transcription
        case 2: cleanup
        case 3: dictionary
        case 4: privacy
        case 5: apiKeys
        default: updates
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow("Shortcut").padding(.top, 20)
            VStack(alignment: .leading, spacing: 12) {
                segmented([("right-option", "Right Option"), ("fn", "Fn / Globe"), ("ctrl-option-space", "Control–Option–Space")], $controller.shortcut)
                help(controller.pressToToggle ? "Press the shortcut to start recording and press it again to stop, or hold it and release. Escape cancels." : "Hold to record until you release. Double-press to keep recording until you press again. Escape cancels.")
            }
            .padding(.vertical, 16).overlay(alignment: .top) { rule }.overlay(alignment: .bottom) { softRule }.padding(.top, 8)
            toggleRow("Press once to start, again to stop", "Holding still works: release to stop. Off means hold to record.", isOn: $controller.pressToToggle)
            toggleRow("Insert at the cursor", "Types into whichever field has the cursor when dictation finishes. If it cannot, press ⌃⌘V to paste the dictation where your cursor is. The previous clipboard is restored unless you copy something newer. Automatic paste is marked transient; other software may still read or retain it. Murmur never sends a message.", isOn: $controller.automaticInsertion)
            toggleRow("Add a leading space when needed", "Separates dictation from existing text at the cursor. Existing whitespace, punctuation and selected text are left alone.", isOn: $controller.intelligentLeadingSpace)
            toggleRow("Show menu bar icon", "When hidden, reopen Murmur from Finder or Spotlight.", isOn: $controller.showMenuBar)
            toggleRow("Open at login", "Starts Murmur in the background when you log in, so the shortcut is ready.", isOn: Binding(get: { controller.openAtLogin }, set: controller.setOpenAtLogin))

            eyebrow("Microphone").padding(.top, 28)
            microphonePicker.padding(.top, 8)

            eyebrow("Permissions").padding(.top, 28)
            VStack(spacing: 0) {
                permissionRow("Microphone", allowed: controller.microphoneAuthorized, actionTitle: "Allow", action: controller.requestMicrophone)
                permissionRow("Accessibility", allowed: controller.accessibilityAuthorized, actionTitle: "Open Settings…") { controller.openPermissionSettings("accessibility") }
                permissionRow("Input Monitoring", allowed: controller.inputMonitoringAuthorized, actionTitle: "Open Settings…") { controller.openPermissionSettings("input-monitoring") }
            }
            .overlay(alignment: .top) { rule }.padding(.top, 8)
            Button("Refresh Permissions", action: controller.refreshPermissionsAndShortcut)
                .buttonStyle(InkButtonStyle(kind: .outline)).padding(.top, 16)

            eyebrow("Appearance").padding(.top, 28)
            segmented([("light", "Light"), ("dark", "Dark")], $appearance).padding(.top, 8)
        }
    }

    private func permissionRow(_ title: String, allowed: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Text(title).font(.system(size: 16, weight: .semibold))
            Spacer()
            mono(allowed ? "Allowed ✓" : "Needed", color: allowed ? Palette.accentInk : Palette.ink)
            if !allowed { Button(actionTitle, action: action).buttonStyle(InkButtonStyle()) }
        }
        .frame(minHeight: 44).padding(.vertical, 12).overlay(alignment: .bottom) { softRule }
    }

    private var transcription: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ModelFacts.displayName).font(.system(size: 18, weight: .semibold))
                        if !controller.modelSummary.isEmpty { help(controller.modelSummary) }
                        Group {
                            if controller.modelRow.isReady { mono("Model ready ✓", color: Palette.accentInk) }
                            else { Text(controller.modelRow.statusText).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true) }
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
            .padding(20).overlay(Rectangle().strokeBorder(Palette.ink, lineWidth: 1.5)).padding(.top, 20)
            if let license = controller.modelLicense {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(license.declarations) { declaration in
                        Button { controller.openLink(declaration.url) } label: { Text("License: " + declaration.name + " · " + declaration.source).underline() }
                            .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Palette.accentInk).help(declaration.url.absoluteString)
                    }
                    help(license.note, color: Palette.ink64).font(.system(size: 12))
                }
                .padding(.top, 10)
            }

            eyebrow("Where transcription runs").padding(.top, 28)
            segmented([(TranscriptionRoute.local, "On this Mac (Parakeet)"), (TranscriptionRoute.cloud, "Cloud")], $controller.transcriptionRoute).padding(.top, 8)
            if controller.transcriptionRoute == .local {
                help("Audio stays on this Mac. Downloading the model uses the network once; dictation does not.").padding(.top, 12)
            } else {
                segmented(CloudTranscriber.allCases.map { ($0, short($0.displayName)) }, $controller.cloudTranscriber, size: 14).padding(.top, 16)
                    .help(controller.cloudTranscriber.displayName)
                disclosure(controller.routeDisclosure(.transcription)).padding(.top, 16)
            }

            Button { showAdvanced.toggle() } label: {
                mono((showAdvanced ? "▾" : "▸") + " Advanced", size: 13).frame(height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.top, 28)
            if showAdvanced {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model folder").font(.system(size: 16, weight: .semibold))
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

    @ViewBuilder private func disclosure(_ text: String?) -> some View {
        if let text {
            Text(text + " Murmur never falls back to another route.")
                .font(.system(size: 14)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.accent16)
        }
    }

    private var cleanup: some View {
        VStack(alignment: .leading, spacing: 0) {
            rule.padding(.top, 20)
            toggleRow("Remove filler words", "Takes out “um”, “uh” and similar.", isOn: $controller.cleanupFillers)
            toggleRow("Apply spoken corrections", "“Friday, no wait, Monday” becomes “Monday”.", isOn: $controller.cleanupCorrections)
            toggleRow("Format spoken lists", "Turns “one, two, three” into a numbered list.", isOn: $controller.cleanupLists)
            toggleRow("Fix punctuation and capitalization", "Adds commas, periods and capitals.", isOn: $controller.cleanupPunctuation)
            HStack(spacing: 16) {
                help("If cleanup fails or changes too much, Murmur keeps the raw transcript in History and does not insert it. Faithful transcription turns every option off; dictionary spellings still apply.")
                Spacer()
                Button("Faithful Transcription", action: controller.useFaithfulTranscription)
                    .buttonStyle(InkButtonStyle(kind: .outline))
                    .disabled(!controller.cleanupFillers && !controller.cleanupCorrections && !controller.cleanupLists && !controller.cleanupPunctuation)
            }
            .padding(.top, 16)

            eyebrow("Cleanup runs with").padding(.top, 28)
            segmented(CleanupChoice.allCases.map { ($0, $0 == .localRules ? "On this Mac" : short($0.displayName)) }, $controller.cleanupChoice, size: 14)
                .padding(.top, 8).help(controller.cleanupChoice.displayName)
            help("Built-in local rules handle only a limited set of cleanup patterns. For private AI cleanup, try an instruction model around 8B or larger with a local model server; Murmur has not qualified a model that size yet. Its tested models under 2B were slower and less accurate than Gemini in a synthetic comparison. Otherwise choose Gemini or a Custom API provider. Murmur never switches routes on its own.")
                .padding(.top, 12)
            if controller.cleanupChoice == .localRules {
                help("Cleanup runs on this Mac. Nothing is sent anywhere.").padding(.top, 12)
            } else {
                disclosure(controller.routeDisclosure(.cleanup)).padding(.top, 16)
            }
            if controller.cleanupChoice == .customAPI {
                VStack(alignment: .leading, spacing: 10) {
                    Text("OpenAI-compatible API base URL").font(.system(size: 14, weight: .semibold))
                    field("https://api.cerebras.ai/v1", text: $controller.customAPIBaseURL)
                        .focused($apiFieldFocused).onSubmit(controller.settingsChanged)
                    Text("Model name").font(.system(size: 14, weight: .semibold)).padding(.top, 4)
                    field("gpt-oss-120b", text: $controller.customAPIModel)
                        .focused($apiFieldFocused).onSubmit(controller.settingsChanged)
                    Text("API key (optional)").font(.system(size: 14, weight: .semibold)).padding(.top, 4)
                    let hasCustomAPIKey = controller.savedKeys.contains(.customAPI)
                    HStack(spacing: 8) {
                        mono(hasCustomAPIKey ? "Saved in Keychain ✓" : KeyText.none, color: hasCustomAPIKey ? Palette.accentInk : Palette.ink70)
                        Spacer()
                        if hasCustomAPIKey {
                            Button("Validate") { controller.validateKey(.customAPI) }.buttonStyle(InkButtonStyle(kind: .outline))
                            Button("Remove", role: .destructive) { controller.removeKey(.customAPI); customAPIKeyDraft = "" }
                                .buttonStyle(InkButtonStyle(kind: .outline))
                        }
                    }
                    HStack(spacing: 8) {
                        field(hasCustomAPIKey ? "Enter to replace saved key" : "Paste API key", text: $customAPIKeyDraft, secure: true)
                        Button("Save Key") {
                            if controller.saveKey(.customAPI, customAPIKeyDraft) { customAPIKeyDraft = "" }
                        }
                        .buttonStyle(InkButtonStyle(kind: .accent)).disabled(customAPIKeyDraft.isEmpty)
                    }
                    if controller.customAPIKeyNeedsConfirmation {
                        help("Save the API key again to confirm this server address. The existing key stays in Keychain and will not be sent until confirmed.", color: Palette.accentInk)
                    }
                    if let message = controller.keyMessages[.customAPI], !message.isEmpty { help(message) }
                    help("The endpoint must accept OpenAI-compatible POST /v1/chat/completions requests. Enter the provider's base URL and exact model ID. A key is sent only over HTTPS; local endpoints can be used without one.")
                }
                .padding(.top, 16)
            }
        }
    }

    /// Download row for dictionary support in on-device transcription (the CTC model).
    private var dictionaryModel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(DictionaryModelFacts.displayName).font(.system(size: 18, weight: .semibold))
                    if !controller.dictionaryModelSummary.isEmpty { help(controller.dictionaryModelSummary) }
                    Group {
                        if controller.dictionaryModelRow.isReady && !controller.dictionarySupportFailed { mono("Ready ✓", color: Palette.accentInk) }
                        else if !controller.dictionaryModelRow.isReady { Text(controller.dictionaryModelRow.statusText).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true) }
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
            if controller.dictionarySupportFailed { Text(DictionaryModelFacts.unavailableMessage).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true) }
            if !controller.dictionaryModelMessage.isEmpty { help(controller.dictionaryModelMessage) }
            if let license = controller.dictionaryModelLicense, let declaration = license.declarations.first {
                help("License: \(declaration.name) (\(declaration.url.absoluteString))", color: Palette.ink64)
            }
        }
        .padding(20).overlay(Rectangle().strokeBorder(Palette.ink, lineWidth: 1.5)).padding(.top, 20)
    }

    private var dictionary: some View {
        VStack(alignment: .leading, spacing: 0) {
            dictionaryModel
            rule.padding(.top, 20)
            toggleRow("Learn from my corrections", "When you fix a misheard name or term within a minute of dictating, Murmur adds the spelling to your dictionary; after the same fix in two dictations it also replaces the misheard form. Where an app hides its text, Murmur follows keys in that app for that minute. Raw key events stay in memory; filtered spellings are saved. Some editors hide field changes, so unrelated typing can be mistaken for a correction. Learned entries keep applying until you delete or reset them.", isOn: $controller.learningEnabled)
            toggleRow("Limit learning to readable fields", "Skips keystroke learning in editors whose text cannot be read back. Corrections in readable fields still learn; names in hidden editors must be added manually.", isOn: $controller.learningRequiresReadableField)
            HStack(spacing: 8) {
                field("Preferred spelling", text: $newPreferred).frame(width: 220).onSubmit(addEntry)
                field("Heard as, comma-separated (optional)", text: $newVariants).onSubmit(addEntry)
                Button("Add", action: addEntry)
                    .buttonStyle(InkButtonStyle(kind: newPreferred.trimmingCharacters(in: .whitespaces).isEmpty ? .outline : .filled)).fixedSize()
                    .disabled(newPreferred.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 20)
            if !controller.dictionaryMessage.isEmpty {
                Text(controller.dictionaryMessage).font(.system(size: 14, weight: .semibold)).padding(.top, 10)
            }
            VStack(alignment: .leading, spacing: 0) {
                if controller.dictionaryEntries.isEmpty {
                    help("No words yet. Add names, jargon and acronyms Murmur gets wrong.").padding(.vertical, 16)
                }
                ForEach(controller.dictionaryEntries) { entry in
                    Group { if editingEntryID == entry.id { dictionaryEditRow(entry) } else { dictionaryRow(entry) } }
                        .frame(minHeight: 56).padding(.vertical, 4).overlay(alignment: .bottom) { softRule }
                }
            }
            .overlay(alignment: .top) { rule }.padding(.top, 20)
            if !controller.blockedWords.isEmpty {
                eyebrow("Not learned").padding(.top, 24)
                help("Murmur skips these because your fixes for them conflicted, or you undid, reversed or deleted them.").padding(.top, 4)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.blockedWords, id: \.self) { item in blockedRow(item).overlay(alignment: .bottom) { softRule } }
                }
                .overlay(alignment: .top) { rule }.padding(.top, 12)
            }
            HStack {
                help("“Heard as” forms are replaced exactly, in every mode. With cleanup on, a word that sounds like one of yours is sent to the cleanup route with its spelling, so it can be fixed. Edits save immediately.")
                Spacer()
                Button("Reset Learned…", role: .destructive, action: controller.resetLearnedEntries).buttonStyle(InkButtonStyle(kind: .outline))
                    .disabled(!controller.dictionaryEntries.contains { $0.source == .learned } && controller.blockedWords.isEmpty)
            }
            .padding(.top, 16)
        }
    }

    private func addEntry() {
        guard !newPreferred.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if controller.addDictionaryEntry(preferred: newPreferred, variants: newVariants) { newPreferred = ""; newVariants = "" }
    }

    private func dictionaryRow(_ entry: DictionaryEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.preferred).font(.system(size: 16, weight: .semibold))
                if !entry.variants.isEmpty {
                    Text("Heard as " + entry.variants.joined(separator: ", ")).font(.system(size: 13)).foregroundStyle(Palette.ink70).lineLimit(1)
                }
            }
            .opacity(entry.enabled ? 1 : 0.45)
            Spacer()
            mono(entry.source == .learned ? "Learned" : "Manual", size: 11, color: Palette.accentDeep)
                .padding(.horizontal, 8).padding(.vertical, 3).background(Palette.accent16)
            Toggle(isOn: Binding(get: { entry.enabled }, set: { on in
                controller.updateDictionaryEntry(entry, preferred: entry.preferred, variants: entry.variants.joined(separator: ", "), enabled: on)
            })) { EmptyView() }
                .toggleStyle(SquareToggleStyle()).fixedSize().accessibilityLabel("Use \(entry.preferred)")
            Button("Edit") {
                editPreferred = entry.preferred; editVariants = entry.variants.joined(separator: ", ")
                controller.dictionaryMessage = ""; editingEntryID = entry.id
            }
            .buttonStyle(.plain).font(.system(size: 14, weight: .semibold)).frame(height: 44).accessibilityLabel("Edit \(entry.preferred)")
            Button { controller.deleteDictionaryEntry(entry) } label: {
                Text("×").font(.system(size: 18)).frame(width: 44, height: 44).contentShape(Rectangle())
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
                Text(word).font(.system(size: 16, weight: .semibold))
                Text(why).font(.system(size: 13)).foregroundStyle(Palette.ink70)
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
            field("Preferred spelling", text: $editPreferred).frame(width: 220).onSubmit(save)
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
                Text(notice).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            if let warning = controller.historyCapWarning {
                Text(warning).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            HStack(spacing: 20) {
                titled("Delete all data", DeleteAllDataText.explanation)
                Spacer()
                Button("Delete All Data…", role: .destructive, action: controller.deleteAllData).buttonStyle(InkButtonStyle())
            }
            .padding(20).overlay(Rectangle().strokeBorder(Palette.ink, lineWidth: 1.5)).padding(.top, 36)
        }
    }

    private var apiKeys: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(KeyText.providers.filter { $0 != .customAPI }, id: \.self) { provider in keyRow(provider) }
            }
            .overlay(alignment: .top) { rule }.padding(.top, 20)
            help("Keys are stored in your Keychain and never shown again after saving. OpenRouter's key is used for transcription; the custom API key is set in Cleanup.").padding(.top, 16)
        }
    }

    private func keyRow(_ provider: ProviderID) -> some View {
        let has = controller.savedKeys.contains(provider), open = openKey == provider
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.displayName).font(.system(size: 16, weight: .semibold))
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
            if let message = controller.keyMessages[provider], !message.isEmpty { help(message) }
        }
        .padding(.vertical, 16).overlay(alignment: .bottom) { softRule }
    }

    private var updates: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Murmur " + controller.currentVersion).font(.system(size: 18, weight: .semibold))
                    if !controller.updateStatus.isEmpty { help(controller.updateStatus) }
                }
                Spacer()
                Button("Check for Updates", action: controller.checkForUpdates).buttonStyle(InkButtonStyle()).disabled(controller.checkingForUpdates)
            }
            .padding(20).overlay(Rectangle().strokeBorder(Palette.ink, lineWidth: 1.5)).padding(.top, 20)
            if let release = controller.availableRelease {
                VStack(alignment: .leading, spacing: 8) {
                    Text(UpdateText.headline(release)).font(.system(size: 16, weight: .semibold))
                    if !release.notes.isEmpty {
                        Text(UpdateText.notesExcerpt(release.notes)).font(.system(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 16) {
                        help("Murmur never downloads or installs updates. Download the new version from GitHub and replace the app yourself.")
                        Spacer()
                        Button("Open Release Page…", action: controller.openReleasePage).buttonStyle(InkButtonStyle())
                    }
                }
                .padding(16).background(Palette.accent16).padding(.top, 16)
            }
            toggleRow("Check automatically", UpdateText.explanation, isOn: $controller.updateChecksEnabled)
        }
    }

    // MARK: History

    private var visibleHistory: [HistoryEntry] {
        controller.history.filter { entry in
            (!attentionOnly || needsAttention(entry.insertionStatus))
                && (searchText.isEmpty || entry.finalText.localizedCaseInsensitiveContains(searchText) || entry.rawText.localizedCaseInsensitiveContains(searchText))
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
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("History").font(.system(size: 36, weight: .bold)).tracking(-1.4)
                    help(controller.historySummary)
                }
                Spacer()
                segmented([(false, "All"), (true, "Needs attention")], $attentionOnly, size: 14).frame(width: 260)
                HStack(spacing: 8) {
                    field("Search transcripts", text: $searchText)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).foregroundStyle(Palette.ink70).accessibilityLabel("Clear search")
                    }
                }
                .frame(width: 220)
            }
            .padding(EdgeInsets(top: 24, leading: 40, bottom: 16, trailing: 40))
            .overlay(alignment: .bottom) { rule }

            ScrollView {
                let groups = historyGroups
                LazyVStack(spacing: 0) {
                    if groups.isEmpty {
                        VStack(spacing: 8) {
                            Text(controller.history.isEmpty ? "Your dictation appears here" : "No matching transcripts").font(.system(size: 26, weight: .semibold))
                            help(controller.history.isEmpty ? "Completed transcripts are saved here before they are inserted." : "Try a different search or filter.")
                            if controller.history.isEmpty && !setupComplete {
                                Button("Set Up Murmur") { screen = .setup }.buttonStyle(InkButtonStyle()).padding(.top, 8)
                            }
                        }
                        .padding(.vertical, 80).frame(maxWidth: .infinity)
                    }
                    ForEach(groups.indices, id: \.self) { index in
                        let group = groups[index]
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 4) {
                                mono(group.day)
                                mono(group.entries.count == 1 ? "1 entry" : "\(group.entries.count) entries", color: Palette.ink64)
                            }
                            .frame(width: 120, alignment: .leading).padding(.top, 14)
                            VStack(spacing: 0) {
                                ForEach(group.entries) { entry in historyRow(entry) }
                            }
                        }
                        .padding(.vertical, 24).overlay(alignment: .bottom) { rule }
                    }
                }
                .padding(.horizontal, 40)
            }

            HStack {
                help(controller.historyMode == .on ? "Saved on this Mac only. \(retentionText)" : controller.historySummary)
                Spacer()
                Button("Clear History…", role: .destructive, action: controller.clearHistory).buttonStyle(InkButtonStyle(kind: .outline))
                    .disabled(controller.history.isEmpty)
            }
            .padding(.horizontal, 40).frame(height: 56).overlay(alignment: .top) { rule }
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
        let open = selectedID == entry.id, attention = needsAttention(entry.insertionStatus)
        let note = controller.sessionOnlyIDs.contains(entry.id) ? HistoryText.sessionOnlyNote : statusNote(entry.insertionStatus)
        return VStack(alignment: .leading, spacing: 0) {
            Button { selectedID = open ? nil : entry.id } label: {
                HStack(alignment: .top, spacing: 16) {
                    Text(entry.recordedAt, format: .dateTime.hour().minute())
                        .font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.ink70).lineLimit(1).fixedSize().frame(width: 72, alignment: .leading).padding(.top, 2)
                    Text((entry.finalText.isEmpty ? entry.rawText : entry.finalText).replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 16)).lineSpacing(2).lineLimit(open ? 1 : 2).frame(maxWidth: .infinity, alignment: .leading)
                    mono(statusLabel(entry.insertionStatus), size: 11, color: attention ? Palette.paper : Palette.accentDeep)
                        .lineLimit(1).fixedSize().padding(.horizontal, 8).padding(.vertical, 3)
                        .background(attention ? Palette.ink : Palette.accent16)
                }
                .padding(.vertical, 12).frame(minHeight: 56).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityAddTraits(open ? .isSelected : [])
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    if let note {
                        Text(note).font(.system(size: 14)).foregroundStyle(Palette.ink80).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.accent16).padding(.bottom, 16)
                    }
                    eyebrow("Final text")
                    Text(entry.finalText.isEmpty ? "No final text saved." : entry.finalText).font(.system(size: 16)).lineSpacing(3)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    if entry.rawText != entry.finalText {
                        eyebrow("Raw transcription").padding(.top, 16)
                        Text(entry.rawText).font(.system(size: 15)).lineSpacing(3).foregroundStyle(Palette.ink70)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }
                    HStack(spacing: 8) {
                        if !entry.finalText.isEmpty {
                            Button(copiedID == entry.id + "f" ? "Copied ✓" : "Copy Text") { controller.copyEntry(entry); flashCopied(entry.id + "f") }
                                .buttonStyle(InkButtonStyle())
                        }
                        if entry.rawText != entry.finalText {
                            Button(copiedID == entry.id + "r" ? "Copied ✓" : "Copy Raw") { controller.copyRawEntry(entry); flashCopied(entry.id + "r") }
                                .buttonStyle(InkButtonStyle(kind: .outline))
                        }
                        Spacer()
                        Button("Delete", role: .destructive) { controller.deleteEntry(entry) }.buttonStyle(InkButtonStyle(kind: .plain))
                    }
                    .padding(.top, 18)
                    Text("Copying never retries insertion or sends a message.").font(.system(size: 13)).foregroundStyle(Palette.ink64).padding(.top, 10)
                }
                .padding(.leading, 88).padding(.top, 4).padding(.bottom, 20)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.ink45).frame(height: 1) }
    }

    private func flashCopied(_ id: String) {
        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copiedID == id { copiedID = nil } }
    }

    private func needsAttention(_ status: String) -> Bool {
        ["unverified", "insertion-pending", "failed", "held-cleanup", "held-transcript"].contains(status)
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "verified": return "Inserted ✓"
        case "unverified", "insertion-pending": return "Delivery uncertain"
        case "failed": return "Not inserted"
        case "copied": return "Copied"
        case "held-cleanup": return "Cleanup held"
        case "held-transcript": return "Held for review"
        default: return "Saved"
        }
    }

    private func statusNote(_ status: String) -> String? {
        switch status {
        case "unverified", "insertion-pending": return "Murmur could not confirm the text arrived. It is saved here in case it did not."
        case "failed": return "Murmur could not type this into the original field. The text is saved here so you can copy it."
        case "held-cleanup": return "Cleanup changed too much, so only the raw transcript was saved and nothing was inserted."
        case "held-transcript": return "The transcript was held for review, so nothing was inserted."
        default: return nil
        }
    }

    // MARK: First run

    private var shortcutName: String {
        ["right-option": "Right Option", "fn": "Fn / Globe", "ctrl-option-space": "Control–Option–Space"][controller.shortcut] ?? "your shortcut"
    }

    /// The PRD's first-run test dictation and the faithful-transcription choice.
    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow("Try it")
            help("Press \(shortcutName) and say a sentence. With this window in front, your words appear here instead of being typed.").padding(.top, 8)
            Text(controller.setupTestTranscript.isEmpty ? "Waiting for your voice…" : controller.setupTestTranscript)
                .font(.system(size: 16)).foregroundStyle(controller.setupTestTranscript.isEmpty ? Palette.ink70 : Palette.ink)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading).padding(12)
                .overlay(Rectangle().strokeBorder(Palette.ink45, lineWidth: 1)).padding(.top, 12)
                .accessibilityLabel(controller.setupTestTranscript.isEmpty ? "Test dictation: waiting" : "Test dictation: \(controller.setupTestTranscript)")
            toggleRow("Clean up my dictation", "Removes filler words, applies spoken corrections and formats spoken lists. Off is faithful transcription: exactly what was heard, with dictionary spellings.", isOn: Binding(
                get: { controller.cleanupFillers || controller.cleanupCorrections || controller.cleanupLists },
                set: { on in if on { controller.cleanupFillers = true; controller.cleanupCorrections = true; controller.cleanupLists = true } else { controller.useFaithfulTranscription() } }))
                .padding(.top, 8)
        }
        .onAppear { controller.setupShowing = true }
        .onDisappear { controller.setupShowing = false }
    }

    private var setup: some View {
        let steps: [(title: String, detail: String, done: Bool, action: String, run: () -> Void)] = [
            ("Microphone", "So Murmur can hear you while the shortcut is held.", controller.microphoneAuthorized, "Allow", controller.requestMicrophone),
            ("Accessibility", "So Murmur can type into the field you are using.", controller.accessibilityAuthorized, "Open Settings…", { controller.openPermissionSettings("accessibility") }),
            ("Input Monitoring", "So the global shortcut works in every app.", controller.inputMonitoringAuthorized, "Open Settings…", { controller.openPermissionSettings("input-monitoring") }),
            ("Speech model", controller.transcriptionRoute == .cloud && !controller.modelRow.isReady ? "Not needed while transcription runs in the cloud." : ModelFacts.displayName + (controller.modelSummary.isEmpty ? "" : " · " + controller.modelSummary), modelSatisfied,
             controller.modelRow.actions.contains(.retry) ? "Retry…" : "Download…", controller.downloadModel)
        ]
        let done = steps.filter(\.done).count
        return GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    eyebrow("First run · \(done) / 4")
                    VStack(alignment: .leading, spacing: -10) {
                        Text("Set up").font(.system(size: 56, weight: .bold)).tracking(-2.8)
                        wordmark("Murmur", size: 56)
                    }
                    .accessibilityElement(children: .combine).padding(.top, 16)
                    Text("Your voice, on your Mac.").font(.system(size: 18)).foregroundStyle(Palette.ink80).padding(.top, 20)
                    Spacer()
                    Logo.mark(size: 140).overlay(Rectangle().strokeBorder(Palette.ink, lineWidth: 2)).rotationEffect(.degrees(-1.5))
                }
                .padding(40).frame(width: geometry.size.width * 5 / 12, alignment: .leading).frame(maxHeight: .infinity, alignment: .top)
                .background(Palette.accent16)
                .overlay(alignment: .trailing) { Rectangle().fill(Palette.ink).frame(width: 1.5) }

                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(steps.indices, id: \.self) { index in
                                let step = steps[index]
                                let working = index == 3 && controller.modelRow.isWorking
                                HStack(spacing: 16) {
                                    mono(String(format: "%02d", index + 1), size: 13, color: step.done ? Palette.accentInk : Palette.ink70).frame(width: 40, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(step.title).font(.system(size: 18, weight: .semibold))
                                        help(working ? controller.modelRow.statusText : step.detail)
                                        if working, let progress = controller.modelRow.progress { progressBar(progress).padding(.top, 7) }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    if step.done { mono("Done ✓", color: Palette.accentInk) }
                                    else if working { Button("Cancel", action: controller.cancelModelDownload).buttonStyle(InkButtonStyle(kind: .outline)) }
                                    else { Button(step.action, action: step.run).buttonStyle(InkButtonStyle()) }
                                }
                                .padding(.vertical, 18).overlay(alignment: .bottom) { Rectangle().fill(Palette.ink45).frame(height: 1) }
                            }
                            if !controller.modelMessage.isEmpty { help(controller.modelMessage).padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading) }
                            if done == 4 { tryIt.padding(.top, 28) }
                        }
                    }
                    HStack {
                        Button("Not Now") { screen = .settings }.buttonStyle(InkButtonStyle(kind: .plain))
                        Spacer()
                        Button("Start Dictating →") { screen = .settings }
                            .buttonStyle(InkButtonStyle(kind: done == 4 ? .filled : .outline)).disabled(done < 4)
                    }
                    .padding(.top, 24)
                }
                .padding(40)
            }
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
            .onChange(of: controller.inputDeviceUID) { controller.settingsChanged() }
            .onChange(of: controller.retention) { controller.settingsChanged() }
            .onChange(of: controller.historyMode) { controller.settingsChanged() }
            .onChange(of: controller.updateChecksEnabled) { controller.settingsChanged() }
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
            .onChange(of: controller.learningEnabled) { controller.settingsChanged() }
            .onChange(of: controller.learningRequiresReadableField) { controller.settingsChanged() }
            .onChange(of: controller.transcriptionRoute) { controller.settingsChanged() }
            .onChange(of: controller.cloudTranscriber) { controller.settingsChanged() }
            .onChange(of: controller.cleanupChoice) { controller.settingsChanged() }
            // Typing in a provider field waits for Return or focus loss.
            .onChange(of: controller.customAPIModel) { if !apiFieldFocused { controller.settingsChanged() } }
            .onChange(of: controller.customAPIBaseURL) { if !apiFieldFocused { controller.settingsChanged() } }
            .onChange(of: apiFieldFocused) { _, focused in if !focused { controller.settingsChanged() } }
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
            }
            // These keep only the pop-up; saved audio stays reachable from Murmur's window.
            if controller.recoveryAudio != nil || controller.hasRecoveryAudio,
               !["No speech was detected", "No audio was captured", "Transcription failed", "Cleanup was held"].contains(where: message.hasPrefix) {
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

/// Shown once when correction learning adds a word (Wispr Flow style): a short notice with Undo.
private struct LearnedNotice: View {
    let word: String
    let undo: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.book.closed").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Added “\(word)” to dictionary").font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 4)
            Button("Undo", action: undo).buttonStyle(.bordered).controlSize(.small)
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
        guard showsFloatingIndicator(phase: phase) else { if notice == nil { hide() }; return }
        notice = nil
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

    func hide() { notice = nil; panel.orderOut(nil) }

    private var notice: UUID?
    /// The learned-word notice; leaves after 5 s unless something else took the panel first.
    func showLearned(_ word: String, screen: NSScreen?, undo: @escaping () -> Void) {
        let frame = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(320, max(200, frame.width - 32))
        let shown = UUID()
        let host = NSHostingView(rootView: LearnedNotice(word: word, undo: { [weak self] in undo(); self?.hide() }).frame(width: width))
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
