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
    /// Capture keeps running this long after release so the last word, still in the input
    /// pipeline when the key comes up, is not cut off. 0 stops synchronously (checks).
    var releaseTail: TimeInterval = 0
    private var pendingTail: (() -> Void)?
    /// Capture started by a press during processing; the next .start adopts it.
    private(set) var early: URL?
    var resumeCapture: (() -> Void)?

    init(store: RetryAudio, start: @escaping (URL) throws -> Void,
         stop: @escaping () -> Bool, process: @escaping (URL, @escaping () -> Void) -> Void) {
        self.store = store; startCapture = start; stopCapture = stop; self.process = process
    }
    func receive(_ action: ShortcutMachine.Action, completed: @escaping () -> Void) {
        switch action {
        case .start:
            guard state == .idle else { return }
            if let url = early {
                // ponytail: the 120 s cap restarts at adoption, not at the early press.
                early = nil; audio = url; state = .listening
                timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in self?.finishRecording?() }
                resumeCapture?(); print("capture=listening adopted-early limit=120s")
                return
            }
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
            let stopAndProcess = { [self] in
                guard stopCapture() else {
                    discard(); completed(); print("capture=failed-or-empty audio=deleted"); return
                }
                print("capture=processing")
                process(url) { [weak self] in
                    self?.audio = nil; self?.state = .idle
                    completed(); print("capture=idle")
                }
            }
            if releaseTail > 0 {
                pendingTail = stopAndProcess
                DispatchQueue.main.asyncAfter(deadline: .now() + releaseTail) { [weak self] in self?.runTail() }
            } else { stopAndProcess() }
        case .cancel:
            if state == .listening { _ = stopCapture(); discard(); print("capture=canceled audio=deleted") }
            else { cancelEarly() }
        }
    }
    private func runTail() { let finish = pendingTail; pendingTail = nil; finish?() }
    /// Starts capture for a press during processing, cutting any release tail short first so two
    /// recordings never overlap. Returns false when nothing could start.
    func startEarly() -> Bool {
        guard state == .processing, early == nil else { return false }
        runTail()
        guard let url = try? store.create() else { return false }
        do { try startCapture(url); early = url; print("capture=listening early"); return true }
        catch { try? store.delete(url); return false }
    }
    func cancelEarly() {
        guard let url = early else { return }
        early = nil; _ = stopCapture(); try? store.delete(url); print("capture=early-canceled audio=deleted")
    }
    func discard() {
        timer?.invalidate(); timer = nil
        if let audio { do { try store.delete(audio) } catch { fputs("capture=cleanup-failed\n", stderr) } }
        audio = nil; state = .idle
    }
    func shutdown() {
        cancelEarly()
        if state == .listening { _ = stopCapture(); discard() }
        timer?.invalidate()
    }
}
