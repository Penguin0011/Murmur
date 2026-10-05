import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Processing routes (PRD R4, R5): which transcriber and cleaner a dictation uses, what each one
// sends off this Mac, and the async glue between the providers and the controller.
// Foundation only, so app/check_routes.swift runs on Linux. Controller.swift keeps the AppKit
// calls (NSAlert, Keychain-backed store, NSSpellChecker) and only acts on these decisions.
//
// Rules enforced here:
// - No fallback. A cloud route that fails or is not configured never runs the local model or
//   another provider; the session ends in the Error phase with its audio or raw text kept.
// - Each stage that sends data off this Mac needs an acknowledged disclosure. A local model
//   server on a loopback address sends nothing off this Mac and needs none.
// - Messages are built from fixed strings and `ProviderError.userMessage`; they never contain a
//   key, a response body or transcript text.

// MARK: - Route settings

enum TranscriptionRoute: String, CaseIterable, Sendable {
    /// Parakeet through the bundled ModelBench helper. The default.
    case local
    case cloud
}

/// Cloud transcribers offered in Settings: implemented and not deprecated upstream. Fireworks is
/// deliberately absent (its audio inference was deprecated on 2026-06-10, see PROVIDERS.md).
/// To add a provider, add a case here, a `displayName` and `providerID`, and one case in
/// `makeTranscriptionProvider(id:key:)`.
enum CloudTranscriber: String, CaseIterable, Identifiable, Sendable {
    /// OpenRouter `audio/transcriptions` (Whisper large v3 turbo). True ASR.
    case openrouterWhisper = "openrouter-whisper"
    /// Gemini `generateContent` with inline audio: a language model asked to transcribe.
    case geminiAudio = "gemini-audio"
    /// Gemini 3.5 Transcribe via the Interactions API: a dedicated speech model. Google stores
    /// requests (user decision, October 3, 2026). The default cloud transcriber.
    case geminiTranscribe = "gemini-transcribe"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openrouterWhisper: return "OpenRouter Whisper (speech recognition)"
        case .geminiAudio: return "Gemini audio (language model)"
        case .geminiTranscribe: return "Gemini 3.5 Transcribe (speech recognition, stored by Google)"
        }
    }

    /// The Keychain account that holds this transcriber's key.
    var providerID: ProviderID {
        switch self {
        case .openrouterWhisper: return .openrouter
        case .geminiAudio, .geminiTranscribe: return .gemini
        }
    }
}

/// The one place a cloud transcriber is constructed. Nil when no key is available.
func makeTranscriptionProvider(id: CloudTranscriber, key: APIKey?) -> TranscriptionProvider? {
    guard let key else { return nil }
    switch id {
    case .openrouterWhisper: return OpenRouterTranscriptionProvider(apiKey: key)
    case .geminiAudio: return GeminiTranscriptionProvider(apiKey: key)
    case .geminiTranscribe:
        var provider = GeminiTranscribeProvider(apiKey: key)
        provider.languageCodes = ["en-US"]  // Google's language table lists en-US, not a bare en.
        return provider
    }
}

enum CleanupChoice: String, CaseIterable, Identifiable, Sendable {
    /// The built-in RuleCleaner. The default.
    case localRules = "local-rules"
    case gemini
    case customAPI = "custom-api"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localRules: return "Local rules (this Mac)"
        case .gemini: return "Gemini"
        case .customAPI: return "Custom API provider"
        }
    }

    /// ProcessingCoordinator's route: anything but the rule cleaner goes through a provider.
    var processingRoute: CleanupRoute { self == .localRules ? .local : .cloud }

    var providerID: ProviderID? {
        switch self {
        case .localRules: return nil
        case .gemini: return .gemini
        case .customAPI: return .customAPI
        }
    }
}

