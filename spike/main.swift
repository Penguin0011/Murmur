import AppKit
import ApplicationServices

let arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String, fallback: String) throws -> String {
    guard let index = arguments.firstIndex(of: name) else { return fallback }
    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
        throw InsertionError.unavailable("Missing value for \(name)")
    }
    return arguments[index + 1]
}

func delayedFocus() throws -> FocusSnapshot {
    let raw = try option("--delay", fallback: "3")
    guard let delay = Double(raw), delay.isFinite, (0...30).contains(delay) else {
        throw InsertionError.unavailable("--delay must be between 0 and 30 seconds")
    }
    print("Focus a disposable test field; inspecting in \(delay) seconds.")
    Thread.sleep(forTimeInterval: delay)
    return try captureFocus()
}

func describe(_ field: FocusSnapshot) {
    print("app=\(field.bundleID) role=\(field.role) subrole=\(field.subrole) secure=\(field.secure) valueReadable=\(field.value != nil) selectionReadable=\(field.selection != nil) learningEligible=\(field.learningEligible)")
}

func observe(_ field: FocusSnapshot, insertedText: String) throws {
    guard field.learningEligible, let value = field.value, let selection = field.selection else {
        throw InsertionError.unavailable("Field is ineligible for observation")
    }
    let length = (insertedText as NSString).length
    let range = NSRange(location: selection.location - length, length: length)
    guard range.location >= 0, NSMaxRange(range) <= (value as NSString).length,
          (value as NSString).substring(with: range) == insertedText,
          var tracker = DictationObservation(value: value, insertedRange: range, now: ProcessInfo.processInfo.systemUptime) else {
        throw InsertionError.unavailable("Inserted range cannot be identified from the verified caret")
    }
    print("Observing the synthetic span for at most 60 seconds; text is never printed.")
    var previous: TermCorrection?
    while !tracker.stopped {
        let current = try? captureFocus()
        let sameField = current.map { $0.pid == field.pid && CFEqual($0.element, field.element) } ?? false
        let readable = current?.learningEligible == true
        let selected = current?.selection.map { NSRange(location: $0.location, length: $0.length) } ?? NSRange(location: 0, length: 0)
        let candidate = tracker.observe(value: current?.value ?? "", selection: selected,
                                        now: ProcessInfo.processInfo.systemUptime,
                                        sameFocusedField: sameField, readableNonsecure: readable)
        if candidate != previous {
            print("provisionalCandidate=\(candidate != nil); no dictionary mapping applied")
            previous = candidate
        }
        if !tracker.stopped { Thread.sleep(forTimeInterval: 0.1) }
    }
    print("observationStopped=\(tracker.stopReason ?? "unknown") candidateRetained=\(tracker.candidate != nil)")
}

do {
    if arguments.isEmpty || arguments == ["--check"] {
        try runShortcutChecks()
        runInsertionChecks()
        runObservationChecks()
        print("Insertion checks passed; all deterministic checks passed.")
    } else if arguments.contains("--listen") {
        try runShortcutListener(arguments: arguments)
    } else if arguments.contains("--inspect") {
        describe(try delayedFocus())
    } else if arguments.contains("--insert-test") {
        let text = "Acme dictation probe"
        let destination = try delayedFocus()
        describe(destination)
        let result = insertText(text, into: destination)
        print("insertion=\(result.status.rawValue) detail=\(result.detail)")
        if arguments.contains("--observe"), result.status == .verified, let snapshot = result.snapshot {
            try observe(snapshot, insertedText: text)
        }
    } else {
        throw InsertionError.unavailable("Use --check, --inspect [--delay 3], --listen [--binding right-option|fn|ctrl-option-space], or --insert-test [--observe] [--delay 3]")
    }
} catch {
    fputs("Spike: \(error)\n", stderr)
    exit(1)
}
