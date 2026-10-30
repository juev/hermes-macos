import Foundation
import Security

/// Everything this app keeps in the Keychain, in one item.
///
/// The Keychain asks the person to allow each item once, and an app that reads three of them asks
/// three times. The tokens of every dashboard and the secrets of the push are a small dictionary, so
/// they live under one account and one password — asked for once, however many of them are used.
public final class KeychainVault: @unchecked Sendable {
    /// What the push needs to exist between launches.
    public struct PushSecrets: Codable, Sendable, Equatable {
        public var keys: PushKeys?
        public var user: String?
        public var password: String?
        public var token: String?

        public init(keys: PushKeys? = nil, user: String? = nil, password: String? = nil, token: String? = nil) {
            self.keys = keys
            self.user = user
            self.password = password
            self.token = token
        }

        public var isEmpty: Bool {
            keys == nil && (user ?? "").isEmpty && (password ?? "").isEmpty && (token ?? "").isEmpty
        }
    }

    private struct Contents: Codable {
        var tokens: [String: Tokens] = [:]
        var push: PushSecrets = PushSecrets()
    }

    public let service: String
    public let account: String
    private let lock = NSLock()
    private var loaded: Contents?

    public init(service: String = "org.evsyukov.hermes.macos", account: String = "vault") {
        self.service = service
        self.account = account
    }

    // MARK: Tokens

    public func tokens(for server: String) -> Tokens? {
        withLock { contents()?.tokens[server] }
    }

    public func saveTokens(_ tokens: Tokens?, for server: String) {
        withLock {
            var current = contents() ?? Contents()
            current.tokens[server] = tokens
            store(current)
        }
    }

    public func forgetTokens(for server: String) {
        withLock {
            guard var current = contents() else { return }
            current.tokens[server] = nil
            store(current)
        }
    }

    /// The addresses the vault holds tokens for: what the sidebar can open without a sign-in.
    public var servers: [String] {
        withLock { contents()?.tokens.keys.sorted() ?? [] }
    }

    // MARK: Push

    public func push() -> PushSecrets {
        withLock { contents()?.push ?? PushSecrets() }
    }

    public func savePush(_ push: PushSecrets) {
        withLock {
            var current = contents() ?? Contents()
            current.push = push
            store(current)
        }
    }

    /// Drops the item: what a test does with what it wrote, and what "forget this Mac" would do.
    public func delete() {
        withLock {
            loaded = Contents()
            SecItemDelete(baseQuery() as CFDictionary)
        }
    }

    // MARK: The item

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func contents() -> Contents? {
        if let loaded { return loaded }
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let contents = try? JSONDecoder().decode(Contents.self, from: data) else {
            return nil
        }
        loaded = contents
        return contents
    }

    private func store(_ contents: Contents) {
        loaded = contents
        let data = (try? JSONEncoder().encode(contents)) ?? Data()
        var query = baseQuery()
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess { return }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// The tokens of a dashboard, kept in the vault.
public struct VaultTokenStorage: TokenStorage {
    public let vault: KeychainVault

    public init(vault: KeychainVault) {
        self.vault = vault
    }

    public func tokens(for server: String) throws -> Tokens? {
        vault.tokens(for: server)
    }

    public func save(_ tokens: Tokens?, for server: String) throws {
        if let tokens {
            vault.saveTokens(tokens, for: server)
        } else {
            vault.forgetTokens(for: server)
        }
    }
}
