import Foundation
import Testing
@testable import HermesCore

@Suite("What was read stays on disk")
struct ChatCacheTests {
    private func temporaryRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cache-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A payload written comes back the same")
    func roundTrip() async throws {
        let cache = ChatCache(root: temporaryRoot())
        let payload: JSONValue = ["sessions": [["id": "a", "title": "x"]], "total": 1]
        await cache.write(payload, name: ChatCache.sessionsName(server: "https://h"))
        let read = await cache.read(ChatCache.sessionsName(server: "https://h"))
        #expect(read == payload)
    }

    @Test("Nothing there reads as nothing, not as an error")
    func missing() async throws {
        let cache = ChatCache(root: temporaryRoot())
        #expect(await cache.read(ChatCache.transcriptName(chat: "a")) == nil)
    }

    @Test("An old entry is refused when the caller asks for fresh")
    func stale() async throws {
        let root = temporaryRoot()
        let cache = ChatCache(root: root)
        let name = ChatCache.transcriptName(chat: "a")
        await cache.write(["a": 1], name: name)
        let url = root.appendingPathComponent(name)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: url.path)
        #expect(await cache.read(name, olderThan: 3600) == nil)
        #expect(await cache.read(name) != nil)
    }

    @Test("Chats that left the list leave the cache with it")
    func trimming() async throws {
        let cache = ChatCache(root: temporaryRoot())
        for id in ["a", "b", "c"] {
            await cache.write(["id": .string(id)], name: ChatCache.transcriptName(chat: id))
        }
        await cache.keepOnlyChats(["a", "c"])
        #expect(await cache.read(ChatCache.transcriptName(chat: "b")) == nil)
        #expect(await cache.read(ChatCache.transcriptName(chat: "a")) != nil)
    }
}
