# Working in this repository

Rules for anyone changing this repository, human or agent. Build and test commands belong in
`README.md` and here once the app target exists.

## Build and test

- `scripts/build.sh` regenerates `Hermes.xcodeproj` from `project.yml` and builds
  `build/Build/Products/Debug/Hermes.app`. The project file is generated and stays out of git.
- `scripts/test.sh` runs `swift test` on `Core`, the package with the protocol and the model. It is
  headless and takes seconds; a change to the wire behaviour or to how a transcript is parsed goes with
  a test there, not only with a build.
- The app target is thin on purpose: windows, menus, typography. Anything decidable from a frame or a
  string belongs in `Core`, where it can be tested without a screen.

## The server contract has one home

The wire behaviour of the Hermes Agent dashboard — routes, sign-in, socket methods, event shapes — is
documented in `../hermes/docs/protocol.md`, next to the reference client that discovered it.

- A change that depends on server behaviour not yet described there is not finished until the
  description is added, in the same piece of work, with the server version it was observed on.
- When the document is silent, the Android client is the source of truth:
  `../hermes/app/src/main/java/org/evsyukov/hermes/data/remote/` (HTTP and socket), `.../data/auth/`
  (sign-in), `.../chat/` (transcript, approvals, tool output), and its tests in
  `../hermes/app/src/test/java/org/evsyukov/hermes/`.
- The contract is not forked into this repository. Two copies of it is how the clients drift.
- A conclusion put together from reading those files is a hypothesis until the app or a test
  reproduces it. Say which parts were checked and which were not.

## Decisions

Taken by the owner, 2026-10-30:

- The macOS client is developed here, in `hermes-macos`, separately from the Android client, which
  keeps its repository, its issues and its releases in `juev/hermes`.
- The URL scheme `org.evsyukov.hermes://` is shared with the Android client, so an "add a server" link
  works on either platform.
- Swift 6 and SwiftUI, macOS only — no Catalyst, no Electron, no Compose Desktop, and no Kotlin
  Multiplatform core under a SwiftUI shell. The Android client has nothing portable to hand over: 45 of
  its 72 source files import `android.*` or its resources, the socket, HTTP and sign-in are written
  against OkHttp and `android.util.Log`, persistence is Room and DataStore, tokens sit in the Android
  Keystore — and the socket is the very part a shared core would have to carry. The 660 lines that do
  port cleanly — the transcript, tool-group folding, approvals, plain text, the chat and channel
  helpers — are cheaper to port to Swift than to wrap an Xcode build around Gradle and Kotlin/Native,
  and porting them is what checks the contract. A core would be a second implementation both clients
  adopt, not reuse of an existing one; the contract and the fixtures each client replays are what keep
  them from drifting. Reopen if a third client appears, or if the Android transport leaves OkHttp for
  its own reasons.

Assumed, to confirm before the first line of code:

- Bundle id `org.evsyukov.hermes.macos`.
- Releases: a tag `vX.Y.Z` builds a signed, notarized disk image on a macOS runner and publishes it;
  `vX.Y.Z-rcN` is published as a pre-release, as the Android client's `release.yml` does.
- Release secrets carry the `HERMES_MACOS_` prefix, and the Developer ID lives under the keychain item
  `org.evsyukov.hermes.macos`, so neither can be confused with the Android `HERMES_KEYSTORE_*` ones.

Open questions are in [handoff.md](handoff.md).

## One task, one worktree

The main checkout stays on `main` and is not used for task work. Each task gets a worktree and a branch
named after the change:

```sh
git fetch origin main
git worktree add -b macos/<change> ../hermes-macos-worktrees/<issue> origin/main
```

Remove the worktree after its branch is merged. This follows the Android client's practice; adjust the
directory if you prefer another.

## Checks do not steal the screen

A build or test run must not take the keyboard focus, put a window in front of the person at the
machine, or play sound.

- Start a built app hidden and without focus: `open -g -j <path to the built Hermes.app>` — with
  `-derivedDataPath build` that is `build/Build/Products/Debug/Hermes.app` — and take the result from
  logs, `os_log` or the data folder rather than from a window.
- Checks that need visible interaction — a menu bar item, a system notification, a passkey in the
  system sheet, the share sheet — are not run silently: say so and leave them to the person.
- Quit the instance you started; leave an instance you did not start alone.

## Commits and documentation

- Conventional commit prefixes (`feat:`, `fix:`, `test:`, `ci:`, `docs:`), an English subject that says
  what the change does, and the issue or pull request number at the end.
- Documentation is in English.
- Issues live in this repository. A server behaviour belongs in `../hermes/docs/protocol.md`, and the
  code that depends on it links there.
