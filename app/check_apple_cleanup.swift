import Foundation

// Deterministic checks for AppleCleanup.swift: availability gating, the route wiring, and the
// local-rules fallback through ProcessingCoordinator. A fake status and model replace
// FoundationModels, so this runs without Apple Intelligence (and on Linux).
//
//   swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift \
//     app/Credentials.swift app/Processing.swift app/Routes.swift app/AppleCleanup.swift spike/Observation.swift \
//     app/check_apple_cleanup.swift -o /tmp/murmur-apple-check && /tmp/murmur-apple-check

private var failures = 0
private var passes = 0
private func check(_ condition: Bool, _ label: String, line: Int = #line) {
    if condition { passes += 1 } else { failures += 1; print("FAIL [line \(line)]: \(label)") }
}

/// Counts model calls and the words of each prompt's transcript.
private final class FakeModel: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [Int] = []
    let reply: @Sendable (String) throws -> String
    init(_ reply: @escaping @Sendable (String) throws -> String) { self.reply = reply }
    var calls: [Int] { lock.withLock { _calls } }
    func generate(_ m: CleanupMessages) throws -> String {
        let text = m.user.split(separator: "\n").dropFirst().dropLast().joined(separator: "\n")
        lock.withLock { _calls.append(text.split(whereSeparator: \.isWhitespace).count) }
        return try reply(text)
    }
}

private func provider(_ status: OnDeviceModelUnavailable?, _ model: FakeModel) -> AppleCleanupProvider {
    var p = AppleCleanupProvider()
    p.status = { status }
    p.generate = { try model.generate($0) }
    return p
}

@main struct AppleCleanupChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-apple-\(UUID())")
        let suite = "murmur-apple-check-\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { print("FAIL: no defaults suite"); exit(1) }
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }

        // Route wiring: a local route with no key, no refusal and no disclosure.
        var routes = RouteSettings(); routes.cleanup = .appleIntelligence
        var keyReads = 0
        let plan = RoutePlan.make(routes, cleanupSendsText: true) { _ in keyReads += 1; return nil }
        check(plan.cleaner is AppleCleanupProvider, "route builds the Apple provider")
        check(plan.refusal == nil, "no key needed, never refuses: \(plan.refusal ?? "")")
        check(plan.stages.isEmpty && keyReads == 0, "no disclosure stage, no Keychain read")
        check(CleanupChoice.appleIntelligence.processingRoute == .cloud, "runs through the provider path")
        check(CleanupChoice(rawValue: "apple-intelligence") == .appleIntelligence, "persisted value round-trips")
        check(RouteSettings().cleanup == .localRules, "default route is unchanged")

        let messages = Set([OnDeviceModelUnavailable.deviceNotEligible, .appleIntelligenceOff, .modelNotReady].map(\.userMessage))
        check(messages.count == 3 && messages.allSatisfy { $0.contains("Apple Intelligence") }, "three distinct availability messages")

        let p = try ProcessingCoordinator(directory: root, defaults: defaults)
        var settings = p.settings; settings.route = .cloud; settings.options = .standard
        try p.update(settings, persist: false)
        let raw = "um so we should ship it on friday"
        let local = p.process(raw)

        // Unavailable: never calls the model, falls back to local rules, names the reason.
        for reason in [OnDeviceModelUnavailable.deviceNotEligible, .appleIntelligenceOff, .modelNotReady] {
            let model = FakeModel { $0 }
            p.cloudCleaner = provider(reason, model)
            let out = await p.processAsync(raw)
            check(model.calls.isEmpty, "\(reason): model not called")
            check(out == local, "\(reason): local rules output: \(out)")
            check(p.lastProviderError == .modelUnavailable(.appleIntelligence, reason), "\(reason): error recorded")
            check(p.lastProviderError?.userMessage == reason.userMessage, "\(reason): message shown")
            check(p.lastFallback == .cleanerFailed, "\(reason): fallback logged")
        }

        // A generation error falls back the same way.
        p.cloudCleaner = provider(nil, FakeModel { _ in throw ProviderError.contentBlocked(.appleIntelligence) })
        check(await p.processAsync(raw) == local && p.lastProviderError == .contentBlocked(.appleIntelligence), "generation error: local rules")

        // Available: the model's output passes the guard and is inserted.
        p.cloudCleaner = provider(nil, FakeModel { _ in "So we should ship it on Friday." })
        check(await p.processAsync(raw) == .insert("So we should ship it on Friday.") && p.lastFallback == nil, "good output inserted")

        // An answer instead of cleanup is rejected by the guard and never inserted.
        p.cloudCleaner = provider(nil, FakeModel { _ in "Sure! Friday works. Here is a plan for the launch." })
        if case .insert(let text) = await p.processAsync(raw) {
            check(!text.contains("Sure") && !text.contains("plan") && p.lastFallback != nil, "guard rejects an answer: \(text)")
            check(p.lastProviderError == nil, "a rejection is not a provider error")
        } else { check(false, "always inserts") }

        // Long text is cleaned in sections that fit the context window.
        let sentence = "we reviewed the plan and agreed on the next steps for the team."
        let long = Array(repeating: sentence, count: 60).joined(separator: " ")
        let echo = FakeModel { $0 }
        p.cloudCleaner = provider(nil, echo)
        _ = await p.processAsync(long)
        check(echo.calls.count > 1 && echo.calls.allSatisfy { $0 <= 600 }, "long text split into sections: \(echo.calls)")
        let short = FakeModel { $0 }
        p.cloudCleaner = provider(nil, short)
        _ = await p.processAsync(raw)
        check(short.calls.count == 1, "short text is one request")

        // The AsyncCleaner entry point builds the shared prompt.
        let direct = FakeModel { $0 }
        _ = try await provider(nil, direct).clean(raw, options: .standard)
        check(direct.calls == [raw.split(separator: " ").count], "clean() sends the transcript in the shared prompt")

        print("\(passes) checks passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
