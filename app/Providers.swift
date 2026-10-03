import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Cloud transcription and cleanup clients. Verified facts and sources: app/PROVIDERS.md.
//
// Rules enforced here:
// - Exactly one HTTP request per call. No automatic retry (a retry could duplicate output)
//   and no fallback to another provider or model.
// - Every request has an explicit total deadline. Task cancellation cancels the request.
// - Error messages are built from fixed strings, the provider name and status codes. They never
//   include response bodies, API keys or transcript text.

// MARK: - Shared contracts

/// Already-built prompt for cleanup. Built by the cleanup worker's prompt builder; the integrator
/// reconciles this type with that module.
struct CleanupMessages: Equatable, Sendable {
    var system: String
    var user: String
}

/// Recorded audio sent to a transcription provider.
struct AudioPayload: Sendable {
    var data: Data
    var filename: String
    var mimeType: String
    /// ISO-639-1, e.g. "en". Nil lets the provider detect it.
    var language: String?
    /// Optional vocabulary hint (relevant dictionary terms). Sent only where the provider uses it,
    /// and listed in that provider's disclosure.
    var vocabularyHint: String?

    init(data: Data, filename: String = "audio.wav", mimeType: String = "audio/wav", language: String? = "en", vocabularyHint: String? = nil) {
        self.data = data; self.filename = filename; self.mimeType = mimeType
        self.language = language; self.vocabularyHint = vocabularyHint
    }
}

enum ProcessingStage: String, Sendable { case transcription, cleanup }

/// What leaves the device for one route. Show it before the first cloud use (PRD R4).
struct DataDisclosure: Equatable, Sendable {
    let provider: ProviderID
    let stage: ProcessingStage
    let destinationHost: String
    let leavesDevice: [String]
    let staysOnDevice: [String]
    let retentionNote: String

    var summary: String {
        "\(provider.displayName) \(stage.rawValue) sends \(leavesDevice.joined(separator: ", ")) to \(destinationHost). "
            + "Not sent: \(staysOnDevice.joined(separator: ", ")). \(retentionNote)"
    }
}

/// The caller's choice for the session after a provider error.
enum SessionDisposition: Equatable, Sendable {
    /// Keep audio or raw text. Offer an explicit retry later with the same route.
    case preserveRetryLater
    /// Keep audio or raw text. Retrying unchanged will fail; the user must change a key,
    /// plan, model, or route first.
    case preserveNeedsChange
    /// The user cancelled. Discard according to the cancellation policy.
    case discard
}

enum ProviderError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case authentication(ProviderID)
    case quota(ProviderID)
    case rateLimited(ProviderID, retryAfter: TimeInterval?)
    case network(ProviderID)
    case timeout(ProviderID)
    case payloadTooLarge(ProviderID, limitBytes: Int?)
    case server(ProviderID, status: Int?)
    case malformedResponse(ProviderID)
    /// The provider's safety or moderation filter declined the input.
    case contentBlocked(ProviderID)
    /// Other 4xx, e.g. an unknown model or a bad parameter.
    case rejected(ProviderID, status: Int)
    /// Missing key or an invalid local setting; no request was sent.
    case invalidConfiguration(ProviderID)
    case cancelled

    var provider: ProviderID? {
        switch self {
        case .authentication(let p), .quota(let p), .rateLimited(let p, _), .network(let p), .timeout(let p),
             .payloadTooLarge(let p, _), .server(let p, _), .malformedResponse(let p), .contentBlocked(let p),
             .rejected(let p, _), .invalidConfiguration(let p):
            return p
        case .cancelled:
            return nil
        }
    }

    var disposition: SessionDisposition {
        switch self {
        case .rateLimited, .network, .timeout, .server, .malformedResponse: return .preserveRetryLater
        case .authentication, .quota, .payloadTooLarge, .contentBlocked, .rejected, .invalidConfiguration: return .preserveNeedsChange
        case .cancelled: return .discard
        }
    }

    /// Short message for the bubble or history. Contains no key, response body or transcript text.
    var userMessage: String {
        let name = provider?.displayName ?? "The provider"
        switch self {
        case .authentication:
            return "\(name) rejected the API key. Check the key in Settings."
        case .quota:
            return "\(name) reports no remaining quota or credits for this account. Check your plan or billing, or choose another route."
        case .rateLimited(_, let retryAfter):
            if let seconds = retryAfter, seconds > 0 { return "\(name) is rate limiting requests. Try again in \(Int(seconds.rounded(.up))) seconds." }
            return "\(name) is rate limiting requests. Try again shortly."
        case .network:
            return "Couldn't reach \(name). Check your internet connection."
        case .timeout:
            return "\(name) didn't respond in time."
        case .payloadTooLarge(_, let limit):
            if let limit = limit { return "The recording is too large for \(name) (limit \(limit / 1_000_000) MB)." }
            return "The request is too large for \(name)."
        case .server(_, let status):
            if let status = status { return "\(name) had a server problem (HTTP \(status))." }
            return "\(name) had a server problem."
        case .malformedResponse:
            return "\(name) returned a response Murmur couldn't use."
        case .contentBlocked:
            return "\(name) declined to process this dictation (content filter)."
        case .rejected(_, let status):
            return "\(name) rejected the request (HTTP \(status)). Check the model setting."
        case .invalidConfiguration:
            return "\(name) isn't set up. Add an API key and model in Settings."
        case .cancelled:
            return "Cancelled."
        }
    }

    var description: String { userMessage }
    var errorDescription: String? { userMessage }
}

