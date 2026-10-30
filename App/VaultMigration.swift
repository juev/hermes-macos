import Foundation
import HermesCore

/// Moves what earlier builds kept in three Keychain items into the one item this build uses: tokens
/// under the dashboard's address, the push keys and the ntfy credentials. Each of those items asked
/// for a password on its own; after this there is one item to allow.
///
/// Runs once, on the first launch that finds the vault empty, and drops the old items behind it.
enum VaultMigration {
    static func runIfNeeded(vault: KeychainVault) {
        guard vault.servers.isEmpty, vault.push().isEmpty else {
            Log.app.info("secrets: the vault is there, nothing to move")
            return
        }
        Log.app.info("secrets: moving the old keychain items into the vault")

        let bookmarks = ServerBookmarks()
        let legacy = KeychainTokenStorage()
        var moved = false
        for address in bookmarks.servers {
            guard let tokens = try? legacy.tokens(for: address) else { continue }
            vault.saveTokens(tokens, for: address)
            moved = true
        }

        var secrets = KeychainVault.PushSecrets()
        if let data = Keychain.read(account: "push-keys") {
            secrets.keys = try? JSONDecoder().decode(PushKeys.self, from: data)
        }
        if let data = Keychain.read(account: "push-credentials"),
           let values = try? JSONDecoder().decode([String: String].self, from: data) {
            secrets.user = values["user"]
            secrets.password = values["password"]
            secrets.token = values["token"]
        }
        if !secrets.isEmpty {
            vault.savePush(secrets)
            moved = true
        }

        guard moved else { return }
        for address in bookmarks.servers {
            try? legacy.save(nil, for: address)
        }
        Keychain.remove(account: "push-keys")
        Keychain.remove(account: "push-credentials")
    }
}
