import AppKit
import SwiftUI

// Meeting notes UI (PRD 11.9): the Meetings page in Murmur's window, the one-time consent sheet,
// and the live panel that stays on screen for the whole recording (PRD 11.3).

private func mono(_ text: String, size: CGFloat = 12, color: Color = Palette.ink) -> some View {
    Text(text).font(.system(size: size, design: .monospaced)).tracking(size * 0.08).textCase(.uppercase).foregroundStyle(color)
}
private func lede(_ text: String, color: Color = Palette.ink70) -> some View {
    Text(text).font(.system(size: 14)).lineSpacing(2).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
}

/// The Start menu (Q1): running call apps first, then All apps, then the microphone alone.
struct MeetingStartMenu: View {
    @ObservedObject var controller: AppController
    var title = "Start Meeting Notes"
    var body: some View {
        Menu {
            let apps = MeetingRecorder.runningCallApps()
            if apps.isEmpty { Text("No call app or browser is open") }
            ForEach(apps, id: \.bundleID) { app in
                Button(app.name) { controller.startMeeting(MeetingSource(name: app.name, bundleID: app.bundleID)) }
            }
            Divider()
            Button("All apps (includes music and notifications)") { controller.startMeeting(.everything) }
            Button("Only my microphone") { controller.startMeeting(.microphoneOnly) }
        } label: {
            Text(title).font(.system(size: 15, weight: .semibold)).padding(.horizontal, 16).frame(height: 44)
                .foregroundStyle(Palette.paper).background(Palette.ink)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(controller.meetingRecorder.live != nil)
        .accessibilityLabel(title)
    }
}

struct MeetingsPage: View {
    @ObservedObject var controller: AppController
    @ObservedObject var recorder: MeetingRecorder
    @State private var selectedID: String?
    @State private var showEcho = false
    @State private var search = ""
    @State private var notesDraft = ""
    @State private var confirmDelete: Meeting?