protocol TranscriptionProvider: Sendable {
    var id: ProviderID { get }
    var disclosure: DataDisclosure { get }
    /// One request, no retry. Throws `ProviderError`; `.cancelled` if the calling Task is cancelled.
    func transcribe(_ audio: AudioPayload) async throws -> String
    /// Minimal authenticated call that consumes no tokens. Throws `ProviderError`.
    func validate() async throws
}

protocol CleanupProvider: Sendable {
    var id: ProviderID { get }
    var disclosure: DataDisclosure { get }
    /// One request, no retry. Returns the model text unchanged; the caller runs the bound/guard check.
    func cleanup(_ messages: CleanupMessages) async throws -> String
    func validate() async throws
}

// MARK: - HTTP

struct HTTPResult: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    /// Case-insensitive header lookup.
    func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
}

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResult
}

/// URLSession transport with no cookies, cache or credential storage. Cancelling the calling
/// Task cancels the underlying data task.
final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        let holder = DataTaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResult, Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error = error { continuation.resume(throwing: error); return }
                    guard let http = response as? HTTPURLResponse else { continuation.resume(throwing: URLError(.badServerResponse)); return }
                    var headers: [String: String] = [:]
                    for (key, value) in http.allHeaderFields {
                        if let k = key as? String { headers[k] = "\(value)" }
                    }
                    continuation.resume(returning: HTTPResult(status: http.statusCode, headers: headers, body: data ?? Data()))
                }
                holder.start(task)
            }
        } onCancel: {
            holder.cancel()
        }
    }
}

private final class DataTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func start(_ newTask: URLSessionDataTask) {
        lock.lock(); task = newTask; let wasCancelled = cancelled; lock.unlock()
        newTask.resume()
        if wasCancelled { newTask.cancel() }
    }

    func cancel() {
        lock.lock(); cancelled = true; let current = task; lock.unlock()
        current?.cancel()
    }
}

/// Executes one request with a total deadline and maps transport failures to `ProviderError`.
struct ProviderHTTP: Sendable {
    let provider: ProviderID
    let transport: HTTPTransport
    let deadline: TimeInterval

    func execute(_ request: URLRequest) async throws -> HTTPResult {
        if Task.isCancelled { throw ProviderError.cancelled }
        var timed = request
        timed.timeoutInterval = deadline
        let finalRequest = timed
        let transport = self.transport
        let provider = self.provider
        let deadline = self.deadline
        do {
            let result = try await withThrowingTaskGroup(of: HTTPResult?.self) { group -> HTTPResult in
                group.addTask { try await transport.send(finalRequest) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(deadline, 0.001) * 1_000_000_000))
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let result = first else { throw ProviderError.timeout(provider) }
                return result
            }
            if Task.isCancelled { throw ProviderError.cancelled }
            return result
        } catch let error as ProviderError {
            if Task.isCancelled { throw ProviderError.cancelled }
            throw error
        } catch {
            if Task.isCancelled || error is CancellationError { throw ProviderError.cancelled }
            throw ProviderErrorClassifier.classify(provider: provider, transportError: error)
        }
    }
}

