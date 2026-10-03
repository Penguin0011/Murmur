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

    mutating func processingFinished() { if state == .processing { state = .idle } }

    mutating func eventStreamLost() -> Action? {
        let action = cancel()
        pressedAt = nil
        stopsExistingSession = false
        return action
    }
}

private enum ShortcutBinding {
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
}

private final class ShortcutListener {
    var machine = ShortcutMachine()
    var tap: CFMachPort?
    let binding: ShortcutBinding
    let processingSeconds: Double
    init(binding: ShortcutBinding, processingSeconds: Double) {
        self.binding = binding
        self.processingSeconds = processingSeconds
    }
    func emit(_ action: ShortcutMachine.Action?) {
        guard let action else { return }
        print("shortcut action=\(action.rawValue) state=\(machine.state.rawValue)")
        fflush(stdout)
        if action == .finish {
            // ponytail: simulated processing only; wire real completion in the recording milestone.
            DispatchQueue.main.asyncAfter(deadline: .now() + processingSeconds) { [self] in
                machine.processingFinished()
                print("shortcut state=\(machine.state.rawValue)")
            }
        }
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
            emit(machine.release(at: time))
        } else if (type == .keyDown || type == .flagsChanged) && binding.isDown(event) {
            emit(machine.press(at: time, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0))
        }
    }
}

struct ShortcutError: Error, CustomStringConvertible { let description: String }

/// Deliberately does nothing without explicit --listen. Never requests permissions.
func runShortcutListener(arguments: [String]) throws {
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
    let listener = ShortcutListener(binding: binding, processingSeconds: seconds)
    let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    listener.tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
        options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
            if let context {
                Unmanaged<ShortcutListener>.fromOpaque(context).takeUnretainedValue().receive(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(listener).toOpaque())
    guard let tap = listener.tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
        throw ShortcutError(description: "Could not create keyboard event tap; verify Input Monitoring and relaunch. Secure Input or system policy may prevent observation.")
    }
    defer {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(tap)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("Listening (250 ms hold threshold). Escape cancels recording; Ctrl-C exits. Events are observed, not consumed. No audio is captured.")
    fflush(stdout)
    withExtendedLifetime(listener) {
        if let listenSeconds {
            CFRunLoopRunInMode(.defaultMode, listenSeconds, false)
            listener.emit(listener.machine.eventStreamLost())
            print("Listener stopped after bounded duration (\(listenSeconds) seconds).")
        } else {
            CFRunLoopRun()
        }
    }
}
