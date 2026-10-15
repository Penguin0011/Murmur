// Recording experience checks (BetterWispr gaps #14, #16, #18). No capture, insertion or key injection:
// synthetic CGEvents go straight into ShortcutListener.receive, never through a tap.
import Foundation
import CoreGraphics
import Carbon.HIToolbox
import AVFoundation

@main struct RecordingChecks {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() {
        shortcutChecks()
        buttonStartChecks()
        undoChecks()
        microphoneChecks()
        meetingCaptureChecks()
        print("Recording checks passed (shortcut validation and custom binding; cancel-undo window, discard and session hook; Automatic microphone rule; a meeting's microphone is never current).")
    }

    /// A dictation during a meeting (PRD 11.1): the shortcut thread cuts only `Capture.current`, which a
    /// meeting's microphone never becomes, and a dictation ending does not unregister anything else.
    static func meetingCaptureChecks() {
        let meeting = Capture(), dictation = Capture()
        meeting.register(current: false)
        check(Capture.current == nil, "a meeting's microphone does not become current")
        dictation.register(current: true)
        check(Capture.current === dictation, "the dictation is what release cuts")
        meeting.unregister()
        check(Capture.current === dictation, "the meeting stopping leaves the dictation current")
        dictation.unregister()
        check(Capture.current == nil, "the dictation finishing leaves nothing current; the meeting keeps recording")
    }

    /// Home's Start button (gap #19): a latched start the next shortcut press finishes.
    static func buttonStartChecks() {
        var machine = ShortcutMachine()
        check(machine.startToggled() == .start && machine.state == .listening, "button start listens")
        check(machine.startToggled() == nil, "a second button start does nothing")
        check(machine.release(at: 1) == nil, "a stray release does not finish it")
        check(machine.press(at: 2) == .finish && machine.state == .processing, "the next press finishes it")
        check(machine.release(at: 2.1) == nil, "that press's release does nothing")
        check(machine.startToggled() == nil, "no start while processing")
        machine.processingFinished()
        check(machine.startToggled() == .start && machine.finish() == .finish, "Finish ends a button start")
        machine.processingFinished()
        _ = machine.press(at: 5)
        check(machine.startToggled() == nil, "no button start while a key is down")
        var cancelled = ShortcutMachine(); _ = cancelled.startToggled()
        check(cancelled.cancel() == .cancel && cancelled.state == .idle, "Escape cancels a button start")
    }

