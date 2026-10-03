import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Deterministic checks for Routes.swift with mock providers and transports: no network, no real
// keys, no AppKit. See app/README.md for the compile command.

private var failures = 0
private var passes = 0
private func check(_ condition: @autoclosure () throws -> Bool, _ label: String, line: Int = #line) rethrows {
    if try condition() { passes += 1 } else { failures += 1; print("FAIL [line \(line)]: \(label)") }
}
private func checkA(_ condition: @autoclosure () async -> Bool, _ label: String, line: Int = #line) async {
    let value = await condition(); check(value, label, line: line)
}

private let secret = "sk-test-SECRET-1234567890"
private let testKey = APIKey(secret)!

/// Counts requests and answers each with a fixed result. Never touches the network.
private final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    let result: HTTPResult
    init(_ result: HTTPResult) { self.result = result }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    private func bump() { lock.lock(); _count += 1; lock.unlock() }
    func send(_ request: URLRequest) async throws -> HTTPResult { bump(); return result }
}

/// A transcriber with no silence pre-check, like OpenRouter Whisper.
private final class SpyTranscriber: TranscriptionProvider, @unchecked Sendable {
    let id: ProviderID
    private let lock = NSLock()
    private var _calls = 0
    let response: Result<String, ProviderError>
    let delaySeconds: Double
    init(_ response: Result<String, ProviderError>, id: ProviderID = .openrouter, delaySeconds: Double = 0) {
        self.id = id; self.response = response; self.delaySeconds = delaySeconds
    }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    private func bump() { lock.lock(); _calls += 1; lock.unlock() }
    var disclosure: DataDisclosure {
        DataDisclosure(provider: id, stage: .transcription, destinationHost: "example.invalid", leavesDevice: ["the recorded audio"], staysOnDevice: ["history"], retentionNote: "test")
    }
    func transcribe(_ audio: AudioPayload) async throws -> String {
        bump()
        if delaySeconds > 0 { try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000)) }
        return try response.get()
    }
    func validate() async throws {}
}

private final class MockCleaner: CleanupProvider, @unchecked Sendable {
    let id = ProviderID.gemini
    let response: Result<String, ProviderError>
    init(_ response: Result<String, ProviderError>) { self.response = response }
    var disclosure: DataDisclosure {
        DataDisclosure(provider: id, stage: .cleanup, destinationHost: "example.invalid", leavesDevice: ["the transcript text"], staysOnDevice: ["audio"], retentionNote: "test")
    }
    func cleanup(_ messages: CleanupMessages) async throws -> String { try response.get() }
    func validate() async throws {}
}

private func tone(seconds: Double, amplitude: Float, rate: Int = 48_000) -> [Float] {
    (0..<Int(seconds * Double(rate))).map { amplitude * Float(sin(Double($0) * 2 * Double.pi * 220 / Double(rate))) }
}

private func geminiBody(_ transcript: String) -> Data {
    let inner = String(data: try! JSONSerialization.data(withJSONObject: ["transcript": transcript]), encoding: .utf8)!
    let outer: [String: Any] = ["candidates": [["content": ["parts": [["text": inner]]], "finishReason": "STOP"]]]
    return try! JSONSerialization.data(withJSONObject: outer)
}

/// A float32 stereo WAVE_FORMAT_EXTENSIBLE file, the shape AVAudioFile may write.
private func floatStereoWAV(_ left: [Float], _ right: [Float], rate: Int) -> Data {
    var b = [UInt8]()
    func p32(_ v: Int) { for s in stride(from: 0, to: 32, by: 8) { b.append(UInt8((v >> s) & 0xFF)) } }
    func p16(_ v: Int) { b.append(UInt8(v & 0xFF)); b.append(UInt8((v >> 8) & 0xFF)) }
    let bytes = left.count * 8
    b += Array("RIFF".utf8); p32(4 + 8 + 40 + 8 + 4 + 8 + bytes); b += Array("WAVE".utf8)
    b += Array("fmt ".utf8); p32(40); p16(0xFFFE); p16(2); p32(rate); p32(rate * 8); p16(8); p16(32)
    p16(22); p16(32); p32(3); p16(3); b += [0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71]
    b += Array("FLLR".utf8); p32(4); b += [0, 0, 0, 0]
    b += Array("data".utf8); p32(bytes)
    for i in left.indices {
        for v in [left[i], right[i]] { let u = v.bitPattern; for s in stride(from: 0, to: 32, by: 8) { b.append(UInt8((u >> UInt32(s)) & 0xFF)) } }
    }
    return Data(b)
}

