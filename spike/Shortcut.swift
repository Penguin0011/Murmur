import Foundation
import ApplicationServices
import os

private let timingLog = Logger(subsystem: "cc.clouddev.dictation", category: "timing")

/// Hold: press and keep holding; release finishes. Double press: two quick presses latch a toggle
/// recording that only the next press finishes. Capture starts on the first press, so a hold never
/// loses its first word; a lone short tap is cancelled once `doublePressWindow` passes without a
/// second press.
struct ShortcutMachine {
    enum State: String { case idle, listening, processing }
    enum Action: String { case start, finish, cancel }
    private enum Mode { case holding, awaitingSecondPress(releasedAt: TimeInterval), toggled }
    private(set) var state = State.idle
    private var mode = Mode.holding
    private var pressedAt: TimeInterval?
    /// The press that latched or finished a toggle owns its release, which must do nothing.
    private var ignoreRelease = false
    let holdThreshold: TimeInterval
    /// Press-to-toggle setting: a short tap latches (the next press finishes), while a hold still
    /// finishes on release, so both gestures work in either mode.
    var pressToToggle = false
    // ponytail: fixed window; make it a setting if people double-press slower or faster.
    let doublePressWindow: TimeInterval

    init(holdThreshold: TimeInterval = 0.250, doublePressWindow: TimeInterval = 0.400) {
        precondition(holdThreshold > 0 && doublePressWindow > 0)
        self.holdThreshold = holdThreshold
        self.doublePressWindow = doublePressWindow
    }

    var awaitingSecondPress: Bool { if case .awaitingSecondPress = mode { return state == .listening }; return false }

    mutating func press(at time: TimeInterval, isRepeat: Bool = false) -> Action? {
        guard !isRepeat, pressedAt == nil else { return nil }
        pressedAt = time
        switch state {
        case .processing: return nil
        case .idle:
            state = .listening; mode = .holding; ignoreRelease = false
            return .start
        case .listening:
            ignoreRelease = true
            if case .awaitingSecondPress = mode { mode = .toggled; return nil }
            state = .processing
            return .finish
        }
    }

    mutating func release(at time: TimeInterval) -> Action? {
        guard let start = pressedAt else { return nil }
        pressedAt = nil
        if ignoreRelease { ignoreRelease = false; return nil }
        guard state == .listening, case .holding = mode else { return nil }
        if time - start >= holdThreshold {
            state = .processing
            return .finish
        }
        mode = pressToToggle ? .toggled : .awaitingSecondPress(releasedAt: time)
        return nil
    }

    /// A lone short tap: no second press arrived in time, so the recording is discarded.
    mutating func doublePressExpired(at time: TimeInterval) -> Action? {
        guard state == .listening, case .awaitingSecondPress(let released) = mode,
              time - released >= doublePressWindow else { return nil }
        state = .idle
        return .cancel
    }

    mutating func cancel() -> Action? {
        guard state == .listening else { return nil }
        // Keep the press latch until release: Escape cannot restart a held key.
        state = .idle
        return .cancel
    }

    mutating func finish() -> Action? {
        guard state == .listening else { return nil }
        state = .processing
        return .finish
    }

    mutating func processingFinished() { if state == .processing { state = .idle } }

    mutating func eventStreamLost() -> Action? {
        let action = cancel()
        pressedAt = nil
        ignoreRelease = false
        return action
    }
}

enum ShortcutBinding {
    case rightOption, fn, controlOptionSpace
    var keyCode: Int64 {
        switch self { case .rightOption: return 61; case .fn: return 63; case .controlOptionSpace: return 49 }
    }
    func isDown(_ event: CGEvent) -> Bool {
        switch self {
        // NX_DEVICERALTKEYMASK distinguishes right Option when left Option is held.
        case .rightOption: return event.flags.rawValue & 0x40 != 0
        case .fn: return event.flags.contains(.maskSecondaryFn)
        case .controlOptionSpace:
            let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
            return event.flags.intersection(relevant) == [.maskControl, .maskAlternate]
        }
    }
    /// Only the chord's Space types a character; swallow it so the shortcut never inserts a space.
    func consumes(_ type: CGEventType, _ event: CGEvent) -> Bool {
        self == .controlOptionSpace && (type == .keyDown || type == .keyUp)
            && event.getIntegerValueField(.keyboardEventKeycode) == keyCode && isDown(event)
    }
}

