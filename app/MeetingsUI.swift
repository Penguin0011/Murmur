import AppKit
import SwiftUI

// Meeting notes UI (PRD 11.9): the Meetings page in Murmur's window, the one-time consent sheet,
// and the live panel that stays on screen for the whole recording (PRD 11.3).

private func mono(_ text: String, size: CGFloat = 12, color: Color = Palette.ink) -> some View {
    Text(text).font(.system(size: size, design: .monospaced)).tracking(size * 0.08).textCase(.uppercase).foregroundStyle(color)
}
private func lede(_ text: String, color: Color = Palette.ink70) -> some View {
    Text(text).font(WindowType.body(14)).lineSpacing(2).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
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
            Text(title).font(WindowType.body(14, weight: .semibold)).padding(.horizontal, 18).frame(height: 36)
                .foregroundStyle(Palette.paper).background(Palette.ink, in: Capsule())
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
    @State private var tab = MeetingsPage.initialTab
    /// The speaker being renamed (W7d) and the name typed so far.
    @State private var renaming: Int?
    @State private var nameDraft = ""
    /// The UI fixture opens other tabs (check_ui.swift --transcript).
    static var initialTab = DetailTab.notes
    /// A cited line to scroll to and highlight on the Transcript tab.
    @State private var jump: Int?

    enum DetailTab: String, CaseIterable { case notes = "Notes", transcript = "Transcript", mine = "My notes" }

    private var filtered: [Meeting] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return recorder.meetings }
        return recorder.meetings.filter { $0.title.lowercased().contains(query) || $0.lines.contains { $0.text.lowercased().contains(query) } }
    }
    private var selected: Meeting? { filtered.first { $0.id == selectedID } ?? filtered.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Meetings").font(WindowType.display(40)).tracking(-0.8)
                    Text("Find transcripts and notes from your calls.")
                        .font(WindowType.body(14)).foregroundStyle(Palette.ink70)
                    DisclosureGroup("Audio and privacy") {
                        lede(controller.speakerSettings.enabled
                         ? "Your microphone as Me and the call’s audio as Them, transcribed on this Mac. Your audio is deleted as soon as it is transcribed; the call’s is kept until its speakers are separated, at most 24 hours."
                         : "Your microphone as Me and the call’s audio as Them, transcribed on this Mac. Audio is deleted as soon as it is transcribed.")
                    }
                    .font(WindowType.body(13))
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
            .padding(.horizontal, 24).padding(.vertical, 12)
            if let message = recorder.message {
                HStack {
                    Text(message).font(WindowType.body(14)).fixedSize(horizontal: false, vertical: true)
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
                GeometryReader { geometry in
                    if geometry.size.width < 680 {
                        VStack(spacing: 12) {
                            TextField("Search meetings", text: $search).textFieldStyle(.roundedBorder)
                            Picker("Meeting", selection: Binding(get: { selected?.id ?? "" }, set: { selectedID = $0 })) {
                                ForEach(filtered) { meeting in Text(meeting.title).tag(meeting.id) }
                            }
                            if let meeting = selected { detail(meeting) }
                            else { lede("No matching meetings.") }
                        }
                        .padding(.horizontal, 24).padding(.top, 12)
                    } else {
                        HStack(spacing: 0) {
                            list.frame(width: 200)
                            Rectangle().fill(Palette.ink20).frame(width: 1)
                            if let meeting = selected { detail(meeting) } else { Spacer() }
                        }
                    }
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
        } message: { Text("The transcript, its notes and your own notes are deleted. This cannot be undone.") }
        .background(Color.clear.sheet(isPresented: Binding(get: { recorder.notesChoicePending != nil && recorder.consentPending == nil }, set: { if !$0 { recorder.notesChoicePending = nil } })) {
            MeetingNotesChoiceSheet(controller: controller) { route in
                controller.meetingNotesRoute = route
                recorder.notesRouteChosen(route)
            }
        })
    }

    private var list: some View {
        VStack(spacing: 0) {
            TextField("Search meetings", text: $search).textFieldStyle(.plain).font(WindowType.body(14))
                .padding(.horizontal, 12).frame(height: 40).overlay(alignment: .bottom) { Rectangle().fill(Palette.ink20).frame(height: 1) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { meeting in
                        Button { selectedID = meeting.id; notesDraft = meeting.myNotes } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(meeting.title).font(WindowType.body(14, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                HStack(spacing: 8) {
                                    mono(MeetingExport.clock(meeting.seconds), size: 11, color: Palette.ink70)
                                    if recorder.finishing.contains(meeting.id) { mono("Finishing", size: 11, color: Palette.accentDeep) }
                                    else if recorder.separating.contains(meeting.id) { mono("Separating speakers", size: 11, color: Palette.accentDeep) }
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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(meeting.title).font(WindowType.body(22, weight: .bold)).tracking(-0.5).textSelection(.enabled)
                    mono("\(MeetingExport.clock(meeting.seconds)) · \(meeting.source.micOnly ? "My microphone only" : "Me and \(meeting.source.name)") · \(meeting.transcribedBy.map { "Transcribed by \($0)" } ?? "Transcribed on this Mac")", size: 11, color: Palette.ink70)
                    let actions = Group {
                        if meeting.notes?.isEmpty == false { Button("Copy Notes") { recorder.copyNotes(meeting) }.buttonStyle(InkButtonStyle(kind: .outline)) }
                        Button("Copy Transcript") { recorder.copyTranscript(meeting) }.buttonStyle(InkButtonStyle(kind: .outline))
                        Button("Save Markdown…") { recorder.saveMarkdown(meeting) }.buttonStyle(InkButtonStyle(kind: .outline))
                        Button("Delete…") { confirmDelete = meeting }.buttonStyle(InkButtonStyle(kind: .plain))
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { actions }.fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 8) { actions }
                    }
                    if recorder.finishing.contains(meeting.id) { lede("Finishing the transcript…", color: Palette.accentDeep) }
                    else if let left = recorder.leftovers[meeting.id] {
                        HStack {
                            lede("\(left) \(left == 1 ? "part" : "parts") of this meeting \(left == 1 ? "was" : "were") not transcribed. The audio is kept for up to 24 hours.")
                            Button("Finish Transcript") { recorder.finishLeftovers(meeting.id) }.buttonStyle(InkButtonStyle(kind: .filled))
                        }
                    }
                    HStack(spacing: 12) {
                        ForEach(DetailTab.allCases, id: \.self) { item in
                            Button { tab = item } label: {
                                Text(item.rawValue).font(WindowType.body(13, weight: .semibold)).padding(.horizontal, 14).frame(height: 32)
                                    .foregroundStyle(tab == item ? Palette.ink : Palette.ink70)
                                    .overlay(alignment: .bottom) { Rectangle().fill(tab == item ? Palette.accentInk : Color.clear).frame(height: 2) }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).accessibilityAddTraits(tab == item ? .isSelected : [])
                        }
                    }
                    .padding(.top, 4)
                    switch tab {
                    case .notes: notesTab(meeting)
                    case .mine:
                        TextEditor(text: $notesDraft).font(WindowType.body(14)).scrollContentBackground(.hidden).frame(minHeight: 160)
                            .padding(6).overlay(Rectangle().strokeBorder(Palette.ink, lineWidth: 1.5))
                            .onChange(of: notesDraft) { if notesDraft != meeting.myNotes { recorder.setNotes(notesDraft, for: meeting.id) } }
                            .onAppear { notesDraft = meeting.myNotes }
                        lede("Your own notes go into the generated notes as yours. Editing them marks the notes out of date.", color: Palette.ink64)
                    case .transcript:
                        speakers(meeting)
                        HStack {
                            Spacer()
                            if meeting.lines.contains(where: { $0.shown != nil }) {
                                Toggle("Show hidden echo", isOn: $showEcho).toggleStyle(.checkbox).font(WindowType.body(13))
                            }
                        }
                        if meeting.lines.isEmpty { lede("No words were transcribed.") }
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(meeting.lines.filter { showEcho || !$0.isHidden }) { line in
                                MeetingLineRow(line: line, showEcho: showEcho, label: MeetingSpeakers.label(line, in: meeting),
                                               moveTo: meeting.speakers?.state == .done && line.stream == .them ? { recorder.reassignLine(line.id, to: $0, in: meeting.id) } : nil,
                                               speakers: MeetingSpeakers.numbers(meeting).map { ($0, meeting.speakers?.names[$0] ?? "Speaker \($0)") }).id(line.id)
                                    .padding(.vertical, 2).background(jump == line.id ? Palette.accent16 : Color.clear)
                            }
                        }
                    }
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: jump) { if let jump { withAnimation(nil) { proxy.scrollTo(jump, anchor: .center) } } }
            .onChange(of: meeting.id) { notesDraft = meeting.myNotes; jump = nil }
        }
        .alert("Rename speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Rename") { if let number = renaming { recorder.renameSpeaker(number, to: nameDraft, in: meeting.id) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: { Text("The name is kept with this meeting only. Leave it empty to go back to “Speaker \(renaming ?? 0)”.") }
    }

    /// Notes, with each item's cited lines as links into the transcript (PRD 11.6, 11.9).
    @ViewBuilder private func notesTab(_ meeting: Meeting) -> some View {
        let route = controller.meetingNotesRoute
        let separating = meeting.speakers?.state == .pending
        if recorder.notesWriting.contains(meeting.id) {
            lede("Writing notes…", color: Palette.accentDeep)
        } else if separating {
            // Notes wait for speaker names (W7d): "Separating speakers…" first, then "Writing notes…".
            lede(recorder.separating.contains(meeting.id) ? "Separating speakers… Notes are written after that, with their names." : "Notes are written once speakers are separated. Skip separation to write them now.", color: Palette.accentDeep)
        } else if let problem = recorder.notesProblem[meeting.id] {
            HStack(alignment: .firstTextBaseline) {
                lede(problem, color: Palette.accentDeep)
                Spacer()
                Button("Try Again") { recorder.writeNotes(meeting.id) }.buttonStyle(InkButtonStyle(kind: .outline))
            }
        }
        if let notes = meeting.notes {
            if notes.outdated == true {
                HStack(alignment: .firstTextBaseline) {
                    lede("The transcript, your notes or the speakers changed after these notes were written.", color: Palette.accentDeep)
                    Spacer()
                }
            }
            if notes.isEmpty { lede("Nothing in the transcript could be written up as a point, decision or action item.") }
            if let summary = notes.summary { Text(summary).font(WindowType.body(15)).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            noteSection("Key points", notes.keyPoints, meeting: meeting)
            noteSection("Decisions", notes.decisions, meeting: meeting)
            noteSection("Action items", notes.actions, meeting: meeting, actions: true)
            HStack(alignment: .firstTextBaseline) {
                lede("Written by \(notes.route). Items cite the lines they rest on\(notes.dropped > 0 ? "; \(notes.dropped) the transcript did not support \(notes.dropped == 1 ? "was" : "were") left out" : "").", color: Palette.ink64)
                Spacer()
                if route != nil && route != MeetingNotesRoute.none {
                    Button("Update Notes") { recorder.writeNotes(meeting.id) }.buttonStyle(InkButtonStyle(kind: .outline))
                        .disabled(recorder.notesWriting.contains(meeting.id) || recorder.finishing.contains(meeting.id) || separating)
                }
            }
        } else if !recorder.notesWriting.contains(meeting.id) && !separating {
            if route == nil || route == MeetingNotesRoute.none {
                HStack(alignment: .firstTextBaseline) {
                    lede(route == nil ? "Choose how notes are written: a title, summary, key points, decisions and action items." : "Notes are off. This meeting keeps its transcript.")
                    Spacer()
                    Button("Choose Notes Route…") { recorder.notesChoicePending = meeting.id }.buttonStyle(InkButtonStyle(kind: .outline))
                }
            } else if recorder.notesProblem[meeting.id] == nil {
                HStack(alignment: .firstTextBaseline) {
                    lede("No notes yet.")
                    Spacer()
                    Button("Write Notes") { recorder.writeNotes(meeting.id) }.buttonStyle(InkButtonStyle(kind: .filled))
                        .disabled(recorder.finishing.contains(meeting.id) || meeting.lines.allSatisfy(\.isHidden))
                }
            }
        }
    }

    /// Speaker separation (W7d, PRD 11.8 and 11.9): progress with Skip, then each speaker with
    /// Rename and Merge. Names and merges belong to this meeting only.
    @ViewBuilder private func speakers(_ meeting: Meeting) -> some View {
        if let status = SpeakerFacts.status(meeting.speakers, running: recorder.separating.contains(meeting.id)) {
            HStack(spacing: 12) {
                lede(status, color: meeting.speakers?.state == .failed ? Palette.ink70 : Palette.accentDeep)
                Spacer()
                if meeting.speakers?.state == .pending { Button("Skip") { recorder.skipSeparation(meeting.id) }.buttonStyle(InkButtonStyle(kind: .outline)) }
            }
        }
        let numbers = MeetingSpeakers.numbers(meeting)
        if meeting.speakers?.state == .done, !numbers.isEmpty {
            mono("Speakers", size: 11, color: Palette.accentInk).padding(.top, 6)
            FlowRow(numbers.map { number in
                AnyView(Menu(meeting.speakers?.names[number] ?? "Speaker \(number)") {
                    Button("Rename…") { nameDraft = meeting.speakers?.names[number] ?? ""; renaming = number }
                    if numbers.count > 1 {
                        Menu("Merge into") {
                            ForEach(numbers.filter { $0 != number }, id: \.self) { other in
                                Button(meeting.speakers?.names[other] ?? "Speaker \(other)") { recorder.mergeSpeaker(number, into: other, in: meeting.id) }
                            }
                        }
                    }
                }.menuStyle(.button).fixedSize())
            })
            lede("Names stay with this meeting. To move one line, use its speaker label.", color: Palette.ink64)
        }
    }

    @ViewBuilder private func noteSection(_ title: String, _ items: [NoteItem], meeting: Meeting, actions: Bool = false) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                mono(title, size: 11, color: Palette.accentInk).padding(.top, 6)
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if actions {
                            Toggle("", isOn: Binding(get: { item.done == true }, set: { _ in recorder.toggleAction(index, of: meeting.id) }))
                                .toggleStyle(.checkbox).labelsHidden().accessibilityLabel(item.done == true ? "Done" : "Not done")
                        } else { Text("•").font(WindowType.body(14)).accessibilityHidden(true) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.text).font(WindowType.body(14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .strikethrough(item.done == true)
                            HStack(spacing: 8) {
                                if let owner = item.owner { mono(owner, size: 10, color: Palette.ink70) }
                                if let due = item.due { mono("Due \(due)", size: 10, color: Palette.ink70) }
                                ForEach(item.lines, id: \.self) { id in
                                    if let line = meeting.lines.first(where: { $0.id == id }) {
                                        Button { tab = .transcript; jump = id } label: { mono(MeetingExport.clock(line.start), size: 10, color: Palette.accentInk).underline() }
                                            .buttonStyle(.plain).help("Show this line in the transcript")
                                            .accessibilityLabel("Cited line at \(MeetingExport.clock(line.start))")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The notes route options with the selected route's disclosure (Settings, and the first-Stop question).
struct MeetingNotesRoutePicker: View {
    @ObservedObject var controller: AppController
    var tooltipDetails = false
    @Binding var selection: MeetingNotesRoute
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 4) {
                Picker("Meeting notes", selection: $selection) {
                    ForEach(MeetingNotesRoute.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup).labelsHidden().font(WindowType.body(14))
                if tooltipDetails { SettingInfoButton(text: controller.meetingNotesDisclosure(selection)) }
            }
            if !tooltipDetails { lede(controller.meetingNotesDisclosure(selection), color: Palette.ink) }
            if selection != MeetingNotesRoute.none, let refusal = controller.meetingNotesSetupProblem(selection) { lede(refusal, color: Palette.accentDeep) }
        }
    }
}

/// Asked once, at the first Stop, with None preselected (Q3).
struct MeetingNotesChoiceSheet: View {
    @ObservedObject var controller: AppController
    let done: (MeetingNotesRoute) -> Void
    @State private var route = MeetingNotesRoute.none
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Write notes for your meetings?").font(WindowType.body(20, weight: .bold))
            lede("After Stop, a model can write a title, a summary, key points, decisions and action items from the transcript. Each item cites the lines it rests on, and items the transcript does not support are left out. You can change this in Settings → Meetings.")
            MeetingNotesRoutePicker(controller: controller, selection: $route)
            HStack {
                Spacer()
                Button("Save") { done(route) }.buttonStyle(InkButtonStyle(kind: .filled)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 500).foregroundStyle(Palette.ink).background(Palette.paper)
    }
}

private struct ConsentItem: Identifiable { let source: MeetingSource; var id: String { source.name + (source.bundleID ?? "") } }

struct MeetingLineRow: View {
    let line: MeetingLine
    var showEcho = false
    /// "Speaker 2" or a given name once speakers are separated (W7d); the stream's label otherwise.
    var label: String? = nil
    /// Set on Them lines after separation: moves this line to another (or a new) speaker.
    var moveTo: ((Int) -> Void)? = nil
    var speakers: [(Int, String)] = []
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            mono(MeetingExport.clock(line.start), size: 11, color: Palette.ink64).frame(width: 56, alignment: .leading)
            let name = label ?? MeetingExport.label(line.stream)
            Group {
                if let moveTo {
                    Menu {
                        ForEach(speakers.filter { $0.0 != line.speaker }, id: \.0) { speaker in Button("Move to \(speaker.1)") { moveTo(speaker.0) } }
                        Button("Move to a new speaker") { moveTo((speakers.map(\.0).max() ?? 0) + 1) }
                    } label: { mono(name, size: 11, color: Palette.ink).lineLimit(1) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel("\(name), change speaker")
                } else {
                    mono(name, size: 11, color: line.stream == .me ? Palette.accentInk : Palette.ink).lineLimit(1)
                }
            }
            .frame(width: label == nil ? 44 : 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(showEcho ? line.text : line.visibleText).font(WindowType.body(14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
            Text(MeetingConsent.title).font(WindowType.body(20, weight: .bold))
            lede(MeetingConsent.body)
            Toggle(MeetingConsent.acknowledgement, isOn: $ticked).toggleStyle(.checkbox).font(WindowType.body(14, weight: .semibold))
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

/// Lays chips out left to right; SwiftUI's HStack would not wrap on a narrow window.
private struct FlowRow: View {
    let items: [AnyView]
    init(_ items: [AnyView]) { self.items = items }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { ForEach(items.indices, id: \.self) { items[$0] } }
            VStack(alignment: .leading, spacing: 6) { ForEach(items.indices, id: \.self) { items[$0] } }
        }
    }
}

/// Settings → Meetings → speaker separation (W7d): the switch, then its optional download while on.
struct SpeakerSettingsSection: View {
    @ObservedObject var settings: SpeakerModelSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            mono("Speakers", size: 11, color: Palette.accentInk).padding(.top, 18)
            Toggle(isOn: $settings.enabled) {
                HStack(spacing: 4) {
                    Text(SpeakerFacts.displayName).font(.system(size: 16, weight: .semibold))
                    SettingInfoButton(text: SpeakerFacts.explanation + (settings.row.isReady ? "" : "\n\nUntil it is downloaded, the call’s side is labelled Them and no audio is kept."))
                }
            }
            .toggleStyle(MurmurToggleStyle())
            if settings.enabled {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text("pyannote community-1").font(WindowType.body(14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                            ModelInfoIcons(license: SpeakerFacts.credits, details: settings.summary)
                        }
                        if settings.row.isReady { mono("Ready ✓", color: Palette.accentInk) }
                        else { lede(settings.row.statusText) }
                    }
                    Spacer()
                    let row = settings.row
                    if row.actions.contains(.download) { Button("Download…", action: settings.download).buttonStyle(InkButtonStyle()).fixedSize() }
                    if row.actions.contains(.retry) { Button("Retry…", action: settings.download).buttonStyle(InkButtonStyle()).fixedSize() }
                    if row.actions.contains(.cancel) { Button("Cancel", action: settings.cancelDownload).buttonStyle(InkButtonStyle(kind: .outline)).fixedSize() }
                    if row.actions.contains(.remove) { Button("Remove…", role: .destructive, action: settings.remove).buttonStyle(InkButtonStyle(kind: .outline)).fixedSize() }
                }
                if let progress = settings.row.progress {
                    ProgressView(value: progress).accessibilityLabel("Download progress")
                }
                if !settings.message.isEmpty { lede(settings.message, color: Palette.ink) }
            }
        }
    }
}