    private var filtered: [Meeting] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return recorder.meetings }
        return recorder.meetings.filter { $0.title.lowercased().contains(query) || $0.lines.contains { $0.text.lowercased().contains(query) } }
    }
    private var selected: Meeting? { recorder.meetings.first { $0.id == selectedID } ?? filtered.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Meetings").font(.system(size: 28, weight: .bold)).tracking(-0.8)
                    lede("Your microphone as Me and the call’s audio as Them, transcribed on this Mac. Audio is deleted as soon as it is transcribed.")
                }
                Spacer()
                if let live = recorder.live {
                    HStack(spacing: 8) {
                        Rectangle().fill(Color.red).frame(width: 9, height: 9)
                        mono("Recording \(MeetingExport.clock(recorder.elapsed)) · \(live.source.name)")
                    }
                    Button("Stop", action: recorder.stop).buttonStyle(InkButtonStyle(kind: .filled))
                } else {
                    MeetingStartMenu(controller: controller)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
            if let message = recorder.message {
                HStack {
                    Text(message).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { recorder.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss")
                }
                .foregroundStyle(Palette.paper).padding(.horizontal, 24).padding(.vertical, 10).background(Palette.accentDeep)
            }
            if controller.historyMode == .off {
                lede("History is off, so meetings are kept only until Murmur quits. Export one to keep it.", color: Palette.accentDeep).padding(.horizontal, 24).padding(.bottom, 8)
            }
            Rectangle().fill(Palette.ink).frame(height: 1.5)
            if recorder.meetings.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    lede("No meetings yet. Start meeting notes when a call begins; Murmur asks you to let participants know the first time.")
                    lede(controller.historyMode == .on ? "Meetings are kept for your History retention period, then deleted." : "", color: Palette.ink64)
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 280)
                    Rectangle().fill(Palette.ink20).frame(width: 1)
                    if let meeting = selected { detail(meeting) } else { Spacer() }
                }
            }
        }
        .sheet(item: Binding(get: { recorder.consentPending.map(ConsentItem.init) }, set: { if $0 == nil { recorder.consentPending = nil } })) { item in
            MeetingConsentSheet(source: item.source) { acknowledged in
                recorder.consentPending = nil
                if acknowledged { MeetingConsent.acknowledge(.standard); controller.startMeeting(item.source) }
            }
        }
        .alert("Delete this meeting?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let meeting = confirmDelete { recorder.delete(meeting.id); selectedID = nil } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The transcript and your notes are deleted. This cannot be undone.") }
    }

    private var list: some View {
        VStack(spacing: 0) {
            TextField("Search meetings", text: $search).textFieldStyle(.plain).font(.system(size: 14))
                .padding(.horizontal, 12).frame(height: 40).overlay(alignment: .bottom) { Rectangle().fill(Palette.ink20).frame(height: 1) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { meeting in
                        Button { selectedID = meeting.id; notesDraft = meeting.myNotes } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(meeting.title).font(.system(size: 14, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                HStack(spacing: 8) {
                                    mono(MeetingExport.clock(meeting.seconds), size: 11, color: Palette.ink70)
                                    if recorder.finishing.contains(meeting.id) { mono("Finishing", size: 11, color: Palette.accentDeep) }
                                    else if let left = recorder.leftovers[meeting.id] { mono("\(left) parts left", size: 11, color: Palette.accentDeep) }
                                }
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(selected?.id == meeting.id ? Palette.accent16 : Color.clear).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).overlay(alignment: .bottom) { Rectangle().fill(Palette.ink20).frame(height: 1) }
                    }
                }
            }
        }
    }

    private func detail(_ meeting: Meeting) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(meeting.title).font(.system(size: 22, weight: .bold)).tracking(-0.5).textSelection(.enabled)
                mono("\(MeetingExport.clock(meeting.seconds)) · \(meeting.source.micOnly ? "My microphone only" : "Me and \(meeting.source.name)") · \(meeting.transcribedBy.map { "Transcribed by \($0)" } ?? "Transcribed on this Mac")", size: 11, color: Palette.ink70)
                HStack(spacing: 12) {
                    Button("Copy Transcript") { recorder.copyTranscript(meeting) }.buttonStyle(InkButtonStyle(kind: .outline))
                    Button("Save Markdown…") { recorder.saveMarkdown(meeting) }.buttonStyle(InkButtonStyle(kind: .outline))
                    Spacer()
                    Button("Delete…") { confirmDelete = meeting }.buttonStyle(InkButtonStyle(kind: .plain))
                }
                if recorder.finishing.contains(meeting.id) { lede("Finishing the transcript…", color: Palette.accentDeep) }
                else if let left = recorder.leftovers[meeting.id] {
                    HStack {
                        lede("\(left) \(left == 1 ? "part" : "parts") of this meeting \(left == 1 ? "was" : "were") not transcribed. The audio is kept for up to 24 hours.")
                        Button("Finish Transcript") { recorder.finishLeftovers(meeting.id) }.buttonStyle(InkButtonStyle(kind: .filled))
                    }
                }
                mono("My notes", size: 11, color: Palette.accentInk).padding(.top, 6)
                TextEditor(text: $notesDraft).font(.system(size: 14)).scrollContentBackground(.hidden).frame(minHeight: 70)
                    .padding(6).overlay(Rectangle().strokeBorder(Palette.ink, lineWidth: 1.5))
                    .onChange(of: notesDraft) { if notesDraft != meeting.myNotes { recorder.setNotes(notesDraft, for: meeting.id) } }
                    .onAppear { notesDraft = meeting.myNotes }
                    .onChange(of: meeting.id) { notesDraft = meeting.myNotes }
                HStack {
                    mono("Transcript", size: 11, color: Palette.accentInk)
                    Spacer()
                    if meeting.lines.contains(where: { $0.shown != nil }) {
                        Toggle("Show hidden echo", isOn: $showEcho).toggleStyle(.checkbox).font(.system(size: 13))
                    }
                }
                .padding(.top, 6)
                if meeting.lines.isEmpty { lede("No words were transcribed.") }
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(meeting.lines.filter { showEcho || !$0.isHidden }) { line in
                        MeetingLineRow(line: line, showEcho: showEcho)
                    }
                }
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ConsentItem: Identifiable { let source: MeetingSource; var id: String { source.name + (source.bundleID ?? "") } }

