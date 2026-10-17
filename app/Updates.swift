import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// GitHub Releases update checker (PRD R12, §8). It only reports. Opening the release page is left
// to the caller, and nothing is ever downloaded or installed. Requests carry only User-Agent and
// Accept headers: no transcripts, audio, dictionary, API keys or GitHub tokens.

// MARK: - Semantic versions

/// SemVer 2.0 precedence. Accepts a leading "v"/"V". Build metadata ("+...") is ignored for ordering.
/// One to three numeric core components are accepted; missing ones count as 0 ("1.2" == "1.2.0").
struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = prerelease
    }

    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") {
            let build = text[text.index(after: plus)...]
            guard !build.isEmpty, build.split(separator: ".", omittingEmptySubsequences: false).allSatisfy(Self.isIdentifier) else { return nil }
            text = String(text[..<plus])
        }
        var pre: [String] = []
        if let dash = text.firstIndex(of: "-") {
            let preText = text[text.index(after: dash)...]
            let identifiers = preText.split(separator: ".", omittingEmptySubsequences: false)
            guard !preText.isEmpty, identifiers.allSatisfy(Self.isIdentifier) else { return nil }
            for identifier in identifiers {
                if identifier.allSatisfy(\.isASCIIDigit), identifier.count > 1, identifier.first == "0" { return nil }
            }
            pre = identifiers.map(String.init)
            text = String(text[..<dash])
        }
        let core = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(core.count) else { return nil }
        var numbers: [Int] = []
        for component in core {
            guard !component.isEmpty, component.count <= 9, component.allSatisfy(\.isASCIIDigit) else { return nil }
            if component.count > 1 && component.first == "0" { return nil }
            numbers.append(Int(component)!)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: pre)
    }

    private static func isIdentifier(_ s: Substring) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // A version without prerelease identifiers has higher precedence.
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            let aNum = a.allSatisfy(\.isASCIIDigit) ? Int(a) : nil
            let bNum = b.allSatisfy(\.isASCIIDigit) ? Int(b) : nil
            switch (aNum, bNum) {
            case let (x?, y?): return x < y
            case (.some, nil): return true    // numeric identifiers sort before alphanumeric ones
            case (nil, .some): return false
            case (nil, nil): return a < b     // ASCII order
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

// MARK: - Configuration and results

struct UpdateConfiguration: Sendable {
    static let defaultOwner = "Penguin0011"
    static let defaultRepository = "Murmur"

    let owner: String
    let repository: String
    let currentVersion: SemanticVersion
    var includePrereleases = false
    var userAgent: String
    var minimumInterval: TimeInterval = 24 * 60 * 60
    var timeout: TimeInterval = 15

    enum Invalid: Error, Equatable { case repository, currentVersion }

    init(currentVersion: String, owner: String = UpdateConfiguration.defaultOwner, repository: String = UpdateConfiguration.defaultRepository, includePrereleases: Bool = false) throws {
        guard Self.isValidName(owner, maxLength: 39), Self.isValidName(repository, maxLength: 100) else { throw Invalid.repository }
        guard let version = SemanticVersion(currentVersion) else { throw Invalid.currentVersion }
        self.owner = owner; self.repository = repository; self.currentVersion = version
        self.includePrereleases = includePrereleases
        self.userAgent = "Murmur/\(version) (update-check)"
    }

    static func isValidName(_ name: String, maxLength: Int) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return !name.isEmpty && name.count <= maxLength && name != "." && name != ".."
            && name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    var releasesURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases?per_page=30")!
    }

    /// Only https://github.com/<owner>/<repo>/releases/... is accepted (owner/repo compared
    /// case-insensitively, as GitHub does). No credentials, port, query or fragment.
    func isValidReleasePage(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == "github.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        let prefix = "/\(owner)/\(repository)/releases/".lowercased()
        let path = url.path.lowercased()
        guard path.hasPrefix(prefix), path.count > prefix.count else { return false }
        let raw = url.absoluteString.lowercased()
        return !url.pathComponents.contains("..") && !raw.contains("%2e") && !raw.contains("%2f") && !raw.contains("%5c")
    }
}

