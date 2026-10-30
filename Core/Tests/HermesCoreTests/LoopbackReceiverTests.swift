import Foundation
import Testing
@testable import HermesCore

private func localSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForRequest = 10
    return URLSession(configuration: configuration)
}

@Suite("The loopback listener of the sign-in")
struct LoopbackReceiverTests {
    @Test("The redirect address is a loopback one with a port the system gave")
    func address() throws {
        let receiver = try LoopbackReceiver()
        defer { receiver.close() }
        #expect(receiver.port > 0)
        #expect(receiver.redirectURI == "http://127.0.0.1:\(receiver.port)/callback")
    }

    @Test("The browser comes back with a code")
    func callback() async throws {
        let receiver = try LoopbackReceiver()
        async let waiting = receiver.wait(timeout: .seconds(10))

        let url = try #require(URL(string: receiver.redirectURI + "?code=abc%2F1&state=st-1"))
        let (body, response) = try await localSession().data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("Signed in"))

        let result = try await waiting
        #expect(result == .code(code: "abc/1", state: "st-1"))
    }

    @Test("A request that is not the callback is answered and the wait goes on")
    func otherRequest() async throws {
        let receiver = try LoopbackReceiver()
        async let waiting = receiver.wait(timeout: .seconds(10))

        let favicon = try #require(URL(string: "http://127.0.0.1:\(receiver.port)/favicon.ico"))
        let (_, notFound) = try await localSession().data(from: favicon)
        #expect((notFound as? HTTPURLResponse)?.statusCode == 404)

        let callback = try #require(URL(string: receiver.redirectURI + "?code=c&state=s"))
        let (_, found) = try await localSession().data(from: callback)
        #expect((found as? HTTPURLResponse)?.statusCode == 200)

        #expect(try await waiting == .code(code: "c", state: "s"))
    }

    @Test("A refusal from the identity provider is carried through, not thrown")
    func refusal() async throws {
        let receiver = try LoopbackReceiver()
        async let waiting = receiver.wait(timeout: .seconds(10))

        let url = try #require(URL(string: receiver.redirectURI + "?error=access_denied&error_description=No+account"))
        let (body, _) = try await localSession().data(from: url)
        #expect(String(decoding: body, as: UTF8.self).contains("Sign-in failed"))

        #expect(try await waiting == .error(code: "access_denied", description: "No account"))
    }

    @Test("Nobody comes back and the wait ends")
    func timeout() async throws {
        let receiver = try LoopbackReceiver()
        let started = Date()
        await #expect(throws: LoopbackError.timedOut) {
            _ = try await receiver.wait(timeout: .milliseconds(200))
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("The listener can be closed twice")
    func closing() throws {
        let receiver = try LoopbackReceiver()
        receiver.close()
        receiver.close()
    }
}
