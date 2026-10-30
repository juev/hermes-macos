import Foundation

/// What the window has already read, kept on disk so opening the app or a chat paints before the
/// dashboard answers. Nothing here is authoritative: a cached page is shown, then replaced by the
/// answer to the same question.
public final class ChatCache: @unchecked Sendable {
    private let root: URL
    private let fileManager: FileManager
    /// Reads and writes are short and rare; a lock keeps them safe without making every caller wait
    /// on an actor — a cache that answers on the next turn of the run loop is a cache that arrives
    /// after the spinner has already been drawn.
    private let lock = NSLock()

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    /// The cache the app keeps: `~/Library/Caches/<bundle>/`.
    public static func standard() -> ChatCache {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return ChatCache(root: base.appendingPathComponent("org.evsyukov.hermes.macos", isDirectory: true))
    }

    /// Reads a stored payload; nil when there is none or it is older than [maxAge].
    public func read(_ name: String, olderThan maxAge: TimeInterval? = nil) -> JSONValue? {
        withLock {
            readLocked(name, olderThan: maxAge)
        }
    }

    private func readLocked(_ name: String, olderThan maxAge: TimeInterval?) -> JSONValue? {
        let url = file(named: name)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        if let maxAge, Date().timeIntervalSince(modified) > maxAge { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONValue.decode(data)
    }

    /// Writes a payload, replacing what was there.
    public func write(_ json: JSONValue, name: String) {
        withLock {
            let url = file(named: name)
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try json.encoded().write(to: url, options: .atomic)
            } catch {
                // A cache that cannot be written is not a reason to fail anything.
            }
        }
    }

    /// Drops every stored chat except the ones named.
    public func keepOnlyChats(_ ids: Set<String>) {
        withLock {
            let directory = root.appendingPathComponent("chats", isDirectory: true)
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names where name.hasSuffix(".json") && name != "sessions.json" {
                let id = String(name.dropLast(5))
                if !ids.contains(id) {
                    try? fileManager.removeItem(at: directory.appendingPathComponent(name))
                }
            }
        }
    }

    /// The bytes on disk, for the tests and for a person wondering where they went.
    public var rootDirectory: URL { root }

    private func file(named name: String) -> URL {
        root.appendingPathComponent(name)
    }
}

extension ChatCache {
    /// The name a dashboard's chat list is kept under, and the one a chat's history is kept under.
    public static func sessionsName(server: String) -> String { "chats/sessions.json" }

    public static func transcriptName(chat id: String) -> String {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        return "chats/" + safe + ".json"
    }
}
