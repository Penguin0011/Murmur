import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Deterministic update-checker checks: no network. Release fixtures follow the GitHub REST
// "List releases" schema (https://docs.github.com/en/rest/releases/releases).

private var failures = 0
private var passes = 0
private func check(_ condition: @autoclosure () -> Bool, _ label: String, line: UInt = #line) {
    if condition() { passes += 1 } else { failures += 1; print("FAIL [\(line)]: \(label)") }
}

final class FakeClient: UpdateHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var next: Result<UpdateHTTPResponse, Error>
    init(_ next: Result<UpdateHTTPResponse, Error>) { self.next = next }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    private func record(_ request: URLRequest) { lock.lock(); _requests.append(request); lock.unlock() }
    func get(_ request: URLRequest) async throws -> UpdateHTTPResponse { record(request); return try next.get() }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var date: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
}

func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, url: String? = nil, notes: String = "Notes") -> [String: Any] {
    ["url": "https://api.github.com/repos/Penguin0011/Murmur/releases/1",
     "html_url": url ?? "https://github.com/Penguin0011/Murmur/releases/tag/\(tag)",
     "id": 1, "tag_name": tag, "target_commitish": "main", "name": "Murmur \(tag)", "draft": draft, "prerelease": prerelease,
     "created_at": "2026-10-01T10:00:00Z", "published_at": "2026-10-01T10:05:00Z", "body": notes, "assets": []]
}
func releasesData(_ items: [[String: Any]]) -> Data { try! JSONSerialization.data(withJSONObject: items) }
func ok(_ items: [[String: Any]]) -> UpdateHTTPResponse { UpdateHTTPResponse(status: 200, headers: [:], body: releasesData(items)) }

@main struct UpdateChecks {
    static func main() async {
        checkVersions()
        checkConfigurationAndURLs()
        checkSelection()
        checkInterpretation()
        await checkThrottleAndStates()
        print(failures == 0
              ? "Update checks passed (\(passes) assertions: semver, prerelease/draft filtering, URL validation, throttle, rate limits, offline, 404, request headers)."
              : "Update checks FAILED: \(failures) of \(passes + failures) assertions.")
        exit(failures == 0 ? 0 : 1)
    }

    static func v(_ s: String) -> SemanticVersion { SemanticVersion(s)! }

    static func checkVersions() {
        check(v("v1.2.3") == v("1.2.3") && v("V1.2.3") == v("1.2.3"), "v prefix ignored")
        check(v("1.2") == v("1.2.0") && v("2") == v("2.0.0"), "missing components are zero")
        check(v("1.2.3+build.5") == v("1.2.3"), "build metadata ignored")
        check(v("1.10.0") > v("1.9.9"), "numeric, not lexical, comparison")
        check(v("2.0.0") > v("1.99.99"), "major dominates")
        check(v("1.0.0-alpha") < v("1.0.0"), "prerelease below release")
        // SemVer spec ordering example.
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"].map(v)
        check(zip(ordered, ordered.dropFirst()).allSatisfy { $0 < $1 }, "SemVer spec precedence chain")
        check(v("1.0.0-2") < v("1.0.0-10"), "numeric prerelease identifiers compare numerically")
        check(v("1.0.0-1") < v("1.0.0-a"), "numeric identifier before alphanumeric")
        check(!(v("1.0.0") < v("1.0.0")), "equal is not less")
        for bad in ["", "v", "1.2.3.4", "01.2.3", "1.02.3", "1..3", "1.2.x", "1.2.3-", "1.2.3-01", "1.2.3+", "1.2.3-a..b", "latest", "1.2.3 beta", "-1.2.3", "１.２.３"] {
            check(SemanticVersion(bad) == nil, "rejects \"\(bad)\"")
        }
        check(v("1.2.3-rc.1").description == "1.2.3-rc.1" && v("v0.1").description == "0.1.0", "description")
    }

