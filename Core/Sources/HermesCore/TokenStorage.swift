import Foundation
import Security

/// Where the tokens of a dashboard live between launches.
public protocol TokenStorage: Sendable {
    func tokens(for server: String) throws -> Tokens?
    func save(_ tokens: Tokens?, for server: String) throws
}

public enum TokenStorageError: Error, Equatable {
    case keychain(OSStatus)
}

/// The Keychain, one generic-password item per dashboard.
///
/// The account is the address of the server, so two dashboards on one Mac keep their own tokens; the
/// service is the bundle id, so nothing else can read them. The items are readable after the first
/// unlock and not before, which is what a client started at login needs and a person would expect.
public struct KeychainTokenStorage: TokenStorage {
    public let service: String

    public init(service: String = "org.evsyukov.hermes.macos") {
        self.service = service
    }

    public func tokens(for server: String) throws -> Tokens? {
        var query = baseQuery(for: server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return try? JSONDecoder().decode(Tokens.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw TokenStorageError.keychain(status)
        }
    }

    public func save(_ tokens: Tokens?, for server: String) throws {
        let query = baseQuery(for: server)
        guard let tokens else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw TokenStorageError.keychain(status)
            }
            return
        }

        let data = try JSONEncoder().encode(tokens)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw TokenStorageError.keychain(updated) }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw TokenStorageError.keychain(added) }
    }

    private func baseQuery(for server: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server
        ]
    }
}
