import Foundation
import ApplicationServices
import Darwin

func sessionCheck() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-session-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RetryAudio(directory: root)
    var starts = 0, stops = 0, finishes = 0
    var processDone: (() -> Void)?
    let session = CaptureSession(store: store, start: { _ in starts += 1 }, stop: { stops += 1; return true }, process: { _, done in processDone = done })
    var machine = ShortcutMachine()
    func deliver(_ action: ShortcutMachine.Action?) { if let action { session.receive(action) { machine.processingFinished(); finishes += 1 } } }
    deliver(machine.press(at: 0)); assert(starts == 1 && session.state == .listening)
    deliver(machine.release(at: 0.1)); deliver(machine.press(at: 0.3)); deliver(machine.release(at: 0.4))
    assert(stops == 0 && session.state == .listening)   // double press: toggle recording
    deliver(machine.press(at: 1)); assert(stops == 1 && session.state == .processing)
    deliver(machine.release(at: 1.1)); deliver(machine.press(at: 2)); assert(starts == 1)
    deliver(machine.release(at: 2.1)); processDone?(); assert(finishes == 1 && session.state == .idle)
    deliver(machine.press(at: 3)); let canceled = session.audio!
    deliver(machine.cancel()); assert(!FileManager.default.fileExists(atPath: canceled.path))
    deliver(machine.release(at: 4)); deliver(machine.press(at: 5))
    let lost = session.audio!; deliver(machine.eventStreamLost()); assert(!FileManager.default.fileExists(atPath: lost.path))
    deliver(machine.press(at: 6)); deliver(machine.release(at: 6.5)); assert(session.state == .processing)
    processDone?(); deliver(machine.press(at: 7)); let shutdown = session.audio!; session.shutdown()
    assert(!FileManager.default.fileExists(atPath: shutdown.path))
    let failed = CaptureSession(store: store, start: { _ in throw CaptureError("synthetic") }, stop: { false }, process: { _, _ in assertionFailure() })
    failed.receive(.start) {}; assert(failed.audio == nil && failed.state == .idle)
    assert(starts == 5 && stops == 5)
    var capped = ShortcutMachine()
    assert(capped.press(at: 0) == .start && capped.finish() == .finish)
    assert(capped.finish() == nil && capped.state == .processing)
    capped.processingFinished(); assert(capped.state == .idle)
    let empty = CaptureSession(store: store, start: { _ in }, stop: { false }, process: { _, _ in assertionFailure() })
    empty.receive(.start) {}; let emptyURL = empty.audio!
    empty.receive(.finish) {}; assert(!FileManager.default.fileExists(atPath: emptyURL.path) && empty.state == .idle)

    // A release tail keeps capturing after release; stop and processing follow on the main queue.
    var tailStops = 0, tailProcessed = false
    let tail = CaptureSession(store: store, start: { _ in }, stop: { tailStops += 1; return true }, process: { _, done in tailProcessed = true; done() })
    tail.releaseTail = 0.05
    tail.receive(.start) {}; tail.receive(.finish) {}
    assert(tailStops == 0 && tail.state == .processing)
    tail.receive(.start) {}; assert(tail.state == .processing)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    assert(tailStops == 1 && tailProcessed && tail.state == .idle)

    // Back-to-back: a press while #1 processes records at once and is adopted when #1 finishes.
    func fnEvent(_ down: Bool, _ t: Double) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: down)!
        e.type = .flagsChanged; e.flags = down ? .maskSecondaryFn : []; e.timestamp = UInt64(t * 1_000_000_000); return e
    }
    let escape = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!
    var captures: [URL] = [], stopped = 0, processed: [URL] = []
    var finishProcessing: [() -> Void] = []
    let b2b = CaptureSession(store: store, start: { captures.append($0) }, stop: { stopped += 1; return true },
                             process: { url, done in processed.append(url); finishProcessing.append(done) })
    b2b.releaseTail = 0.05
    let b2bListener = ShortcutListener(binding: .fn, processingSeconds: 0) { action, done in b2b.receive(action, completed: done) }
    b2bListener.onQueuedPress = { b2b.startEarly() }
    b2bListener.onQueuedCancel = { b2b.cancelEarly() }
    b2bListener.receive(type: .flagsChanged, event: fnEvent(true, 10)); b2bListener.receive(type: .flagsChanged, event: fnEvent(false, 11))
    // #2 pressed inside #1's release tail: the tail is cut so the recordings never overlap.
    b2bListener.receive(type: .flagsChanged, event: fnEvent(true, 11.03))
    assert(captures.count == 2 && stopped == 1 && processed == [captures[0]] && b2b.early == captures[1])
    b2bListener.receive(type: .flagsChanged, event: fnEvent(false, 13))
    assert(processed.count == 1 && b2bListener.queued.count == 2)
    finishProcessing.removeFirst()()                       // #1 delivered: #2 adopts and finishes.
    assert(b2b.early == nil && b2b.audio == captures[1] && b2b.state == .processing)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    assert(stopped == 2 && processed == [captures[0], captures[1]] && b2bListener.queued.isEmpty)
    finishProcessing.removeFirst()(); assert(b2b.state == .idle && b2bListener.machine.state == .idle)
    // Escape while #2 is queued deletes only #2; #1 still completes and nothing replays.
    b2bListener.receive(type: .flagsChanged, event: fnEvent(true, 20)); b2bListener.receive(type: .flagsChanged, event: fnEvent(false, 21))
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    b2bListener.receive(type: .flagsChanged, event: fnEvent(true, 22))
    let queuedURL = b2b.early!
    assert(b2bListener.consumes(.keyDown, escape))
    b2bListener.receive(type: .keyDown, event: escape)
    assert(b2b.early == nil && !FileManager.default.fileExists(atPath: queuedURL.path) && b2bListener.queued.isEmpty)
    b2bListener.receive(type: .flagsChanged, event: fnEvent(false, 23)); finishProcessing.removeFirst()()
    assert(b2b.state == .idle && b2bListener.machine.state == .idle && processed.count == 3)
    try? FileManager.default.removeItem(at: processed[2])

    // A lone tap queued during processing expires at its own deadline, not at replay.
    b2bListener.receive(type: .flagsChanged, event: fnEvent(true, 60)); b2bListener.receive(type: .flagsChanged, event: fnEvent(false, 61))
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))                 // #1 is processing
    b2bListener.receive(type: .flagsChanged, event: fnEvent(true, 62)); let loneQueued = b2b.early!
    b2bListener.receive(type: .flagsChanged, event: fnEvent(false, 62.1))
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    assert(b2b.early == nil && !FileManager.default.fileExists(atPath: loneQueued.path) && b2bListener.queued.isEmpty && b2b.state == .processing)
    // A double press queued during processing still survives the window and is adopted.
    b2bListener.receive(type: .flagsChanged, event: fnEvent(true, 63)); let dblQueued = b2b.early!
    b2bListener.receive(type: .flagsChanged, event: fnEvent(false, 63.1)); b2bListener.receive(type: .flagsChanged, event: fnEvent(true, 63.3))
    b2bListener.receive(type: .flagsChanged, event: fnEvent(false, 63.4))
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    assert(b2b.early == dblQueued && b2bListener.queued.count == 4)
    finishProcessing.removeFirst()()                                        // #1 done: the toggle is adopted
    assert(b2b.audio == dblQueued && b2b.state == .listening && b2bListener.machine.state == .listening)
    b2bListener.receive(type: .flagsChanged, event: fnEvent(true, 70)); b2bListener.receive(type: .flagsChanged, event: fnEvent(false, 70.1))
    RunLoop.main.run(until: Date().addingTimeInterval(0.2)); finishProcessing.removeFirst()()
    assert(b2b.state == .idle)

    // After an automatic stop (time cap, interruption) a press means "stop", not a new dictation.
    let capped2 = CaptureSession(store: store, start: { _ in }, stop: { true }, process: { _, _ in })
    let cappedListener = ShortcutListener(binding: .fn, processingSeconds: 0) { action, done in capped2.receive(action, completed: done) }
    var cappedQueued = 0
    cappedListener.onQueuedPress = { cappedQueued += 1; return capped2.startEarly() }
    cappedListener.receive(type: .flagsChanged, event: fnEvent(true, 40)); cappedListener.receive(type: .flagsChanged, event: fnEvent(false, 40.1))
    cappedListener.emit(cappedListener.machine.finish())      // the 120 s cap, not the user
    cappedListener.receive(type: .flagsChanged, event: fnEvent(true, 45)); cappedListener.receive(type: .flagsChanged, event: fnEvent(false, 45.1))
    assert(cappedQueued == 0 && capped2.early == nil && cappedListener.queued.isEmpty && cappedListener.machine.state == .processing)
    try? FileManager.default.removeItem(at: capped2.audio!)

    // A lone tap: the listener's timer cancels it once the double-press window passes.
    let lone = CaptureSession(store: store, start: { _ in }, stop: { true }, process: { _, done in done() })
    let loneListener = ShortcutListener(binding: .fn, processingSeconds: 0) { action, done in lone.receive(action, completed: done) }
    loneListener.receive(type: .flagsChanged, event: fnEvent(true, 50)); let loneAudio = lone.audio!
    loneListener.receive(type: .flagsChanged, event: fnEvent(false, 50.1))
    assert(lone.state == .listening && loneListener.machine.awaitingSecondPress)
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    assert(lone.state == .idle && loneListener.machine.state == .idle && !FileManager.default.fileExists(atPath: loneAudio.path))

    // Prestart: the tap thread starts capture on a press from idle; .start adopts it instead of
    // starting a second capture, and a press that starts nothing reports itself for cleanup.
    var preStarted: URL?, preStarts = 0, unused = 0, ordinaryStarts = 0
    let pre = CaptureSession(store: store, start: { _ in ordinaryStarts += 1 }, stop: { true }, process: { _, done in done() })
    pre.takePrestarted = { defer { preStarted = nil }; return preStarted }
    let preListener = ShortcutListener(binding: .fn, processingSeconds: 0) { action, done in pre.receive(action, completed: done) }
    preListener.onPressFromIdle = { preStarts += 1; preStarted = try? store.create() }
    preListener.onPressWithoutStart = { unused += 1 }
    let down30 = fnEvent(true, 30)
    preListener.notePress(.flagsChanged, down30); let adopted = preStarted
    preListener.receive(type: .flagsChanged, event: down30)
    assert(preStarts == 1 && ordinaryStarts == 0 && pre.audio == adopted && pre.state == .listening && unused == 0)
    preListener.receive(type: .flagsChanged, event: fnEvent(false, 30.6))   // hold: finishes
    assert(pre.state == .idle)
    let down32 = fnEvent(true, 32)
    preListener.notePress(.flagsChanged, down32); preListener.receive(type: .flagsChanged, event: down32)
    preListener.receive(type: .flagsChanged, event: fnEvent(false, 32.1))
    let second = fnEvent(true, 32.3)                                          // second press of a double press
    preListener.notePress(.flagsChanged, second); assert(preStarts == 2)      // not idle: no prestart
    preListener.receive(type: .flagsChanged, event: second); assert(unused == 1 && pre.state == .listening)
    preListener.receive(type: .flagsChanged, event: fnEvent(false, 32.4))
    preListener.receive(type: .flagsChanged, event: fnEvent(true, 33)); assert(pre.state == .idle)
    preListener.receive(type: .flagsChanged, event: fnEvent(false, 33.1))
    try? FileManager.default.removeItem(at: preStarted ?? adopted!)
    // The tap thread reports a hold's release at once; taps and double presses are not cut.
    var released: [TimeInterval] = []
    let cutListener = ShortcutListener(binding: .fn, processingSeconds: 0, onAction: nil)
    cutListener.onHoldRelease = { released.append($0) }
    cutListener.notePress(.flagsChanged, fnEvent(true, 80)); cutListener.notePress(.flagsChanged, fnEvent(false, 81))
    assert(released == [81], "hold release reported")
    cutListener.notePress(.flagsChanged, fnEvent(true, 90)); cutListener.notePress(.flagsChanged, fnEvent(false, 90.1))
    assert(released == [81], "a tap is not a hold")
    cutListener.machine = ShortcutMachine(); _ = cutListener.machine.press(at: 100); cutListener.publishState()   // listening
    cutListener.notePress(.flagsChanged, fnEvent(true, 100.3)); cutListener.notePress(.flagsChanged, fnEvent(false, 101))
    assert(released == [81], "a press while recording (double press, toggle) is not cut")
    try? FileManager.default.removeItem(at: adopted!)

    var attempts = 0
    let retry = CaptureSession(store: store, start: { _ in
        attempts += 1
        if attempts == 1 { throw CaptureError("synthetic failed start") }
    }, stop: { true }, process: { _, done in done() })
    let listener = ShortcutListener(binding: .controlOptionSpace, processingSeconds: 0,
        onAction: { action, done in retry.receive(action, completed: done) })
    retry.resetShortcut = { listener.emit(listener.machine.eventStreamLost()); listener.machine.processingFinished() }
    func queue(_ type: CGEventType, key: CGKeyCode, time: UInt64, flags: CGEventFlags = []) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: type == .keyDown)!
        event.flags = flags; event.timestamp = time
        listener.enqueue(type: type, event: event)
    }
    queue(.keyDown, key: 49, time: 1, flags: [.maskControl, .maskAlternate])
    queue(.keyDown, key: 53, time: 2)
    queue(.keyUp, key: 49, time: 3)
    queue(.keyDown, key: 49, time: 4, flags: [.maskControl, .maskAlternate])
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    assert(attempts == 2 && retry.state == .listening && listener.machine.state == .listening)
    assert(FileManager.default.fileExists(atPath: retry.audio!.path))
    retry.shutdown()
    print("session-check=passed tap hold processing-guard cancellation event-loss shutdown startup-failure")
}