struct MeetingLineRow: View {
    let line: MeetingLine
    var showEcho = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            mono(MeetingExport.clock(line.start), size: 11, color: Palette.ink64).frame(width: 56, alignment: .leading)
            mono(MeetingExport.label(line.stream), size: 11, color: line.stream == .me ? Palette.accentInk : Palette.ink).frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(showEcho ? line.text : line.visibleText).font(.system(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(line.isHidden ? Palette.ink45 : Palette.ink)
                if line.localFallback == true { mono("Transcribed on this Mac: the cloud failed", size: 10, color: Palette.ink45) }
                if showEcho && line.shown != nil { mono(line.isHidden ? "Hidden as echo" : "Echo partly hidden", size: 10, color: Palette.ink45) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The one-time acknowledgement (PRD 11.3, Q8).
struct MeetingConsentSheet: View {
    let source: MeetingSource
    let done: (Bool) -> Void
    @State private var ticked = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(MeetingConsent.title).font(.system(size: 20, weight: .bold))
            lede(MeetingConsent.body)
            Toggle(MeetingConsent.acknowledgement, isOn: $ticked).toggleStyle(.checkbox).font(.system(size: 14, weight: .semibold))
            HStack {
                Spacer()
                Button("Cancel") { done(false) }.buttonStyle(InkButtonStyle(kind: .plain)).keyboardShortcut(.cancelAction)
                Button("Start Meeting Notes") { done(true) }.buttonStyle(InkButtonStyle(kind: .filled)).disabled(!ticked).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 460).foregroundStyle(Palette.ink).background(Palette.paper)
    }
}

// MARK: - Live panel

/// The panel shown for the whole recording. It cannot be closed, only collapsed (PRD 11.3).
struct MeetingLiveView: View {
    @ObservedObject var recorder: MeetingRecorder
    @Binding var collapsed: Bool
    @State private var notes = ""
    @State private var confirmCancel = false

    var body: some View {
        Group { if collapsed { pill } else { full } }
            .foregroundStyle(Palette.ink)
            .onChange(of: notes) { if let id = recorder.live?.id { recorder.setNotes(notes, for: id) } }
            .onAppear { notes = recorder.live?.myNotes ?? "" }
    }

    private var dot: some View { Circle().fill(Color.red).frame(width: 10, height: 10).accessibilityHidden(true) }

    /// The minimized panel: red dot, timer and Stop. Clicking the dot or timer expands it; drag it anywhere.
    private var pill: some View {
        HStack(spacing: 10) {
            Button { collapsed = false } label: {
                HStack(spacing: 8) { dot; mono(MeetingExport.clock(recorder.elapsed), size: 12) }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Show the meeting panel").accessibilityLabel("Recording meeting notes, \(MeetingExport.clock(recorder.elapsed)). Show the panel")
            Button("Stop", action: recorder.stop).buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 8).frame(height: 24).background(Palette.ink).foregroundStyle(Palette.paper)
                .accessibilityLabel("Stop meeting notes")
        }
        .padding(.horizontal, 12).frame(height: 40).modifier(UtilityGlass(radius: 20))
        .accessibilityElement(children: .contain)
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                dot
                mono("Recording \(MeetingExport.clock(recorder.elapsed))", size: 12)
                Spacer()
                if let live = recorder.live { mono((live.source.micOnly ? "Mic only" : live.source.name) + (live.transcribedBy.map { " · " + $0 } ?? ""), size: 11, color: Palette.ink70).lineLimit(1) }
                Button { collapsed = true } label: { Label("Minimize", systemImage: "arrow.down.right.and.arrow.up.left").labelStyle(.iconOnly).font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("Minimize to a small pill with the timer and Stop").accessibilityLabel("Minimize to a small indicator")
            }
            HStack(spacing: 8) {
                Text(MeetingConsent.reminder).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Button("Copy Notice", action: recorder.copyNotice).buttonStyle(.link).font(.system(size: 13))
            }
            if !recorder.persists { Text("History is off: this meeting is kept only until Murmur quits.").font(.system(size: 12)).foregroundStyle(Palette.accentDeep) }
            if let problem = recorder.systemAudioProblem {
                VStack(alignment: .leading, spacing: 6) {
                    Text(problem).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Record Only My Microphone", action: recorder.continueWithMicrophoneOnly).font(.system(size: 12))
                        Button("Stop", action: recorder.stop).font(.system(size: 12))
                    }
                }
                .padding(8).background(Palette.accent16)
            }
            if let warning = recorder.warning { Text(warning).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accentDeep).fixedSize(horizontal: false, vertical: true) }
            if recorder.behind { Text("The transcript is behind; nothing is lost.").font(.system(size: 12)).foregroundStyle(Palette.ink70) }
            if recorder.askEnded {
                HStack { Text("Call ended?").font(.system(size: 13, weight: .semibold)); Spacer(); Button("Stop", action: recorder.stop) }
            }
            meter("Me", recorder.meLevel)
            if recorder.live?.source.micOnly == false {
                meter("Them", recorder.themLevel)
                if recorder.live?.source.bundleID == "com.apple.Safari" { Text("Safari plays audio through a shared WebKit process, so Mail and other WebKit apps are recorded too.").font(.system(size: 11)).foregroundStyle(Palette.ink64).fixedSize(horizontal: false, vertical: true) }
                if recorder.live?.source.allApps == true { Text("All apps: music and notification sounds are recorded too.").font(.system(size: 11)).foregroundStyle(Palette.ink64) }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        let lines = (recorder.live?.lines ?? []).filter { !$0.isHidden }.suffix(40)
                        if lines.isEmpty { Text("Lines appear about 15 seconds after they are spoken.").font(.system(size: 12)).foregroundStyle(Palette.ink64) }
                        ForEach(Array(lines)) { line in MeetingLineRow(line: line).id(line.id) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: recorder.live?.lines.count) { if let last = recorder.live?.lines.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
            }
            mono("My notes", size: 10, color: Palette.accentInk)
            TextField("Type a note", text: $notes, axis: .vertical).textFieldStyle(.plain).font(.system(size: 13)).lineLimit(2...4)
                .padding(6).overlay(Rectangle().strokeBorder(Palette.ink20, lineWidth: 1))
            HStack {
                Button("Cancel…") { confirmCancel = true }.buttonStyle(InkButtonStyle(kind: .plain))
                Spacer()
                Button("Stop", action: recorder.stop).buttonStyle(InkButtonStyle(kind: .filled))
            }
        }
        .padding(14).frame(width: 340, height: 520).modifier(UtilityGlass(radius: 18))
        .alert("Discard this meeting?", isPresented: $confirmCancel) {
            Button("Discard", role: .destructive, action: recorder.cancel)
            Button("Keep Recording", role: .cancel) {}
        } message: { Text("The recording and its transcript are deleted.") }
    }

    private func meter(_ label: String, _ level: Double) -> some View {
        HStack(spacing: 8) {
            mono(label, size: 10, color: Palette.ink70).frame(width: 40, alignment: .leading)
            GeometryReader { g in Rectangle().fill(Palette.accent).frame(width: g.size.width * min(1, level)) }
                .frame(height: 6).background(Palette.ink20)
        }
        .accessibilityElement().accessibilityLabel("\(label) level").accessibilityValue("\(Int(min(1, level) * 100)) percent")
    }
}

private final class MeetingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Shows the live panel while a meeting records: top right of the main screen at first, then where
/// the user drags it. Minimized or not, and where, are remembered across meetings. It cannot be
/// closed while recording (PRD 11.3, R6).
@MainActor final class MeetingPanelPresenter {
    static let collapsedKey = "meetingPanelCollapsed", cornerKey = "meetingPanelTopRight"
    private var panel: MeetingPanel?
    private let recorder: MeetingRecorder
    private var collapsed: Bool { UserDefaults.standard.bool(forKey: Self.collapsedKey) }
    private var moved: NSObjectProtocol?