// MARK: - Error classification (pure)

enum ProviderErrorClassifier {
    static func classify(provider: ProviderID, transportError error: Error) -> ProviderError {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timeout(provider)
            default: return .network(provider)
            }
        }
        return .network(provider)
    }

    /// Classifies a non-success HTTP result, or a 200 that carries an error object (OpenRouter
    /// reports errors raised mid-generation that way).
    static func classify(provider: ProviderID, result: HTTPResult, now: Date = Date()) -> ProviderError {
        let info = ErrorBody(result.body)
        var status = result.status
        if (200..<300).contains(status) {
            guard let code = info.numericCode, code >= 400 else { return .server(provider, status: nil) }
            status = code
        }
        let retryAfter = parseRetryAfter(result.header("Retry-After"), now: now) ?? info.retryDelay
        let text = info.searchableText

        switch status {
        case 401:
            return .authentication(provider)
        case 403:
            if provider == .openrouter && (text.contains("moderation") || text.contains("guardrail") || text.contains("flagged")) {
                return .contentBlocked(provider)
            }
            return .authentication(provider)
        case 402:
            return .quota(provider)
        case 412 where provider == .fireworks:
            return .quota(provider)
        case 413:
            return .payloadTooLarge(provider, limitBytes: nil)
        case 408, 504:
            return .timeout(provider)
        case 429:
            if provider == .gemini && isDailyQuota(text) { return .quota(provider) }
            return .rateLimited(provider, retryAfter: retryAfter)
        case 400:
            if provider == .gemini {
                if text.contains("api_key_invalid") || text.contains("api key not valid") || text.contains("api key expired") { return .authentication(provider) }
                if text.contains("failed_precondition") && text.contains("billing") { return .quota(provider) }
            }
            return .rejected(provider, status: status)
        case 400..<500:
            return .rejected(provider, status: status)
        default:
            return .server(provider, status: status)
        }
    }

    static func isDailyQuota(_ lowercasedText: String) -> Bool {
        // Not "billing": Google's per-minute 429 message also says "check your plan and billing details".
        ["quota_exceeded", "perday", "per day", "per_day", "daily", "spend cap", "spending cap", "spend limit"].contains { lowercasedText.contains($0) }
    }

    /// `Retry-After` as delta-seconds or an HTTP-date.
    static func parseRetryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = Double(raw) { return seconds >= 0 ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// Google duration string such as "30s" or "1.5s".
    static func parseGoogleDuration(_ value: String) -> TimeInterval? {
        guard value.hasSuffix("s"), let seconds = Double(value.dropLast()), seconds >= 0 else { return nil }
        return seconds
    }
}

/// Extracts classification signals from the error body shapes of all three providers.
/// It is only matched against fixed keywords; none of its text is shown to the user.
struct ErrorBody {
    var numericCode: Int?
    var codeString: String?
    var status: String?
    var type: String?
    var message: String?
    var reasons: [String] = []
    var retryDelay: TimeInterval?

    init(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return }
        if let code = error["code"] as? Int { numericCode = code }
        else if let code = error["code"] as? String { codeString = code; numericCode = Int(code) }
        status = error["status"] as? String
        type = error["type"] as? String
        message = error["message"] as? String
        if let details = error["details"] as? [[String: Any]] {
            for detail in details {
                if let reason = detail["reason"] as? String { reasons.append(reason) }
                if let delay = detail["retryDelay"] as? String { retryDelay = ProviderErrorClassifier.parseGoogleDuration(delay) }
                if let violations = detail["violations"] as? [[String: Any]] {
                    for violation in violations {
                        if let quotaId = violation["quotaId"] as? String { reasons.append(quotaId) }
                    }
                }
            }
        }
        if let metadata = error["metadata"] as? [String: Any] {
            if let reasons = metadata["reasons"] as? [String] { self.reasons.append(contentsOf: reasons) }
            if metadata["flagged_input"] != nil { self.reasons.append("flagged") }
        }
    }

    var searchableText: String {
        ([codeString, status, type, message].compactMap { $0 } + reasons).joined(separator: " ").lowercased()
    }
}

// MARK: - Request building and parsing (pure)

