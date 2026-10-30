import Foundation

/// A push subscription as `hermes-push` takes it: where to post, the keys the dashboard encrypts to,
/// and who this one is.
public struct PushSubscription: Sendable, Equatable {
    /// An address the client can read, `https` — an ntfy topic here.
    public let endpoint: String
    public let keys: PushKeys
    /// What the dashboard calls this client, e.g. "Hermes for macOS".
    public let name: String
    /// A stable id of this client, so a new subscription replaces the ones it no longer reads.
    public let device: String

    public init(endpoint: String, keys: PushKeys, name: String, device: String) {
        self.endpoint = endpoint
        self.keys = keys
        self.name = name
        self.device = device
    }

    public var payload: [String: JSONValue] {
        [
            "endpoint": .string(endpoint),
            "p256dh": .string(Self.base64URL(keys.publicKey)),
            "auth": .string(Self.base64URL(keys.authSecret)),
            "name": .string(name),
            "device": .string(device)
        ]
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The routes of the `hermes-push` plugin, under `/api/plugins/hermes-push` and behind the same
/// sign-in as the rest of the dashboard (`../hermes/docs/protocol.md` §12).
public struct PushAPI: Sendable {
    public let endpoint: Endpoint
    public let transport: HTTPTransport

    public init(endpoint: Endpoint, transport: HTTPTransport = URLSessionTransport()) {
        self.endpoint = endpoint
        self.transport = transport
    }

    /// The dashboard's VAPID public key: what a push service is registered with.
    public func key(token: String?) async throws -> String {
        let response = try await transport.send(HTTPRequest(url: endpoint.url("api/plugins/hermes-push/key"), headers: bearer(token)))
        guard response.isSuccess, let key = response.json?["key"]?.stringValue, !key.isEmpty else {
            throw DashboardError(status: response.status, response: response)
        }
        return key
    }

    /// Tells the dashboard where to push and with what keys.
    public func register(_ subscription: PushSubscription, token: String?) async throws {
        let request = HTTPRequest(
            method: "POST",
            url: endpoint.url("api/plugins/hermes-push/subscriptions"),
            headers: bearer(token)
        ).json(.object(subscription.payload))
        let response = try await transport.send(request)
        guard response.isSuccess else { throw DashboardError(status: response.status, response: response) }
    }

    public func unregister(endpoint address: String, token: String?) async throws {
        let request = HTTPRequest(
            method: "DELETE",
            url: endpoint.url("api/plugins/hermes-push/subscriptions"),
            headers: bearer(token)
        ).json(["endpoint": .string(address)])
        let response = try await transport.send(request)
        guard response.isSuccess else { throw DashboardError(status: response.status, response: response) }
    }

    /// Asks the dashboard to push to every subscription: the test a person runs once.
    public func test(token: String?) async throws {
        let request = HTTPRequest(
            method: "POST",
            url: endpoint.url("api/plugins/hermes-push/test"),
            headers: bearer(token)
        ).json(.object([:]))
        let response = try await transport.send(request)
        guard response.isSuccess else { throw DashboardError(status: response.status, response: response) }
    }

    private func bearer(_ token: String?) -> [String: String] {
        token.map { ["Authorization": "Bearer \($0)"] } ?? [:]
    }
}