final class ShortcutListener {
    var machine = ShortcutMachine()
    var tap: CFMachPort?
    let binding: ShortcutBinding
    let processingSeconds: Double
    let onAction: ((ShortcutMachine.Action, @escaping () -> Void) -> Void)?
    /// Called on the main thread for a fresh Escape press while a session is processing; the app
    /// uses it to cancel a cloud request. Escape is not swallowed then.
    var onEscapeWhileProcessing: (() -> Void)?
    /// Called on the main thread for a fresh ⌃⌘C press. The tap swallows the chord, so the front
    /// app neither beeps nor races the clipboard write.
    var onCopyChord: (() -> Void)?
    /// ⌃⌘C exactly: Control and Command, no Option or Shift.
    static func isCopyChord(keyCode: Int64, flags: CGEventFlags) -> Bool {
        keyCode == 8 && flags.intersection([.maskControl, .maskCommand, .maskAlternate, .maskShift]) == [.maskControl, .maskCommand]
    }
    /// Shortcut presses/releases that arrive while a session is processing. They are replayed into
    /// the machine when processing finishes, so a back-to-back dictation is not dropped.
    /// `onQueuedPress` starts capture at the first one (false drops the press, as before wiring);
    /// Escape or a lost event stream clears the queue and calls `onQueuedCancel`.
    private(set) var queued: [(down: Bool, at: TimeInterval)] = []
    var onQueuedPress: (() -> Bool)?
    /// Whether the user's own release or tap ended the session now processing. Only then is a
    /// press during processing a new dictation; after an automatic stop (interruption, time cap)
    /// the user most likely meant to stop, so the press is ignored.
    private var userFinished = false
    private var handlingEvent = false
    var onQueuedCancel: (() -> Void)?
    /// Called on the tap thread for a fresh shortcut press from idle, before the main thread sees
    /// it, so capture can start while a slow (paged-out) main thread catches up.
    var onPressFromIdle: (() -> Void)?
    /// Called on the main thread when a shortcut press did not start a session.
    var onPressWithoutStart: (() -> Void)?
    /// Called on the tap thread with the release time when a press from idle was held past the
    /// hold threshold: the hold is over, even if the main thread has not handled it yet.
    var onHoldRelease: ((TimeInterval) -> Void)?
    /// Tap thread only: when the current press from idle went down.
    private var tapThreadPressAt: TimeInterval?
    private let tapHoldThreshold = ShortcutMachine().holdThreshold
    /// Set before the tap starts and read on the tap thread.
    var pressToToggle = false { didSet { machine.pressToToggle = pressToToggle } }
    /// The machine state as last published by the main thread; the tap thread reads only this.
    private let mirrorLock = NSLock()
    private var mirror: (state: ShortcutMachine.State, queued: Bool) = (.idle, false)
    func publishState() { mirrorLock.lock(); mirror = (machine.state, !queued.isEmpty); mirrorLock.unlock() }
    private var mirrored: (state: ShortcutMachine.State, queued: Bool) { mirrorLock.lock(); defer { mirrorLock.unlock() }; return mirror }
    init(binding: ShortcutBinding, processingSeconds: Double, onAction: ((ShortcutMachine.Action, @escaping () -> Void) -> Void)?) {
        self.binding = binding
        self.processingSeconds = processingSeconds
        self.onAction = onAction
    }
    func emit(_ action: ShortcutMachine.Action?) {
        defer { publishState() }
        guard let action else { return }
        if action == .finish { userFinished = handlingEvent }
        print("shortcut action=\(action.rawValue) state=\(machine.state.rawValue)")
        fflush(stdout)
        if let onAction {
            onAction(action) { [self] in machine.processingFinished(); replayQueued(); publishState() }
        } else if action == .finish {
            // ponytail: simulated processing only; wire real completion in the recording milestone.
            DispatchQueue.main.asyncAfter(deadline: .now() + processingSeconds) { [self] in
                machine.processingFinished()
                print("shortcut state=\(machine.state.rawValue)")
            }
        }
    }
    func replayQueued() {
        guard machine.state == .idle, !queued.isEmpty else { return }
        let events = queued; queued.removeAll()
        handlingEvent = true; defer { handlingEvent = false }
        for (n, e) in events.enumerated() {
            if n > 0 && machine.state == .idle { break } // The replayed start was refused.
            emit(e.down ? machine.press(at: e.at) : machine.release(at: e.at))
            if !e.down { scheduleDoublePressExpiry() }
        }
    }
    /// After a short tap, wait out the double-press window; a lone tap is then cancelled. A timer
    /// left from a tap that became a toggle finds nothing to expire.
    private func scheduleDoublePressExpiry() {
        guard machine.awaitingSecondPress else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + machine.doublePressWindow + 0.02) { [self] in
            emit(machine.doublePressExpired(at: ProcessInfo.processInfo.systemUptime))
        }
    }
    /// A lone short tap queued during processing must not keep its early capture recording until
    /// the replay: expire it at its own deadline. A second press in time makes it a double press.
    private func scheduleQueuedTapExpiry() {
        guard !machine.pressToToggle, queued.count == 2, queued[1].at - queued[0].at < machine.holdThreshold else { return }
        let pressedAt = queued[0].at
        DispatchQueue.main.asyncAfter(deadline: .now() + machine.doublePressWindow + 0.02) { [self] in
            guard queued.count == 2, queued[0].at == pressedAt else { return }
            cancelQueued(); publishState()
        }
    }
    func cancelQueued() {
        guard !queued.isEmpty else { return }
        queued.removeAll(); onQueuedCancel?()
    }
    private var swallowingEscape = false
    /// Whether the tap drops this event: the chord's Space always, Escape only while recording.
    /// Runs in the tap callback on the main run loop, the same thread that drains `enqueue`, so the
    /// `machine` read is race-free. It sees every event already drained but not ones still queued, so
    /// state lags only when Escape lands in the same main-loop turn as a press/release; then Escape
    /// still cancels via `receive` and at worst passes through (or is swallowed as a no-op) once.
    /// The latch keeps a swallowed Escape's repeats and key-up from reaching the app after cancel
    /// flips state to idle; the next fresh Escape press resets it.
    func consumes(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if binding.consumes(type, event) { return true }
        if type == .keyDown || type == .keyUp, Self.isCopyChord(keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags) { return true }
        guard type == .keyDown || type == .keyUp,
              event.getIntegerValueField(.keyboardEventKeycode) == 53 else { return false }
        if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            let m = mirrored
            swallowingEscape = m.state == .listening || m.queued
        }
        defer { if type == .keyUp { swallowingEscape = false } }
        return swallowingEscape
    }
    /// The one place taps are created, so the app and spike cannot drift. Active (not listen-only)
    /// taps need Accessibility as well as Input Monitoring; returns nil when either is missing.
    func createTap() -> CFMachPort? {
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<ShortcutListener>.fromOpaque(context).takeUnretainedValue()
                let swallow = listener.consumes(type, event)
                listener.notePress(type, event)
                listener.enqueue(type: type, event: event)
                return swallow ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        return tap
    }
    /// Tap thread: a fresh press of the binding while idle starts capture; that press's release,
    /// if it was a hold, ends the recording's audio at once (see `onHoldRelease`).
    func notePress(_ type: CGEventType, _ event: CGEvent) {
        guard type == .keyDown || type == .keyUp || type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == binding.keyCode,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
        let time = Double(event.timestamp) / 1_000_000_000
        if type == .keyUp || (type == .flagsChanged && !binding.isDown(event)) {
            if let pressed = tapThreadPressAt, time - pressed >= tapHoldThreshold { onHoldRelease?(time) }
            tapThreadPressAt = nil
            return
        }
        guard binding.isDown(event) else { return }
        let m = mirrored
        guard m.state == .idle && !m.queued else { tapThreadPressAt = nil; return }
        tapThreadPressAt = time
        onPressFromIdle?()
    }
    func enqueue(type: CGEventType, event: CGEvent) {
        // Copy the borrowed event; defer the entire mutation/action pair together.
        guard let copy = event.copy() else { return }
        DispatchQueue.main.async { [self] in receive(type: type, event: copy) }
    }
    func receive(type: CGEventType, event: CGEvent) {
        handlingEvent = true
        defer { handlingEvent = false; publishState() }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelQueued()
            emit(machine.eventStreamLost())
            print("event tap disabled; capture canceled, re-enabling tap")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown, Self.isCopyChord(keyCode: key, flags: event.flags), event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            onCopyChord?(); return
        }
        if type == .keyDown && key == 53 {
            if !queued.isEmpty { cancelQueued(); return } // Cancels only the queued recording.
            if machine.state == .processing && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { onEscapeWhileProcessing?() }
            emit(machine.cancel()); return
        }
        guard key == binding.keyCode else { return }
        let time = Double(event.timestamp) / 1_000_000_000
        if type == .flagsChanged || event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            let handled = ProcessInfo.processInfo.systemUptime, down = binding.isDown(event)
            timingLog.notice("shortcut \(down ? "down" : "up", privacy: .public) event=\(time, format: .fixed(precision: 3)) handled=\(handled, format: .fixed(precision: 3)) lag=\(handled - time, format: .fixed(precision: 3)) state=\(self.machine.state.rawValue, privacy: .public)")
        }
        if machine.state == .processing, userFinished, let onQueuedPress {
            let down = (type == .keyDown || type == .flagsChanged) && binding.isDown(event)
            if down, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                onPressWithoutStart?()
                if !queued.isEmpty || onQueuedPress() { queued.append((true, time)); return }
            }
            if !down, !queued.isEmpty { queued.append((false, time)); scheduleQueuedTapExpiry(); return }
        }
        if type == .keyUp || (type == .flagsChanged && !binding.isDown(event)) {
            let action = machine.release(at: time)
            if action == .finish { print("shortcut gesture=hold-release") }
            emit(action)
            scheduleDoublePressExpiry()
        } else if (type == .keyDown || type == .flagsChanged) && binding.isDown(event) {
            let action = machine.press(at: time, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            if action == .finish { print("shortcut gesture=tap-stop") }
            if action != .start { onPressWithoutStart?() }
            emit(action)
        }
    }
}

