import os

/// What the app says about itself, for `log show --predicate 'process == "Hermes"'`: a check that has
/// to see a window takes its result from here instead.
enum Log {
    static let app = Logger(subsystem: "org.evsyukov.hermes.macos", category: "app")
}