@main struct RouteChecks {
    static func main() async throws {
        let suite = "murmur-routes-check-\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { print("FAIL: no defaults suite"); exit(1) }
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-routes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }

        factoryChecks()
        planChecks()
        disclosureChecks(defaults)
        settingsChecks(defaults)
        audioChecks()
        await transcriptionChecks()
        await keyChecks()
        try await lexiconChecks(root.appendingPathComponent("lexicon"), defaults)
        try await cleanupChecks(root.appendingPathComponent("cleanup"), defaults)
        await cancelChecks()

        let stored = defaults.dictionaryRepresentation().values.map { "\($0)" }.joined()
        check(!stored.contains(secret), "no key in UserDefaults")
        print("\(passes) checks passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: Factory

    static func factoryChecks() {
        check(CloudTranscriber.allCases.allSatisfy { $0.providerID != .fireworks }, "Fireworks is not offered")
        check(Set(CloudTranscriber.allCases) == [.openrouterWhisper, .geminiAudio, .geminiTranscribe], "offered transcribers")
        check(RouteSettings().cloudTranscriber == .geminiTranscribe, "Gemini Transcribe is the default cloud transcriber")
        check((makeTranscriptionProvider(id: .geminiTranscribe, key: testKey) as? GeminiTranscribeProvider)?.languageCodes == ["en-US"], "Gemini Transcribe factory sends en-US")
        check(makeTranscriptionProvider(id: .geminiTranscribe, key: testKey)?.disclosure.summary.contains("stored") == true, "Gemini Transcribe disclosure says stored")
        check(makeTranscriptionProvider(id: .geminiAudio, key: nil) == nil, "no key, no provider")
        check(makeTranscriptionProvider(id: .geminiAudio, key: testKey) is GeminiTranscriptionProvider, "Gemini audio factory")
        check(makeTranscriptionProvider(id: .openrouterWhisper, key: testKey) is OpenRouterTranscriptionProvider, "OpenRouter factory")
        check(makeCleanupProvider(.localRules, key: testKey, serverURL: "", serverModel: "") == nil, "local rules has no provider")
        check(makeCleanupProvider(.gemini, key: nil, serverURL: "", serverModel: "") == nil, "Gemini cleanup needs a key")
        check(makeCleanupProvider(.localServer, key: nil, serverURL: "http://localhost:11434", serverModel: "llama3.2") is OpenAICompatibleCleanupProvider, "local server key is optional")
        check(makeCleanupProvider(.localServer, key: nil, serverURL: "http://localhost:11434", serverModel: " ") == nil, "local server needs a model")
        check(makeCleanupProvider(.localServer, key: nil, serverURL: "ftp://x", serverModel: "m") == nil, "local server rejects a bad URL")
        check(CleanupChoice.localRules.processingRoute == .local && CleanupChoice.localServer.processingRoute == .cloud, "processing route mapping")
    }

    // MARK: Plans, no fallback

    static func planChecks() {
        let none: (ProviderID) -> APIKey? = { _ in nil }
        let all: (ProviderID) -> APIKey? = { _ in testKey }

        let local = RoutePlan.make(RouteSettings(), cleanupSendsText: true, key: all)
        check(local.usesLocalModel && local.cleaner == nil && local.stages.isEmpty && local.refusal == nil, "defaults are local/local with no disclosure")

        var cloud = RouteSettings(); cloud.transcription = .cloud; cloud.cloudTranscriber = .geminiAudio
        let unconfigured = RoutePlan.make(cloud, cleanupSendsText: true, key: none)
        check(unconfigured.transcriber == nil && !unconfigured.usesLocalModel, "no fallback: an unconfigured cloud route never uses the local model")
        check(unconfigured.refusal == ProviderError.invalidConfiguration(.gemini).userMessage, "unconfigured cloud route refuses")
        check(unconfigured.stages.count == 1, "the disclosure is known before a key is saved")

        let gemini = RoutePlan.make(cloud, cleanupSendsText: true, key: all)
        check(gemini.transcriber is GeminiTranscriptionProvider && gemini.refusal == nil, "configured Gemini audio")
        let summary = gemini.stages.first?.disclosure.summary ?? ""
        check(summary.contains("audio") && summary.contains("Google"), "Gemini disclosure says audio goes to Google")
        check(summary.contains("human reviewers"), "Gemini disclosure says free-tier human review")
        check(summary.lowercased().contains("logs prompts for a limited time"), "Gemini disclosure states storage")
        check(DisclosureText.summary(gemini, stage: .transcription) == summary, "Settings summary")

        var loopback = RouteSettings(); loopback.cleanup = .localServer; loopback.serverModel = "llama3.2"
        let onMac = RoutePlan.make(loopback, cleanupSendsText: true, key: none)
        check(onMac.cleaner != nil && onMac.stages.isEmpty && onMac.refusal == nil, "loopback server needs no disclosure")
        loopback.serverURL = "http://192.168.1.20:11434"
        let lan = RoutePlan.make(loopback, cleanupSendsText: true, key: none)
        check(lan.stages.count == 1 && lan.stages[0].disclosure.warning != nil, "LAN server is disclosed with a plain-http warning")
        loopback.serverModel = ""
        check(RoutePlan.make(loopback, cleanupSendsText: true, key: none).refusal == ProviderError.invalidConfiguration(.localServer).userMessage, "server without a model refuses")

        var geminiCleanup = RouteSettings(); geminiCleanup.cleanup = .gemini
        let off = RoutePlan.make(geminiCleanup, cleanupSendsText: false, key: none)
        check(off.cleaner == nil && off.refusal == nil && off.stages.isEmpty, "cleanup with every option off sends nothing and needs no key")
        let missing = RoutePlan.make(geminiCleanup, cleanupSendsText: true, key: none)
        check(missing.refusal != nil && missing.cleaner == nil, "cloud cleanup without a key refuses instead of using local rules")
    }

    // MARK: Disclosure acknowledgement

    static func disclosureChecks(_ defaults: UserDefaults) {
        let all: (ProviderID) -> APIKey? = { _ in testKey }
        var settings = RouteSettings(); settings.transcription = .cloud; settings.cloudTranscriber = .openrouterWhisper
        let first = RoutePlan.make(settings, cleanupSendsText: true, key: all)
        check(DisclosureAcknowledgement.pending(first, acknowledged: DisclosureAcknowledgement.acknowledged(defaults)).count == 1, "first cloud use needs confirmation")
        DisclosureAcknowledgement.record(first, in: defaults)
        check(DisclosureAcknowledgement.pending(first, acknowledged: DisclosureAcknowledgement.acknowledged(defaults)).isEmpty, "acknowledged route needs no alert")

        settings.cloudTranscriber = .geminiAudio
        let changed = RoutePlan.make(settings, cleanupSendsText: true, key: all)
        let pending = DisclosureAcknowledgement.pending(changed, acknowledged: DisclosureAcknowledgement.acknowledged(defaults))
        check(pending.count == 1 && pending[0].disclosure.provider == .gemini, "provider change asks again")
        let alert = DisclosureText.alert(pending)
        check(alert.title.contains("Gemini") && alert.body.contains("human reviewers") && !alert.body.contains(secret), "alert text")

        settings.cloudTranscriber = .openrouterWhisper; settings.cleanup = .localServer; settings.serverModel = "m"
        settings.serverURL = "http://10.0.0.5:8080"
        let endpoint = RoutePlan.make(settings, cleanupSendsText: true, key: all)
        check(DisclosureAcknowledgement.pending(endpoint, acknowledged: DisclosureAcknowledgement.acknowledged(defaults)).map(\.disclosure.stage) == [.cleanup], "only the new stage is pending")
        DisclosureAcknowledgement.record(endpoint, in: defaults)
        settings.serverURL = "http://10.0.0.6:8080"
        check(DisclosureAcknowledgement.pending(RoutePlan.make(settings, cleanupSendsText: true, key: all), acknowledged: DisclosureAcknowledgement.acknowledged(defaults)).count == 1, "endpoint change asks again")

        // Switching back to local and then to the same cloud route asks again.
        DisclosureAcknowledgement.record(RoutePlan.make(RouteSettings(), cleanupSendsText: true, key: all), in: defaults)
        check(DisclosureAcknowledgement.acknowledged(defaults).isEmpty, "local route clears acknowledgements")
        check(DisclosureAcknowledgement.pending(first, acknowledged: DisclosureAcknowledgement.acknowledged(defaults)).count == 1, "returning to a cloud route asks again")
    }

    static func settingsChecks(_ defaults: UserDefaults) {
        check(RouteSettings.load(from: defaults) == RouteSettings(), "missing settings load as local defaults")
        var settings = RouteSettings(); settings.transcription = .cloud; settings.cloudTranscriber = .geminiAudio
        settings.cleanup = .localServer; settings.serverURL = "http://localhost:1234"; settings.serverModel = "qwen"
        settings.save(to: defaults)
        check(RouteSettings.load(from: defaults) == settings, "route settings round-trip")
        defaults.set("fireworks", forKey: RouteSettings.Key.cloudTranscriber)
        check(RouteSettings.load(from: defaults).cloudTranscriber == .geminiTranscribe, "unknown transcriber falls back to the default choice")
        for key in [RouteSettings.Key.transcription, RouteSettings.Key.cloudTranscriber, RouteSettings.Key.cleanup, RouteSettings.Key.serverURL, RouteSettings.Key.serverModel] { defaults.removeObject(forKey: key) }
    }

    // MARK: Audio

    static func audioChecks() {
        let samples = tone(seconds: 1, amplitude: 0.5)
        let pcm = WAVAudio.encodePCM16(samples, sampleRate: 48_000)
        let decoded = WAVAudio.decode(pcm)
        check(decoded?.sampleRate == 48_000 && decoded?.samples.count == 48_000, "PCM16 round trip")
        let prepared = CloudAudio.prepare(pcm)
        check(prepared.payload.data.count == 44 + 16_000 * 2 && prepared.payload.mimeType == "audio/wav", "downsampled to 16 kHz mono PCM16")
        check(abs((prepared.peak ?? 0) - 0.5) < 0.01 && abs((prepared.duration ?? 0) - 1) < 0.001, "peak and duration")
        let stereo = floatStereoWAV(tone(seconds: 0.5, amplitude: 0.8, rate: 44_100), [Float](repeating: 0, count: 22_050), rate: 44_100)
        let floatDecoded = WAVAudio.decode(stereo)
        check(floatDecoded?.samples.count == 22_050 && abs((floatDecoded?.samples.map { abs($0) }.max() ?? 0) - 0.4) < 0.01, "float32 extensible stereo is averaged to mono")
        check(WAVAudio.decode(Data("not a wav".utf8)) == nil, "non-WAV is not decoded")
        let raw = CloudAudio.prepare(Data("not a wav".utf8))
        check(raw.peak == nil && raw.payload.data == Data("not a wav".utf8), "unparsable audio is sent unchanged with no peak")
        check(WAVAudio.downsample([1, 2, 3], from: 8_000, to: 16_000) == [1, 2, 3], "never upsamples")
    }

    // MARK: Cloud transcription

    static func transcriptionChecks() async {
        let speech = WAVAudio.encodePCM16(tone(seconds: 1, amplitude: 0.3), sampleRate: 48_000)
        let silence = WAVAudio.encodePCM16([Float](repeating: 0.001, count: 48_000), sampleRate: 48_000)

        // Silence skip: the Gemini LLM transcriber is never called for silence.
        let quiet = MockTransport(HTTPResult(status: 200, body: geminiBody("Thank you for watching.")))
        var gemini = GeminiTranscriptionProvider(apiKey: testKey); gemini.transport = quiet
        await checkA(await CloudTranscription.run(provider: gemini, audioData: silence) == .noSpeech(skipped: true), "silence is skipped")
        check(quiet.count == 0, "skipped silence sends no request")
        let tap = WAVAudio.encodePCM16(tone(seconds: 0.1, amplitude: 0.5), sampleRate: 48_000)
        await checkA(await CloudTranscription.run(provider: gemini, audioData: tap) == .noSpeech(skipped: true), "an accidental tap is skipped")

        // Answer-suspected hold.
        let answer = MockTransport(HTTPResult(status: 200, body: geminiBody("Sure, here's a poem about the sea.")))
        gemini.transport = answer
        let held = await CloudTranscription.run(provider: gemini, audioData: speech)
        check(held == .heldAnswerSuspected("Sure, here's a poem about the sea."), "reply-shaped LLM output is held: \(held)")
        check(answer.count == 1, "one request")
        check(CloudTranscription.message(held)?.contains("held") == true, "held message")

        let plain = MockTransport(HTTPResult(status: 200, body: geminiBody("Meet Thursday at three.")))
        gemini.transport = plain
        await checkA(await CloudTranscription.run(provider: gemini, audioData: speech) == .transcript("Meet Thursday at three."), "Gemini transcript")

        // Whisper has no pre-check: silence is sent, and an empty result is "no speech".
        let whisper = SpyTranscriber(.success("  "))
        await checkA(await CloudTranscription.run(provider: whisper, audioData: silence) == .noSpeech(skipped: false), "empty transcript is no speech")
        check(whisper.calls == 1, "no pre-check for Whisper")

        // Errors: one call, no retry, no other provider; audio kept for retry.
        let failing = SpyTranscriber(.failure(.authentication(.openrouter)))
        let bystander = SpyTranscriber(.success("should never run"))
        let failed = await CloudTranscription.run(provider: failing, audioData: speech)
        check(failed == .failed(message: ProviderError.authentication(.openrouter).userMessage, keepAudio: true), "error maps to userMessage")
        check(failing.calls == 1 && bystander.calls == 0, "no retry and no fallback provider")
        check(CloudTranscription.message(failed)?.hasSuffix("Audio is saved for retry for up to 24 hours.") == true, "preserve disposition keeps audio")
        let limited = await CloudTranscription.run(provider: SpyTranscriber(.failure(.rateLimited(.openrouter, retryAfter: 30))), audioData: speech)
        check(limited == .failed(message: ProviderError.rateLimited(.openrouter, retryAfter: 30).userMessage, keepAudio: true), "rate limit keeps audio")
        await checkA(await CloudTranscription.run(provider: SpyTranscriber(.failure(.cancelled)), audioData: speech) == .cancelled, "cancelled maps to cancelled")

        // Real request path with a 401 whose body echoes the key: the message has no key.
        let rejecting = MockTransport(HTTPResult(status: 401, body: Data("{\"error\":{\"message\":\"bad key \(secret)\",\"code\":401}}".utf8)))
        var openrouter = OpenRouterTranscriptionProvider(apiKey: testKey); openrouter.transport = rejecting
        let rejected = await CloudTranscription.run(provider: openrouter, audioData: speech)
        check(CloudTranscription.message(rejected).map { !$0.contains(secret) && $0.contains("OpenRouter rejected the API key") } == true, "key never in transcription messages")
        await checkA(await CloudTranscription.run(provider: whisper, audioFile: URL(fileURLWithPath: "/nonexistent/\(UUID()).wav")) == .failed(message: CloudTranscription.unreadableAudio, keepAudio: true), "unreadable file keeps audio")
    }

    // MARK: Keys

    static func keyChecks() async {
        check(APIKey("sk bad 99") == nil && !KeyText.invalid.contains("sk bad 99"), "invalid key message does not echo input")
        check(KeyText.providers == [.gemini, .openrouter, .localServer], "key rows")
        check("\(testKey)" == "APIKey(redacted)", "key is redacted when printed")
        let echo = HTTPResult(status: 401, body: Data("{\"error\":{\"message\":\"API key not valid: \(secret)\",\"code\":401}}".utf8))
        for provider in [ProviderID.gemini, .openrouter, .localServer] {
            let message = await KeyCheck.run(provider, key: testKey, serverURL: "http://localhost:11434", transport: MockTransport(echo))
            check(!message.contains(secret) && message == ProviderError.authentication(provider).userMessage, "validate \(provider.rawValue) message has no key")
        }
        let ok = MockTransport(HTTPResult(status: 200, body: Data("{\"data\":[{\"id\":\"llama3.2\"}],\"object\":\"list\"}".utf8)))
        await checkA(await KeyCheck.run(.gemini, key: testKey, serverURL: "", transport: ok) == KeyText.validated(.gemini), "validation success")
        await checkA(await KeyCheck.run(.openrouter, key: nil, serverURL: "", transport: ok) == KeyText.missing, "validation needs a saved key")
        await checkA(await KeyCheck.run(.localServer, key: nil, serverURL: "http://localhost:11434", transport: ok) == KeyText.validated(.localServer), "local server validates without a key")
        let found = await KeyCheck.discoverModels(serverURL: "http://localhost:11434", key: nil, transport: ok)
        check((try? found.get()) == ["llama3.2"] && KeyCheck.discoveryMessage(found) == "Found 1 model.", "Find Models")
        let badURL = await KeyCheck.discoverModels(serverURL: "file:///etc", key: testKey)
        check(KeyCheck.discoveryMessage(badURL) == ProviderError.invalidConfiguration(.localServer).userMessage, "Find Models rejects a bad URL")
    }

    // MARK: Learning lexicon (approved condition)

    static func lexiconChecks(_ directory: URL, _ defaults: UserDefaults) async throws {
        let lexicon: Set<String> = ["lunch", "launch", "casual", "causal", "team"]
        let p = try ProcessingCoordinator(directory: directory.appendingPathComponent("with"), defaults: defaults, isCommonWord: { lexicon.contains($0) })
        var settings = p.settings; settings.learningEnabled = true; try p.update(settings)
        func observe(_ c: ProcessingCoordinator, _ s: String, _ t: String) throws -> CorrectionLedger.RecordOutcome {
            try c.observe(ObservedCorrection(sessionID: UUID(), source: s, target: t, observedAt: Date()))
        }
        try check(try observe(p, "lunch", "launch") == .rejected(.ordinaryWords), "lexicon rejects lunch -> launch")
        try check(try observe(p, "casual", "causal") == .rejected(.ordinaryWords), "lexicon rejects casual -> causal")
        try check(try observe(p, "Acme", "Akme") == .provisional, "lexicon keeps a name respelling")
        let without = try ProcessingCoordinator(directory: directory.appendingPathComponent("without"), defaults: defaults)
        try check(try observe(without, "casual", "causal") == .provisional, "without a lexicon the swap passes (known limit)")
    }

    // MARK: Cloud cleanup

    @MainActor static func cleanupChecks(_ directory: URL, _ defaults: UserDefaults) async throws {
        let p = try ProcessingCoordinator(directory: directory, defaults: defaults)
        var settings = p.settings; settings.route = CleanupChoice.gemini.processingRoute; settings.options = .standard; try p.update(settings)
        p.cloudCleaner = MockCleaner(.success("Call Akme."))
        await checkA(await p.processAsync("Um, call Akme.") == .insert("Call Akme."), "configured cloud cleanup inserts")
        p.cloudCleaner = MockCleaner(.failure(.quota(.gemini)))
        let held = await p.processAsync("Um, call Akme.")
        check(held == .heldForRecovery(raw: "Um, call Akme.", reason: .cleanerFailed), "cleanup error holds, no local fallback")
        check(p.lastProviderError == .quota(.gemini), "provider error kept for the hold message")
        p.cloudCleaner = nil
        await checkA(await p.processAsync("Um, call Akme.") == .heldForRecovery(raw: "Um, call Akme.", reason: .cleanerFailed), "unconfigured cloud cleanup holds")
        check(p.lastProviderError == nil, "error cleared per call")
        settings.route = .local; try p.update(settings)
    }

    // MARK: Cancellation prevents insertion

    @MainActor static func cancelChecks() async {
        let request = CloudRequest()
        var delivered: [CloudTranscriptionOutcome] = []

        // Cancel while the provider call is in flight.
        let slow = SpyTranscriber(.success("late text"), delaySeconds: 5)
        let speech = WAVAudio.encodePCM16(tone(seconds: 1, amplitude: 0.3), sampleRate: 16_000)
        request.start({ await CloudTranscription.run(provider: slow, audioData: speech) }) { delivered.append($0) }
        check(request.isActive, "request active")
        for _ in 0..<200 where slow.calls == 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
        check(slow.calls == 1, "provider call started")
        let started = Date()
        request.cancel()
        check(!request.isActive, "cancel clears the request")
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(delivered.isEmpty && Date().timeIntervalSince(started) < 4, "canceled request never delivers")

        // Cancel after the work finished but before the main actor delivered it.
        request.start({ "done" }) { _ in delivered.append(.transcript("should not insert")) }
        request.cancel()
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(delivered.isEmpty, "finished-but-canceled work never delivers")

        // A superseding request cancels the first one.
        var texts: [String] = []
        request.start({ try? await Task.sleep(nanoseconds: 2_000_000_000); return "first" }) { texts.append($0) }
        request.start({ "second" }) { texts.append($0) }
        for _ in 0..<200 where texts.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(texts == ["second"] && !request.isActive, "only the latest request delivers: \(texts)")
    }
}