/// The one place a cleanup provider is constructed. Nil for local rules or invalid custom settings.
func makeCleanupProvider(_ choice: CleanupChoice, key: APIKey?, apiBaseURL: String, model: String) -> CleanupProvider? {
    switch choice {
    case .localRules: return nil
    case .gemini: return key.map { GeminiCleanupProvider(apiKey: $0) }
    case .customAPI:
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return try? OpenAICompatibleCleanupProvider(baseURL: apiBaseURL, model: name, apiKey: key, provider: .customAPI)
    }
}

/// Route settings persisted in UserDefaults. Keys are never stored here (they live in the Keychain).
struct RouteSettings: Equatable, Sendable {
    static let defaultCustomAPIURL = "https://api.cerebras.ai/v1"
    static let defaultCustomAPIModel = "gpt-oss-120b"

    var transcription: TranscriptionRoute = .local
    var cloudTranscriber: CloudTranscriber = .geminiTranscribe
    var cleanup: CleanupChoice = .localRules
    var customAPIBaseURL: String = RouteSettings.defaultCustomAPIURL
    var customAPIModel: String = RouteSettings.defaultCustomAPIModel

    enum Key {
        static let transcription = "transcriptionRoute"
        static let cloudTranscriber = "cloudTranscriber"
        static let cleanup = "cleanupChoice"
        static let customAPIBaseURL = "customAPIBaseURL"
        static let customAPIModel = "customAPIModel"
        static let legacyServerURL = "localServerURL"
        static let legacyServerModel = "localServerModel"
        static let acknowledged = "acknowledgedCloudRoutes"
    }

    static func legacyCustomAPIKey(from choice: String?) -> ProviderID? {
        switch choice {
        case "local-server": return .localServer
        case "openrouter": return .openrouter
        case "cerebras": return .cerebras
        default: return nil
        }
    }

    /// Persist migration only after copying the selected route's key, so failure can be retried.
    static func migrateCustomAPI(in defaults: UserDefaults, credentials: CredentialStore) throws {
        guard let legacy = legacyCustomAPIKey(from: defaults.string(forKey: Key.cleanup)) else { return }
        if !credentials.exists(.customAPI), let key = try credentials.read(legacy) {
            try CustomAPIKeyBinding.save(key, at: load(from: defaults).customAPIBaseURL, defaults: defaults, credentials: credentials)
        }
        load(from: defaults).save(to: defaults)
    }

    /// Missing or unknown values fall back to the approved local defaults.
    static func load(from defaults: UserDefaults) -> RouteSettings {
        var settings = RouteSettings()
        settings.transcription = defaults.string(forKey: Key.transcription).flatMap(TranscriptionRoute.init(rawValue:)) ?? .local
        settings.cloudTranscriber = defaults.string(forKey: Key.cloudTranscriber).flatMap(CloudTranscriber.init(rawValue:)) ?? .geminiTranscribe
        let oldChoice = defaults.string(forKey: Key.cleanup)
        settings.cleanup = oldChoice.flatMap(CleanupChoice.init(rawValue:)) ?? (legacyCustomAPIKey(from: oldChoice) == nil ? .localRules : .customAPI)
        settings.customAPIBaseURL = defaults.string(forKey: Key.customAPIBaseURL) ?? {
            switch oldChoice {
            case "cerebras": return "https://api.cerebras.ai/v1"
            case "openrouter": return "https://openrouter.ai/api/v1"
            case "local-server": return defaults.string(forKey: Key.legacyServerURL) ?? OpenAICompatibleCleanupProvider.ollamaDefault
            default: return defaultCustomAPIURL
            }
        }()
        settings.customAPIModel = defaults.string(forKey: Key.customAPIModel) ?? {
            switch oldChoice {
            case "cerebras": return "gpt-oss-120b"
            case "openrouter": return OpenRouterCleanupProvider.defaultModel
            case "local-server": return defaults.string(forKey: Key.legacyServerModel) ?? ""
            default: return defaultCustomAPIModel
            }
        }()
        return settings
    }