struct ReleaseInfo: Equatable, Sendable {
    let version: SemanticVersion
    let tag: String
    let title: String?
    let notes: String
    let pageURL: URL
    let publishedAt: Date?
}

enum UpdateFailure: Equatable, Sendable {
    case malformedResponse
    /// A newer release exists, but its page link failed validation.
    case invalidReleaseURL
    case httpStatus(Int)
}

/// All states are non-fatal; none should interrupt dictation.
enum UpdateCheckResult: Equatable, Sendable {
    case updateAvailable(ReleaseInfo)
    case upToDate(latest: SemanticVersion?)
    case noReleases
    /// 404: the repository is missing, private or renamed.
    case repositoryNotFound
    /// An automatic check was skipped because one ran within the interval.
    case throttled(nextCheck: Date)
    case rateLimited(until: Date?)
    case offline
    case failed(UpdateFailure)
}

// MARK: - Storage and transport

struct UpdateCheckState: Codable, Equatable, Sendable {
    var lastCheck: Date?
    var rateLimitedUntil: Date?
}

protocol UpdateCheckStore: Sendable {
    func load() -> UpdateCheckState
    func save(_ state: UpdateCheckState)
}

final class InMemoryUpdateCheckStore: UpdateCheckStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: UpdateCheckState
    init(_ state: UpdateCheckState = UpdateCheckState()) { self.state = state }
    func load() -> UpdateCheckState { lock.lock(); defer { lock.unlock() }; return state }
    func save(_ state: UpdateCheckState) { lock.lock(); self.state = state; lock.unlock() }
}

final class UserDefaultsUpdateCheckStore: UpdateCheckStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    init(defaults: UserDefaults = .standard, key: String = "MurmurUpdateCheckState") { self.defaults = defaults; self.key = key }
    func load() -> UpdateCheckState {
        guard let data = defaults.data(forKey: key), let state = try? JSONDecoder().decode(UpdateCheckState.self, from: data) else { return UpdateCheckState() }
        return state
    }
    func save(_ state: UpdateCheckState) {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) }
    }
}

struct UpdateHTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
}

protocol UpdateHTTPClient: Sendable {
    func get(_ request: URLRequest) async throws -> UpdateHTTPResponse
}

/// Ephemeral session: no cookies, cache or stored credentials, so no GitHub token is ever attached.
final class URLSessionUpdateClient: UpdateHTTPClient, @unchecked Sendable {
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

    func get(_ request: URLRequest) async throws -> UpdateHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error = error { continuation.resume(throwing: error); return }
                guard let http = response as? HTTPURLResponse else { continuation.resume(throwing: URLError(.badServerResponse)); return }
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields { if let k = key as? String { headers[k] = "\(value)" } }
                continuation.resume(returning: UpdateHTTPResponse(status: http.statusCode, headers: headers, body: data ?? Data()))
            }.resume()
        }
    }
}

// MARK: - Checker

final class UpdateChecker: @unchecked Sendable {
    private static let maximumRateLimitDelay: TimeInterval = 24 * 60 * 60
    let configuration: UpdateConfiguration
    private let client: UpdateHTTPClient
    private let store: UpdateCheckStore
    private let now: @Sendable () -> Date