enum Multipart {
    static func makeBoundary() -> String { "MurmurBoundary-" + UUID().uuidString }

    /// multipart/form-data body with text fields followed by one file part.
    static func body(boundary: String, fields: [(name: String, value: String)], fileField: String, filename: String, mimeType: String, fileData: Data) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for field in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(sanitize(field.name))\"\r\n\r\n")
            append(field.value)
            append("\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(sanitize(fileField))\"; filename=\"\(sanitize(filename))\"\r\n")
        append("Content-Type: \(sanitize(mimeType))\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    /// Prevents header injection through names, filenames or MIME types.
    static func sanitize(_ value: String) -> String {
        String(value.unicodeScalars.filter { $0 != "\"" && $0 != "\r" && $0 != "\n" && $0 != "\\" }.map(Character.init))
    }
}

enum OpenAITranscriptionFormat {
    static func makeRequest(endpoint: URL, apiKey: APIKey, model: String, audio: AudioPayload, includePrompt: Bool, boundary: String) -> URLRequest {
        var fields: [(name: String, value: String)] = [("model", model), ("response_format", "json"), ("temperature", "0")]
        if let language = audio.language, !language.isEmpty { fields.append(("language", language)) }
        if includePrompt, let hint = audio.vocabularyHint, !hint.isEmpty { fields.append(("prompt", hint)) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey.secret)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Multipart.body(boundary: boundary, fields: fields, fileField: "file", filename: audio.filename, mimeType: audio.mimeType, fileData: audio.data)
        return request
    }

    /// `{"text": "..."}`. An empty string (silence) is valid; a missing `text` is not.
    static func parse(provider: ProviderID, result: HTTPResult) throws -> String {
        guard (200..<300).contains(result.status) else { throw ProviderErrorClassifier.classify(provider: provider, result: result) }
        guard let object = try? JSONSerialization.jsonObject(with: result.body) as? [String: Any] else { throw ProviderError.malformedResponse(provider) }
        if object["error"] != nil { throw ProviderErrorClassifier.classify(provider: provider, result: result) }
        guard let text = object["text"] as? String else { throw ProviderError.malformedResponse(provider) }
        return text
    }
}

func validationResult(provider: ProviderID, _ result: HTTPResult) throws {
    guard (200..<300).contains(result.status) else { throw ProviderErrorClassifier.classify(provider: provider, result: result) }
}

private func requireModel(_ model: String, provider: ProviderID) throws {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:~"))
    guard !model.isEmpty, model.count <= 200, model.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }),
          !model.contains("..") else { throw ProviderError.invalidConfiguration(provider) }
}

// MARK: - Fireworks speech to text

/// DEPRECATED UPSTREAM: Fireworks deprecated audio inference on 2026-06-10 (see PROVIDERS.md).
/// Kept because the PRD named it; do not offer it until a live check with a real key passes.
struct FireworksTranscriptionProvider: TranscriptionProvider {
    static let defaultEndpoint = URL(string: "https://audio-turbo.api.fireworks.ai/v1/audio/transcriptions")!
    static let defaultModel = "whisper-v3-turbo"
    static let validationURL = URL(string: "https://api.fireworks.ai/v1/accounts/fireworks/models?pageSize=1")!

    let id = ProviderID.fireworks
    let apiKey: APIKey
    var endpoint: URL = FireworksTranscriptionProvider.defaultEndpoint
    var model: String = FireworksTranscriptionProvider.defaultModel
    var timeout: TimeInterval = 60
    var maxUploadBytes: Int = 25_000_000
    var transport: HTTPTransport = URLSessionTransport()

    init(apiKey: APIKey) { self.apiKey = apiKey }

    var disclosure: DataDisclosure {
        DataDisclosure(provider: id, stage: .transcription, destinationHost: endpoint.host ?? "fireworks.ai",
                       leavesDevice: ["the recorded audio", "relevant dictionary terms as a vocabulary hint (when enabled)"],
                       staysOnDevice: ["history", "the rest of the dictionary", "other apps' text"],
                       retentionNote: "Fireworks states it does not store prompt or generation data without opt-in; whether this covers audio is not documented.")
    }