    init(recorder: MeetingRecorder) { self.recorder = recorder }
    /// The panel's content, for the UI fixture's snapshot.
    var view: NSView? { panel?.contentView }

    func update() {
        guard recorder.live != nil else {
            if let moved { NotificationCenter.default.removeObserver(moved) }; moved = nil
            panel?.orderOut(nil); panel = nil
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: "Meeting notes stopped", .priority: NSAccessibilityPriorityLevel.high.rawValue])
            return
        }
        if panel == nil {
            let next = MeetingPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 520), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            next.level = .floating; next.isFloatingPanel = true; next.hidesOnDeactivate = false
            next.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            next.backgroundColor = .clear; next.isOpaque = false; next.hasShadow = true; next.isMovableByWindowBackground = true
            next.contentView = NSHostingView(rootView: LivePanelRoot(recorder: recorder) { [weak self] _ in self?.place() })
            panel = next
            // Remember where the user drags it (its top-right corner, so minimizing keeps it in place).
            moved = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: next, queue: .main) { [weak next] _ in
                MainActor.assumeIsolated {
                    guard let frame = next?.frame else { return }
                    UserDefaults.standard.set([frame.maxX, frame.maxY], forKey: Self.cornerKey)
                }
            }
            place(initial: true)
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: "Meeting notes recording", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        panel?.orderFrontRegardless()
    }

    /// Keeps the panel's top-right corner where it was (or where it was last left) and resizes around it.
    private func place(initial: Bool = false) {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = collapsed ? NSSize(width: 180, height: 40) : NSSize(width: 340, height: 520)
        let visible = screen.visibleFrame
        var corner = NSPoint(x: visible.maxX - 16, y: visible.maxY - 16)
        if !initial { corner = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY) }
        else if let saved = UserDefaults.standard.array(forKey: Self.cornerKey) as? [Double], saved.count == 2,
                NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(NSPoint(x: saved[0] - 1, y: saved[1] - 1)) }) {
            corner = NSPoint(x: saved[0], y: saved[1])
        }
        panel.setFrame(NSRect(x: corner.x - size.width, y: corner.y - size.height, width: size.width, height: size.height), display: true)
    }
}

private struct LivePanelRoot: View {
    @ObservedObject var recorder: MeetingRecorder
    let changed: (Bool) -> Void
    @AppStorage(MeetingPanelPresenter.collapsedKey) private var collapsed = false
    var body: some View {
        MeetingLiveView(recorder: recorder, collapsed: $collapsed)
            .onChange(of: collapsed) { changed(collapsed) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}
