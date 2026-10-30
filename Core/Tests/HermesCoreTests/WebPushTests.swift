import Foundation
import Testing
@testable import HermesCore

/// A push made by the plugin's own encryptor (`server/hermes-push/webpush.py`, v0.1.2) with a fixed
/// salt and server key, so the two implementations can be held against each other.
enum PushVector {
    static let p256dh = "BMu_PfX7npZiBrcvw0Y3ZfRoVXdt7AQceT6kwioXn0CSNQ6_6osZSwKRGWW1Rd7TZZDX0rWBU2xZgttktuh_8WU"
    static let auth = "AAECAwQFBgcICQoLDA0ODw"
    static let userPrivateDER = "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgIf3bccMJi+jjqJGdVOXZPx17hvhnjh88P9kWDJCsIKKhRANCAATLvz31+56WYga3L8NGN2X0aFV3bewEHHk+pMIqF59AkjUOv+qLGUsCkRlltUXe02WQ19K1gVNsWYLbZLbof/Fl"
    static let body = "EBESExQVFhcYGRobHB0eHwAAEABBBGNlIoSSxXiGjNWg6MjmVAFYzGhbStt4vzUzUloeiYVx4FdpmJhh7YDakDIA4es9PWbI20KII7buqrjvgX6Y872PP9Jz7irMPaoUJrz/ddpYALz56kNutQ0FxjXX9QxcTb7UriXmpoEb/4FgSJsA/BOaNsdd34yFCV/N7H2WAQHGOzMjrmev46x/FjfZun1IllTGtoKJx9cMjmSHAs4xD+Sla76ZJExG38rzWZGpkyWNU4pbEtyWMpVujTaYtJb2kwmRSLw0kNAt5o8="
    static let plaintext = #"{"type": "turn", "session_id": "local-abc", "platform": "cron", "job": "morning", "preview": "The build is green again."}"#

    static func keys() -> PushKeys {
        PushKeys(
            privateKeyDER: data(userPrivateDER),
            publicKey: data(p256dh),
            authSecret: data(auth)
        )
    }

    static func data(_ text: String) -> Data {
        let padded = text + String(repeating: "=", count: (4 - text.count % 4) % 4)
        let base64 = padded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base64) ?? Data()
    }
}

@Suite("A push from hermes-push")
struct WebPushTests {
    @Test("The body the plugin encrypted opens with the subscription's key")
    func decrypt() throws {
        let plain = try WebPush.decrypt(PushVector.data(PushVector.body), keys: PushVector.keys())
        #expect(String(decoding: plain, as: UTF8.self) == PushVector.plaintext)
    }

    @Test("What the plugin sent reads as a finished turn")
    func message() throws {
        let plain = try WebPush.decrypt(PushVector.data(PushVector.body), keys: PushVector.keys())
        let message = PushMessage(try JSONValue.decode(plain))
        #expect(message.type == "turn")
        #expect(message.sessionID == "local-abc")
        #expect(message.platform == "cron")
        #expect(message.job == "morning")
        #expect(message.oneLine == "The build is green again.")
    }