    func save(to defaults: UserDefaults) {
        defaults.set(transcription.rawValue, forKey: Key.transcription)
        defaults.set(cloudTranscriber.rawValue, forKey: Key.cloudTranscriber)
        defaults.set(cleanup.rawValue, forKey: Key.cleanup)
        defaults.set(customAPIBaseURL, forKey: Key.customAPIBaseURL)
        defaults.set(customAPIModel, forKey: Key.customAPIModel)
    }
}

/// Only the endpoint identifier lives in preferences; the secret stays in the Keychain.
enum CustomAPIKeyBinding {
    static let preference = "customAPIKeyEndpoint"

    static func endpoint(_ raw: String) throws -> String {
        let url = try LocalEndpoint.normalize(raw)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if components.port == (components.scheme == "https" ? 443 : 80) { components.port = nil }
        return components.string!
    }

    static func save(_ key: APIKey, at address: String, defaults: UserDefaults, credentials: CredentialStore) throws {
        let destination = try endpoint(address)
        // Fail closed if replacing a key fails partway through: never keep the old binding.
        defaults.removeObject(forKey: preference)
        try credentials.save(key, for: .customAPI)
        defaults.set(destination, forKey: preference)
    }

    static func read(at address: String, defaults: UserDefaults, credentials: CredentialStore) throws -> APIKey? {
        guard credentials.exists(.customAPI) else { return nil }
        guard defaults.string(forKey: preference) == (try endpoint(address)) else { throw CredentialError.destinationMismatch }
        return try credentials.read(.customAPI)
    }
}

// MARK: - Route plan

/// One stage that sends data off this Mac, with the signature its acknowledgement is stored under.
struct DisclosureStage: Equatable, Sendable {
    /// Route, provider and endpoint. Changing any of them changes the signature.
    let signature: String
    let disclosure: DataDisclosure
}

/// What a dictation would use with these settings and keys, decided before recording starts.
struct RoutePlan {
    /// Nil means local transcription (Parakeet).
    let transcriber: TranscriptionProvider?
    /// Nil means the local rule cleaner, or cleanup that sends nothing (all options off).
    let cleaner: CleanupProvider?
    /// Why a dictation cannot start on this route, or nil. Never triggers a fallback.
    let refusal: String?
    /// Stages whose data leaves this Mac, in transcription-then-cleanup order.
    let stages: [DisclosureStage]

    var usesLocalModel: Bool { transcriber == nil && refusal == nil }
    var signatures: [String] { stages.map(\.signature) }

    /// Reads only the disclosure of a provider; this placeholder is never sent anywhere.
    private static let placeholderKey = APIKey("disclosure-only")!

    /// `cleanupSendsText` is false when every cleanup option is off: the provider is not called
    /// then, so nothing is sent and no key is needed.
    static func make(_ settings: RouteSettings, cleanupSendsText: Bool, key: (ProviderID) -> APIKey?) -> RoutePlan {
        var stages: [DisclosureStage] = []
        var refusal: String?
        var transcriber: TranscriptionProvider?
        if settings.transcription == .cloud {
            let choice = settings.cloudTranscriber
            transcriber = makeTranscriptionProvider(id: choice, key: key(choice.providerID))
            if transcriber == nil { refusal = ProviderError.invalidConfiguration(choice.providerID).userMessage }
            if let disclosure = (transcriber ?? makeTranscriptionProvider(id: choice, key: placeholderKey))?.disclosure, !disclosure.staysOnThisMac {
                stages.append(DisclosureStage(signature: "transcription=\(choice.rawValue)@\(disclosure.destinationHost)", disclosure: disclosure))
            }
        }
        var cleaner: CleanupProvider?
        if settings.cleanup != .localRules && cleanupSendsText, let provider = settings.cleanup.providerID {
            let storedKey = key(provider)
            cleaner = makeCleanupProvider(settings.cleanup, key: storedKey, apiBaseURL: settings.customAPIBaseURL, model: settings.customAPIModel)
            if cleaner == nil, refusal == nil { refusal = ProviderError.invalidConfiguration(provider).userMessage }
            let preview = cleaner ?? makeCleanupProvider(settings.cleanup, key: storedKey ?? placeholderKey,
                                                        apiBaseURL: settings.customAPIBaseURL, model: settings.customAPIModel)
            if let disclosure = preview?.disclosure, !disclosure.staysOnThisMac {
                stages.append(DisclosureStage(signature: "cleanup=\(settings.cleanup.rawValue)@\(disclosure.destinationHost)", disclosure: disclosure))
            }
        }
        return RoutePlan(transcriber: transcriber, cleaner: cleaner, refusal: refusal, stages: stages)
    }
}