    static func shortcutChecks() {
        let ctrlOpt: CGEventFlags = [.maskControl, .maskAlternate]
        func refused(_ key: Int, _ flags: CGEventFlags) -> Bool { CustomShortcut.refusal(keyCode: Int64(key), modifiers: flags) != nil }
        // Accepted.
        check(!refused(kVK_ANSI_D, ctrlOpt), "⌃⌥D accepted")
        check(!refused(kVK_ANSI_D, [.maskCommand, .maskAlternate]), "⌘⌥D accepted")
        check(!refused(kVK_ANSI_D, .maskControl), "⌃D accepted")
        check(!refused(kVK_Space, [.maskAlternate]), "⌥Space accepted")
        check(!refused(kVK_F5, []), "F5 alone accepted")
        check(!refused(kVK_F13, .maskShift), "⇧F13 accepted")
        check(!refused(kVK_F5, .maskCommand), "⌘F5 accepted")
        // Refused, each with a reason.
        check(refused(kVK_ANSI_D, []), "plain D refused: it types")
        check(refused(kVK_ANSI_D, .maskShift), "⇧D refused: Shift alone types")
        check(refused(kVK_Escape, []) && refused(kVK_Escape, ctrlOpt), "Escape refused: it cancels")
        check(refused(kVK_ANSI_C, [.maskControl, .maskCommand]) && refused(kVK_ANSI_V, [.maskControl, .maskCommand]), "⌃⌘C and ⌃⌘V refused: Murmur's own")
        check(!refused(kVK_ANSI_C, ctrlOpt), "⌃⌥C is not the copy chord")
        for key in [kVK_ANSI_Q, kVK_ANSI_W, kVK_Tab, kVK_Space, kVK_ANSI_C] { check(refused(key, .maskCommand), "⌘ chord \(key) refused") }
        for key in [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5] { check(refused(key, [.maskCommand, .maskShift]), "screenshot chord \(key) refused") }
        check(refused(kVK_Space, .maskControl) && refused(kVK_Space, [.maskControl, .maskCommand]), "input source and emoji chords refused")
        check(refused(kVK_LeftArrow, .maskControl), "Mission Control chord refused")
        for key in [kVK_Command, kVK_Option, kVK_RightOption, kVK_Control, kVK_Shift, kVK_CapsLock, kVK_Function] {
            check(refused(key, ctrlOpt), "modifier key \(key) refused as the main key")
        }
        check(CustomShortcut.refusal(keyCode: Int64(kVK_ANSI_D), modifiers: []).map { $0.contains("⌘, ⌥ or ⌃") } == true, "the reason names what to add")

        // Stored form round-trips; presets and unusable values parse safely.
        let custom = CustomShortcut(keyCode: Int64(kVK_ANSI_D), modifiers: [.maskControl, .maskAlternate, .maskSecondaryFn], key: "D")
        check(custom.modifiers == ctrlOpt, "only ⌘⌥⌃⇧ are kept")
        check(custom.label == "⌃⌥D", "label in menu order")
        check(ShortcutBinding(stored: custom.stored) == .custom(custom), "custom round-trips")
        check(CustomShortcut(stored: "custom:2:\(ctrlOpt.rawValue):a:b")?.key == "a:b", "a key name with a colon round-trips")
        check(ShortcutBinding(stored: "right-option") == .rightOption && ShortcutBinding(stored: "fn") == .fn && ShortcutBinding(stored: "ctrl-option-space") == .controlOptionSpace, "presets parse")
        check(ShortcutBinding(stored: "custom:53:0:Esc") == .rightOption, "a stored refused key falls back to Right Option")
        check(ShortcutBinding(stored: "garbage") == .rightOption && ShortcutBinding(stored: "custom:x") == .rightOption, "garbage falls back to Right Option")

        // The binding matches its chord even with the Fn/keypad flags F-keys and arrows carry.
        func key(_ code: Int, _ down: Bool, _ flags: CGEventFlags, at seconds: Double = 0) -> CGEvent {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
            event.flags = flags; event.timestamp = UInt64(seconds * 1_000_000_000); return event
        }
        let binding = ShortcutBinding.custom(custom)
        check(binding.isDown(key(kVK_ANSI_D, true, ctrlOpt.union(.maskSecondaryFn))), "Fn flag ignored")
        check(!binding.isDown(key(kVK_ANSI_D, true, ctrlOpt.union(.maskShift))), "an extra Shift is another chord")
        check(binding.consumes(.keyDown, key(kVK_ANSI_D, true, ctrlOpt)) && binding.consumes(.keyUp, key(kVK_ANSI_D, false, ctrlOpt)), "the chord's key is swallowed")
        check(!binding.consumes(.keyDown, key(kVK_ANSI_D, true, [])), "plain D passes through")
        let f5 = ShortcutBinding.custom(CustomShortcut(keyCode: Int64(kVK_F5), modifiers: [], key: "F5"))
        check(f5.isDown(key(kVK_F5, true, [.maskSecondaryFn, .maskNumericPad])), "F5 matches with the flags F-keys carry")
        check(!ShortcutBinding.rightOption.consumes(.keyDown, key(kVK_ANSI_D, true, ctrlOpt)), "presets without a key swallow nothing")

        // Hold, double-press, toggle and Escape behave as with the presets.
        var actions: [ShortcutMachine.Action] = []
        let listener = ShortcutListener(binding: binding, processingSeconds: 0) { action, done in actions.append(action); if action != .finish { done() } }
        func feed(_ event: CGEvent) { listener.receive(type: event.type, event: event) }
        feed(key(kVK_ANSI_D, true, ctrlOpt, at: 1)); feed(key(kVK_ANSI_D, false, ctrlOpt, at: 1.6))
        check(actions == [.start, .finish], "hold records until release")
        listener.machine.processingFinished()
        feed(key(kVK_ANSI_D, true, ctrlOpt, at: 3)); feed(key(kVK_ANSI_D, false, ctrlOpt, at: 3.1))
        feed(key(kVK_ANSI_D, true, ctrlOpt, at: 3.3)); feed(key(kVK_ANSI_D, false, ctrlOpt, at: 3.4))
        check(actions == [.start, .finish, .start] && listener.machine.state == .listening, "double press latches a toggle")
        feed(key(kVK_ANSI_D, true, ctrlOpt.union(.maskShift), at: 5))
        check(listener.machine.state == .listening, "a different chord does not stop it")
        feed(key(kVK_Escape, true, [], at: 6))
        check(actions == [.start, .finish, .start, .cancel] && listener.machine.state == .idle, "Escape cancels")
        let toggle = ShortcutListener(binding: binding, processingSeconds: 0) { action, done in actions.append(action); if action != .finish { done() } }
        toggle.pressToToggle = true; actions = []
        toggle.receive(type: .keyDown, event: key(kVK_ANSI_D, true, ctrlOpt, at: 1)); toggle.receive(type: .keyUp, event: key(kVK_ANSI_D, false, ctrlOpt, at: 1.1))
        toggle.receive(type: .keyDown, event: key(kVK_ANSI_D, true, ctrlOpt, at: 4))
        check(actions == [.start, .finish], "press-to-toggle: tap starts, next press finishes")
    }

