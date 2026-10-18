import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Apple's on-device system model through
// FoundationModels. Nothing to download, no key, and nothing leaves this Mac, so the route has no
// disclosure. Prompts come from `CleanupPrompt.build` unchanged. ProcessingCoordinator guards the
// output and falls back to local rules on any error, as for every provider route (PRD section 4).
// The context is about 4,096 tokens, so ProcessingCoordinator cleans text of 600 words or more in
// sections of about 400. The Professional prompt is about 3,300 characters. Measured October 14,
// 2026: a single 900-word unpunctuated request did not exceed the context, but long text is slow
// (about 3 s per 100 words), and a context error would only fall back to local rules. Without FoundationModels (Linux checks) the model reports itself unavailable.

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

    /// Meeting notes (W7b) with guided generation: the on-device model breaks free-form formats, so a
    /// schema fixes the shape. The result is rendered in the notes reply format (MeetingNotes.swift),
    /// so grounding is the same on every route. A fresh session per call, like cleanup.
    /// Notes for one chunk are short. Without a cap, a few replies ran on for over 3 minutes
    /// (measured October 15, 2026). With a 5,000-character request (about 1,700 tokens) and the
    /// instructions, 1,200 still fits the 4,096-token context.
    static let maximumNotesTokens = 1_200

    @Sendable static func notes(system: String, user: String) async throws -> String {
        let int = DynamicGenerationSchema(type: Int.self), text = DynamicGenerationSchema(type: String.self)
        let cites = DynamicGenerationSchema.Property(name: "lines", description: "The L numbers of the lines it rests on", schema: DynamicGenerationSchema(arrayOf: int))
        let item = DynamicGenerationSchema(name: "Item", properties: [cites, .init(name: "text", schema: text)])
        let action = DynamicGenerationSchema(name: "Action", properties: [
            cites,
            .init(name: "owner", description: "Who took it on, as named in the lines, or Me, or the other side’s speaker label as written in the lines (Them, Speaker 2 or a name)", schema: text, isOptional: true),
            .init(name: "due", description: "When it is due, only if said", schema: text, isOptional: true),
            .init(name: "text", description: "The task", schema: text),
        ])
        let root = DynamicGenerationSchema(name: "Notes", properties: [
            .init(name: "title", description: "At most 8 words, in sentence case: only the first word and names capitalized", schema: text),
            .init(name: "summary", description: "2 to 4 sentences", schema: text),
            // Generated in this order: decisions and action items before key points, so a reply that
            // reaches the token cap loses points, not commitments.
            .init(name: "decisions", description: "Choices the group agreed on", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(referenceTo: "Item"), maximumElements: 10)),
            .init(name: "actions", description: "Tasks someone committed to or accepted", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(referenceTo: "Action"), maximumElements: 12)),
            .init(name: "points", description: "Key points, each a short phrase", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(referenceTo: "Item"), maximumElements: 8)),
        ])
        let session = LanguageModelSession(instructions: system)
        let content: GeneratedContent
        do {
            content = try await session.respond(to: user, schema: try GenerationSchema(root: root, dependencies: [item, action]),
                                           options: GenerationOptions(sampling: .greedy, maximumResponseTokens: maximumNotesTokens)).content
        } catch let error as LanguageModelSession.GenerationError {
            throw providerError(error)
        } catch is CancellationError {
            throw ProviderError.cancelled
        } catch {
            throw ProviderError.malformedResponse(.appleIntelligence)
        }
        func one(_ value: String?) -> String { (value ?? "").replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
        func lines(_ entry: GeneratedContent) -> String { ((try? entry.value([Int].self, forProperty: "lines")) ?? []).map { "L\($0)" }.joined(separator: " ") }
        func entries(_ key: String) -> [GeneratedContent] { (try? content.value([GeneratedContent].self, forProperty: key)) ?? [] }
        var out: [String] = []
        if let title = try? content.value(String.self, forProperty: "title") { out.append("TITLE | " + one(title)) }
        if let summary = try? content.value(String.self, forProperty: "summary") { out.append("SUMMARY | " + one(summary)) }
        for (key, kind) in [("decisions", "DECISION"), ("points", "POINT")] {
            for entry in entries(key) { out.append("\(kind) | \(lines(entry)) | " + one(try? entry.value(String.self, forProperty: "text"))) }
        }
        for entry in entries("actions") {
            let owner = one((try? entry.value(String?.self, forProperty: "owner")) ?? nil), due = one((try? entry.value(String?.self, forProperty: "due")) ?? nil)
            out.append("ACTION | \(lines(entry)) | \(owner.isEmpty ? "-" : owner) | \(due.isEmpty ? "-" : due) | " + one(try? entry.value(String.self, forProperty: "text")))
        }
        return out.joined(separator: "\n")
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
    @Sendable static func notes(system: String, user: String) async throws -> String {
        throw ProviderError.modelUnavailable(.appleIntelligence, .deviceNotEligible)
    }
#endif
}
