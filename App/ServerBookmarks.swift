import Foundation

/// The dashboards this Mac has opened, newest first.
///
/// The tokens of each one are already in the Keychain, under its address; what is missing is the
/// address itself, and asking a person to type it on every launch is a tax on a client that is meant
/// to be opened and read.
struct ServerBookmarks {
    private static let key = "org.evsyukov.hermes.macos.servers"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Every known address, the one used last first.
    var servers: [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    var last: String? { servers.first }

    /// Remembers an address, moving it to the front when it is already known.
    func remember(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var known = servers.filter { $0 != trimmed }
        known.insert(trimmed, at: 0)
        defaults.set(Array(known.prefix(10)), forKey: Self.key)
    }

    func forget(_ address: String) {
        defaults.set(servers.filter { $0 != address }, forKey: Self.key)
    }
}
