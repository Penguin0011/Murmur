import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Deterministic provider checks: no network, no real keys. Fixtures are copied from the
// official docs or from unauthenticated responses observed on 2026-10-03 (see PROVIDERS.md).

private var failures = 0
private var passes = 0
private func check(_ condition: @autoclosure () -> Bool, _ label: String, file: StaticString = #file, line: UInt = #line) {
    if condition() { passes += 1 } else { failures += 1; print("FAIL [\(line)]: \(label)") }
}
private func expectError(_ expected: ProviderError, _ label: String, line: UInt = #line, _ body: () throws -> Any) {
    do { _ = try body(); failures += 1; print("FAIL [\(line)]: \(label): no error thrown") }
    catch let error as ProviderError { check(error == expected, "\(label): got \(error) expected \(expected)", line: line) }
    catch { failures += 1; print("FAIL [\(line)]: \(label): unexpected error type") }
}
private func json(_ data: Data?) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:] }
private func result(_ status: Int, _ body: String, _ headers: [String: String] = [:]) -> HTTPResult {
    HTTPResult(status: status, headers: headers, body: Data(body.utf8))
}

/// Records requests; returns canned results or throws; optionally delays.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    let response: Result<HTTPResult, Error>
    let delay: TimeInterval
    init(_ response: Result<HTTPResult, Error>, delay: TimeInterval = 0) { self.response = response; self.delay = delay }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    private func record(_ request: URLRequest) { lock.lock(); _requests.append(request); lock.unlock() }
    func send(_ request: URLRequest) async throws -> HTTPResult {
        record(request)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return try response.get()
    }
}

// Fake key shaped like a real one; never valid anywhere.
let fakeSecret = "sk-or-v1-FAKEKEY0123456789abcdefFAKE"
let key = APIKey(fakeSecret)!
let transcriptSecret = "Synthetic private dictation about Project Nightingale"

