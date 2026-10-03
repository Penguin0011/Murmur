import Foundation

// Main-thread coordinator; capture writes and processing use their own queues.
final class CaptureSession {
    enum State { case idle, listening, processing }
    private(set) var state = State.idle
    private(set) var audio: URL?
    let store: RetryAudio
    let startCapture: (URL) throws -> Void
    let stopCapture: () -> Bool
    let process: (URL, @escaping () -> Void) -> Void
    var timer: Timer?
    var finishRecording: (() -> Void)?
    var resetShortcut: (() -> Void)?

    init(store: RetryAudio, start: @escaping (URL) throws -> Void,
         stop: @escaping () -> Bool, process: @escaping (URL, @escaping () -> Void) -> Void) {
        self.store = store; startCapture = start; stopCapture = stop; self.process = process
    }
    func receive(_ action: ShortcutMachine.Action, completed: @escaping () -> Void) {
        switch action {
        case .start:
            guard state == .idle else { return }
            do {
                let url = try store.create(); audio = url
                try startCapture(url)
                state = .listening
                timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in self?.finishRecording?() }
                print("capture=listening limit=120s")
            } catch {
                discard(); resetShortcut?(); completed()
                fputs("capture=start-failed; audio deleted\n", stderr)
            }
        case .finish:
            guard state == .listening, let url = audio else { completed(); return }
            timer?.invalidate(); timer = nil
            state = .processing
            guard stopCapture() else {
                discard(); completed(); print("capture=failed-or-empty audio=deleted"); return
            }
            print("capture=processing")
            process(url) { [weak self] in
                self?.audio = nil; self?.state = .idle
                completed(); print("capture=idle")
            }
        case .cancel:
            if state == .listening { _ = stopCapture(); discard(); print("capture=canceled audio=deleted") }
        }
    }
    func discard() {
        timer?.invalidate(); timer = nil
        if let audio { do { try store.delete(audio) } catch { fputs("capture=cleanup-failed\n", stderr) } }
        audio = nil; state = .idle
    }
    func shutdown() {
        if state == .listening { _ = stopCapture(); discard() }
        timer?.invalidate()
    }
}
