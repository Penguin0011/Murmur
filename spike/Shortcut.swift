import Foundation
import ApplicationServices

/// Starts on press so determining tap versus hold never discards the first word.
struct ShortcutMachine {
    enum State: String { case idle, listening, processing }
    enum Action: String { case start, finish, cancel }
    private(set) var state = State.idle
    private var pressedAt: TimeInterval?
    private var stopsExistingSession = false
    let holdThreshold: TimeInterval

    init(holdThreshold: TimeInterval = 0.250) {
        precondition(holdThreshold > 0)
        self.holdThreshold = holdThreshold
    }

    mutating func press(at time: TimeInterval, isRepeat: Bool = false) -> Action? {
        guard !isRepeat, pressedAt == nil else { return nil }
        pressedAt = time
        stopsExistingSession = state == .listening
        guard state != .processing else { return nil }
        if stopsExistingSession {
            state = .processing
            return .finish
        }
        state = .listening
        return .start
    }

    mutating func release(at time: TimeInterval) -> Action? {
        guard let start = pressedAt else { return nil }
        pressedAt = nil
        defer { stopsExistingSession = false }
        guard state == .listening, !stopsExistingSession,
              time - start >= holdThreshold else { return nil }
        state = .processing
        return .finish
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
        stopsExistingSession = false
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
    init(binding: ShortcutBinding, processingSeconds: Double, onAction: ((ShortcutMachine.Action, @escaping () -> Void) -> Void)?) {
        self.binding = binding
        self.processingSeconds = processingSeconds
        self.onAction = onAction
    }
    func emit(_ action: ShortcutMachine.Action?) {
        guard let action else { return }
        print("shortcut action=\(action.rawValue) state=\(machine.state.rawValue)")
        fflush(stdout)
        if let onAction {
            onAction(action) { [self] in machine.processingFinished() }
        } else if action == .finish {
            // ponytail: simulated processing only; wire real completion in the recording milestone.
            DispatchQueue.main.asyncAfter(deadline: .now() + processingSeconds) { [self] in
                machine.processingFinished()
                print("shortcut state=\(machine.state.rawValue)")
            }
        }
    }
    func enqueue(type: CGEventType, event: CGEvent) {
        // Copy the borrowed event; defer the entire mutation/action pair together.
        guard let copy = event.copy() else { return }
        DispatchQueue.main.async { [self] in receive(type: type, event: copy) }
    }
    func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            emit(machine.eventStreamLost())
            print("event tap disabled; capture canceled, re-enabling tap")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown && key == 53 { emit(machine.cancel()); return }
        guard key == binding.keyCode else { return }
        let time = Double(event.timestamp) / 1_000_000_000
        if type == .keyUp || (type == .flagsChanged && !binding.isDown(event)) {
            let action = machine.release(at: time)
            if action == .finish { print("shortcut gesture=hold-release") }
            emit(action)
        } else if (type == .keyDown || type == .flagsChanged) && binding.isDown(event) {
            let action = machine.press(at: time, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            if action == .finish { print("shortcut gesture=tap-stop") }
            emit(action)
        }
    }
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
    let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    listener.tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
        options: binding == .controlOptionSpace ? .defaultTap : .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
            if let context {
                let listener = Unmanaged<ShortcutListener>.fromOpaque(context).takeUnretainedValue()
                listener.enqueue(type: type, event: event)
                if listener.binding.consumes(type, event) { return nil }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(listener).toOpaque())
    guard let tap = listener.tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
        throw ShortcutError(description: "Could not create keyboard event tap; verify Input Monitoring and relaunch. Secure Input or system policy may prevent observation.")
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
    print("Listening (250 ms hold threshold). Escape cancels recording; Ctrl-C exits. Events are observed, not consumed, except the Space of Control-Option-Space. Capture behavior is controlled by the caller.")
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