// Fixtures
let sttSuccess = #"{"text": "Hello, this is a test of speech-to-text transcription.", "usage": {"seconds": 9.2, "total_tokens": 113, "input_tokens": 83, "output_tokens": 30, "cost": 0.000508}}"#
let geminiSuccess = #"{"candidates": [{"content": {"parts": [{"text": "Please send the report."}], "role": "model"}, "finishReason": "STOP", "index": 0}], "usageMetadata": {"promptTokenCount": 12, "candidatesTokenCount": 5, "totalTokenCount": 17}, "modelVersion": "gemini-3.5-flash-lite", "responseId": "r1"}"#
let geminiThought = #"{"candidates": [{"content": {"parts": [{"text": "thinking...", "thought": true}, {"text": "Meet Thursday "}, {"text": "at three."}], "role": "model"}, "finishReason": "STOP"}]}"#
let geminiBlocked = #"{"promptFeedback": {"blockReason": "SAFETY", "safetyRatings": []}, "usageMetadata": {"promptTokenCount": 3}}"#
let geminiMaxTokens = #"{"candidates": [{"content": {"parts": [{"text": "Please send"}], "role": "model"}, "finishReason": "MAX_TOKENS"}]}"#
let geminiSafetyStop = #"{"candidates": [{"content": {"parts": [], "role": "model"}, "finishReason": "SAFETY"}]}"#
let geminiUnregistered = #"{"error": {"code": 403, "message": "Method doesn't allow unregistered callers (callers without established identity). Please use API Key or other form of API consumer identity to call this API.", "status": "PERMISSION_DENIED"}}"#
let geminiBadKey = #"{"error": {"code": 400, "message": "API key not valid. Please pass a valid API key.", "status": "INVALID_ARGUMENT", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "API_KEY_INVALID", "domain": "googleapis.com"}]}}"#
let geminiPerMinute = #"{"error": {"code": 429, "message": "You exceeded your current quota, please check your plan and billing details.", "status": "RESOURCE_EXHAUSTED", "details": [{"@type": "type.googleapis.com/google.rpc.QuotaFailure", "violations": [{"quotaMetric": "generativelanguage.googleapis.com/generate_content_free_tier_requests", "quotaId": "GenerateRequestsPerMinutePerProjectPerModel-FreeTier"}]}, {"@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "17s"}]}}"#
let geminiPerDay = #"{"error": {"code": 429, "message": "You exceeded your current quota.", "status": "RESOURCE_EXHAUSTED", "details": [{"@type": "type.googleapis.com/google.rpc.QuotaFailure", "violations": [{"quotaId": "GenerateRequestsPerDayPerProjectPerModel-FreeTier"}]}]}}"#
let geminiInteractionsQuota = #"{"error": {"code": "quota_exceeded", "message": "You have exceeded your daily quota."}}"#
let geminiPrepay = #"{"error": {"code": "payment_required", "message": "Your Prepay credit balance is depleted."}}"#
let geminiModelMissing = #"{"error": {"code": 404, "message": "models/gemini-9 is not found", "status": "NOT_FOUND"}}"#
let openRouterChat = #"{"id": "gen-123", "provider": "Google", "model": "google/gemini-3.5-flash-lite", "object": "chat.completion", "created": 1791000000, "choices": [{"logprobs": null, "finish_reason": "stop", "native_finish_reason": "STOP", "index": 0, "message": {"role": "assistant", "content": "Shopping list:\n- apples\n- milk\n- bread", "refusal": null}}], "usage": {"prompt_tokens": 40, "completion_tokens": 12, "total_tokens": 52}}"#
let openRouterNoCookie = #"{"error":{"message":"No cookie auth credentials found","code":401}}"#
let openRouterCredits = #"{"error": {"code": 402, "message": "Insufficient credits. Add more using https://openrouter.ai/credits"}}"#
let openRouterRate = #"{"error": {"code": 429, "message": "Rate limit exceeded"}}"#
let openRouterMidStream = #"{"id": "gen-9", "error": {"code": 502, "message": "Provider returned error"}}"#
let openRouterModeration = #"{"error": {"code": 403, "message": "Input was flagged", "metadata": {"reasons": ["harassment"], "flagged_input": "Synthetic private dictation about Project Nightingale", "provider_name": "OpenAI", "model_slug": "openai/gpt-x"}}}"#
let openRouterNoProvider = #"{"error": {"code": 503, "message": "No endpoints found matching your data policy"}}"#
let openRouterLength = #"{"choices": [{"finish_reason": "length", "message": {"role": "assistant", "content": "Shopping"}}]}"#
let fireworksUnauthorized = #"{"error":{"message":"You must provide an API key. See https://docs.fireworks.ai/api-reference/introduction#authentication for more information.","param":null,"code":"UNAUTHORIZED","type":"error"},"request_id":"9065354e-1dde-4fff-a352-d73dcfe3f95f"}"#
let fireworksAudioUnauthorized = #"{"error":{"object":"error","type":"unauthorized","message":"Unauthorized"}}"#

@main struct ProviderChecks {
    static func main() async {
        checkAPIKeyAndCredentials()
        checkMultipart()
        checkGeminiRequest()
        checkOpenRouterRequest()
        checkParsing()
        checkClassification()
        checkNoSecretsInMessages()
        checkDisclosures()
        await checkTransportBehaviour()
        print(failures == 0
              ? "Provider checks passed (\(passes) assertions: credentials, multipart/JSON shape, parsing, classification, redaction, disclosure, deadline, cancellation, no retry)."
              : "Provider checks FAILED: \(failures) of \(passes + failures) assertions.")
        exit(failures == 0 ? 0 : 1)
    }

