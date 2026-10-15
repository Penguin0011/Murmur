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
    private var _lastBody: Data?
    init(_ result: HTTPResult) { self.result = result }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    var lastBody: String { lock.lock(); defer { lock.unlock() }; return String(decoding: _lastBody ?? Data(), as: UTF8.self) }
    func send(_ request: URLRequest) async throws -> HTTPResult { lock.withLock { _count += 1; _lastBody = request.httpBody }; return result }
}

/// A transcriber stub with no network, for checking retry, fallback and error mapping.
private final class SpyTranscriber: TranscriptionProvider, @unchecked Sendable {
    let id: ProviderID
    private let lock = NSLock()
    private var _calls = 0
    let response: Result<String, ProviderError>
    let delaySeconds: Double
    init(_ response: Result<String, ProviderError>, id: ProviderID = .customAPI, delaySeconds: Double = 0) {
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
        disclosureChecks()
        settingsChecks(defaults)
        audioChecks()
        await transcriptionChecks()
        try await dictionaryTranscriptionChecks(root.appendingPathComponent("transcription"), defaults)
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
        check(Set(CloudTranscriber.allCases) == [.customAPI, .gemini], "offered transcribers")
        check(RouteSettings().cloudTranscriber == .gemini, "Gemini is the default cloud transcriber")
        check((makeTranscriptionProvider(id: .gemini, key: testKey) as? GeminiTranscribeProvider)?.languageCodes == ["en-US"], "Gemini Transcribe factory sends en-US")
        check(makeTranscriptionProvider(id: .gemini, key: testKey)?.disclosure.summary.contains("stored") == true, "Gemini Transcribe disclosure says stored")
        check(makeTranscriptionProvider(id: .gemini, key: nil) == nil, "no key, no provider")
        check(makeTranscriptionProvider(id: .gemini, key: testKey, geminiModel: "gemini-2.5-flash") is GeminiTranscriptionProvider, "non-transcription Gemini model uses general audio endpoint")
        check(makeTranscriptionProvider(id: .customAPI, key: testKey) is OpenAICompatibleTranscriptionProvider, "custom transcription factory")
        check(makeCleanupProvider(.localRules, key: testKey, apiBaseURL: "", model: "") == nil, "local rules has no provider")
        check(makeCleanupProvider(.gemini, key: nil, apiBaseURL: "", model: "") == nil, "Gemini cleanup needs a key")
        check(makeCleanupProvider(.customAPI, key: nil, apiBaseURL: "http://localhost:11434", model: "llama3.2") is OpenAICompatibleCleanupProvider, "local custom API needs no key")
        check(makeCleanupProvider(.customAPI, key: nil, apiBaseURL: "http://localhost:11434", model: " ") == nil, "custom API needs a model")
        check(makeCleanupProvider(.customAPI, key: testKey, apiBaseURL: "ftp://x", model: "m") == nil, "custom API rejects a bad URL")
        check(makeCleanupProvider(.customAPI, key: nil, apiBaseURL: "https://api.example.com/v1", model: "m") is OpenAICompatibleCleanupProvider, "custom API key is optional")
        check(CleanupChoice.allCases == [.localRules, .appleIntelligence, .gemini, .customAPI], "cleanup choices: local rules, Apple Intelligence, Gemini and custom API")
        check(ProviderID.customAPI.displayName == "Custom Provider" && CleanupChoice.customAPI.displayName == "Custom Provider", "custom provider name matches key and route controls")
        check(CleanupChoice.localRules.processingRoute == .local && CleanupChoice.customAPI.processingRoute == .cloud, "processing route mapping")
    }

    // MARK: Plans, no fallback

