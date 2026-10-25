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
    /// A dictation finishes and is processed after five minutes, so one left on by accident stops
    /// (user decision, October 6, 2026).
    static let recordingLimit: TimeInterval = 300
    var finishRecording: (() -> Void)?
    var resetShortcut: (() -> Void)?
    /// Capture keeps running this long after release so the last word, still in the input
    /// pipeline when the key comes up, is not cut off. 0 stops synchronously (checks).
    var releaseTail: TimeInterval = 0
    /// Uptime of the key-release event for the next `.finish`, when it is known earlier than the
    /// main thread handled it. The tail then runs to release + `releaseTail`, not handled + `releaseTail`
    /// (capture drops audio after that cut-off anyway, so waiting longer recorded nothing). Consumed by `.finish`.
    var releasedAt: TimeInterval?
    private var pendingTail: (() -> Void)?
    /// Capture started by a press during processing; the next .start adopts it.
    private(set) var early: URL?
    private var earlyStarted: Date?
    /// The clock for the recording limit; checks substitute a fixed one.
    var now: () -> Date = Date.init
    var resumeCapture: (() -> Void)?
    /// Sees a canceled recording's finished file just before it is deleted (Undo reads it into memory).
    var willDeleteCanceled: ((URL) -> Void)?
    /// Returns a capture started before the main thread handled the press, for .start to adopt.
    var takePrestarted: (() -> URL?)?

    init(store: RetryAudio, start: @escaping (URL) throws -> Void,
         stop: @escaping () -> Bool, process: @escaping (URL, @escaping () -> Void) -> Void) {
        self.store = store; startCapture = start; stopCapture = stop; self.process = process
    }
    func receive(_ action: ShortcutMachine.Action, completed: @escaping () -> Void) {
        switch action {
        case .start:
            guard state == .idle else { return }
            if let url = early ?? takePrestarted?() {
                // A capture started while the last dictation processed counts from its own start,
                // so it never records past the limit. A tap-thread prestart is milliseconds early.
                let elapsed = early == nil ? 0 : earlyStarted.map { now().timeIntervalSince($0) } ?? 0
                let remaining = max(0, Self.recordingLimit - elapsed)
                early = nil; earlyStarted = nil; audio = url; state = .listening
                timer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in self?.finishRecording?() }
                resumeCapture?(); print("capture=listening adopted limit=\(Int(remaining))s")
                return
            }
            do {
                let url = try store.create(); audio = url
                try startCapture(url)
                state = .listening
                timer = Timer.scheduledTimer(withTimeInterval: Self.recordingLimit, repeats: false) { [weak self] _ in self?.finishRecording?() }
                print("capture=listening limit=\(Int(Self.recordingLimit))s")
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
                let remaining = releasedAt.map { max(0, $0 + releaseTail - ProcessInfo.processInfo.systemUptime) } ?? releaseTail
                releasedAt = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in self?.runTail() }
            } else { stopAndProcess() }
        case .cancel:
            if state == .listening {
                _ = stopCapture()
                if let audio { willDeleteCanceled?(audio) }
                discard(); print("capture=canceled audio=deleted")
            }
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
        do { try startCapture(url); early = url; earlyStarted = now(); print("capture=listening early"); return true }
        catch { try? store.delete(url); return false }
    }
    func cancelEarly() {
        guard let url = early else { return }
        early = nil; earlyStarted = nil; _ = stopCapture(); try? store.delete(url); print("capture=early-canceled audio=deleted")
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

/// Holds one item for `lifetime` seconds, then lets it go (gap #18: a canceled recording's audio,
/// in memory only, so Undo can still process it). `take` hands it over once, inside the window.
final class UndoWindow<Item> {
    let lifetime: TimeInterval
    /// The clock; checks substitute a fixed one.
    var now: () -> Date = Date.init
    private var held: (item: Item, until: Date)?
    init(lifetime: TimeInterval = 5) { self.lifetime = lifetime }
    func hold(_ item: Item) { held = (item, now().addingTimeInterval(lifetime)) }
    var isOpen: Bool { held.map { now() < $0.until } ?? false }
    /// The item while the window is open, then nothing: it is released either way.
    func take() -> Item? { defer { held = nil }; return isOpen ? held?.item : nil }
    func discard() { held = nil }
}