    init(configuration: UpdateConfiguration, client: UpdateHTTPClient = URLSessionUpdateClient(),
         store: UpdateCheckStore = UserDefaultsUpdateCheckStore(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration; self.client = client; self.store = store; self.now = now
    }

    /// The only request this checker sends: GET with User-Agent and Accept, nothing else.
    static func makeRequest(_ configuration: UpdateConfiguration) -> URLRequest {
        var request = URLRequest(url: configuration.releasesURL)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = configuration.timeout
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return request
    }

    /// `manual == true` bypasses the daily throttle (the "Check for Updates" action), but still
    /// honours a known rate-limit window so GitHub is not hammered.
    func check(manual: Bool) async -> UpdateCheckResult {
        let current = now()
        var state = store.load()
        if let until = state.rateLimitedUntil, until > current,
           until.timeIntervalSince(current) <= Self.maximumRateLimitDelay { return .rateLimited(until: until) }
        if !manual, let last = state.lastCheck, last <= current {
            let next = last.addingTimeInterval(configuration.minimumInterval)
            if current < next { return .throttled(nextCheck: next) }
        }
        let response: UpdateHTTPResponse
        do {
            response = try await client.get(Self.makeRequest(configuration))
        } catch {
            return .offline // Offline attempts do not consume the daily check.
        }
        let outcome = Self.interpret(response, configuration: configuration, now: current)
        state.lastCheck = current
        if case .rateLimited(let until) = outcome { state.rateLimitedUntil = until ?? current.addingTimeInterval(60 * 60) }
        else { state.rateLimitedUntil = nil }
        store.save(state)
        return outcome
    }

    /// Pure interpretation of a GitHub response.
    static func interpret(_ response: UpdateHTTPResponse, configuration: UpdateConfiguration, now: Date) -> UpdateCheckResult {
        switch response.status {
        case 200..<300:
            return evaluate(releasesJSON: response.body, configuration: configuration)
        case 404:
            return .repositoryNotFound
        case 403, 429:
            if let until = rateLimitReset(response, now: now) { return .rateLimited(until: until) }
            return response.status == 429 ? .rateLimited(until: nil) : .failed(.httpStatus(403))
        default:
            return .failed(.httpStatus(response.status))
        }
    }

    /// `Retry-After` (seconds) wins; otherwise `x-ratelimit-reset` (UTC epoch seconds) when
    /// `x-ratelimit-remaining` is 0.
    static func rateLimitReset(_ response: UpdateHTTPResponse, now: Date) -> Date? {
        // A malformed response must not disable update checks beyond the normal daily interval.
        if let retry = response.header("Retry-After").flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
           retry.isFinite, (0...maximumRateLimitDelay).contains(retry) {
            return now.addingTimeInterval(retry)
        }
        if response.header("x-ratelimit-remaining")?.trimmingCharacters(in: .whitespaces) == "0",
           let reset = response.header("x-ratelimit-reset").flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
           reset.isFinite, reset >= 0, reset - now.timeIntervalSince1970 <= maximumRateLimitDelay {
            return Date(timeIntervalSince1970: reset)
        }
        return nil
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String?
        let name: String?
        let body: String?
        let html_url: String?
        let draft: Bool?
        let prerelease: Bool?
        let published_at: String?
    }

    /// Pure selection: ignores drafts, ignores prereleases unless configured (by GitHub flag or by
    /// a SemVer prerelease tag), skips unparseable tags, and requires a valid release page link.
    static func evaluate(releasesJSON: Data, configuration: UpdateConfiguration) -> UpdateCheckResult {
        guard let releases = try? JSONDecoder().decode([GitHubRelease].self, from: releasesJSON) else { return .failed(.malformedResponse) }
        if releases.isEmpty { return .noReleases }
        let iso = ISO8601DateFormatter()
        var newestValid: ReleaseInfo?
        var newestOverall: SemanticVersion?
        var newerWithBadURL = false
        for release in releases {
            guard release.draft != true, let tag = release.tag_name, let version = SemanticVersion(tag) else { continue }
            let isPrerelease = release.prerelease == true || version.isPrerelease
            if isPrerelease && !configuration.includePrereleases { continue }
            if newestOverall == nil || version > newestOverall! { newestOverall = version }
            guard let link = release.html_url, let url = URL(string: link), configuration.isValidReleasePage(url) else {
                if version > configuration.currentVersion { newerWithBadURL = true }
                continue
            }
            if newestValid == nil || version > newestValid!.version {
                newestValid = ReleaseInfo(version: version, tag: tag, title: release.name, notes: release.body ?? "", pageURL: url,
                                          publishedAt: release.published_at.flatMap { iso.date(from: $0) })
            }
        }
        if let best = newestValid, best.version > configuration.currentVersion { return .updateAvailable(best) }
        if newerWithBadURL { return .failed(.invalidReleaseURL) }
        guard let latest = newestOverall else { return .noReleases }
        return .upToDate(latest: latest)
    }
}
