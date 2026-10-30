import Foundation
import Testing
@testable import HermesCore

/// The stream a listener sees, scripted by the test.
final class FakeStream: PushStreamProvider, @unchecked Sendable {
    private let lines: [String]
    private let error: Error?

    init(_ lines: [String], error: Error? = nil) {
        self.lines = lines
        self.error = error
    }

    func lines(from url: URL, headers: [String: String]) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish(throwing: error)
        }
    }
}

@Suite("The topic pushes arrive on")
struct NtfyTopicTests {
    @Test("A topic address as a person types it")
    func address() throws {
        let topic = try #require(NtfyTopic(address: "https://ntfy.example.org/upabc"))
        #expect(topic.topic == "upabc")
        #expect(topic.base.absoluteString == "https://ntfy.example.org")
        #expect(topic.endpoint == "https://ntfy.example.org/upabc")
        #expect(topic.streamURL.absoluteString == "https://ntfy.example.org/upabc/json")
    }

    @Test("A bare host gets https and keeps a path prefix")
    func prefix() throws {
        let topic = try #require(NtfyTopic(address: "ntfy.example.org/push/upxyz"))
        #expect(topic.topic == "upxyz")
        #expect(topic.base.absoluteString == "https://ntfy.example.org/push")
        #expect(topic.streamURL.absoluteString == "https://ntfy.example.org/push/upxyz/json")
    }

    @Test("What is not a topic is refused")
    func refused() {
        #expect(NtfyTopic(address: "") == nil)
        #expect(NtfyTopic(address: "   ") == nil)
        #expect(NtfyTopic(address: "https://") == nil)
    }

    @Test("The credentials a reader sends")
    func credentials() {
        let basic = NtfyCredentials(kind: .basic(user: "phone", password: "secret"))
        #expect(basic.headers["Authorization"] == "Basic " + Data("phone:secret".utf8).base64EncodedString())
        let token = NtfyCredentials(kind: .token("tk_123"))
        #expect(token.headers["Authorization"] == "Bearer tk_123")
    }
}

@Suite("A line of the ntfy stream")
struct NtfyMessageTests {
    @Test("A message carries the body as bytes")
    func message() throws {
        let line = #"{"id":"abc","time":1793353067,"event":"message","topic":"upabc","message":"hello"}"#
        let message = try #require(NtfyMessage(line: line))
        #expect(message.event == "message")
        #expect(message.topic == "upabc")
        #expect(message.body == Data("hello".utf8))
    }

    @Test("A binary body arrives base64-encoded and is decoded")
    func binary() throws {
        let bytes = Data([0x00, 0xFF, 0x10, 0x80])
        let line = #"{"event":"message","topic":"upabc","encoding":"base64","message":"\#(bytes.base64EncodedString())"}"#
        let message = try #require(NtfyMessage(line: line))
        #expect(message.body == bytes)
    }

    @Test("The opening of a stream and its keepalives are not messages")
    func openings() throws {
        let open = try #require(NtfyMessage(line: #"{"event":"open","topic":"upabc"}"#))
        #expect(open.event == "open")
        let keepalive = try #require(NtfyMessage(line: #"{"event":"keepalive","topic":"upabc"}"#))
        #expect(keepalive.event == "keepalive")
        #expect(NtfyMessage(line: "not json") == nil)
    }
}

@Suite("Listening for pushes")
struct PushListenerTests {
    private func line(_ body: Data) -> String {
        #"{"id":"m1","event":"message","topic":"upabc","encoding":"base64","message":"\#(body.base64EncodedString())"}"#
    }

    @Test("A push from the dashboard reaches the listener, opened")
    func delivered() async throws {
        let collected = Recorder<PushMessage>()
        let listener = PushListener(
            topic: NtfyTopic(base: URL(string: "https://ntfy.example.test")!, topic: "upabc"),
            credentials: nil,
            keys: PushVector.keys(),
            stream: FakeStream([line(PushVector.data(PushVector.body))]),
            onPush: { collected.record($0) }
        )
        await listener.start()
        try await waitUntil { collected.all.count == 1 }

        let push = try #require(collected.all.first)
        #expect(push.type == "turn")
        #expect(push.sessionID == "local-abc")
        #expect(push.preview == "The build is green again.")
        await listener.stop()
    }

    @Test("A body that does not open with these keys is dropped, not fatal")
    func foreign() async throws {
        let collected = Recorder<PushMessage>()
        let listener = PushListener(
            topic: NtfyTopic(base: URL(string: "https://ntfy.example.test")!, topic: "upabc"),
            credentials: nil,
            keys: try PushKeys(),
            stream: FakeStream([line(Data("not a web push".utf8))]),
            onPush: { collected.record($0) }
        )
        await listener.start()
        try await Task.sleep(for: .milliseconds(120))
        #expect(collected.all.isEmpty)
        await listener.stop()
    }
}
