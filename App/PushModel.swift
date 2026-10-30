import Foundation
import HermesCore
import Observation

/// The push of a dashboard: the ntfy topic the plugin posts to, the keys the dashboard encrypts to,
/// and the listener that turns what arrives into a banner.
@MainActor
@Observable
final class PushModel {
    enum State: Equatable {
        case off
        case connecting
        case on
        case failed(String)
    }

    var server: String
    var topic: String
    var user: String
    var password: String

    private(set) var state: State = .off
    private(set) var detail: String?
    private(set) var lastPush: PushMessage?

    private let session: DashboardSession
    private let store: PushStore
    private var listener: PushListener?
    let device: String

    private static let enabledKey = "org.evsyukov.hermes.macos.push.enabled"

    init(session: DashboardSession) {
        let store = PushStore()
        self.store = store
        self.session = session
        self.server = store.server
        self.topic = store.topic
        self.device = store.device
        self.user = ""
        self.password = ""
        // Only when push is on: a Keychain item costs the person a password to open, and one for a
        // feature that is off is a password for nothing.
        if UserDefaults.standard.bool(forKey: Self.enabledKey),
           case .basic(let name, let secret)? = store.loadCredentials()?.kind {
            self.user = name
            self.password = secret
        }
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// A topic name for a Mac that has none: ntfy topics for pushes all start with `up`.
    var suggestedTopic: String {
        "up" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }

    /// Starts the listener again when the app opens and push was on.
    func restoreIfEnabled() async {
        guard isEnabled, !topic.isEmpty, case .off = state else { return }
        do {
            try await startListening()
        } catch {
            state = .failed(ErrorMessage.of(error))
        }
    }

    func enable() async {
        state = .connecting
        detail = nil
        do {
            if server.trimmingCharacters(in: .whitespaces).isEmpty {
                throw PushSetupError.noServer
            }
            if topic.trimmingCharacters(in: .whitespaces).isEmpty {
                topic = suggestedTopic
            }
            guard let ntfy = NtfyTopic(address: server + "/" + topic) else {
                throw PushSetupError.badTopic
            }
            store.server = ntfy.base.absoluteString
            store.topic = ntfy.topic
            if !user.isEmpty || !password.isEmpty {
                try store.saveCredentials(user: user, password: password)
            }

            let keys = try keysForSubscription()
            let token = try await session.accessToken()
            try await PushAPI(endpoint: session.endpoint).register(
                PushSubscription(endpoint: ntfy.endpoint, keys: keys, name: "Hermes for macOS", device: device),
                token: token
            )
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
            try await startListening()
        } catch {
            state = .failed(ErrorMessage.of(error))
        }
    }

    func disable() async {
        let keys = store.loadKeys()
        if let listener { await listener.stop() }
        listener = nil
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        state = .off
        store.forgetCredentials()

        guard let keys, !store.topic.isEmpty,
              let ntfy = NtfyTopic(address: store.server + "/" + store.topic),
              let token = try? await session.accessToken() else { return }
        _ = keys
        try? await PushAPI(endpoint: session.endpoint).unregister(endpoint: ntfy.endpoint, token: token)
    }

    /// Asks the dashboard to push to every subscription — this Mac and the phone alike.
    func sendTest() async {
        do {
            try await PushAPI(endpoint: session.endpoint).test(token: try await session.accessToken())
            detail = "The dashboard pushed to every subscriber, this Mac and the phone alike."
        } catch {
            detail = ErrorMessage.of(error)
        }
    }

    private func startListening() async throws {
        guard let ntfy = NtfyTopic(address: store.server + "/" + store.topic) else {
            throw PushSetupError.badTopic
        }
        let keys = try keysForSubscription()
        if let listener { await listener.stop() }
        let listener = PushListener(
            topic: ntfy,
            credentials: store.loadCredentials(),
            keys: keys,
            onPush: { [weak self] push in
                Task { @MainActor in
                    self?.lastPush = push
                    TurnNotifier.shared.pushArrived(push)
                }
            },
            onState: { [weak self] listenerState in
                Task { @MainActor in
                    guard let self else { return }
                    switch listenerState {
                    case .listening: self.state = .on
                    case .failed(let message): self.state = .failed(message)
                    case .idle: if self.state == .on { self.state = .off }
                    }
                }
            }
        )
        self.listener = listener
        await listener.start()
        state = .on
    }

    /// The keys of this Mac's subscription, made once and kept: the dashboard encrypts to them, and a
    /// new pair would make every push before it unreadable.
    private func keysForSubscription() throws -> PushKeys {
        if let known = store.loadKeys() { return known }
        let made = try PushKeys()
        try store.saveKeys(made)
        return made
    }
}

enum PushSetupError: Error, Equatable {
    case noServer
    case badTopic
}