    static func checkAPIKeyAndCredentials() {
        check(APIKey("") == nil && APIKey("   \n") == nil, "empty key rejected")
        check(APIKey("ab cd") == nil && APIKey("ab\ncd") == nil, "embedded whitespace rejected")
        check(APIKey("  abc123 \n")?.secret == "abc123", "key trimmed")
        check(APIKey("ключ") == nil, "non-ASCII key rejected")
        check(!"\(key)".contains(fakeSecret) && !String(reflecting: key).contains(fakeSecret), "APIKey description redacted")
        var dumped = ""; dump(key, to: &dumped)
        check(!dumped.contains(fakeSecret), "APIKey dump redacted")
        let provider = OpenRouterCleanupProvider(apiKey: key)
        var providerDump = ""; dump(provider, to: &providerDump)
        check(!providerDump.contains(fakeSecret) && !String(describing: provider).contains(fakeSecret), "provider dump redacted")

        let store = InMemoryCredentialStore()
        check((try? store.read(.gemini)) == .some(nil), "missing key reads nil")
        try? store.save(APIKey("first")!, for: .gemini)
        try? store.save(APIKey("second")!, for: .gemini)
        try? store.save(APIKey("other")!, for: .openrouter)
        check((try? store.read(.gemini))??.secret == "second", "save updates existing key")
        try? store.delete(.gemini)
        check((try? store.read(.gemini)) == .some(nil), "delete removes key")
        check((try? store.delete(.gemini)) != nil, "deleting missing key succeeds")
        try? store.deleteAll()
        check((try? store.read(.openrouter)) == .some(nil), "deleteAll removes every key")
        check(ProviderID.allCases.map(\.rawValue) == ["fireworks", "gemini", "openrouter"], "Keychain account names are provider ids")
        check(CredentialError.keychain(status: -25300).description == "Keychain operation failed (status -25300).", "credential error has status only")
    }