    @Test("Another subscription's key does not open it")
    func wrongKey() throws {
        let foreign = try PushKeys()
        let keys = PushKeys(
            privateKeyDER: foreign.privateKeyDER,
            publicKey: PushVector.keys().publicKey,
            authSecret: PushVector.keys().authSecret
        )
        do {
            _ = try WebPush.decrypt(PushVector.data(PushVector.body), keys: keys)
            Issue.record("A foreign key opened the body")
        } catch let error as WebPushError {
            #expect(error == .cannotOpen || error == .badServerKey)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A truncated body is refused before any key is used")
    func short() {
        do {
            _ = try WebPush.decrypt(Data([1, 2, 3]), keys: PushVector.keys())
            Issue.record("A short body was accepted")
        } catch let error as WebPushError {
            #expect(error == .malformedBody)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Padding is cut from the end of the record")
    func padding() {
        #expect(WebPush.stripPadding(Data("hello".utf8) + Data([0x02])) == Data("hello".utf8))
        #expect(WebPush.stripPadding(Data("hello".utf8) + Data([0x02]) + Data([0, 0, 0])) == Data("hello".utf8))
        #expect(WebPush.stripPadding(Data("hello".utf8)) == Data("hello".utf8))
    }

    @Test("A subscription makes a key pair of its own")
    func freshKeys() throws {
        let keys = try PushKeys()
        #expect(keys.publicKey.count == 65)
        #expect(keys.publicKey.first == 0x04)
        #expect(keys.authSecret.count == 16)
        // The private half survives its DER form.
        #expect(try keys.privateKey.publicKey.x963Representation == keys.publicKey)
    }

    @Test("A continuation preview folds onto a line")
    func preview() {
        let message = PushMessage(["type": "turn", "preview": "line one\n\nline two  "])
        #expect(message.oneLine == "line one line two")
    }
}

@Suite("Registering with hermes-push")
struct PushAPITests {
    private func api(_ transport: StubTransport) throws -> PushAPI {
        PushAPI(endpoint: try #require(Endpoint(address: "https://hermes.example.test")), transport: transport)
    }

    private func response(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: Data(text.utf8))
    }

    @Test("A subscription goes to the plugin with its keys")
    func register() async throws {
        let transport = StubTransport([response(#"{"ok":true}"#)])
        let keys = try PushKeys()
        let subscription = PushSubscription(
            endpoint: "https://ntfy.example.test/upabc",
            keys: keys,
            name: "Hermes for macOS",
            device: "mac-1"
        )
        try await api(transport).register(subscription, token: "at")

        let request = try #require(transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://hermes.example.test/api/plugins/hermes-push/subscriptions")
        #expect(request.headers["Authorization"] == "Bearer at")

        let sent = try #require(try JSONValue.decode(try #require(request.body)))
        #expect(sent["endpoint"]?.stringValue == "https://ntfy.example.test/upabc")
        #expect(sent["name"]?.stringValue == "Hermes for macOS")
        #expect(sent["device"]?.stringValue == "mac-1")
        // The keys travel as base64url without padding, the form the plugin decodes.
        let p256dh = try #require(sent["p256dh"]?.stringValue)
        #expect(!p256dh.contains("="))
        #expect(!p256dh.contains("+"))
        let decoded = Data(base64Encoded: p256dh.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "==")
        #expect(decoded == keys.publicKey)
    }

    @Test("The key the dashboard pushes with")
    func key() async throws {
        let transport = StubTransport([response(#"{"key":"BCPJja7C"}"#)])
        let value = try await api(transport).key(token: "at")
        #expect(value == "BCPJja7C")
        #expect(transport.requests.first?.url.absoluteString == "https://hermes.example.test/api/plugins/hermes-push/key")
    }

    @Test("Leaving and testing")
    func leaving() async throws {
        let transport = StubTransport([response("{}"), response(#"{"sent":1}"#)])
        try await api(transport).unregister(endpoint: "https://ntfy.example.test/upabc", token: "at")
        try await api(transport).test(token: "at")

        #expect(transport.requests[0].method == "DELETE")
        let removed = try JSONValue.decode(try #require(transport.requests[0].body))
        #expect(removed["endpoint"]?.stringValue == "https://ntfy.example.test/upabc")
        #expect(transport.requests[1].method == "POST")
        #expect(transport.requests[1].url.path == "/api/plugins/hermes-push/test")
    }

    @Test("A refused registration is an error")
    func refused() async throws {
        let transport = StubTransport([HTTPResponse(status: 401, body: Data(#"{"detail":"Unauthorized"}"#.utf8))])
        do {
            try await api(transport).register(
                PushSubscription(endpoint: "https://ntfy.example.test/upabc", keys: try PushKeys(), name: "mac", device: "d"),
                token: nil
            )
            Issue.record("A refused registration did not throw")
        } catch let error as DashboardError {
            #expect(error.needsSignIn)
        }
    }
}
