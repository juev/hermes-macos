import Foundation

/// What can be done to a chat that is not open: rename it, file it away, delete it.
///
/// On a plain `hermes dashboard` these changes cannot go over REST — the session lives in the
/// dashboard's own process and the route answers `not_found` — so they go over the socket. An archive
/// and a delete find their session by the id the sidebar knows; a rename needs the live one, which is
/// joined for the moment it takes and let go again (`../hermes/docs/protocol.md` §6).
public actor ChatAdmin {
    private let gateway: GatewaySession

    public init(gateway: GatewaySession) {
        self.gateway = gateway
    }

    public func rename(storedID: String, title: String) async throws {
        let live = try await join(storedID)
        defer {
            Task { _ = try? await gateway.call("session.close", params: ["session_id": .string(live)]) }
        }
        _ = try await gateway.call("session.title", params: [
            "session_id": .string(live),
            "title": .string(title)
        ])
    }

    public func archive(storedID: String, archived: Bool) async throws {
        _ = try await gateway.call("session.archive", params: [
            "session_key": .string(storedID),
            "archived": .bool(archived)
        ])
    }

    public func delete(storedID: String) async throws {
        _ = try await gateway.call("session.delete", params: ["session_id": .string(storedID)])
    }

    /// Joins a stored chat without its history, for as long as one call needs it.
    private func join(_ storedID: String) async throws -> String {
        let answer = try await gateway.call("session.resume", params: [
            "session_id": .string(storedID),
            "lazy": true,
            "omit_messages": true
        ], timeout: .seconds(120))
        guard let live = answer["session_id"]?.scalarString, !live.isEmpty else {
            throw ChatError.noLiveSession
        }
        return live
    }
}