// MARK: - Disclosure acknowledgement

/// Stores cloud-transcription confirmations. Cleanup disclosures are shown inline in Settings.
enum DisclosureAcknowledgement {
    static func acknowledged(_ defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: RouteSettings.Key.acknowledged) ?? [])
    }

    /// Transcription stages needing confirmation. Cleanup disclosures stay visible inline.
    static func pending(_ plan: RoutePlan, acknowledged: Set<String>) -> [DisclosureStage] {
        plan.stages.filter { $0.disclosure.stage == .transcription && !acknowledged.contains($0.signature) }
    }

    /// Replaces the stored set with this plan's transcription stages, so switching routes asks again.
    static func record(_ plan: RoutePlan, in defaults: UserDefaults) {
        defaults.set(plan.stages.filter { $0.disclosure.stage == .transcription }.map(\.signature), forKey: RouteSettings.Key.acknowledged)
    }
}

enum DisclosureText {
    /// Alert title and body for the stages that need confirmation.
    static func alert(_ stages: [DisclosureStage]) -> (title: String, body: String) {
        let names = stages.map { $0.disclosure.provider.displayName }
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        let title = "Send dictation to \(unique.joined(separator: " and "))?"
        let body = stages.map { $0.disclosure.summary }.joined(separator: "\n\n")
            + "\n\nMurmur never falls back to another route. If this route fails, your audio or raw transcript stays on this Mac for retry."
        return (title, body)
    }

    /// Shown when a dictation starts on a route whose disclosure was not confirmed.
    static let startRefusal = "Confirm what leaves this Mac first: open Settings and choose the route again."

    /// One-line description for Settings, shown before any cloud use.
    static func summary(_ plan: RoutePlan, stage: ProcessingStage) -> String? {
        plan.stages.first { $0.disclosure.stage == stage }?.disclosure.summary
    }
}

// MARK: - Cloud transcription

/// A transcriber that can tell from the recording's level that it should not be called.
protocol SilencePrecheckedTranscriber: TranscriptionProvider {
    func shouldSkip(peakLevel: Float, durationSeconds: Double?) -> Bool
}

/// A language-model transcriber that flags reply-shaped output for recovery.
protocol LLMTranscriber: TranscriptionProvider {
    func transcribeChecked(_ audio: AudioPayload) async throws -> LLMTranscript
}

extension GeminiTranscriptionProvider: SilencePrecheckedTranscriber, LLMTranscriber {
    func shouldSkip(peakLevel: Float, durationSeconds: Double?) -> Bool {
        Self.shouldSkipForSilence(peakLevel: peakLevel, durationSeconds: durationSeconds)
    }
}

enum CloudTranscriptionOutcome: Equatable, Sendable {
    case transcript(String)
    /// An LLM transcriber's output looked like an answer: save it for recovery, never insert.
    case heldAnswerSuspected(String)
    /// Silence was skipped before sending (`skipped`), or the provider heard nothing.
    case noSpeech(skipped: Bool)
    /// `message` is safe to show; `keepAudio` follows the provider error's disposition.
    case failed(message: String, keepAudio: Bool)
    case cancelled
}

enum CloudTranscription {
    static let unreadableAudio = "The recording could not be read."
    static let unknownFailure = "Cloud transcription failed."

    /// Reads the recording off the main thread and runs `run(provider:audioData:vocabulary:)`.
    static func run(provider: TranscriptionProvider, audioFile: URL, vocabulary: [String] = []) async -> CloudTranscriptionOutcome {
        guard let data = try? Data(contentsOf: audioFile) else { return .failed(message: unreadableAudio, keepAudio: true) }
        return await run(provider: provider, audioData: data, vocabulary: vocabulary)
    }