    static func checkConfigurationAndURLs() {
        let config = try! UpdateConfiguration(currentVersion: "1.0.0")
        check(config.owner == "Penguin0011" && config.repository == "Murmur", "default repository")
        check(config.releasesURL.absoluteString == "https://api.github.com/repos/Penguin0011/Murmur/releases?per_page=30", "releases API URL")
        check((try? UpdateConfiguration(currentVersion: "1.0.0", owner: "evil/../x")) == nil, "owner with slash rejected")
        check((try? UpdateConfiguration(currentVersion: "1.0.0", repository: "..")) == nil, "dot-dot repository rejected")
        check((try? UpdateConfiguration(currentVersion: "not-a-version")) == nil, "invalid current version rejected")
        check((try? UpdateConfiguration(currentVersion: "1.0.0", owner: "someone", repository: "murmur"))?.releasesURL.path == "/repos/someone/murmur/releases", "configurable repository")

        let good = ["https://github.com/Penguin0011/Murmur/releases/tag/v1.2.0", "https://github.com/penguin0011/Murmur/releases/tag/v1.2.0"]
        for s in good { check(config.isValidReleasePage(URL(string: s)!), "accepts \(s)") }
        let bad = [
            "http://github.com/Penguin0011/Murmur/releases/tag/v1.2.0",
            "https://github.com.evil.example/Penguin0011/Murmur/releases/tag/v1",
            "https://github.com@evil.example/Penguin0011/Murmur/releases/tag/v1",
            "https://user:pass@github.com/Penguin0011/Murmur/releases/tag/v1",
            "https://github.com:8443/Penguin0011/Murmur/releases/tag/v1",
            "https://github.com/Other/dictation/releases/tag/v1",
            "https://github.com/Penguin0011/Murmur-fork/releases/tag/v1",
            "https://github.com/Penguin0011/Murmur/releases/",
            "https://github.com/Penguin0011/Murmur/issues/1",
            "https://github.com/Penguin0011/Murmur/releases/../../Other/x/releases/tag/v1",
            "https://github.com/Penguin0011/Murmur/releases/%2e%2e/%2e%2e/Other",
            "https://github.com/Penguin0011/Murmur/releases/tag/v1?redirect=https://evil.example",
            "https://objects.githubusercontent.com/Penguin0011/Murmur/releases/tag/v1",
            "javascript:alert(1)",
        ]
        for s in bad { check(URL(string: s).map { !config.isValidReleasePage($0) } ?? true, "rejects \(s)") }
    }

    static func checkSelection() {
        let config = try! UpdateConfiguration(currentVersion: "v1.2.0")
        func eval(_ items: [[String: Any]], _ c: UpdateConfiguration = config) -> UpdateCheckResult {
            UpdateChecker.evaluate(releasesJSON: releasesData(items), configuration: c)
        }
        if case .updateAvailable(let info) = eval([release("v1.2.0"), release("v1.3.0", notes: "Fixes insertion."), release("v1.2.5")]) {
            check(info.version == v("1.3.0") && info.tag == "v1.3.0" && info.notes == "Fixes insertion.", "picks highest stable with notes")
            check(info.pageURL.absoluteString == "https://github.com/Penguin0011/Murmur/releases/tag/v1.3.0" && info.title == "Murmur v1.3.0", "carries URL and title")
            check(info.publishedAt == ISO8601DateFormatter().date(from: "2026-10-01T10:05:00Z"), "published date parsed")
        } else { check(false, "update expected") }
        check(eval([release("v2.0.0", draft: true), release("v1.2.0")]) == .upToDate(latest: v("1.2.0")), "drafts ignored")
        check(eval([release("v2.0.0-beta.1", prerelease: true), release("v1.1.0")]) == .upToDate(latest: v("1.1.0")), "flagged prereleases ignored by default")
        check(eval([release("v2.0.0-rc.1"), release("v1.2.0")]) == .upToDate(latest: v("1.2.0")), "SemVer prerelease tag ignored even if not flagged")
        check(eval([release("v1.3.0", prerelease: true)]) == .noReleases, "only prereleases → noReleases")
        var withPre = config; withPre.includePrereleases = true
        if case .updateAvailable(let info) = eval([release("v2.0.0-rc.1", prerelease: true), release("v1.3.0")], withPre) {
            check(info.version == v("2.0.0-rc.1"), "prereleases included when opted in")
        } else { check(false, "prerelease update expected when opted in") }
        check(eval([release("nightly"), release("v1.1.9")]) == .upToDate(latest: v("1.1.9")), "unparseable tags skipped")
        check(eval([]) == .noReleases, "empty list → noReleases")
        check(eval([release("v9.0.0", url: "https://evil.example/Penguin0011/Murmur/releases/tag/v9.0.0")]) == .failed(.invalidReleaseURL), "newer release with foreign URL refused")
        if case .updateAvailable(let info) = eval([release("v9.0.0", url: "https://evil.example/x"), release("v1.4.0")]) {
            check(info.version == v("1.4.0"), "invalid-link release skipped in favour of valid newer one")
        } else { check(false, "valid release expected") }
        check(UpdateChecker.evaluate(releasesJSON: Data("{\"message\":\"x\"}".utf8), configuration: config) == .failed(.malformedResponse), "non-array → malformed")
        let prereleaseCurrent = try! UpdateConfiguration(currentVersion: "1.3.0-beta.2")
        if case .updateAvailable(let info) = eval([release("v1.3.0")], prereleaseCurrent) { check(info.version == v("1.3.0"), "stable supersedes running prerelease") }
        else { check(false, "stable update over prerelease expected") }
    }