    static func makeRequest(audio: AudioPayload, apiKey: APIKey, endpoint: URL = defaultEndpoint, model: String = defaultModel, boundary: String = Multipart.makeBoundary()) -> URLRequest {
        OpenAITranscriptionFormat.makeRequest(endpoint: endpoint, apiKey: apiKey, model: model, audio: audio, includePrompt: true, boundary: boundary)
    }

    static func parse(_ result: HTTPResult) throws -> String { try OpenAITranscriptionFormat.parse(provider: .fireworks, result: result) }

    static func makeValidationRequest(apiKey: APIKey) -> URLRequest {
        var request = URLRequest(url: validationURL)
        request.setValue("Bearer \(apiKey.secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func transcribe(_ audio: AudioPayload) async throws -> String {
        try requireModel(model, provider: id)
        guard audio.data.count <= maxUploadBytes else { throw ProviderError.payloadTooLarge(id, limitBytes: maxUploadBytes) }
        let result = try await ProviderHTTP(provider: id, transport: transport, deadline: timeout)
            .execute(Self.makeRequest(audio: audio, apiKey: apiKey, endpoint: endpoint, model: model))
        return try Self.parse(result)
    }

    /// Proves the key works on the general Fireworks API only, not that audio is available.
    func validate() async throws {
        let result = try await ProviderHTTP(provider: id, transport: transport, deadline: 15).execute(Self.makeValidationRequest(apiKey: apiKey))
        try validationResult(provider: id, result)
    }
}

// MARK: - OpenRouter speech to text

struct OpenRouterTranscriptionProvider: TranscriptionProvider {
    static let defaultEndpoint = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
    static let defaultModel = "openai/whisper-large-v3-turbo"
    /// Documented multipart cap.
    static let multipartLimitBytes = 25_000_000

    let id = ProviderID.openrouter
    let apiKey: APIKey
    var endpoint: URL = OpenRouterTranscriptionProvider.defaultEndpoint
    var model: String = OpenRouterTranscriptionProvider.defaultModel
    /// Upstream providers time out after 60 s; allow some margin for upload.
    var timeout: TimeInterval = 75
    var transport: HTTPTransport = URLSessionTransport()

    init(apiKey: APIKey) { self.apiKey = apiKey }

    var disclosure: DataDisclosure {
        DataDisclosure(provider: id, stage: .transcription, destinationHost: endpoint.host ?? "openrouter.ai",
                       leavesDevice: ["the recorded audio"],
                       staysOnDevice: ["history", "the dictionary", "other apps' text"],
                       retentionNote: "OpenRouter does not store prompts unless you opt in; the upstream speech provider's own retention policy applies.")
    }

    /// `prompt` is ignored by this endpoint, so dictionary terms are never sent.
    static func makeRequest(audio: AudioPayload, apiKey: APIKey, endpoint: URL = defaultEndpoint, model: String = defaultModel, boundary: String = Multipart.makeBoundary()) -> URLRequest {
        OpenAITranscriptionFormat.makeRequest(endpoint: endpoint, apiKey: apiKey, model: model, audio: audio, includePrompt: false, boundary: boundary)
    }

    static func parse(_ result: HTTPResult) throws -> String { try OpenAITranscriptionFormat.parse(provider: .openrouter, result: result) }

    func transcribe(_ audio: AudioPayload) async throws -> String {
        try requireModel(model, provider: id)
        guard audio.data.count <= Self.multipartLimitBytes else { throw ProviderError.payloadTooLarge(id, limitBytes: Self.multipartLimitBytes) }
        let result = try await ProviderHTTP(provider: id, transport: transport, deadline: timeout)
            .execute(Self.makeRequest(audio: audio, apiKey: apiKey, endpoint: endpoint, model: model))
        return try Self.parse(result)
    }

    func validate() async throws {
        let result = try await ProviderHTTP(provider: id, transport: transport, deadline: 15).execute(OpenRouterCleanupProvider.makeValidationRequest(apiKey: apiKey))
        try validationResult(provider: id, result)
    }
}

// MARK: - Gemini cleanup

struct GeminiCleanupProvider: CleanupProvider {
    static let defaultBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
    static let defaultModel = "gemini-3.5-flash-lite"
    /// Documented total request size for inline data.
    static let requestLimitBytes = 20_000_000