    /// One provider call at most: silence pre-check, then one request, no retry, no fallback.
    /// `vocabulary` (dictionary spellings) goes as the hint; providers that ignore hints drop it.
    static func run(provider: TranscriptionProvider, audioData: Data, vocabulary: [String] = []) async -> CloudTranscriptionOutcome {
        var prepared = CloudAudio.prepare(audioData)
        if !vocabulary.isEmpty { prepared.payload.vocabularyHint = vocabulary.joined(separator: ", ") }
        if let checker = provider as? SilencePrecheckedTranscriber, let peak = prepared.peak,
           checker.shouldSkip(peakLevel: peak, durationSeconds: prepared.duration) {
            return .noSpeech(skipped: true)
        }
        if Task.isCancelled { return .cancelled }
        do {
            let text: String
            var suspected = false
            if let llm = provider as? LLMTranscriber {
                let result = try await llm.transcribeChecked(prepared.payload)
                text = result.text; suspected = result.answerSuspected
            } else {
                text = try await provider.transcribe(prepared.payload)
            }
            if Task.isCancelled { return .cancelled }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noSpeech(skipped: false) }
            return suspected ? .heldAnswerSuspected(text) : .transcript(text)
        } catch let error as ProviderError {
            if error == .cancelled || Task.isCancelled { return .cancelled }
            return .failed(message: error.userMessage, keepAudio: error.disposition != .discard)
        } catch {
            if Task.isCancelled { return .cancelled }
            return .failed(message: unknownFailure, keepAudio: true)
        }
    }

    /// Text for the Error phase.
    static func message(_ outcome: CloudTranscriptionOutcome) -> String? {
        switch outcome {
        case .transcript: return nil
        case .heldAnswerSuspected: return "The transcript looked like an answer rather than dictation, so it was held for review. It is in History."
        case .noSpeech: return "No speech was detected. Check your microphone and try again."
        case .failed(let message, let keepAudio): return keepAudio ? message + " Audio is saved for retry for up to 24 hours." : message
        case .cancelled: return "Canceled. The recording was deleted."
        }
    }
}

/// Converts the recorder's WAV (any channel count, 16/24/32-bit integer or float samples) to
/// 16 kHz mono 16-bit PCM before upload, and measures its peak for the silence pre-check. This
/// keeps two minutes of speech near 3.8 MB, well under the providers' 20–25 MB limits. A file it
/// cannot parse is sent unchanged, with no peak (the silence pre-check is then skipped).
enum CloudAudio {
    static let targetRate = 16_000

    struct Prepared {
        var payload: AudioPayload
        var peak: Float?
        var duration: Double?
    }

    static func prepare(_ data: Data) -> Prepared {
        guard let decoded = WAVAudio.decode(data), decoded.sampleRate > 0 else {
            return Prepared(payload: AudioPayload(data: data), peak: nil, duration: nil)
        }
        let samples = WAVAudio.downsample(decoded.samples, from: decoded.sampleRate, to: targetRate)
        let rate = decoded.sampleRate > targetRate ? targetRate : decoded.sampleRate
        let peak = decoded.samples.reduce(Float(0)) { max($0, $1.isFinite ? abs($1) : 0) }
        return Prepared(payload: AudioPayload(data: WAVAudio.encodePCM16(samples, sampleRate: rate)),
                        peak: min(peak, 1), duration: Double(decoded.samples.count) / Double(decoded.sampleRate))
    }
}

enum WAVAudio {
    struct Decoded { var samples: [Float]; var sampleRate: Int }

