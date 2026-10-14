// Runs app/cleanup-corpus.json through a cleanup route with the real ProcessingCoordinator path
// (prompt, guard, local-rules fallback) for Strict, Polish and Professional, and prints the PRD
// section 4 measures plus model latency. `apple` uses Apple's on-device model; `gemini` reads
// Murmur's Gemini key from the Keychain (never printed) and costs API calls. Corpus text is
// synthetic, so per-utterance misses may be printed with --verbose.
//
//   SDKROOT="$(dirname "$(xcrun --show-sdk-path)")/MacOSX26.sdk" swiftc -swift-version 5 -parse-as-library -suppress-warnings \
//     app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift \
//     app/Processing.swift app/Routes.swift app/AppleCleanup.swift spike/Observation.swift app/tools/measure_cleanup_route.swift \
//     -o /tmp/mcr && /tmp/mcr apple [strict,polish,professional] [--verbose]
import Foundation

struct Entry: Decodable { var id: String; var input: String; var options: CleanupOptions; var expected: String; var tags: [String] }

/// Times each model call and keeps its raw output.
final class Timed: CleanupProvider, @unchecked Sendable {
    let inner: CleanupProvider
    private let lock = NSLock()
    private var _seconds: [Double] = []
    var id: ProviderID { inner.id }
    var disclosure: DataDisclosure { inner.disclosure }
    init(_ inner: CleanupProvider) { self.inner = inner }
    var seconds: [Double] { lock.withLock { _seconds } }
    func cleanup(_ messages: CleanupMessages) async throws -> String {
        let start = Date()
        defer { let t = Date().timeIntervalSince(start); lock.withLock { _seconds.append(t) } }
        return try await inner.cleanup(messages)
    }
    func validate() async throws { try await inner.validate() }
}

struct Protected: Equatable { var names: [String: Int] = [:], numbers: [String: Int] = [:], negations: [String: Int] = [:] }
func protected(_ s: String) -> Protected {
    var p = Protected()
    for w in CleanupGuard.words(s) {
        if w.isName { p.names[w.lower, default: 0] += 1 }
        if let v = CleanupText.numberValue(w.lower) { p.numbers[v, default: 0] += 1 }
        if CleanupText.isNegation(w.lower) { p.negations[w.lower, default: 0] += 1 }
    }
    return p
}
func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "n/a" : String(format: "%.1f%% (%d/%d)", 100.0 * Double(n) / Double(d), n, d) }
func quantile(_ xs: [Double], _ q: Double) -> Double { let s = xs.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * q))] }

@main enum MeasureCleanupRoute {
    static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        var args = Array(CommandLine.arguments.dropFirst())
        let verbose = args.contains("--verbose"); args.removeAll { $0 == "--verbose" }
        let route = args.first ?? "apple"
        let styles = (args.dropFirst().first ?? "strict,polish,professional").split(separator: ",").map(String.init)
        let corpus = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: URL(fileURLWithPath: "app/cleanup-corpus.json")))
        let inner: CleanupProvider
        switch route {
        case "apple":
            let apple = AppleCleanupProvider()
            if let reason = apple.status() { print("Apple Intelligence unavailable: \(reason.userMessage)"); exit(2) }
            inner = apple
        case "gemini":
            guard let key = try KeychainCredentialStore().read(.gemini) else { print("No Gemini key in Murmur's Keychain"); exit(2) }
            inner = GeminiCleanupProvider(apiKey: key)
        default: print("route must be apple or gemini"); exit(2)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-measure-\(UUID())")
        let suite = "murmur-measure-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let p = try ProcessingCoordinator(directory: root, defaults: defaults)

        for style in styles {
            let timed = Timed(inner)
            p.cloudCleaner = timed
            var used = 0, rejected = 0, errors = 0, insertedExact = 0, modelPassExact = 0
            var protectedEdits = 0, corrN = 0, corrExact = 0, ambN = 0, ambKept = 0
            var listMade = 0, listMadeOK = 0, listWanted = 0, listWantedMade = 0
            var reasons: [String: Int] = [:], errorKinds: [String: Int] = [:]
            if route == "apple" { (inner as? AppleCleanupProvider)?.prewarm() }
            for e in corpus {
                var o = e.options
                o.polish = style != "strict"; o.professional = style == "professional"
                var s = p.settings; s.route = .cloud; s.options = o
                try p.update(s, persist: false)
                guard case .insert(let out) = await p.processAsync(e.input) else { continue }
                if let error = p.lastProviderError { errors += 1; errorKinds[Mirror(reflecting: error).children.first?.label ?? "\(error)", default: 0] += 1 }
                else if let why = p.lastFallback { rejected += 1; reasons[why.rawValue, default: 0] += 1 }
                else if o.anyEnabled { used += 1 }
                let exact = out == e.expected
                if exact { insertedExact += 1 }
                if exact && p.lastFallback == nil { modelPassExact += 1 }
                let pe = protected(e.expected), po = protected(out), pr = protected(e.input)
                if pe != po && pr != po { protectedEdits += 1; if verbose { print("protected edit \(e.id): \(out.debugDescription)") } }
                if e.tags.contains("corrections") { corrN += 1; if exact { corrExact += 1 } }
                if e.tags.contains("ambiguous-correction") { ambN += 1; if exact { ambKept += 1 } }
                let made = out.contains("\n1. "), wanted = e.expected.contains("\n1. ")
                if made { listMade += 1; if wanted { listMadeOK += 1 } }
                if wanted { listWanted += 1; if made { listWantedMade += 1 } }
                if verbose && !exact { print("miss \(e.id) [\(p.lastFallback?.rawValue ?? "model")]\n  exp: \(e.expected.debugDescription)\n  got: \(out.debugDescription)") }
            }
            let t = timed.seconds, n = corpus.count, called = n - corpus.filter { !$0.options.anyEnabled }.count
            print("== \(route) \(style): \(n) utterances, \(t.count) model calls")
            print("  model output used (passed guard): \(pct(used, called)); guard rejected -> local rules: \(pct(rejected, called)) \(reasons.sorted { $0.key < $1.key }); errors -> local rules: \(pct(errors, called)) \(errorKinds)")
            print("  inserted == label: \(pct(insertedExact, n)); model output used and == label: \(pct(modelPassExact, n))")
            print("  unintended name/number/negation edits in inserted text: \(pct(protectedEdits, n)) (bar <= 1%)")
            print("  spoken-correction exact: \(pct(corrExact, corrN)) (>= 95%); ambiguous kept: \(pct(ambKept, ambN)) (100%)")
            print("  list precision: \(pct(listMadeOK, listMade)) (>= 97%); recall: \(pct(listWantedMade, listWanted)) (>= 95%)")
            print(String(format: "  latency s: first %.2f, p50 %.2f, p90 %.2f, max %.2f, mean %.2f", t.first ?? 0, quantile(t, 0.5), quantile(t, 0.9), t.max() ?? 0, t.reduce(0, +) / Double(max(1, t.count))))
        }
    }
}
