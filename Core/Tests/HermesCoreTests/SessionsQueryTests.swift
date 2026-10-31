import Foundation
import Testing
@testable import HermesCore

@Suite("The query of the chat list")
struct SessionsQueryTests {
    @Test("One-shot runs and other programmatic sources are left out of the list")
    func excludedSources() async throws {
        let transport = StubTransport([HTTPResponse(status: 200, body: Data(#"{"sessions":[],"total":0}"#.utf8))])
        let endpoint = try #require(Endpoint(address: "https://hermes.example.test"))
        let session = DashboardSession(endpoint: endpoint, transport: transport)

        let page = try await session.sessions()
        #expect(page.sessions.isEmpty)

        let request = try #require(transport.requests.first)
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        #expect(components.path.hasSuffix("/api/sessions"))
        let items = components.queryItems ?? []
        #expect(items.filter { $0.name == "exclude_sources" }.map(\.value)
            == ["oneshot,tool,api_server,acp,hermes_flow,vulcan_delegate,webhook"])
        #expect(!items.contains { $0.name == "sources" })
    }
}
