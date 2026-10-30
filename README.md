# Hermes for macOS

A native macOS client for the [Hermes Agent](https://github.com/NousResearch/hermes-agent) dashboard
(`hermes dashboard`), the same server the [Android client](https://github.com/juev/hermes) talks to.

Status: the shell and the protocol layer. The app opens on the address of a dashboard and checks it;
the sign-in, the socket and the chat are being built. How the work is organised is in
[AGENTS.md](AGENTS.md); the decisions taken so far and the slice under way are in `handoff.md` in the
working tree, which stays out of git on purpose.

## Two clients, one server

The clients live in separate repositories and share no source: the Android app is Kotlin and Compose on
Android APIs, this one is Swift and SwiftUI on macOS. What they share is what the server sends and
expects, and that is written down once, in the Android repository:
[docs/protocol.md](https://github.com/juev/hermes/blob/main/docs/protocol.md).

A behaviour learned from the server is described there, in the same piece of work that relies on it, and
not copied into this README.

## Layout

- `Core/` — a Swift package with the protocol and the model: the routes, the frames, the tokens, the
  sign-in, and later the transcript and its formatting. It has no window and no Xcode project, so its
  tests run headless in a couple of seconds.
- `App/` — the SwiftUI app: windows, menus, typography, notifications. It depends on `Core`.
- `project.yml` — the XcodeGen description. `Hermes.xcodeproj` is generated from it and is not
  committed.

## Building

Xcode 27 with the macOS 27 SDK, and XcodeGen (`brew install xcodegen`).

```sh
scripts/build.sh        # generate the project and build build/Build/Products/Debug/Hermes.app
scripts/test.sh         # swift test on Core: no window, no Xcode project
```

`scripts/smoke.sh` runs the client's own code against a live dashboard, with the tokens the app keeps
in the Keychain, and prints what came back. Run it after a change that touches the wire.

`scripts/test.sh` first copies the payloads of the contract out of `../hermes/docs/fixtures` into the
test bundle (`scripts/sync-fixtures.sh`); the copy is generated and stays out of git, so the contract
keeps one home. Set `HERMES_CONTRACT_FIXTURES` when the two repositories are not siblings.

A check must not take the screen: start the built app with
`open -g -j build/Build/Products/Debug/Hermes.app` and take the result from the log, the data folder or
a test.

## License

[MIT](LICENSE).