    private static func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ i: Int) -> Int { u16(b, i) | u16(b, i + 2) << 16 }

    /// Mono samples in -1...1 (channels averaged). Nil for anything but RIFF/WAVE PCM or float.
    static func decode(_ data: Data) -> Decoded? {
        let b = [UInt8](data)
        guard b.count >= 12, b[0..<4] == [0x52, 0x49, 0x46, 0x46], b[8..<12] == [0x57, 0x41, 0x56, 0x45] else { return nil }
        var format = 0, channels = 0, rate = 0, bits = 0
        var body: Range<Int>?
        var i = 12
        while i + 8 <= b.count {
            let id = String(decoding: b[i..<i + 4], as: UTF8.self)
            var size = u32(b, i + 4)
            let start = i + 8
            // A data chunk whose size was never finalized (0 or 0xFFFFFFFF) runs to the end of the file.
            if id == "data" && (size == 0 || size == 0xFFFF_FFFF) { size = b.count - start }
            let end = min(b.count, start + size)
            if id == "fmt " && end - start >= 16 {
                format = u16(b, start); channels = u16(b, start + 2); rate = u32(b, start + 4); bits = u16(b, start + 14)
                if format == 0xFFFE && end - start >= 26 { format = u16(b, start + 24) }
            } else if id == "data" {
                body = start..<end
                break
            }
            guard size >= 0, start + size + (size & 1) > i else { return nil }
            i = start + size + (size & 1)
        }
        guard let body, channels > 0, channels <= 32, rate > 0,
              (format == 1 && [16, 24, 32].contains(bits)) || (format == 3 && [32, 64].contains(bits)) else { return nil }
        let width = bits / 8
        let frame = width * channels
        let frames = body.count / frame
        var samples = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels {
                let o = body.lowerBound + f * frame + c * width
                let value: Float
                switch (format, bits) {
                case (1, 16): value = Float(Int16(truncatingIfNeeded: u16(b, o))) / 32768
                case (1, 24): value = Float(Int32(truncatingIfNeeded: (u16(b, o) | Int(b[o + 2]) << 16) << 8) >> 8) / 8_388_608
                case (1, 32): value = Float(Int32(truncatingIfNeeded: u32(b, o))) / 2_147_483_648
                case (3, 32): value = Float(bitPattern: UInt32(truncatingIfNeeded: u32(b, o)))
                default: value = Float(Double(bitPattern: UInt64(truncatingIfNeeded: u32(b, o)) | UInt64(truncatingIfNeeded: u32(b, o + 4)) << 32))
                }
                sum += value.isFinite ? value : 0
            }
            samples[f] = sum / Float(channels)
        }
        return Decoded(samples: samples, sampleRate: rate)
    }

    /// Box-filter decimation. Rates at or below `to` are returned unchanged (never upsampled).
    static func downsample(_ samples: [Float], from: Int, to: Int) -> [Float] {
        guard from > to, to > 0, !samples.isEmpty else { return samples }
        let ratio = Double(from) / Double(to)
        let count = Int(Double(samples.count) / ratio)
        var out = [Float](repeating: 0, count: count)
        for n in 0..<count {
            let lo = Int(Double(n) * ratio), hi = min(samples.count, max(lo + 1, Int(Double(n + 1) * ratio)))
            var sum: Float = 0
            for k in lo..<hi { sum += samples[k] }
            out[n] = sum / Float(hi - lo)
        }
        return out
    }

    static func encodePCM16(_ samples: [Float], sampleRate: Int) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(44 + samples.count * 2)
        func put32(_ v: Int) { for s in stride(from: 0, to: 32, by: 8) { out.append(UInt8((v >> s) & 0xFF)) } }
        func put16(_ v: Int) { out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF)) }
        let bytes = samples.count * 2
        out += Array("RIFF".utf8); put32(36 + bytes); out += Array("WAVE".utf8)
        out += Array("fmt ".utf8); put32(16); put16(1); put16(1); put32(sampleRate); put32(sampleRate * 2); put16(2); put16(16)
        out += Array("data".utf8); put32(bytes)
        for s in samples {
            let v = Int16(max(-32768, min(32767, (s.isFinite ? s : 0) * 32767)))
            put16(Int(UInt16(bitPattern: v)))
        }
        return Data(out)
    }
}

