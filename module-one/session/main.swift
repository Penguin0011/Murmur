import Foundation
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
    deliver(machine.release(at: 0.1)); assert(stops == 0)
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
    defer { monitor.invalidate(); interrupt.cancel(); terminate.cancel(); session.shutdown(); processorTask?.terminate() }
    try runShortcutListener(arguments: args, onAction: { action, done in session.receive(action, completed: done) }, onReady: { finish, reset in session.finishRecording = finish; session.resetShortcut = reset }, onShutdown: { session.shutdown() })
}
do { try runSession() } catch { fputs("\(error)\n", stderr); exit(1) }