    static func checkMultipart() {
        let audioBytes = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0xFF, 0x0D, 0x0A, 0x2D, 0x2D])
        let audio = AudioPayload(data: audioBytes, filename: "clip.wav", mimeType: "audio/wav", language: "en", vocabularyHint: "Akme, Penguin0011")
        let boundary = "TESTBOUNDARY"
        let fw = FireworksTranscriptionProvider.makeRequest(audio: audio, apiKey: key, boundary: boundary)
        check(fw.httpMethod == "POST", "Fireworks POST")
        check(fw.url?.absoluteString == "https://audio-turbo.api.fireworks.ai/v1/audio/transcriptions", "Fireworks endpoint")
        check(fw.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeSecret)", "Fireworks bearer auth")
        check(fw.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=TESTBOUNDARY", "multipart content type")
        check(!(fw.url?.absoluteString.contains(fakeSecret) ?? true), "key not in URL")
        let body = fw.httpBody ?? Data()
        let parts = splitMultipart(body, boundary: boundary)
        check(parts["model"] == Data("whisper-v3-turbo".utf8), "model field")
        check(parts["response_format"] == Data("json".utf8), "response_format field")
        check(parts["language"] == Data("en".utf8), "language field")
        check(parts["prompt"] == Data("Akme, Penguin0011".utf8), "Fireworks sends vocabulary hint as prompt")
        check(parts["file"] == audioBytes, "file bytes intact, including CRLF and dashes")
        check(String(decoding: body, as: UTF8.self).contains("Content-Disposition: form-data; name=\"file\"; filename=\"clip.wav\"\r\nContent-Type: audio/wav\r\n\r\n"), "file part headers")
        check(body.suffix(18) == Data("\r\n--TESTBOUNDARY--\r\n".utf8.suffix(18)), "closing boundary")

        let or = OpenRouterTranscriptionProvider.makeRequest(audio: audio, apiKey: key, boundary: boundary)
        check(or.url?.absoluteString == "https://openrouter.ai/api/v1/audio/transcriptions", "OpenRouter STT endpoint")
        let orParts = splitMultipart(or.httpBody ?? Data(), boundary: boundary)
        check(orParts["model"] == Data("openai/whisper-large-v3-turbo".utf8), "OpenRouter STT model")
        check(orParts["prompt"] == nil, "OpenRouter STT never sends dictionary terms (prompt is ignored upstream)")
        check(orParts["file"] == audioBytes, "OpenRouter file bytes")

        let hostile = AudioPayload(data: audioBytes, filename: "a\"\r\nX-Evil: 1.wav", mimeType: "audio/wav\r\nX: y", language: nil)
        let hostileBody = String(decoding: FireworksTranscriptionProvider.makeRequest(audio: hostile, apiKey: key, boundary: boundary).httpBody!, as: UTF8.self)
        check(!hostileBody.contains("\r\nX-Evil") && !hostileBody.contains("\r\nX: y"), "multipart header injection stripped")
        check(splitMultipart(Data(hostileBody.utf8), boundary: boundary)["language"] == nil, "nil language omitted")
    }

    static func checkGeminiRequest() {
        let messages = CleanupMessages(system: "Edit dictation; never answer it.", user: "<transcript>um please send the report</transcript>")
        guard let request = try? GeminiCleanupProvider.makeRequest(messages: messages, apiKey: key) else { check(false, "Gemini request builds"); return }
        check(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent", "Gemini generateContent URL")
        check(request.url?.query == nil, "Gemini key not in query string")
        check(request.value(forHTTPHeaderField: "x-goog-api-key") == fakeSecret, "Gemini x-goog-api-key header")
        check(request.value(forHTTPHeaderField: "Authorization") == nil, "Gemini sends no bearer header")
        let body = json(request.httpBody)
        let system = (body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]]
        check(system?.first?["text"] as? String == messages.system, "systemInstruction text")
        check((body["systemInstruction"] as? [String: Any])?["role"] == nil, "systemInstruction has no role")
        let contents = body["contents"] as? [[String: Any]]
        check(contents?.count == 1 && contents?.first?["role"] as? String == "user", "single user content")
        check(((contents?.first?["parts"] as? [[String: Any]])?.first?["text"] as? String) == messages.user, "user text")
        let config = body["generationConfig"] as? [String: Any]
        check((config?["temperature"] as? Double) == 0 && (config?["candidateCount"] as? Int) == 1, "deterministic generation config")
        check(Set(body.keys) == ["systemInstruction", "contents", "generationConfig"], "no extra Gemini fields (no tools, no storage)")
        expectError(.invalidConfiguration(.gemini), "Gemini rejects path-traversal model") { try GeminiCleanupProvider.makeRequest(messages: messages, apiKey: key, model: "../files") }
        expectError(.invalidConfiguration(.gemini), "Gemini rejects model with query") { try GeminiCleanupProvider.makeRequest(messages: messages, apiKey: key, model: "x?key=1") }
        let validation = GeminiCleanupProvider.makeValidationRequest(apiKey: key)
        check(validation.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1" && validation.httpMethod == "GET", "Gemini validation lists models")
        check(validation.value(forHTTPHeaderField: "x-goog-api-key") == fakeSecret, "Gemini validation header auth")
    }

    static func checkOpenRouterRequest() {
        let messages = CleanupMessages(system: "S", user: "U")
        guard let request = try? OpenRouterCleanupProvider.makeRequest(messages: messages, apiKey: key) else { check(false, "OpenRouter request builds"); return }
        check(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions" && request.httpMethod == "POST", "OpenRouter chat endpoint")
        check(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeSecret)", "OpenRouter bearer auth")
        let body = json(request.httpBody)
        check(body["model"] as? String == "google/gemini-3.5-flash-lite", "OpenRouter default model")
        let roles = (body["messages"] as? [[String: Any]])?.map { "\($0["role"]!):\($0["content"]!)" }
        check(roles == ["system:S", "user:U"], "system then user messages")
        check(body["stream"] as? Bool == false && (body["temperature"] as? Double) == 0, "non-streaming, temperature 0")
        check(body["provider"] == nil, "no routing restriction by default")
        let zdr = json((try? OpenRouterCleanupProvider.makeRequest(messages: messages, apiKey: key, zeroDataRetention: true))?.httpBody)
        check((zdr["provider"] as? [String: Any])?["zdr"] as? Bool == true, "zdr routing flag")
        let validation = OpenRouterCleanupProvider.makeValidationRequest(apiKey: key)
        check(validation.url?.absoluteString == "https://openrouter.ai/api/v1/key" && validation.httpMethod == "GET", "OpenRouter validation endpoint")
        let fwValidation = FireworksTranscriptionProvider.makeValidationRequest(apiKey: key)
        check(fwValidation.url?.absoluteString == "https://api.fireworks.ai/v1/accounts/fireworks/models?pageSize=1", "Fireworks validation endpoint")
    }

    static func checkParsing() {
        check((try? OpenRouterTranscriptionProvider.parse(result(200, sttSuccess))) == "Hello, this is a test of speech-to-text transcription.", "STT success parse")
        check((try? FireworksTranscriptionProvider.parse(result(200, #"{"text": ""}"#))) == "", "empty transcript (silence) is valid")
        expectError(.malformedResponse(.fireworks), "STT missing text") { try FireworksTranscriptionProvider.parse(result(200, #"{"segments": []}"#)) }
        expectError(.malformedResponse(.openrouter), "STT non-JSON") { try OpenRouterTranscriptionProvider.parse(result(200, "<html>")) }
        expectError(.authentication(.fireworks), "Fireworks observed 401") { try FireworksTranscriptionProvider.parse(result(401, fireworksUnauthorized)) }
        expectError(.authentication(.fireworks), "Fireworks audio-host 401") { try FireworksTranscriptionProvider.parse(result(401, fireworksAudioUnauthorized)) }
        expectError(.server(.fireworks, status: 503), "Fireworks 503 no healthy upstream") { try FireworksTranscriptionProvider.parse(result(503, "no healthy upstream")) }

        check((try? GeminiCleanupProvider.parse(result(200, geminiSuccess))) == "Please send the report.", "Gemini success parse")
        check((try? GeminiCleanupProvider.parse(result(200, geminiThought))) == "Meet Thursday at three.", "Gemini joins parts, skips thoughts")
        expectError(.contentBlocked(.gemini), "Gemini blocked prompt") { try GeminiCleanupProvider.parse(result(200, geminiBlocked)) }
        expectError(.malformedResponse(.gemini), "Gemini MAX_TOKENS is never partial output") { try GeminiCleanupProvider.parse(result(200, geminiMaxTokens)) }
        expectError(.contentBlocked(.gemini), "Gemini SAFETY finish") { try GeminiCleanupProvider.parse(result(200, geminiSafetyStop)) }
        expectError(.malformedResponse(.gemini), "Gemini empty object") { try GeminiCleanupProvider.parse(result(200, "{}")) }

        check((try? OpenRouterCleanupProvider.parse(result(200, openRouterChat))) == "Shopping list:\n- apples\n- milk\n- bread", "OpenRouter success parse")
        expectError(.server(.openrouter, status: 502), "OpenRouter error inside HTTP 200") { try OpenRouterCleanupProvider.parse(result(200, openRouterMidStream)) }
        expectError(.malformedResponse(.openrouter), "OpenRouter truncated output") { try OpenRouterCleanupProvider.parse(result(200, openRouterLength)) }
        expectError(.malformedResponse(.openrouter), "OpenRouter no choices") { try OpenRouterCleanupProvider.parse(result(200, #"{"choices": []}"#)) }
    }

    static func checkClassification() {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        func c(_ p: ProviderID, _ status: Int, _ body: String, _ headers: [String: String] = [:]) -> ProviderError {
            ProviderErrorClassifier.classify(provider: p, result: result(status, body, headers), now: now)
        }
        check(c(.gemini, 403, geminiUnregistered) == .authentication(.gemini), "Gemini 403 → authentication")
        check(c(.gemini, 400, geminiBadKey) == .authentication(.gemini), "Gemini API_KEY_INVALID → authentication")
        check(c(.gemini, 429, geminiPerMinute) == .rateLimited(.gemini, retryAfter: 17), "Gemini per-minute 429 → rateLimited(RetryInfo)")
        check(c(.gemini, 429, geminiPerDay) == .quota(.gemini), "Gemini per-day 429 → quota")
        check(c(.gemini, 429, geminiInteractionsQuota) == .quota(.gemini), "Gemini quota_exceeded → quota")
        check(c(.gemini, 402, geminiPrepay) == .quota(.gemini), "Gemini 402 → quota")
        check(c(.gemini, 404, geminiModelMissing) == .rejected(.gemini, status: 404), "Gemini unknown model → rejected")
        check(c(.gemini, 400, #"{"error": {"code": 400, "message": "Invalid JSON payload", "status": "INVALID_ARGUMENT"}}"#) == .rejected(.gemini, status: 400), "Gemini plain 400 → rejected")
        check(c(.gemini, 504, "") == .timeout(.gemini), "504 → timeout")
        check(c(.openrouter, 401, openRouterNoCookie) == .authentication(.openrouter), "OpenRouter 401")
        check(c(.openrouter, 402, openRouterCredits) == .quota(.openrouter), "OpenRouter 402 → quota")
        check(c(.openrouter, 429, openRouterRate, ["Retry-After": "60"]) == .rateLimited(.openrouter, retryAfter: 60), "Retry-After seconds")
        check(c(.openrouter, 429, openRouterRate, ["retry-after": "Sat, 03 Oct 2026 04:00:30 GMT"]) == .rateLimited(.openrouter, retryAfter: 30), "Retry-After HTTP-date, case-insensitive header")
        check(c(.openrouter, 429, openRouterRate) == .rateLimited(.openrouter, retryAfter: nil), "429 without Retry-After")
        check(c(.openrouter, 403, openRouterModeration) == .contentBlocked(.openrouter), "OpenRouter moderation 403 → contentBlocked")
        check(c(.openrouter, 503, openRouterNoProvider) == .server(.openrouter, status: 503), "OpenRouter 503")
        check(c(.openrouter, 408, "") == .timeout(.openrouter), "408 → timeout")
        check(c(.fireworks, 412, "{}") == .quota(.fireworks), "Fireworks 412 suspended → quota")
        check(c(.fireworks, 413, "{}") == .payloadTooLarge(.fireworks, limitBytes: nil), "413 → payloadTooLarge")
        check(c(.fireworks, 520, "") == .server(.fireworks, status: 520), "520 → server")
        check(c(.openrouter, 200, "not json") == .server(.openrouter, status: nil), "unexplained 200 error → server")

        check(ProviderErrorClassifier.classify(provider: .gemini, transportError: URLError(.notConnectedToInternet)) == .network(.gemini), "offline → network")
        check(ProviderErrorClassifier.classify(provider: .gemini, transportError: URLError(.cannotFindHost)) == .network(.gemini), "DNS → network")
        check(ProviderErrorClassifier.classify(provider: .gemini, transportError: URLError(.timedOut)) == .timeout(.gemini), "URL timeout → timeout")
        check(ProviderErrorClassifier.classify(provider: .gemini, transportError: URLError(.cancelled)) == .cancelled, "URL cancel → cancelled")
        check(ProviderErrorClassifier.classify(provider: .gemini, transportError: CancellationError()) == .cancelled, "CancellationError → cancelled")

        check(ProviderError.rateLimited(.gemini, retryAfter: 3).disposition == .preserveRetryLater, "rate limit keeps session for retry")
        check(ProviderError.network(.gemini).disposition == .preserveRetryLater && ProviderError.timeout(.gemini).disposition == .preserveRetryLater, "network/timeout keep session")
        check(ProviderError.server(.gemini, status: 500).disposition == .preserveRetryLater && ProviderError.malformedResponse(.gemini).disposition == .preserveRetryLater, "server/malformed keep session")
        check(ProviderError.authentication(.gemini).disposition == .preserveNeedsChange && ProviderError.quota(.gemini).disposition == .preserveNeedsChange, "auth/quota keep session, need change")
        check(ProviderError.payloadTooLarge(.gemini, limitBytes: 1).disposition == .preserveNeedsChange, "payload keeps session, needs change")
        check(ProviderError.cancelled.disposition == .discard, "cancel discards")
        check(ProviderError.rateLimited(.openrouter, retryAfter: 1.2).userMessage.contains("2 seconds"), "retry hint rounds up")
        check(ProviderError.payloadTooLarge(.openrouter, limitBytes: 25_000_000).userMessage.contains("25 MB"), "payload message states limit")
    }

    static func checkNoSecretsInMessages() {
        // Bodies that (maliciously or by echo) contain the key and transcript must not leak into messages.
        let echo = #"{"error": {"code": 400, "message": "bad key \#(fakeSecret) for text \#(transcriptSecret)", "status": "INVALID_ARGUMENT"}}"#
        var errors: [ProviderError] = []
        for provider in ProviderID.allCases {
            for status in [200, 400, 401, 402, 403, 404, 408, 412, 413, 429, 500, 503, 504] {
                errors.append(ProviderErrorClassifier.classify(provider: provider, result: result(status, echo, ["Retry-After": "5"])))
            }
            errors.append(ProviderErrorClassifier.classify(provider: provider, result: result(403, openRouterModeration)))
        }
        errors += [.cancelled, .invalidConfiguration(.gemini), .contentBlocked(.openrouter), .payloadTooLarge(.gemini, limitBytes: nil)]
        for error in errors {
            let texts = [error.userMessage, error.description, error.localizedDescription, String(reflecting: error)]
            check(!texts.contains { $0.contains(fakeSecret) || $0.contains("FAKEKEY") || $0.contains("Nightingale") }, "no key/transcript in \(error)")
        }
        let parsed: Error
        do { _ = try GeminiCleanupProvider.parse(result(400, echo)); parsed = ProviderError.cancelled } catch { parsed = error }
        check(!"\(parsed)".contains(fakeSecret) && !"\(parsed)".contains("Nightingale"), "thrown parse error redacted")
    }

    static func checkDisclosures() {
        let gemini = GeminiCleanupProvider(apiKey: key).disclosure
        check(gemini.stage == .cleanup && gemini.leavesDevice.joined().contains("transcript") && gemini.leavesDevice.joined().contains("dictionary terms"), "cleanup disclosure lists transcript and dictionary terms")
        check(gemini.staysOnDevice.contains("audio") && gemini.retentionNote.contains("human reviewers"), "Gemini disclosure: audio stays, free-tier review warning")
        let orSTT = OpenRouterTranscriptionProvider(apiKey: key).disclosure
        check(orSTT.leavesDevice == ["the recorded audio"] && orSTT.destinationHost == "openrouter.ai", "OpenRouter STT sends audio only")
        let fw = FireworksTranscriptionProvider(apiKey: key).disclosure
        check(fw.leavesDevice.joined().contains("audio") && fw.leavesDevice.joined().contains("vocabulary"), "Fireworks STT discloses vocabulary hint")
        var zdr = OpenRouterCleanupProvider(apiKey: key); zdr.zeroDataRetention = true
        check(zdr.disclosure.retentionNote.contains("zero-data-retention"), "ZDR disclosure")
        check(!gemini.summary.contains(fakeSecret), "summary has no key")
    }

    static func checkTransportBehaviour() async {
        let audio = AudioPayload(data: Data(repeating: 1, count: 64))
        // One request only on a retryable failure: no automatic retry.
        let failing = MockTransport(.success(result(503, openRouterNoProvider)))
        var stt = OpenRouterTranscriptionProvider(apiKey: key); stt.transport = failing
        do { _ = try await stt.transcribe(audio); check(false, "503 should throw") }
        catch { check(error as? ProviderError == .server(.openrouter, status: 503), "503 surfaces as server") }
        check(failing.requests.count == 1, "exactly one request, no automatic retry")

        let ok = MockTransport(.success(result(200, sttSuccess)))
        stt.transport = ok
        let transcribed = try? await stt.transcribe(audio)
        check(transcribed == "Hello, this is a test of speech-to-text transcription.", "transcribe through transport")
        check(ok.requests.first?.timeoutInterval == 75, "explicit request timeout applied")

        // Oversized audio is rejected before any network request.
        let unused = MockTransport(.success(result(200, sttSuccess)))
        stt.transport = unused
        do { _ = try await stt.transcribe(AudioPayload(data: Data(count: 25_000_001))); check(false, "oversize should throw") }
        catch { check(error as? ProviderError == .payloadTooLarge(.openrouter, limitBytes: 25_000_000), "local payload limit") }
        check(unused.requests.isEmpty, "no request for oversize audio")

        // Deadline.
        var slowGemini = GeminiCleanupProvider(apiKey: key)
        slowGemini.transport = MockTransport(.success(result(200, geminiSuccess)), delay: 5)
        slowGemini.timeout = 0.2
        let started = Date()
        do { _ = try await slowGemini.cleanup(CleanupMessages(system: "s", user: "u")); check(false, "deadline should throw") }
        catch { check(error as? ProviderError == .timeout(.gemini), "total deadline → timeout, got \(error)") }
        check(Date().timeIntervalSince(started) < 2, "deadline enforced promptly")

        // Cancellation through Task.
        var cancellable = OpenRouterCleanupProvider(apiKey: key)
        cancellable.transport = MockTransport(.success(result(200, openRouterChat)), delay: 5)
        let provider = cancellable
        let task = Task { try await provider.cleanup(CleanupMessages(system: "s", user: "u")) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let cancelStart = Date()
        do { _ = try await task.value; check(false, "cancel should throw") }
        catch { check(error as? ProviderError == .cancelled, "task cancellation → cancelled, got \(error)") }
        check(Date().timeIntervalSince(cancelStart) < 2, "cancellation prompt")

        // Transport errors.
        var offline = OpenRouterCleanupProvider(apiKey: key)
        offline.transport = MockTransport(.failure(URLError(.notConnectedToInternet)))
        do { _ = try await offline.cleanup(CleanupMessages(system: "s", user: "u")); check(false, "offline should throw") }
        catch { check(error as? ProviderError == .network(.openrouter), "offline → network") }

        // Missing/invalid model fails locally.
        var badModel = OpenRouterCleanupProvider(apiKey: key)
        let neverCalled = MockTransport(.success(result(200, openRouterChat)))
        badModel.transport = neverCalled; badModel.model = ""
        do { _ = try await badModel.cleanup(CleanupMessages(system: "s", user: "u")); check(false, "empty model should throw") }
        catch { check(error as? ProviderError == .invalidConfiguration(.openrouter) && neverCalled.requests.isEmpty, "empty model → invalidConfiguration, no request") }

        // validate(): one cheap authenticated GET; classifies failures.
        let validOK = MockTransport(.success(result(200, #"{"data": {"label": "sk-or-v1-abc...xyz", "limit": null}}"#)))
        var validator = OpenRouterCleanupProvider(apiKey: key); validator.transport = validOK
        do { try await validator.validate(); check(validOK.requests.first?.httpMethod == "GET" && validOK.requests.first?.url?.path == "/api/v1/key", "validate GET /key") }
        catch { check(false, "validate should pass: \(error)") }
        var badValidator = GeminiCleanupProvider(apiKey: key); badValidator.transport = MockTransport(.success(result(400, geminiBadKey)))
        do { try await badValidator.validate(); check(false, "bad key validate should throw") }
        catch { check(error as? ProviderError == .authentication(.gemini), "validate bad key → authentication") }
        var fwValidator = FireworksTranscriptionProvider(apiKey: key); fwValidator.transport = MockTransport(.success(result(401, fireworksUnauthorized)))
        do { try await fwValidator.validate(); check(false, "Fireworks validate should throw") }
        catch { check(error as? ProviderError == .authentication(.fireworks), "Fireworks validate 401") }
    }

    /// Minimal multipart parser for checks: name → content bytes.
    static func splitMultipart(_ body: Data, boundary: String) -> [String: Data] {
        let delimiter = Data("--\(boundary)".utf8)
        var parts: [String: Data] = [:]
        var ranges: [Range<Data.Index>] = []
        var search = body.startIndex
        while let r = body.range(of: delimiter, in: search..<body.endIndex) { ranges.append(r); search = r.upperBound }
        for (i, r) in ranges.enumerated() where i + 1 < ranges.count {
            var chunk = body.subdata(in: r.upperBound..<ranges[i + 1].lowerBound)
            guard chunk.starts(with: Data("\r\n".utf8)) else { continue }
            chunk = chunk.dropFirst(2)
            guard let headerEnd = chunk.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let header = String(decoding: chunk[chunk.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            var content = Data(chunk[headerEnd.upperBound..<chunk.endIndex])
            if content.suffix(2) == Data("\r\n".utf8) { content.removeLast(2) }
            guard let nameRange = header.range(of: "name=\"") else { continue }
            let rest = header[nameRange.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            parts[String(rest[..<end])] = content
        }
        return parts
    }
}