    let id = ProviderID.gemini
    let apiKey: APIKey
    var baseURL: URL = GeminiCleanupProvider.defaultBaseURL
    var model: String = GeminiCleanupProvider.defaultModel
    var timeout: TimeInterval = 30
    var maxOutputTokens: Int? = 4096
    var transport: HTTPTransport = URLSessionTransport()

    init(apiKey: APIKey) { self.apiKey = apiKey }

    var disclosure: DataDisclosure {
        DataDisclosure(provider: id, stage: .cleanup, destinationHost: baseURL.host ?? "generativelanguage.googleapis.com",
                       leavesDevice: ["the transcript text", "relevant dictionary terms included in the cleanup prompt"],
                       staysOnDevice: ["audio", "history", "the rest of the dictionary"],
                       retentionNote: "Paid tier: Google logs prompts for a limited time for abuse detection only. Free tier: content may be used to improve Google products and read by human reviewers.")
    }

    private struct Part: Encodable { let text: String }
    private struct Content: Encodable { let role: String?; let parts: [Part] }
    private struct GenerationConfig: Encodable { let temperature: Double; let candidateCount: Int; let maxOutputTokens: Int? }
    private struct Body: Encodable { let systemInstruction: Content; let contents: [Content]; let generationConfig: GenerationConfig }

    static func makeRequest(messages: CleanupMessages, apiKey: APIKey, model: String = defaultModel, baseURL: URL = defaultBaseURL, maxOutputTokens: Int? = 4096) throws -> URLRequest {
        try requireModel(model, provider: .gemini)
        guard !model.contains("/") && !model.contains(":") else { throw ProviderError.invalidConfiguration(.gemini) }
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/models/\(model):generateContent") else { throw ProviderError.invalidConfiguration(.gemini) }
        let body = Body(systemInstruction: Content(role: nil, parts: [Part(text: messages.system)]),
                        contents: [Content(role: "user", parts: [Part(text: messages.user)])],
                        generationConfig: GenerationConfig(temperature: 0, candidateCount: 1, maxOutputTokens: maxOutputTokens))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey.secret, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(body)
        return request
    }

    /// Returns `candidates[0].content.parts[].text`, excluding thought parts. A blocked prompt,
    /// safety stop or truncated output (MAX_TOKENS) is an error: partial cleanup must not be inserted.
    static func parse(_ result: HTTPResult) throws -> String {
        guard (200..<300).contains(result.status) else { throw ProviderErrorClassifier.classify(provider: .gemini, result: result) }
        guard let object = try? JSONSerialization.jsonObject(with: result.body) as? [String: Any] else { throw ProviderError.malformedResponse(.gemini) }
        if object["error"] != nil { throw ProviderErrorClassifier.classify(provider: .gemini, result: result) }
        let candidates = object["candidates"] as? [[String: Any]] ?? []
        guard let first = candidates.first else {
            if let feedback = object["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil { throw ProviderError.contentBlocked(.gemini) }
            throw ProviderError.malformedResponse(.gemini)
        }
        let finish = first["finishReason"] as? String ?? "STOP"
        switch finish {
        case "STOP": break
        case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "LANGUAGE": throw ProviderError.contentBlocked(.gemini)
        default: throw ProviderError.malformedResponse(.gemini)
        }
        guard let content = first["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] else { throw ProviderError.malformedResponse(.gemini) }
        let texts = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }
        guard !texts.isEmpty else { throw ProviderError.malformedResponse(.gemini) }
        return texts.joined()
    }

    static func makeValidationRequest(apiKey: APIKey, baseURL: URL = defaultBaseURL) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "pageSize", value: "1")]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey.secret, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func cleanup(_ messages: CleanupMessages) async throws -> String {
        let request = try Self.makeRequest(messages: messages, apiKey: apiKey, model: model, baseURL: baseURL, maxOutputTokens: maxOutputTokens)
        guard (request.httpBody?.count ?? 0) <= Self.requestLimitBytes else { throw ProviderError.payloadTooLarge(id, limitBytes: Self.requestLimitBytes) }
        return try Self.parse(try await ProviderHTTP(provider: id, transport: transport, deadline: timeout).execute(request))
    }

    func validate() async throws {
        let result = try await ProviderHTTP(provider: id, transport: transport, deadline: 15).execute(Self.makeValidationRequest(apiKey: apiKey, baseURL: baseURL))
        try validationResult(provider: id, result)
    }
}