    static func checkInterpretation() {
        let config = try! UpdateConfiguration(currentVersion: "1.0.0")
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        func r(_ status: Int, _ headers: [String: String] = [:]) -> UpdateCheckResult {
            UpdateChecker.interpret(UpdateHTTPResponse(status: status, headers: headers, body: Data("{\"message\":\"API rate limit exceeded\"}".utf8)), configuration: config, now: now)
        }
        check(r(404) == .repositoryNotFound, "404 non-fatal")
        check(r(403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1791003600"]) == .rateLimited(until: Date(timeIntervalSince1970: 1_791_003_600)), "403 primary limit uses x-ratelimit-reset")
        check(r(429, ["Retry-After": "120"]) == .rateLimited(until: now.addingTimeInterval(120)), "429 secondary limit uses Retry-After")
        check(r(403, ["retry-after": "30", "x-ratelimit-remaining": "0", "x-ratelimit-reset": "1791003600"]) == .rateLimited(until: now.addingTimeInterval(30)), "Retry-After wins, headers case-insensitive")
        check(r(429) == .rateLimited(until: nil), "429 without headers still rate limited")
        check(r(403, ["x-ratelimit-remaining": "12"]) == .failed(.httpStatus(403)), "plain 403 is a failure, not rate limit")
        check(r(500) == .failed(.httpStatus(500)), "500 non-fatal failure")

        let request = UpdateChecker.makeRequest(config)
        check(request.httpMethod == "GET" && request.httpBody == nil, "GET without body")
        let headers = request.allHTTPHeaderFields ?? [:]
        check(Set(headers.keys.map { $0.lowercased() }) == ["user-agent", "accept"], "only User-Agent and Accept headers")
        check(headers["Accept"] == "application/vnd.github+json" && headers["User-Agent"] == "Murmur/1.0.0 (update-check)", "header values")
        check(request.url?.query == "per_page=30", "no identifying query parameters")
    }

    static func checkThrottleAndStates() async {
        let config = try! UpdateConfiguration(currentVersion: "1.0.0")
        let clock = TestClock(Date(timeIntervalSince1970: 1_791_000_000))
        let store = InMemoryUpdateCheckStore()
        let client = FakeClient(.success(ok([release("v1.1.0")])))
        let checker = UpdateChecker(configuration: config, client: client, store: store, now: { clock.date })
        var r: UpdateCheckResult

        if case .updateAvailable = await checker.check(manual: false) { check(true, "first automatic check runs") } else { check(false, "first automatic check runs") }
        check(client.requests.count == 1, "one request")
        clock.advance(3600)
        let throttled = await checker.check(manual: false)
        check(throttled == .throttled(nextCheck: Date(timeIntervalSince1970: 1_791_000_000 + 86_400)), "second automatic check within a day throttled")
        check(client.requests.count == 1, "throttled check sends nothing")
        if case .updateAvailable = await checker.check(manual: true) { check(true, "manual bypasses throttle") } else { check(false, "manual bypasses throttle") }
        check(client.requests.count == 2, "manual sends a request")
        clock.advance(86_400)
        _ = await checker.check(manual: false)
        check(client.requests.count == 3, "automatic check allowed after a day")

        // Offline does not consume the daily check.
        clock.advance(86_400)
        client.next = .failure(URLError(.notConnectedToInternet))
        let before = store.load().lastCheck
        r = await checker.check(manual: false); check(r == .offline, "offline is a non-fatal state")
        check(store.load().lastCheck == before, "offline does not record a check")

        // Rate limit is remembered; even manual checks wait until reset.
        clock.advance(60)
        let reset = clock.date.addingTimeInterval(1800)
        client.next = .success(UpdateHTTPResponse(status: 403, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": String(Int(reset.timeIntervalSince1970))], body: Data()))
        r = await checker.check(manual: true); check(r == .rateLimited(until: reset), "rate limited state")
        let count = client.requests.count
        clock.advance(60)
        r = await checker.check(manual: true); check(r == .rateLimited(until: reset), "manual check honours known reset")
        check(client.requests.count == count, "no request during rate-limit window")
        clock.advance(1800)
        client.next = .success(ok([release("v1.0.0")]))
        r = await checker.check(manual: true); check(r == .upToDate(latest: v("1.0.0")), "after reset, check resumes; up to date")
        check(store.load().rateLimitedUntil == nil, "rate-limit window cleared")

        // 404 and empty list are non-fatal.
        client.next = .success(UpdateHTTPResponse(status: 404, headers: [:], body: Data("{\"message\":\"Not Found\"}".utf8)))
        r = await checker.check(manual: true); check(r == .repositoryNotFound, "404 state")
        client.next = .success(ok([]))
        r = await checker.check(manual: true); check(r == .noReleases, "no releases state")

        // Clock moved backwards does not lock out automatic checks forever.
        let skewStore = InMemoryUpdateCheckStore(UpdateCheckState(lastCheck: clock.date.addingTimeInterval(10 * 86_400), rateLimitedUntil: nil))
        let skewed = UpdateChecker(configuration: config, client: client, store: skewStore, now: { clock.date })
        r = await skewed.check(manual: false); check(r == .noReleases, "future lastCheck (clock skew) does not block")

        // Persisted state round-trips through UserDefaults.
        if let defaults = UserDefaults(suiteName: "murmur-update-check-\(UUID().uuidString)") {
            let persisted = UserDefaultsUpdateCheckStore(defaults: defaults)
            let state = UpdateCheckState(lastCheck: Date(timeIntervalSince1970: 1_791_000_000), rateLimitedUntil: nil)
            persisted.save(state)
            check(persisted.load() == state, "UserDefaults store round-trip")
        }
    }
}
