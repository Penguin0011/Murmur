// Recording experience checks (BetterWispr gaps #14, #16, #18). No capture, insertion or key injection:
// synthetic CGEvents go straight into ShortcutListener.receive, never through a tap.
import Foundation
import CoreGraphics
import Carbon.HIToolbox

@main struct RecordingChecks {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() {
        shortcutChecks()
        print("Recording checks passed (shortcut validation and custom binding).")
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
}
