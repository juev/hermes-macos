# Hermes for macOS

A native macOS client for the [Hermes Agent](https://github.com/NousResearch/hermes-agent) dashboard
(`hermes dashboard`), the same server the [Android client](https://github.com/juev/hermes) talks to.

Status: it is a client. It signs in through the dashboard's browser flow, keeps its tokens in the
Keychain, reads the chats and their history, sends messages and follows a turn as it streams, answers
the questions an agent stops for, sends and receives files, searches the dashboard's index, raises a
notification when a turn ends out of sight, and publishes itself as a `hermes-push` subscriber so a
turn anywhere — Telegram, Matrix, a cron run — reaches this Mac. How the work is organised is in
[AGENTS.md](AGENTS.md); what was decided and what is left is in `handoff.md` in the working tree, which
stays out of git on purpose.

## Two clients, one server

The clients live in separate repositories and share no source: the Android app is Kotlin and Compose on
Android APIs, this one is Swift and SwiftUI on macOS. What they share is what the server sends and
expects, and that is written down once, in the Android repository:
[docs/protocol.md](https://github.com/juev/hermes/blob/main/docs/protocol.md).

A behaviour learned from the server is described there, in the same piece of work that relies on it, and
not copied into this README.

## What it does

- **Sign-in** — `native_pkce` in the system browser, the code back on a loopback listener, the tokens in
  the Keychain under the dashboard's address. The second launch opens straight into the chats with what
  it kept; if the tokens have run out it says so instead of opening a browser by itself.
- **Chats** — the sidebar groups them the way a long list is read (pinned, today, yesterday, the last
  week and month, then by month and year), with the archive behind a button, a pinned search field
  whose results read as chats rather than as messages, and rename, archive and delete on a right
  click. A pin is kept on this Mac, because a plain dashboard has nowhere to keep it.
- **Reading** — the answer is set for reading and Markdown is rendered rather than shown. What a turn
  did on the way — its thinking, its commands, its tool runs — folds into a single line that opens on a
  click, so an answer is what the eye lands on. Each day of a long chat opens with its own separator,
  the transcript follows a streaming answer until you scroll away, and a chat paints from disk before
  the dashboard answers.
- **Writing** — Return sends, Option+Return starts a new line, the paperclip attaches a picture or a
  file, ⌘N starts a chat at once, the toolbar picks the model the chat answers on, and an approval, a
  choice or a secret from the agent arrives as a card above the field with a banner behind it.
- **Files** — a file the agent delivers is drawn under the answer, a picture showing itself; a click
  fetches it with the token and opens it.
- **Tailscale** — a dashboard published only on the tailnet is told apart from one that is down: the
  address family is read before a request is made, and the answer names Tailscale instead of waiting out
  a timeout.
- **Push** — the `hermes-push` plugin posts RFC 8291 Web Push to whatever endpoint a subscriber names,
  so this Mac subscribes with its own P-256 keys to an ntfy topic it reads, and opens each body itself.

## Layout

- `Core/` — a Swift package with everything that has nothing to do with a window: the routes and frames
  of the contract, the sign-in, the socket and its reconnects, the transcript and its formatting, the
  push keys and their decryption.
  - `HermesCore` — the protocol and the model. Its tests replay the payloads captured from a real
    dashboard, and run headless in a couple of seconds.
  - `HermesUI` — the typography and the views: the transcript, the composer, the question card, the
    search results. SwiftUI only, so a test can draw it with `ImageRenderer` and a person can look at
    `build/snapshots/` without the machine's screen being taken.
  - `hermes-live` — an executable that runs the client's own code against a live dashboard.
- `App/` — the window: the connection, the chat model, notifications, the Keychain of the app.
- `project.yml` — the XcodeGen description. `Hermes.xcodeproj` is generated from it and is not
  committed.

## Building

Xcode 27 with the macOS 27 SDK, and XcodeGen (`brew install xcodegen`).

```sh
scripts/build.sh        # generate the project and build build/Build/Products/Debug/Hermes.app
scripts/test.sh         # swift test on the package: no window, no Xcode project
scripts/smoke.sh        # the client's own code against a live dashboard, tokens from the Keychain
```

`scripts/smoke.sh` prints what came back — the status, the chats, the archive, the search, a transcript
folded from stored rows, a delivered file when there is one, the ticket and `gateway.ready`, and a join
that turns a stored id into a live one. Run it after a change that touches the wire; it is the way to
see the client work without opening the window.

`scripts/test.sh` first copies the payloads of the contract out of `../hermes/docs/fixtures` into the
test bundle (`scripts/sync-fixtures.sh`); the copy is generated and stays out of git, so the contract
keeps one home. Set `HERMES_CONTRACT_FIXTURES` when the two repositories are not siblings.

A check must not take the screen: a test draws a view with `ImageRenderer` instead of opening a window,
and the app is started with `open -g -j build/Build/Products/Debug/Hermes.app` when it has to be started
at all. See "A window is not a check" in [AGENTS.md](AGENTS.md) for what that does and does not prove.

## License

[MIT](LICENSE).
