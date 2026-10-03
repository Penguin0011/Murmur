import Foundation
#if canImport(Security)
import Security
#endif

/// Providers that can hold a user-supplied API key. The raw value is the Keychain account name.
/// `localServer` is a user-run OpenAI-compatible server (Ollama, LM Studio, llama-server, vLLM);
/// its key is optional and it is on-device only when its address is loopback (see Providers.swift).
enum ProviderID: String, CaseIterable, Codable, Sendable {
    case fireworks
    case gemini
    case openrouter
    case localServer

    var displayName: String {
        switch self {
        case .fireworks: return "Fireworks"
        case .gemini: return "Gemini"
        case .openrouter: return "OpenRouter"
        case .localServer: return "Local model server"
        }
    }
}

/// An API key. Every textual and reflective representation is redacted, so printing,
/// interpolating, or dumping a key (or a struct holding one) never reveals it.
struct APIKey: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The secret. Read it only to build an authentication header.
    let secret: String

    /// Trims surrounding whitespace. Returns nil for empty keys or keys containing
    /// whitespace or control characters, which cannot be valid in an HTTP header.
    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4096 else { return nil }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard trimmed.unicodeScalars.allSatisfy({ !forbidden.contains($0) && $0.isASCII }) else { return nil }
        secret = trimmed
    }

    var description: String { "APIKey(redacted)" }
    var debugDescription: String { "APIKey(redacted)" }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Errors carry only status codes, never key material.
enum CredentialError: Error, Equatable, CustomStringConvertible {
    case keychain(status: Int32)
    case unreadableItem

    var description: String {
        switch self {
        case .keychain(let status): return "Keychain operation failed (status \(status))."
        case .unreadableItem: return "The stored API key could not be read."
        }
    }
}

/// Storage for provider API keys. Implementations must never print or log keys.
protocol CredentialStore: Sendable {
    func read(_ provider: ProviderID) throws -> APIKey?
    /// Adds the key, or replaces an existing key for the same provider.
    func save(_ key: APIKey, for provider: ProviderID) throws
    /// Deleting a missing key succeeds.
    func delete(_ provider: ProviderID) throws
    /// Removes every key this app created (used by "Delete all data").
    func deleteAll() throws
    /// Whether a key is stored, without reading the secret.
    func exists(_ provider: ProviderID) -> Bool
}

extension CredentialStore {
    func exists(_ provider: ProviderID) -> Bool { (try? read(provider)) != nil }
}

/// Test and preview store. Holds keys only in process memory.
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var keys: [ProviderID: APIKey] = [:]
    private let lock = NSLock()

    init(_ initial: [ProviderID: APIKey] = [:]) { keys = initial }

    func read(_ provider: ProviderID) throws -> APIKey? { lock.lock(); defer { lock.unlock() }; return keys[provider] }
    func save(_ key: APIKey, for provider: ProviderID) throws { lock.lock(); defer { lock.unlock() }; keys[provider] = key }
    func delete(_ provider: ProviderID) throws { lock.lock(); defer { lock.unlock() }; keys[provider] = nil }
    func deleteAll() throws { lock.lock(); defer { lock.unlock() }; keys.removeAll() }
}

#if canImport(Security)
/// macOS Keychain store: generic password items, service "Murmur", account = provider id.
///
/// Uses the login (file-based) keychain. The data-protection keychain would need a
/// keychain-access-groups entitlement that ad-hoc or development signing does not provide.
struct KeychainCredentialStore: CredentialStore {
    static let defaultService = "Murmur"
    let service: String

    init(service: String = KeychainCredentialStore.defaultService) { self.service = service }

    private func baseQuery(_ provider: ProviderID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue]
    }

    func read(_ provider: ProviderID) throws -> APIKey? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.keychain(status: status) }
        guard let data = item as? Data, let text = String(data: data, encoding: .utf8), let key = APIKey(text) else {
            throw CredentialError.unreadableItem
        }
        return key
    }

    func save(_ key: APIKey, for provider: ProviderID) throws {
        let data = Data(key.secret.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(provider) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CredentialError.keychain(status: status) }
        var add = baseQuery(provider)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "\(service) \(provider.displayName) API key"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw CredentialError.keychain(status: added) }
    }

    /// Attribute-only lookup: the secret is never decrypted into this process.
    func exists(_ provider: ProviderID) -> Bool {
        var query = baseQuery(provider)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func delete(_ provider: ProviderID) throws {
        let status = SecItemDelete(baseQuery(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status: status) }
    }

    /// Deletes known provider accounts, then any remaining generic passwords under this
    /// service. The loop is bounded because macOS file keychains may delete one match per call.
    func deleteAll() throws {
        for provider in ProviderID.allCases { try delete(provider) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        for _ in 0..<64 {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw CredentialError.keychain(status: status) }
        }
    }
}
#endif
