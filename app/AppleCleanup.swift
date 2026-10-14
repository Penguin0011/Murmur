import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Apple Intelligence cleanup (BETTERWISPR_GAPS.md #1): Apple's on-device system model through
// FoundationModels. Nothing to download, no key, and nothing leaves this Mac, so the route has no
// disclosure. Prompts come from `CleanupPrompt.build` unchanged. ProcessingCoordinator guards the
// output and falls back to local rules on any error, as for every provider route (PRD section 4).
// The context is about 4,096 tokens, so ProcessingCoordinator cleans text over 600 words in
// sections of about 400: the Professional prompt (about 1,100 tokens), a section and its cleaned
// copy fit. Without FoundationModels (Linux checks) the model reports itself unavailable.

struct AppleCleanupProvider: CleanupProvider, AsyncCleaner {
    let id = ProviderID.appleIntelligence
    /// Nil when the model can run. Checks inject a fixed status.
    var status: @Sendable () -> OnDeviceModelUnavailable? = AppleSystemModel.status
    /// One generation, no retry. Checks inject a fake model.
    var generate: @Sendable (CleanupMessages) async throws -> String = AppleSystemModel.respond
    var disclosure: DataDisclosure {
        DataDisclosure(provider: id, stage: .cleanup, destinationHost: "Apple's on-device model", leavesDevice: [],
                       staysOnDevice: ["the transcript"], retentionNote: "")
    }

    func cleanup(_ messages: CleanupMessages) async throws -> String {
        if let reason = status() { throw ProviderError.modelUnavailable(id, reason) }
        return try await generate(messages)
    }

    func validate() async throws {
        if let reason = status() { throw ProviderError.modelUnavailable(id, reason) }
    }

    func clean(_ raw: String, options: CleanupOptions) async throws -> String {
        try await cleanup(CleanupPrompt.build(transcript: raw, options: options))
    }

    /// Loads the model ahead of the first request (route selected, recording started).
    func prewarm() { if status() == nil { AppleSystemModel.prewarm() } }
}

enum AppleSystemModel {
#if canImport(FoundationModels)
    private static let lock = NSLock()
    /// Kept alive so the prewarm is not cancelled with its session.
    nonisolated(unsafe) private static var warm: LanguageModelSession?

    @Sendable static func status() -> OnDeviceModelUnavailable? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable: return .modelNotReady
        }
    }

    static func prewarm() {
        let session = LanguageModelSession()
        session.prewarm()
        lock.withLock { warm = session }
    }

    /// A fresh session per call: a session keeps its transcript, which would fill the context.
    @Sendable static func respond(_ messages: CleanupMessages) async throws -> String {
        let session = LanguageModelSession(instructions: messages.system)
        do {
            return try await session.respond(to: messages.user, options: GenerationOptions(sampling: .greedy)).content
        } catch let error as LanguageModelSession.GenerationError {
            throw providerError(error)
        } catch is CancellationError {
            throw ProviderError.cancelled
        }
    }

    static func providerError(_ error: LanguageModelSession.GenerationError) -> ProviderError {
        let id = ProviderID.appleIntelligence
        switch error {
        case .exceededContextWindowSize: return .payloadTooLarge(id, limitBytes: nil)
        case .assetsUnavailable: return .modelUnavailable(id, .modelNotReady)
        case .guardrailViolation, .refusal: return .contentBlocked(id)
        case .rateLimited, .concurrentRequests: return .rateLimited(id, retryAfter: nil)
        default: return .malformedResponse(id)
        }
    }
#else
    @Sendable static func status() -> OnDeviceModelUnavailable? { .deviceNotEligible }
    static func prewarm() {}
    @Sendable static func respond(_ messages: CleanupMessages) async throws -> String {
        throw ProviderError.modelUnavailable(.appleIntelligence, .deviceNotEligible)
    }
#endif
}
