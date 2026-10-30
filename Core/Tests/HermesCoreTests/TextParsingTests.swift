import Foundation
import Testing
@testable import HermesCore


@Suite("Files the agent delivers")
struct DeliveredFilesTests {
    private func turn(_ text: String) -> AssistantTurn {
        AssistantTurn(key: "a1", parts: [.text(text)])
    }

    @Test("A directive names a file and is not part of the words")
    func directive() {
        let answer = "Готово.\n\nMEDIA: /opt/hermes/reports/build.md\n"
        let turn = turn(answer)
        #expect(turn.deliveredFiles == ["/opt/hermes/reports/build.md"])
        #expect(!turn.displayText.contains("MEDIA:"))
        #expect(turn.displayText.hasPrefix("Готово."))
    }

    @Test("Prose that mentions the directive is not a file")
    func prose() {
        let answer = "The client parses the MEDIA: directive like this, and the rest of the sentence goes on"
        #expect(turn(answer).deliveredFiles.isEmpty)

        let long = "MEDIA: " + String(repeating: "a", count: 900)
        #expect(turn(long).deliveredFiles.isEmpty)
    }

    @Test("Files open, not a file with an extension")
    func extensions() {
        let turn = turn("MEDIA: /tmp/a.png\nMEDIA: /tmp/b.tar.gz\nMEDIA: not-a-path")
        #expect(turn.deliveredFiles == ["/tmp/a.png", "/tmp/b.tar.gz"])
    }
}

@Suite("Reading a file from the dashboard")
struct FileDownloadTests {
    @Test("The path travels as a query and the token as a header")
    func request() async throws {
        let transport = StubTransport([HTTPResponse(status: 200, body: Data("hello".utf8))])
        let download = FileDownload(endpoint: try #require(Endpoint(address: "https://hermes.example.test")), transport: transport)

        let data = try await download.data(path: "/opt/hermes/a.md", token: "at")
        #expect(data == Data("hello".utf8))

        let request = try #require(transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.path == "/api/files/download")
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "path" }?.value == "/opt/hermes/a.md")
        #expect(request.headers["Authorization"] == "Bearer at")
        #expect(request.timeout == 60)
    }

    @Test("A file the dashboard does not have is an error")
    func missing() async throws {
        let transport = StubTransport([HTTPResponse(status: 404, body: Data(#"{"detail":"Path not found"}"#.utf8))])
        let download = FileDownload(endpoint: try #require(Endpoint(address: "https://hermes.example.test")), transport: transport)
        do {
            _ = try await download.data(path: "/opt/nope", token: "at")
            Issue.record("A missing file did not throw")
        } catch let error as DashboardError {
            #expect(error.status == 404)
            #expect(error.detail == "Path not found")
        }
    }
}