// MARK: - OpenRouter cleanup

struct OpenRouterCleanupProvider: CleanupProvider {
    static let defaultEndpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    static let defaultModel = "google/gemini-3.5-flash-lite"
    static let validationURL = URL(string: "https://openrouter.ai/api/v1/key")!

    let id = ProviderID.openrouter
    let apiKey: APIKey
    var endpoint: URL = OpenRouterCleanupProvider.defaultEndpoint
    var model: String = OpenRouterCleanupProvider.defaultModel
    var timeout: TimeInterval = 30
    var maxTokens: Int? = 4096
    /// Sends `provider.zdr = true`, which restricts routing to Zero Data Retention endpoints.
    /// A model with no such endpoint then fails (typically 503) instead of falling back.
    var zeroDataRetention = false
    var transport: HTTPTransport = URLSessionTransport()

    init(apiKey: APIKey) { self.apiKey = apiKey }

    var disclosure: DataDisclosure {
        DataDisclosure(provider: id, stage: .cleanup, destinationHost: endpoint.host ?? "openrouter.ai",
                       leavesDevice: ["the transcript text", "relevant dictionary terms included in the cleanup prompt"],
                       staysOnDevice: ["audio", "history", "the rest of the dictionary"],
                       retentionNote: zeroDataRetention
                           ? "Routed only to zero-data-retention endpoints; OpenRouter does not store prompts unless you opt in."
                           : "OpenRouter does not store prompts unless you opt in; the upstream model provider's retention policy applies.")
    }

    private struct Message: Encodable { let role: String; let content: String }
    private struct Routing: Encodable { let zdr: Bool }
    private struct Body: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let stream: Bool
        let max_tokens: Int?
        let provider: Routing?
    }

    static func makeRequest(messages: CleanupMessages, apiKey: APIKey, model: String = defaultModel, endpoint: URL = defaultEndpoint, maxTokens: Int? = 4096, zeroDataRetention: Bool = false) throws -> URLRequest {
        try requireModel(model, provider: .openrouter)
        let body = Body(model: model,
                        messages: [Message(role: "system", content: messages.system), Message(role: "user", content: messages.user)],
                        temperature: 0, stream: false, max_tokens: maxTokens,
                        provider: zeroDataRetention ? Routing(zdr: true) : nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey.secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(body)
        return request
    }

    /// `choices[0].message.content`. Errors can arrive with HTTP 200, so the `error` object is
    /// checked first. A `length` finish (truncated) is an error.
    static func parse(_ result: HTTPResult) throws -> String {
        guard (200..<300).contains(result.status) else { throw ProviderErrorClassifier.classify(provider: .openrouter, result: result) }
        guard let object = try? JSONSerialization.jsonObject(with: result.body) as? [String: Any] else { throw ProviderError.malformedResponse(.openrouter) }
        if object["error"] != nil { throw ProviderErrorClassifier.classify(provider: .openrouter, result: result) }
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else { throw ProviderError.malformedResponse(.openrouter) }
        if first["error"] != nil { throw ProviderError.server(.openrouter, status: nil) }
        switch first["finish_reason"] as? String {
        case nil, "stop": break
        case "content_filter": throw ProviderError.contentBlocked(.openrouter)
        default: throw ProviderError.malformedResponse(.openrouter)
        }
        guard let message = first["message"] as? [String: Any], let content = message["content"] as? String else { throw ProviderError.malformedResponse(.openrouter) }
        return content
    }

    static func makeValidationRequest(apiKey: APIKey) -> URLRequest {
        var request = URLRequest(url: validationURL)
        request.setValue("Bearer \(apiKey.secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func cleanup(_ messages: CleanupMessages) async throws -> String {
        let request = try Self.makeRequest(messages: messages, apiKey: apiKey, model: model, endpoint: endpoint, maxTokens: maxTokens, zeroDataRetention: zeroDataRetention)
        return try Self.parse(try await ProviderHTTP(provider: id, transport: transport, deadline: timeout).execute(request))
    }

    func validate() async throws {
        let result = try await ProviderHTTP(provider: id, transport: transport, deadline: 15).execute(Self.makeValidationRequest(apiKey: apiKey))
        try validationResult(provider: id, result)
    }
}
