import Foundation
import HermesCore
import Security

/// Where the push settings live: the ntfy address and topic beside the app's own defaults, the keys
/// and the password in the Keychain, because they are secrets and outlive a launch.
@MainActor
struct PushStore {
    private let defaults: UserDefaults
    private static let serverKey = "org.evsyukov.hermes.macos.push.server"
    private static let topicKey = "org.evsyukov.hermes.macos.push.topic"
    private static let deviceKey = "org.evsyukov.hermes.macos.push.device"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var server: String {
        get { defaults.string(forKey: Self.serverKey) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Self.serverKey) }
    }

    var topic: String {
        get { defaults.string(forKey: Self.topicKey) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Self.topicKey) }
    }

    /// A stable id of this Mac, so a new registration replaces the old one.
    var device: String {
        if let known = defaults.string(forKey: Self.deviceKey) { return known }
        let made = "mac-" + UUID().uuidString
        defaults.set(made, forKey: Self.deviceKey)
        return made
    }

    func loadKeys() -> PushKeys? {
        if let cached = PushStore.keysCache { return cached }
        guard let data = Keychain.read(account: "push-keys") else { return nil }
        let keys = try? JSONDecoder().decode(PushKeys.self, from: data)
        PushStore.keysCache = keys
        return keys
    }

    /// The Keychain asks the person once per item per launch, so an item read is kept for the launch.
    @MainActor private static var keysCache: PushKeys?
    @MainActor private static var credentialsCache: NtfyCredentials?

    func saveKeys(_ keys: PushKeys) throws {
        try Keychain.write(try JSONEncoder().encode(keys), account: "push-keys")
    }

    func loadCredentials() -> NtfyCredentials? {
        if let cached = PushStore.credentialsCache { return cached }
        guard let data = Keychain.read(account: "push-credentials"),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        if let token = values["token"], !token.isEmpty {
            let credentials = NtfyCredentials(kind: .token(token))
            PushStore.credentialsCache = credentials
            return credentials
        }
        guard let user = values["user"], let password = values["password"], !user.isEmpty else { return nil }
        let credentials = NtfyCredentials(kind: .basic(user: user, password: password))
        PushStore.credentialsCache = credentials
        return credentials
    }

    func saveCredentials(user: String, password: String) throws {
        PushStore.credentialsCache = nil
        let values = ["user": user, "password": password]
        try Keychain.write(try JSONEncoder().encode(values), account: "push-credentials")
    }

    func forgetCredentials() {
        Keychain.remove(account: "push-credentials")
    }
}

/// The small part of the Keychain this app needs beside the tokens.
enum Keychain {
    private static let service = "org.evsyukov.hermes.macos"

    static func read(account: String) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func write(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw PushStoreError.keychain(added) }
    }

    static func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum PushStoreError: Error, Equatable {
    case keychain(OSStatus)
}