    static func planChecks() {
        let none: (ProviderID) -> APIKey? = { _ in nil }
        let all: (ProviderID) -> APIKey? = { _ in testKey }

        let local = RoutePlan.make(RouteSettings(), cleanupSendsText: true, key: all)
        check(local.usesLocalModel && local.cleaner == nil && local.stages.isEmpty && local.refusal == nil, "defaults are local/local with no disclosure")

        var cloud = RouteSettings(); cloud.transcription = .cloud; cloud.cloudTranscriber = .gemini
        let unconfigured = RoutePlan.make(cloud, cleanupSendsText: true, key: none)
        check(unconfigured.transcriber == nil && !unconfigured.usesLocalModel, "no fallback: an unconfigured cloud route never uses the local model")
        check(unconfigured.refusal == ProviderError.invalidConfiguration(.gemini).userMessage, "unconfigured cloud route refuses")
        check(unconfigured.stages.count == 1, "the disclosure is known before a key is saved")

        let gemini = RoutePlan.make(cloud, cleanupSendsText: true, key: all)
        check(gemini.transcriber is GeminiTranscribeProvider && gemini.refusal == nil, "configured recommended Gemini Transcribe model")
        let summary = gemini.stages.first?.disclosure.summary ?? ""
        check(summary.contains("audio") && summary.contains("Google"), "Gemini disclosure says audio goes to Google")
        check(summary.contains("human reviewers"), "Gemini disclosure says free-tier human review")
        check(summary.lowercased().contains("55 days") && summary.lowercased().contains("stored"), "Gemini Transcribe disclosure states storage")
        check(DisclosureText.summary(gemini, stage: .transcription) == summary, "Settings summary")

        var separate = RouteSettings()
        separate.transcription = .cloud; separate.cloudTranscriber = .customAPI
        separate.customTranscriptionAPIBaseURL = "https://speech.example/v1"
        separate.customAPIBaseURL = "https://cleanup.example/v1"
        separate.cleanup = .customAPI; separate.customAPIModel = "cleanup-model"
        let speechKey = APIKey("speech-key")!, cleanupKey = APIKey("cleanup-key")!
        let independent = RoutePlan.make(separate, cleanupSendsText: true) { id in
            id == .customTranscription ? speechKey : id == .customCleanup ? cleanupKey : nil
        }
        let speechProvider = independent.transcriber as? OpenAICompatibleTranscriptionProvider
        let cleanupProvider = independent.cleaner as? OpenAICompatibleCleanupProvider
        check(speechProvider?.server.apiKey == speechKey && cleanupProvider?.apiKey == cleanupKey &&
              independent.stages.map(\.disclosure.destinationHost).contains("speech.example") &&
              independent.stages.map(\.disclosure.destinationHost).contains("cleanup.example"),
              "custom transcription and cleanup use independent endpoints and credentials")

        var loopback = RouteSettings(); loopback.cleanup = .customAPI; loopback.customAPIBaseURL = "http://localhost:11434"; loopback.customAPIModel = "llama3.2"
        let onMac = RoutePlan.make(loopback, cleanupSendsText: true, key: none)
        check(onMac.cleaner != nil && onMac.stages.isEmpty && onMac.refusal == nil, "loopback server needs no disclosure")
        loopback.customAPIBaseURL = "http://192.168.1.20:11434"
        let lan = RoutePlan.make(loopback, cleanupSendsText: true, key: all)
        check(lan.stages.count == 1 && lan.stages[0].disclosure.warning != nil, "LAN server is disclosed with a plain-http warning")
        let publicNoKey = RoutePlan.make(loopback, cleanupSendsText: true, key: none)
        check(publicNoKey.cleaner != nil && publicNoKey.refusal == nil && publicNoKey.stages.count == 1, "public custom API may omit a key")
        loopback.customAPIModel = ""
        check(RoutePlan.make(loopback, cleanupSendsText: true, key: all).refusal == ProviderError.invalidConfiguration(.customAPI).userMessage, "custom API without a model refuses")

        var geminiCleanup = RouteSettings(); geminiCleanup.cleanup = .gemini
        let off = RoutePlan.make(geminiCleanup, cleanupSendsText: false, key: none)
        check(off.cleaner == nil && off.refusal == nil && off.stages.isEmpty, "cleanup with every option off sends nothing and needs no key")
        let missing = RoutePlan.make(geminiCleanup, cleanupSendsText: true, key: none)
        check(missing.refusal != nil && missing.cleaner == nil, "cloud cleanup without a key refuses instead of using local rules")
    }

    // MARK: Inline disclosure

