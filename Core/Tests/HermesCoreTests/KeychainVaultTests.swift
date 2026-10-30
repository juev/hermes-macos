import Foundation
import Testing
@testable import HermesCore

@Suite("One item for every secret")
struct KeychainVaultTests {
    private func service() -> String { "org.evsyukov.hermes.macos.test." + UUID().uuidString }
    private func tokens(_ value: String) -> Tokens {
        Tokens(accessToken: value, refreshToken: value + "-r", expiresAt: 0, provider: "p", userID: "u")
    }

    @Test("Tokens of two dashboards live side by side and are dropped one at a time")
    func tokens() throws {
        let vault = KeychainVault(service: service())
        defer { vault.delete() }
        vault.saveTokens(tokens("a"), for: "https://a")
        vault.saveTokens(tokens("b"), for: "https://b")
        #expect(vault.tokens(for: "https://a")?.accessToken == "a")
        #expect(vault.tokens(for: "https://b")?.accessToken == "b")
        #expect(vault.servers.count == 2)

        vault.forgetTokens(for: "https://a")
        #expect(vault.tokens(for: "https://a") == nil)
        #expect(vault.tokens(for: "https://b") != nil)
    }

    @Test("The push secrets survive beside the tokens")
    func push() throws {
        let vault = KeychainVault(service: service())
        defer { vault.delete() }
        vault.saveTokens(tokens("a"), for: "https://a")
        var secrets = KeychainVault.PushSecrets()
        secrets.user = "hermes-macos"
        secrets.password = "secret"
        vault.savePush(secrets)

        #expect(vault.push().user == "hermes-macos")
        // A fresh instance reads what the other wrote: the item is the truth, not the cache.
        let again = KeychainVault(service: vault.service)
        #expect(again.tokens(for: "https://a")?.accessToken == "a")
        #expect(again.push().password == "secret")
    }

    @Test("An empty vault reads as empty, not as an error")
    func empty() {
        let vault = KeychainVault(service: service())
        #expect(vault.tokens(for: "https://nothing") == nil)
        #expect(vault.push().isEmpty)
        #expect(vault.servers.isEmpty)
    }
}