func runSession() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args == ["--check"] { try sessionCheck(); return }
    guard args.contains("--listen") else { throw CaptureError("Use --check or --listen [--binding NAME] [--listen-seconds 1..60] [--processor PATH --model-directory PATH]") }
    let valued = ["--binding", "--listen-seconds", "--processor", "--model-directory"]
    var seen = Set<String>(), index = 0
    while index < args.count {
        let key = args[index]
        guard key == "--listen" || valued.contains(key), seen.insert(key).inserted else { throw CaptureError("Unknown or duplicate option: \(key)") }
        if valued.contains(key) {
            guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else { throw CaptureError("Missing value for \(key)") }
            index += 2
        } else { index += 1 }
    }
    func value(_ name: String) throws -> String? {
        guard let i = args.firstIndex(of: name) else { return nil }
        guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { throw CaptureError("Missing value for \(name)") }
        return args[i + 1]
    }
    if let binding = try value("--binding"), !["right-option", "fn", "ctrl-option-space"].contains(binding) { throw CaptureError("Unsupported binding") }
    if let duration = try value("--listen-seconds") {
        guard let seconds = Double(duration), seconds.isFinite, seconds > 0, seconds <= 60 else { throw CaptureError("Listener duration must be finite and in 0..60") }
    }
    let processor = try value("--processor"), model = try value("--model-directory")
    guard (processor == nil) == (model == nil) else { throw CaptureError("Processor and model directory must be supplied together") }
    if let processor { guard FileManager.default.isExecutableFile(atPath: processor) else { throw CaptureError("Processor must be executable") } }
    guard permission() == "authorized" else { throw CaptureError("Microphone permission is \(permission()); no permission requested") }
    let store = try RetryAudio(directory: recoveryDirectory())
    var capture: Capture?
    var processorTask: Process?
    let session = CaptureSession(store: store, start: { url in
        let next = Capture(); capture = next; try next.start(url: url)
    }, stop: {
        capture?.stop()
        let valid = (capture?.frames ?? 0) > 0
        if capture?.writeError != nil { fputs("capture=write-failed partial-audio=retained\n", stderr) }
        capture = nil; return valid
    }, process: { url, done in
        guard let processor, let model else { print("retry-audio=retained expiry=24h"); done(); return }
        let task = Process(); task.executableURL = URL(fileURLWithPath: processor); task.arguments = [model, url.path]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        do { try task.run(); processorTask = task }
        catch { print("processor=failed retry-audio=retained"); done(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            task.waitUntilExit()
            DispatchQueue.main.async {
                processorTask = nil
                print(task.terminationStatus == 0 ? "processor=complete" : "processor=failed retry-audio=retained")
                done()
            }
        }
    })
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    for source in [interrupt, terminate] { source.setEventHandler { session.shutdown(); processorTask?.terminate(); CFRunLoopStop(CFRunLoopGetMain()) }; source.resume() }
    let monitor = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
        if session.state == .listening, let capture,
           !capture.engine.isRunning || capture.queue.sync(execute: { capture.writeError != nil }) {
            session.finishRecording?()
        }
    }
    let expiry = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
        do { try store.purge() } catch { fputs("retry-audio=purge-failed\n", stderr) }
    }
    defer { expiry.invalidate(); monitor.invalidate(); interrupt.cancel(); terminate.cancel(); session.shutdown(); processorTask?.terminate() }
    try runShortcutListener(arguments: args, onAction: { action, done in session.receive(action, completed: done) }, onReady: { finish, reset in session.finishRecording = finish; session.resetShortcut = reset }, onShutdown: { session.shutdown() })
}
do { try runSession() } catch { fputs("\(error)\n", stderr); exit(1) }