    static func undoChecks() {
        // The window: open for `lifetime`, handed over once, gone after it or on discard.
        var clock = Date(timeIntervalSince1970: 1_000)
        let window = UndoWindow<[Float]>(lifetime: 5); window.now = { clock }
        check(!window.isOpen && window.take() == nil, "nothing held at first")
        window.hold([0.1, 0.2])
        clock += 4.9
        check(window.isOpen && window.take() == [0.1, 0.2], "taken inside the window")
        check(window.take() == nil && !window.isOpen, "taken only once")
        window.hold([0.3]); clock += 5
        check(!window.isOpen && window.take() == nil, "nothing after the window")
        window.hold([0.4]); window.discard()
        check(!window.isOpen && window.take() == nil, "discard drops it (a new recording calls this)")
        window.hold([0.5]); window.hold([0.6])
        check(window.take() == [0.6], "a later cancel replaces the earlier one")
        window.hold([0.7]); _ = window.take(); clock += 1
        check(window.take() == nil, "an expired take also releases the audio")

        // The session shows the canceled file to Undo just before deleting it; a finish never does.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-undo-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        guard let store = try? RetryAudio(directory: root) else { check(false, "temporary retry store"); return }
        var seen: [URL] = [], existed = false
        let session = CaptureSession(store: store, start: { url in try Data([1, 2, 3]).write(to: url) }, stop: { true }, process: { _, done in done() })
        session.willDeleteCanceled = { url in seen.append(url); existed = FileManager.default.fileExists(atPath: url.path) }
        session.receive(.start, completed: {})
        let audio = session.audio
        session.receive(.cancel, completed: {})
        check(seen == [audio].compactMap { $0 } && existed, "the hook sees the canceled file before deletion")
        check(audio.map { !FileManager.default.fileExists(atPath: $0.path) } == true && session.state == .idle, "the file is still deleted at cancel")
        session.receive(.start, completed: {}); session.receive(.finish, completed: {})
        check(seen.count == 1, "a finished recording is not offered to Undo")

        // Undo runs as processing: a press meanwhile is ignored, and the shortcut works after.
        var actions: [ShortcutMachine.Action] = []
        let listener = ShortcutListener(binding: .controlOptionSpace, processingSeconds: 0) { action, done in actions.append(action); done() }
        var finish: (() -> Void)?
        check(listener.runAsProcessing { finish = $0 } && listener.machine.state == .processing, "Undo puts the shortcut into processing")
        check(!listener.runAsProcessing { _ in }, "a second Undo cannot start")
        let chord: CGEventFlags = [.maskControl, .maskAlternate]
        func key(_ down: Bool, _ at: Double) -> CGEvent {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Space), keyDown: down)!
            event.flags = chord; event.timestamp = UInt64(at * 1_000_000_000); return event
        }
        listener.receive(type: .keyDown, event: key(true, 1)); listener.receive(type: .keyUp, event: key(false, 1.5))
        check(actions.isEmpty, "a press during Undo starts nothing")
        finish?()
        check(listener.machine.state == .idle, "Undo finishing frees the shortcut")
        listener.receive(type: .keyDown, event: key(true, 3))
        check(actions == [.start], "the next press starts a dictation")

        // Only Escape or the menu's Cancel count as the user's cancel; a lone tap's expiry does not.
        var explicit: [Bool] = []
        var cancelling: ShortcutListener!
        cancelling = ShortcutListener(binding: .controlOptionSpace, processingSeconds: 0) { action, done in
            if action == .cancel { explicit.append(cancelling.cancelIsExplicit) }; done()
        }
        cancelling.receive(type: .keyDown, event: key(true, 10))
        let escape = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Escape), keyDown: true)!
        cancelling.receive(type: .keyDown, event: escape)
        cancelling.receive(type: .keyUp, event: key(false, 10.5))
        cancelling.receive(type: .keyDown, event: key(true, 20)); cancelling.receive(type: .keyUp, event: key(false, 20.1))
        cancelling.emit(cancelling.machine.doublePressExpired(at: 21))
        check(explicit == [true, false] && !cancelling.cancelIsExplicit, "Escape is explicit; a lone tap's expiry is not")
    }

    static func microphoneChecks() {
        typealias D = MicrophoneChoice.Device
        let builtIn = D(uid: "BuiltInMicrophoneDevice", transport: .builtIn, alive: true)
        let airPods = D(uid: "AA-BB-CC:input", transport: .bluetooth, alive: true)
        let usb = D(uid: "usb-mic", transport: .other, alive: true)
        func pick(_ current: String?, _ devices: [D]) -> String? { MicrophoneChoice.automaticUID(defaultInput: current, devices: devices) }
        check(pick(airPods.uid, [builtIn, airPods]) == builtIn.uid, "Bluetooth default with a built-in mic → built-in")
        check(pick(airPods.uid, [builtIn, airPods, usb]) == builtIn.uid, "also with other devices around")
        check(pick(airPods.uid, [airPods]) == nil, "Bluetooth default, no built-in mic (Mac mini) → system default")
        check(pick(airPods.uid, [D(uid: builtIn.uid, transport: .builtIn, alive: false), airPods]) == nil, "built-in mic not alive → system default")
        check(pick(usb.uid, [builtIn, usb, airPods]) == nil, "USB default → system default")
        check(pick(builtIn.uid, [builtIn, airPods]) == nil, "built-in default → system default (already built-in)")
        check(pick(nil, [builtIn, airPods]) == nil && pick("gone", [builtIn]) == nil, "unknown default → system default")
        check(MicrophoneChoice.automatic != "", "Automatic has a stored value distinct from System default")

        // Mid-recording format change: a 16 kHz headset buffer converts to the file's 48 kHz format.
        let from = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!, to = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let converter = AVAudioConverter(from: from, to: to)!
        var total = 0
        for _ in 0..<10 {
            let buffer = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: 1600)!; buffer.frameLength = 1600
            for i in 0..<1600 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.1) }
            guard let out = Capture.convert(buffer, with: converter) else { check(false, "conversion"); return }
            check(out.format == to, "converted to the file's format")
            total += Int(out.frameLength)
        }
        check(abs(total - 48_000) < 200, "a second of 16 kHz audio becomes about a second at 48 kHz (\(total))")
    }
}