// MARK: - Async glue

/// Runs one async request at a time for the controller. Main actor only. `cancel()` cancels the
/// Task (which cancels the HTTP request) and guarantees `deliver` is never called for it, even
/// if the work had already finished and was waiting for the main actor.
@MainActor final class CloudRequest {
    private var task: Task<Void, Never>?
    private var token = UUID()

    var isActive: Bool { task != nil }

    func start<T>(_ work: @escaping @MainActor () async -> T, deliver: @escaping @MainActor (T) -> Void) {
        cancel()
        let current = UUID()
        token = current
        task = Task { @MainActor [weak self] in
            let value = await work()
            guard let self, self.token == current, !Task.isCancelled else { return }
            self.task = nil
            deliver(value)
        }
    }

    func cancel() {
        token = UUID()
        task?.cancel()
        task = nil
    }
}

// MARK: - API keys

enum KeyText {
    static let saved = "Key saved"
    static let none = "No key saved"
    static let invalid = "That doesn't look like an API key: it is empty or has spaces or unsupported characters. Nothing was saved."
    static let storeFailed = "The key could not be saved to the Keychain."
    static let removeFailed = "The key could not be removed from the Keychain."
    static let removed = "Key removed"
    static let checking = "Checking…"
    static let missing = "Save a key first."
    static let unreadable = "The saved key could not be read from the Keychain."

    /// OpenRouter remains available for speech transcription; custom cleanup uses its own key.
    static let providers: [ProviderID] = [.gemini, .openrouter, .customAPI]

    static func validated(_ provider: ProviderID) -> String {
        provider == .localServer ? "The local model server answered." : provider == .customAPI ? "The custom API endpoint answered." : "\(provider.displayName) accepted the key."
    }
}

enum KeyCheck {
    /// One validation request (no tokens used). Returns a message with no key or response body.
    static func run(_ provider: ProviderID, key: APIKey?, apiBaseURL: String, transport: HTTPTransport? = nil) async -> String {
        do {
            switch provider {
            case .gemini:
                guard let key else { return KeyText.missing }
                var p = GeminiCleanupProvider(apiKey: key); if let transport { p.transport = transport }
                try await p.validate()
            case .openrouter:
                guard let key else { return KeyText.missing }
                var p = OpenRouterCleanupProvider(apiKey: key); if let transport { p.transport = transport }
                try await p.validate()
            case .customAPI:
                var p = try OpenAICompatibleCleanupProvider(baseURL: apiBaseURL, model: "validation", apiKey: key, provider: .customAPI)
                if let transport { p.transport = transport }
                try await p.validate()
            case .localServer:
                var p = try OpenAICompatibleCleanupProvider(baseURL: apiBaseURL, model: "validation", apiKey: key); if let transport { p.transport = transport }
                try await p.validate()
            case .cerebras:
                return ProviderError.invalidConfiguration(provider).userMessage
            case .fireworks:
                return ProviderError.invalidConfiguration(provider).userMessage
            }
            return KeyText.validated(provider)
        } catch let error as ProviderError {
            return error.userMessage
        } catch {
            return ProviderError.network(provider).userMessage
        }
    }

    /// Lists a local server's models. Sends no transcript.
    static func discoverModels(serverURL: String, key: APIKey?, transport: HTTPTransport? = nil) async -> Result<[String], ProviderError> {
        do {
            var p = try OpenAICompatibleCleanupProvider(baseURL: serverURL, model: "discovery", apiKey: key)
            if let transport { p.transport = transport }
            return .success(try await p.discoverModels())
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.network(.localServer))
        }
    }

    static func discoveryMessage(_ result: Result<[String], ProviderError>) -> String {
        switch result {
        case .success(let models) where models.isEmpty: return "The server answered but lists no models. Load or pull a model, then try again."
        case .success(let models): return "Found \(models.count) model\(models.count == 1 ? "" : "s")."
        case .failure(let error): return error.userMessage
        }
    }
}