/// Runs an event tap's run loop source on its own high-priority thread, so a busy or paged-out
/// main thread does not delay seeing the shortcut.
final class TapThread: Thread {
    private let source: CFRunLoopSource
    private var loop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    init(source: CFRunLoopSource) {
        self.source = source
        super.init()
        qualityOfService = .userInteractive; name = "murmur.shortcut-tap"
    }
    override func main() {
        loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, source, .commonModes); ready.signal()
        CFRunLoopRun()
    }
    func startAndWait() { start(); ready.wait() }
    func stop() { if let loop { CFRunLoopRemoveSource(loop, source, .commonModes); CFRunLoopStop(loop) } }
}

struct ShortcutError: Error, CustomStringConvertible { let description: String }

/// Deliberately does nothing without explicit --listen. Never requests permissions.
func runShortcutListener(arguments: [String],
    onAction: ((ShortcutMachine.Action, @escaping () -> Void) -> Void)? = nil,
    onReady: ((@escaping () -> Void, @escaping () -> Void) -> Void)? = nil,
    onShutdown: (() -> Void)? = nil) throws {
    guard arguments.contains("--listen") else {
        throw ShortcutError(description: "Use --listen to enable global keyboard observation.")
    }
    func value(_ option: String, default fallback: String) throws -> String {
        guard let index = arguments.firstIndex(of: option) else { return fallback }
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
            throw ShortcutError(description: "Missing value for \(option)")
        }
        return arguments[index + 1]
    }
    let binding: ShortcutBinding
    switch try value("--binding", default: "right-option") {
    case "right-option": binding = .rightOption
    case "fn": binding = .fn
    case "ctrl-option-space": binding = .controlOptionSpace
    default: throw ShortcutError(description: "Supported bindings: right-option, fn, ctrl-option-space")
    }
    guard let seconds = Double(try value("--processing-seconds", default: "1")),
          seconds.isFinite, seconds >= 0 else {
        throw ShortcutError(description: "--processing-seconds must be finite and nonnegative")
    }
    var listenSeconds: Double?
    if arguments.contains("--listen-seconds") {
        guard let duration = Double(try value("--listen-seconds", default: "")),
              duration.isFinite, duration > 0, duration <= 60 else {
            throw ShortcutError(description: "--listen-seconds must be finite, greater than 0, and at most 60")
        }
        listenSeconds = duration
    }
    let monitoring = CGPreflightListenEventAccess()
    print("Input Monitoring granted=\(monitoring); Accessibility granted=\(AXIsProcessTrusted())")
    guard monitoring else {
        throw ShortcutError(description: "Global keyboard observation is unavailable. Grant Input Monitoring to the executable/terminal in System Settings, then relaunch. No permission was requested.")
    }
    let listener = ShortcutListener(binding: binding, processingSeconds: seconds, onAction: onAction)
    guard let tap = listener.createTap(), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
        throw ShortcutError(description: "Could not create keyboard event tap; verify Input Monitoring and Accessibility, then relaunch. Secure Input or system policy may prevent observation.")
    }
    defer {
        onShutdown?()
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(tap)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    onReady?({ listener.emit(listener.machine.finish()) }, {
        listener.emit(listener.machine.eventStreamLost())
        listener.machine.processingFinished()
    })
    print("Listening (250 ms hold threshold). Escape cancels recording; Ctrl-C exits. Events are observed, not consumed, except the Space of Control-Option-Space and Escape while recording. Capture behavior is controlled by the caller.")
    fflush(stdout)
    withExtendedLifetime(listener) {
        if let listenSeconds {
            CFRunLoopRunInMode(.defaultMode, listenSeconds, false)
            listener.emit(listener.machine.eventStreamLost())
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            print("Listener stopped after bounded duration (\(listenSeconds) seconds).")
        } else {
            CFRunLoopRun()
        }
    }
}