    static func disclosureChecks() {
        let all: (ProviderID) -> APIKey? = { _ in testKey }
        var settings = RouteSettings(); settings.transcription = .cloud; settings.cloudTranscriber = .customAPI
        let first = RoutePlan.make(settings, cleanupSendsText: true, key: all)
        check(first.stages.count == 1 && first.stages[0].disclosure.stage == .transcription &&
              first.stages[0].disclosure.summary.contains("audio"), "cloud transcription shows its disclosure in Settings")

        settings.cleanup = .gemini
        let geminiCleanup = RoutePlan.make(settings, cleanupSendsText: true, key: all)
        check(Set(geminiCleanup.stages.map(\.disclosure.stage)) == [.transcription, .cleanup], "transcription and cleanup disclosures stay visible inline")

        settings.cloudTranscriber = .gemini
        let changed = RoutePlan.make(settings, cleanupSendsText: true, key: all)
        check(changed.stages.first?.disclosure.provider == .gemini &&
              changed.stages.first?.disclosure.summary.contains("human reviewers") == true,
              "Gemini disclosure stays visible without a confirmation alert")

        settings.cloudTranscriber = .customAPI; settings.cleanup = .customAPI; settings.customAPIModel = "m"
        settings.customTranscriptionAPIBaseURL = "http://10.0.0.5:8080"
        settings.customAPIBaseURL = "http://10.0.0.7:8080"
        let endpoint = RoutePlan.make(settings, cleanupSendsText: true, key: all)
        check(Set(endpoint.stages.map(\.disclosure.destinationHost)) == ["10.0.0.5", "10.0.0.7"],
              "separate custom destinations are disclosed without a confirmation alert")
        settings.customTranscriptionAPIBaseURL = "http://10.0.0.6:8080"
        check(RoutePlan.make(settings, cleanupSendsText: true, key: all).stages.map(\.disclosure.destinationHost).contains("10.0.0.6"),
              "custom destination changes update the inline disclosure")
    }

