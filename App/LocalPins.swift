import Foundation

/// The chats pinned on this Mac, for the chats a plain dashboard will not pin.
///
/// The dashboard has no socket call for a pin, and its REST route answers `404` for a session that
/// lives in its own process — as every chat of a plain `hermes dashboard` does. The Android client
/// keeps such pins on the phone for the same reason; this one keeps them here, per dashboard.
struct LocalPins {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func pins(for server: String) -> Set<String> {
        Set(defaults.stringArray(forKey: key(server)) ?? [])
    }

    func set(_ id: String, pinned: Bool, for server: String) {
        var current = pins(for: server)
        if pinned {
            current.insert(id)
        } else {
            current.remove(id)
        }
        defaults.set(Array(current), forKey: key(server))
    }

    private func key(_ server: String) -> String {
        "org.evsyukov.hermes.macos.pins:" + server
    }
}
