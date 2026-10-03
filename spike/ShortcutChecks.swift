import CoreGraphics
import Foundation

func runShortcutChecks() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw ShortcutError(description: "Shortcut check failed: \(message)") }
    }
    var double = ShortcutMachine()
    try check(double.press(at: 0) == .start, "first press starts capture immediately")
    try check(double.press(at: 0.05, isRepeat: true) == nil, "repeat ignored")
    try check(double.press(at: 0.08) == nil, "duplicate down ignored")
    try check(double.release(at: 0.1) == nil && double.awaitingSecondPress, "short tap waits for a second press")
    try check(double.doublePressExpired(at: 0.3) == nil, "window still open")
    try check(double.press(at: 0.35) == nil && double.state == .listening && !double.awaitingSecondPress, "second press latches toggle")
    try check(double.release(at: 2) == nil && double.state == .listening, "the latching press's release keeps recording, even after a hold")
    try check(double.doublePressExpired(at: 10) == nil, "a stale expiry cannot cancel a toggle")
    try check(double.press(at: 5) == .finish, "next press finishes the toggle")
    try check(double.release(at: 5.6) == nil, "stop release ignored")
    try check(double.press(at: 5.7) == nil && double.state == .processing, "processing guard")
    double.processingFinished()
    try check(double.press(at: 5.8) == nil, "held processing key cannot restart")
    try check(double.release(at: 5.9) == nil, "processing press release")
    try check(double.press(at: 6) == .start && double.release(at: 6.25) == .finish, "250 ms boundary is hold")
    double.processingFinished()
    try check(double.press(at: 7) == .start && double.release(at: 7.1) == nil, "lone tap")
    try check(double.doublePressExpired(at: 7.49) == nil, "lone tap kept inside the window")
    try check(double.doublePressExpired(at: 7.5) == .cancel && double.state == .idle, "lone tap cancelled after the window")
    try check(double.press(at: 8) == .start, "new recording after a lone tap")

    var hold = ShortcutMachine()
    try check(hold.press(at: 0) == .start && hold.release(at: 0.5) == .finish, "hold release finishes")
    try check(hold.cancel() == nil, "Escape cannot discard processing")
    hold.processingFinished()
    try check(hold.press(at: 1) == .start && hold.cancel() == .cancel, "Escape cancels listening")
    try check(hold.press(at: 1.1) == nil, "canceled held key remains latched")
    try check(hold.release(at: 2) == nil && hold.state == .idle, "canceled release cannot finish")
    try check(hold.cancel() == nil && hold.release(at: 3) == nil, "idle events ignored")
    try check(hold.press(at: 4) == .start, "restart after canceled release")
    try check(hold.release(at: 4.249) == nil, "below threshold is tap")
    try check(hold.cancel() == .cancel, "Escape cancels latched tap recording")
    try check(hold.eventStreamLost() == nil, "stream loss after cancellation")
    try check(hold.press(at: 5) == .start, "stream recovery resets lost release")
    try check(hold.eventStreamLost() == .cancel && hold.state == .idle, "stream loss cancels capture")
    for duration in ["0", "-1", "61", "nan", "inf", "nope"] {
        do {
            try runShortcutListener(arguments: ["--listen", "--listen-seconds", duration])
            throw ShortcutError(description: "Invalid listener duration accepted: \(duration)")
        } catch let error as ShortcutError {
            try check(error.description.contains("--listen-seconds must"), "duration rejected before permission checks")
        }
    }
    do {
        try runShortcutListener(arguments: ["--listen", "--listen-seconds"])
        throw ShortcutError(description: "Missing listener duration accepted")
    } catch let error as ShortcutError {
        try check(error.description == "Missing value for --listen-seconds", "missing duration rejected")
    }
    func key(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!; event.flags = flags; return event
    }
    let chord: CGEventFlags = [.maskControl, .maskAlternate]
    try check(ShortcutBinding.controlOptionSpace.consumes(.keyDown, key(49, true, chord)), "chord Space down is swallowed")
    try check(ShortcutBinding.controlOptionSpace.consumes(.keyUp, key(49, false, chord)), "chord Space up is swallowed")
    try check(!ShortcutBinding.controlOptionSpace.consumes(.keyDown, key(49, true, [])), "plain Space passes through")
    try check(!ShortcutBinding.controlOptionSpace.consumes(.keyDown, key(49, true, [.maskControl, .maskAlternate, .maskCommand])), "other chords pass through")
    try check(!ShortcutBinding.rightOption.consumes(.keyDown, key(49, true, chord)), "other bindings consume nothing")
    func repeatKey(_ code: CGKeyCode) -> CGEvent {
        let event = key(code, true, []); event.setIntegerValueField(.keyboardEventAutorepeat, value: 1); return event
    }
    for binding in [ShortcutBinding.rightOption, .fn, .controlOptionSpace] {
        let listener = ShortcutListener(binding: binding, processingSeconds: 0, onAction: { _, _ in })
        try check(!listener.consumes(.keyDown, key(53, true, [])) && !listener.consumes(.keyUp, key(53, false, [])), "idle Escape passes through")
        _ = listener.machine.press(at: 0); listener.publishState() // The tap thread reads the published state.
        try check(listener.machine.state == .listening, "listener is recording")
        try check(listener.consumes(.keyDown, key(53, true, [])), "recording Escape down is swallowed")
        _ = listener.machine.cancel(); listener.publishState()
        try check(listener.consumes(.keyDown, repeatKey(53)), "swallowed Escape repeats stay swallowed after cancel")
        try check(listener.consumes(.keyUp, key(53, false, [])), "swallowed Escape up is swallowed")
        try check(!listener.consumes(.keyDown, key(53, true, [])), "fresh Escape after cancel passes through")
        try check(!listener.consumes(.keyUp, key(53, false, [])), "unswallowed Escape up passes through")
        _ = listener.machine.release(at: 0.1); _ = listener.machine.press(at: 1); _ = listener.machine.release(at: 1.5); listener.publishState()
        try check(listener.machine.state == .processing, "listener is processing")
        try check(!listener.consumes(.keyDown, key(53, true, [])), "processing Escape passes through")
        try check(!listener.consumes(.keyDown, key(0, true, [])) && !listener.consumes(.keyDown, key(49, true, [])), "plain keys pass through")
        try check(listener.consumes(.keyDown, key(49, true, chord)) == (binding == .controlOptionSpace), "only the chord binding swallows chord Space")
        listener.machine.processingFinished(); _ = listener.machine.press(at: 3); listener.publishState()
        try check(!listener.consumes(.keyDown, key(0, true, [])) && !listener.consumes(.keyDown, key(36, true, [])), "plain keys pass through while recording")
    }
    print("Shortcut checks passed (double-press toggle, lone-tap expiry, hold, threshold, repeats, cancellation, processing guard, chord consumption, Escape consumption).")
}
