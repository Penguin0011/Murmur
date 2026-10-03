import CoreGraphics
import Foundation

func runShortcutChecks() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw ShortcutError(description: "Shortcut check failed: \(message)") }
    }
    var tap = ShortcutMachine()
    try check(tap.press(at: 0) == .start, "tap starts immediately")
    try check(tap.press(at: 0.05, isRepeat: true) == nil, "repeat ignored")
    try check(tap.press(at: 0.08) == nil, "duplicate down ignored")
    try check(tap.release(at: 0.1) == nil && tap.state == .listening, "tap remains listening")
    try check(tap.press(at: 1) == .finish, "next tap finishes")
    try check(tap.release(at: 1.1) == nil, "stop release ignored")
    try check(tap.press(at: 1.2) == nil && tap.state == .processing, "processing guard")
    tap.processingFinished()
    try check(tap.press(at: 1.3) == nil, "held processing key cannot restart")
    try check(tap.release(at: 1.4) == nil, "processing press release")
    try check(tap.press(at: 2) == .start, "new session after processing")
    try check(tap.release(at: 2.25) == .finish, "250 ms boundary is hold")

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
    print("Shortcut checks passed (tap, hold, threshold, repeats, cancellation, processing guard, chord consumption).")
}
