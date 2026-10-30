# Hermes for macOS

A native macOS client for the [Hermes Agent](https://github.com/NousResearch/hermes-agent) dashboard
(`hermes dashboard`), the same server the [Android client](https://github.com/juev/hermes) talks to.

Status: a skeleton. There is no application code yet. How the work is organised is in
[AGENTS.md](AGENTS.md); the decisions taken so far and the first slice are in `handoff.md` in the
working tree, which stays out of git on purpose.

## Two clients, one server

The clients live in separate repositories and share no source: the Android app is Kotlin and Compose on
Android APIs, this one is Swift and SwiftUI on macOS. What they share is what the server sends and
expects, and that is written down once, in the Android repository:
[docs/protocol.md](https://github.com/juev/hermes/blob/main/docs/protocol.md).

A behaviour learned from the server is described there, in the same piece of work that relies on it, and
not copied into this README.

## Building

Nothing to build yet. Once the app target exists, its commands go here and in [AGENTS.md](AGENTS.md).

## License

[MIT](LICENSE).