    static func settingsChecks(_ defaults: UserDefaults) {
        check(RouteSettings.load(from: defaults) == RouteSettings(), "missing settings load as local defaults")
        var settings = RouteSettings(); settings.transcription = .cloud; settings.cloudTranscriber = .gemini
        settings.cleanup = .customAPI; settings.customAPIBaseURL = "https://api.example.com/v1"; settings.customAPIModel = "qwen"
        settings.save(to: defaults)
        check(RouteSettings.load(from: defaults) == settings, "route settings round-trip")
        defaults.set("cerebras", forKey: RouteSettings.Key.cleanup)
        defaults.removeObject(forKey: RouteSettings.Key.customAPIBaseURL)
        defaults.removeObject(forKey: RouteSettings.Key.customAPIModel)
        let migrated = RouteSettings.load(from: defaults)
        check(migrated.cleanup == .customAPI && migrated.customAPIBaseURL == "https://api.cerebras.ai/v1" && migrated.customAPIModel == "gpt-oss-120b", "legacy Cerebras route migrates to editable custom API settings")
        check(RouteSettings.legacyCustomAPIKey(from: "openrouter") == .openrouter && RouteSettings.legacyCustomAPIKey(from: "local-server") == .localServer, "legacy custom-route keys migrate by provider")
        defaults.set("openrouter-whisper", forKey: RouteSettings.Key.cloudTranscriber)
        defaults.removeObject(forKey: RouteSettings.Key.customTranscriptionModel)
        let oldSpeech = RouteSettings.load(from: defaults)
        check(oldSpeech.cloudTranscriber == .customAPI && oldSpeech.customTranscriptionModel == "openai/whisper-large-v3-turbo",
              "legacy OpenRouter transcription becomes editable custom transcription")
        check(oldSpeech.customAPIBaseURL == "https://api.cerebras.ai/v1", "migration preserves an existing chosen custom server")
        defaults.set("gemini-audio", forKey: RouteSettings.Key.cloudTranscriber)
        defaults.removeObject(forKey: RouteSettings.Key.geminiTranscriptionModel)
        check(RouteSettings.load(from: defaults).geminiTranscriptionModel == GeminiTranscriptionProvider.defaultModel,
              "legacy Gemini audio route keeps its general audio model on migration")
        defaults.set("fireworks", forKey: RouteSettings.Key.cloudTranscriber)
        check(RouteSettings.load(from: defaults).cloudTranscriber == .gemini, "removed transcriber (Fireworks) falls back to the default choice")
        for key in [RouteSettings.Key.transcription, RouteSettings.Key.cloudTranscriber, RouteSettings.Key.cleanup, RouteSettings.Key.customAPIBaseURL, RouteSettings.Key.customAPIModel, RouteSettings.Key.customTranscriptionModel, RouteSettings.Key.geminiTranscriptionModel, RouteSettings.Key.legacyServerURL, RouteSettings.Key.legacyServerModel] { defaults.removeObject(forKey: key) }
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
        let tail = CloudAudio.prepare(WAVAudio.encodePCM16(tone(seconds: 1, amplitude: 0.5) + [Float](repeating: 0.001, count: 96_000), sampleRate: 48_000))
        check(tail.payload.data.count == 44 + 24_000 * 2 && abs((tail.duration ?? 0) - 3) < 0.001, "silent tail trimmed to a 0.5 s pad; duration is the recording's")
        check(CloudAudio.trimTrailingSilence([0.001, 0, 0.002], sampleRate: 16_000) == [0.001, 0, 0.002], "all-silent clip left for the pre-check")
        var click = [Float](repeating: 0.002, count: 48_000); click[20_000] = 0.5
        check(GeminiTranscriptionProvider.shouldSkipForSilence(peakLevel: CloudAudio.prepare(WAVAudio.encodePCM16(click, sampleRate: 48_000)).peak ?? 1), "a lone click does not make a silent clip count as speech")
        let word = [Float](repeating: 0.002, count: 24_000) + tone(seconds: 0.2, amplitude: 0.3) + [Float](repeating: 0.002, count: 24_000)
        check(!GeminiTranscriptionProvider.shouldSkipForSilence(peakLevel: CloudAudio.prepare(WAVAudio.encodePCM16(word, sampleRate: 48_000)).peak ?? 0), "a 0.2 s word is speech")
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
        var custom = try! OpenAICompatibleTranscriptionProvider(baseURL: "https://stt.example.test", model: "whisper-large-v3-turbo", apiKey: testKey)
        let whisperQuiet = MockTransport(HTTPResult(status: 200, body: Data(#"{"text":"Thank you."}"#.utf8)))
        custom.transport = whisperQuiet
        await checkA(await CloudTranscription.run(provider: custom, audioData: silence) == .noSpeech(skipped: true), "custom Whisper transcriber skips silence")
        check(whisperQuiet.count == 0, "skipped silence sends no Whisper request")

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
        check(!plain.lastBody.contains("Spelling hints"), "no hint without a dictionary")
        _ = await CloudTranscription.run(provider: gemini, audioData: speech, vocabulary: ["Kubernetes", "Shelfmate"])
        check(plain.lastBody.contains("Kubernetes, Shelfmate"), "dictionary spellings reach cloud transcription")

        // A transcriber without a pre-check: silence is sent, and an empty result is "no speech".
        let whisper = SpyTranscriber(.success("  "))
        await checkA(await CloudTranscription.run(provider: whisper, audioData: silence) == .noSpeech(skipped: false), "empty transcript is no speech")
        check(whisper.calls == 1, "no pre-check for a transcriber without one")

        // Vocabulary alone cannot distinguish speech from a prompt echo. Preserve provider text,
        // including names, lists and literal discussion of vocabulary, on every cloud route.
        let vocab = ["Aakash", "spaceyboi", "Open Router"]
        for spoken in ["Aakash.", "Aakash, spaceyboi, Open Router.", "Meet at three. Aakash.",
                       "Call Aakash, spaceyboi", "Vocabulary: Aakash, spaceyboi.",
                       "We adjusted the camera settings. Vocabulary is aakash, spaceyboi. Vocabulary is",
                       "Thanks, Aakash.", "Ask Aakash about it."] {
            let response = try! JSONSerialization.data(withJSONObject: ["text": spoken])
            let customSpeech = MockTransport(HTTPResult(status: 200, body: response))
            custom.transport = customSpeech
            await checkA(await CloudTranscription.run(provider: custom, audioData: speech, vocabulary: vocab) == .transcript(spoken), "custom preserves spoken dictionary terms: \(spoken)")
            check(!customSpeech.lastBody.contains("name=\"prompt\"") && !customSpeech.lastBody.contains("spaceyboi"), "custom request has no dictionary prompt")

            gemini.transport = MockTransport(HTTPResult(status: 200, body: geminiBody(spoken)))
            await checkA(await CloudTranscription.run(provider: gemini, audioData: speech, vocabulary: vocab) == .transcript(spoken), "Gemini LLM preserves spoken dictionary terms: \(spoken)")

            var asr = GeminiTranscribeProvider(apiKey: testKey)
            let result = try! JSONSerialization.data(withJSONObject: ["id": "v1_test", "status": "completed", "steps": [["type": "model_output", "content": [["type": "text", "text": spoken]]]]])
            let structured = MockTransport(HTTPResult(status: 200, body: result))
            asr.transport = structured
            await checkA(await CloudTranscription.run(provider: asr, audioData: speech, vocabulary: vocab) == .transcript(spoken), "Gemini ASR preserves spoken dictionary terms: \(spoken)")
            let body = try! JSONSerialization.jsonObject(with: Data(structured.lastBody.utf8)) as! [String: Any]
            let config = (body["generation_config"] as? [String: Any])?["transcription_config"] as? [String: Any]
            check(config?["custom_vocabulary"] as? [String] == vocab, "Gemini ASR keeps structured vocabulary")
        }

        // Errors: one call, no retry, no other provider; audio kept for retry.
        let failing = SpyTranscriber(.failure(.authentication(.customAPI)))
        let bystander = SpyTranscriber(.success("should never run"))
        let failed = await CloudTranscription.run(provider: failing, audioData: speech)
        check(failed == .failed(message: ProviderError.authentication(.customAPI).userMessage, keepAudio: true), "error maps to userMessage")
        check(failing.calls == 1 && bystander.calls == 0, "no retry and no fallback provider")
        check(CloudTranscription.message(failed)?.hasSuffix("Audio is saved for retry for up to 24 hours.") == true, "preserve disposition keeps audio")
        let limited = await CloudTranscription.run(provider: SpyTranscriber(.failure(.rateLimited(.customAPI, retryAfter: 30))), audioData: speech)
        check(limited == .failed(message: ProviderError.rateLimited(.customAPI, retryAfter: 30).userMessage, keepAudio: true), "rate limit keeps audio")
        await checkA(await CloudTranscription.run(provider: SpyTranscriber(.failure(.cancelled)), audioData: speech) == .cancelled, "cancelled maps to cancelled")

        // Real request path with a 401 whose body echoes the key: the message has no key.
        let rejecting = MockTransport(HTTPResult(status: 401, body: Data("{\"error\":{\"message\":\"bad key \(secret)\",\"code\":401}}".utf8)))
        var rejectingGemini = GeminiTranscriptionProvider(apiKey: testKey); rejectingGemini.transport = rejecting
        let rejected = await CloudTranscription.run(provider: rejectingGemini, audioData: speech)
        check(CloudTranscription.message(rejected).map { !$0.contains(secret) && $0.contains(ProviderError.authentication(.gemini).userMessage) } == true, "key never in transcription messages")
        await checkA(await CloudTranscription.run(provider: whisper, audioFile: URL(fileURLWithPath: "/nonexistent/\(UUID()).wav")) == .failed(message: CloudTranscription.unreadableAudio, keepAudio: true), "unreadable file keeps audio")
    }

    @MainActor static func dictionaryTranscriptionChecks(_ root: URL, _ defaults: UserDefaults) async throws {
        let p = try ProcessingCoordinator(directory: root, defaults: defaults)
        try p.dictionary.add(preferred: "Aakash", variants: ["Akash"])
        try p.dictionary.add(preferred: "spaceyboi", variants: ["spacey boy"], source: .learned)
        try p.dictionary.add(preferred: "Shelfmate", variants: [], source: .learned)
        var settings = p.settings
        settings.options = .faithful
        try p.update(settings)
        var provider = try OpenAICompatibleTranscriptionProvider(baseURL: "https://stt.example.test", model: "whisper-1", apiKey: testKey)
        let speech = WAVAudio.encodePCM16(tone(seconds: 1, amplitude: 0.3), sampleRate: 48_000)
        let raw = "Call Akash and spacey boy."
        let response = try JSONSerialization.data(withJSONObject: ["text": raw])
        let transport = MockTransport(HTTPResult(status: 200, body: response))
        provider.transport = transport
        let outcome = await CloudTranscription.run(provider: provider, audioData: speech, vocabulary: p.dictionary.vocabularyTerms)
        guard case .transcript(let text) = outcome else { check(false, "custom transcript reaches dictionary"); return }
        check(text == raw, "raw provider text remains available for history")
        check(p.process(text) == .insert("Call Aakash and spaceyboi."), "manual and learned variants correct without ASR hints or cleanup")
        check(!transport.lastBody.contains("name=\"prompt\"") && !transport.lastBody.contains("Shelfmate"), "whole dictionary stays out of custom ASR")
        check(p.process("Send a shelf made report.") == .insert("Send a shelf made report."), "preferred-only learned entry does not make faithful correction fuzzy")
        settings.route = .cloud; settings.options = .standard
        try p.update(settings)
        p.cloudCleaner = MockCleaner(.success("Send a Shelfmate report."))
        await checkA(await p.processAsync("Send a shelf made report.") == .insert("Send a Shelfmate report."), "preferred-only learned spelling still corrected by guarded cleanup")
        p.cloudCleaner = MockCleaner(.failure(.timeout(.gemini)))
        await checkA(await p.processAsync(text) == .insert("Call Aakash and spaceyboi."), "cleanup failure keeps manual and learned exact corrections")
    }

    // MARK: Keys

    static func keyChecks() async {
        let bindingSuite = "murmur-key-binding-" + UUID().uuidString
        let binding = UserDefaults(suiteName: bindingSuite)!
        defer { binding.removePersistentDomain(forName: bindingSuite) }
        let boundKeys = InMemoryCredentialStore([.customAPI: testKey])
        do { _ = try CustomAPIKeyBinding.read(at: "https://first.example/v1", defaults: binding, credentials: boundKeys); check(false, "unbound keys must not leave") }
        catch { check(error as? CredentialError == .destinationMismatch, "legacy unbound key refuses") }
        try! CustomAPIKeyBinding.save(testKey, at: "https://FIRST.example:443/v1/", defaults: binding, credentials: boundKeys)
        check((try? CustomAPIKeyBinding.read(at: "https://first.example/v1", defaults: binding, credentials: boundKeys)) == testKey, "normalized destination accepts its key")
        for address in ["https://second.example/v1", "http://first.example/v1", "https://first.example:8443/v1", "https://first.example/tenant/v1"] {
            do { _ = try CustomAPIKeyBinding.read(at: address, defaults: binding, credentials: boundKeys); check(false, "changed destination must not reuse key") }
            catch { check(error as? CredentialError == .destinationMismatch, "host, scheme, port and path changes refuse") }
        }
        let relaunched = UserDefaults(suiteName: bindingSuite)!
        check((try? CustomAPIKeyBinding.read(at: "https://first.example/v1", defaults: relaunched, credentials: boundKeys)) == testKey, "binding survives relaunch")
        check(!binding.dictionaryRepresentation().values.map { "\($0)" }.joined().contains(secret), "binding stores no secret")
        check(APIKey("sk bad 99") == nil && !KeyText.invalid.contains("sk bad 99"), "invalid key message does not echo input")
        check(KeyText.providers == [.gemini, .customTranscription, .customCleanup], "separate custom provider keys appear in settings")
        let migration = UserDefaults(suiteName: "murmur-migration-" + UUID().uuidString)!
        defer { for key in [RouteSettings.Key.cleanup, RouteSettings.Key.customAPIBaseURL, RouteSettings.Key.customTranscriptionAPIBaseURL, RouteSettings.Key.customAPIModel, RouteSettings.Key.customTranscriptionModel, RouteSettings.Key.geminiTranscriptionModel, RouteSettings.Key.transcription, RouteSettings.Key.cloudTranscriber, "customAPIKeysSplitMigrationComplete"] { migration.removeObject(forKey: key) } }
        let keys = InMemoryCredentialStore([.cerebras: testKey, .openrouter: testKey])
        migration.set("legacy-cloud-route", forKey: "acknowledgedCloudRoutes")
        migration.set("custom-api", forKey: RouteSettings.Key.cleanup)
        try! RouteSettings.migrateCustomAPI(in: migration, credentials: keys)
        check(migration.string(forKey: "acknowledgedCloudRoutes") == nil, "launch migration removes obsolete cloud acknowledgement state")
        check(!keys.exists(.customAPI), "unselected legacy Cerebras key is not copied to a custom endpoint")
        migration.removeObject(forKey: "customAPIKeysSplitMigrationComplete")
        migration.removeObject(forKey: RouteSettings.Key.customAPIBaseURL)
        migration.set("openrouter", forKey: RouteSettings.Key.cleanup)
        try! RouteSettings.migrateCustomAPI(in: migration, credentials: keys)
        check(keys.exists(.customTranscription) && keys.exists(.customCleanup) && RouteSettings.load(from: migration).customAPIBaseURL == "https://openrouter.ai/api/v1", "legacy shared key splits into route-specific keys")
        do { _ = try CustomAPIKeyBinding.read(at: RouteSettings.load(from: migration).customAPIBaseURL, defaults: migration, credentials: keys, provider: .customCleanup); check(false, "migration must not guess approval") }
        catch { check(error as? CredentialError == .destinationMismatch, "migrated keys need destination confirmation") }
        try! keys.delete(.customTranscription); try! keys.delete(.customCleanup)
        try! RouteSettings.migrateCustomAPI(in: migration, credentials: keys)
        check(!keys.exists(.customTranscription) && !keys.exists(.customCleanup), "removed split keys stay removed after relaunch")
        let changedKeys = InMemoryCredentialStore([.customCleanup: testKey])
        migration.set("https://other.example", forKey: CustomAPIKeyBinding.preference(.customCleanup))
        do { _ = try CustomAPIKeyBinding.read(at: "https://changed.example/v1", defaults: migration, credentials: changedKeys, provider: .customCleanup); check(false, "changed custom endpoint must not reuse another key") }
        catch { check(error as? CredentialError == .destinationMismatch, "each custom route keeps its own endpoint binding") }
        let speechSuite = "murmur-speech-migration-" + UUID().uuidString
        let speechDefaults = UserDefaults(suiteName: speechSuite)!
        defer { speechDefaults.removePersistentDomain(forName: speechSuite) }
        speechDefaults.set("cloud", forKey: RouteSettings.Key.transcription)
        speechDefaults.set("openrouter-whisper", forKey: RouteSettings.Key.cloudTranscriber)
        let speechKeys = InMemoryCredentialStore([.openrouter: testKey])
        try! RouteSettings.migrateCustomAPI(in: speechDefaults, credentials: speechKeys)
        let migratedSpeech = RouteSettings.load(from: speechDefaults)
        check(migratedSpeech.cloudTranscriber == .customAPI && migratedSpeech.customAPIBaseURL == "https://openrouter.ai/api/v1", "selected legacy speech server migrates to editable settings")
        check(speechKeys.exists(.customTranscription) && speechDefaults.string(forKey: CustomAPIKeyBinding.preference(.customTranscription)) == nil, "migrated speech key remains unbound")
        check("\(testKey)" == "APIKey(redacted)", "key is redacted when printed")
        let echo = HTTPResult(status: 401, body: Data("{\"error\":{\"message\":\"API key not valid: \(secret)\",\"code\":401}}".utf8))
        for provider in [ProviderID.gemini, .localServer, .customAPI, .customTranscription, .customCleanup] {
            let message = await KeyCheck.run(provider, key: testKey, apiBaseURL: "http://localhost:11434", transport: MockTransport(echo))
            let errorProvider: ProviderID = provider == .customTranscription || provider == .customCleanup ? .customAPI : provider
            check(!message.contains(secret) && message == ProviderError.authentication(errorProvider).userMessage, "validate \(provider.rawValue) message has no key")
        }
        let ok = MockTransport(HTTPResult(status: 200, body: Data("{\"data\":[{\"id\":\"llama3.2\"}],\"object\":\"list\"}".utf8)))
        await checkA(await KeyCheck.run(.gemini, key: testKey, apiBaseURL: "", transport: ok) == KeyText.validated(.gemini), "validation success")
        await checkA(await KeyCheck.run(.openrouter, key: testKey, apiBaseURL: "", transport: ok) == ProviderError.invalidConfiguration(.openrouter).userMessage, "legacy OpenRouter key cannot be validated")
        await checkA(await KeyCheck.run(.customAPI, key: testKey, apiBaseURL: "https://api.example.com/v1", transport: ok) == KeyText.validated(.customAPI), "custom API validates its configured endpoint")
        await checkA(await KeyCheck.run(.customAPI, key: nil, apiBaseURL: "https://api.example.com/v1", transport: ok) == KeyText.validated(.customAPI), "custom API validates without a key when the endpoint permits it")
        await checkA(await KeyCheck.run(.localServer, key: nil, apiBaseURL: "http://localhost:11434", transport: ok) == KeyText.validated(.localServer), "local server validates without a key")
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
        let fellBack = await p.processAsync("Um, call Akme.")
        check(fellBack == .insert("Call Akme."), "cleanup error uses local rules: \(fellBack)")
        check(p.lastProviderError == .quota(.gemini), "provider error kept for the notice")
        p.cloudCleaner = nil
        await checkA(await p.processAsync("Um, call Akme.") == .insert("Call Akme."), "unconfigured cloud cleanup uses local rules")
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
