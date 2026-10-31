import AppKit
import Foundation
import HermesCore
import Observation

/// The tailnet this app carries itself: a userspace Tailscale node in the app, pointed at Tailscale
/// or at a Headscale instance, and the proxy its HTTP and socket traffic takes while it runs.
///
/// This is the route for a Mac that has no Tailscale app, or has one that is off: the node joins the
/// tailnet before the client asks the dashboard anything, and the sign-in link the control server
/// hands out opens in the browser. The tokens the Keychain already holds work over it; a browser
/// sign-in does not, because the browser does not take this node's route (see README).
@MainActor
@Observable
final class TailnetModel {
    enum Phase: Equatable {
        /// The route is off: the app talks to the dashboard as the system network reaches it.
        case off
        /// The route is on and the node is not started.
        case idle
        case starting
        /// The control server wants the node signed in; the link opens the page that does it.
        case needsLogin(URL?)
        /// The node runs; the name is what it is called on the tailnet, when it knows.
        case running(String?)
        case failed(String)
    }

    /// What the person chose, kept between launches.
    struct Settings: Equatable {
        var enabled: Bool
        var controlURL: String
        var hostname: String

        static let hostname = "hermes-macos"
    }

    private(set) var settings: Settings
    private(set) var phase: Phase
    private(set) var status: TailnetNodeStatus = .stopped
    /// The proxy the sessions take once the node runs.
    private(set) var proxy: TailnetProxy?

    private let node: any TailnetNode
    private let defaults: UserDefaults
    private var poller: Task<Void, Never>?
    /// The link already opened, so a state that keeps repeating opens one browser tab, not twenty.
    private var openedLogin: URL?

    private enum Key {
        static let enabled = "org.evsyukov.hermes.macos.tailnet.enabled"
        static let controlURL = "org.evsyukov.hermes.macos.tailnet.control"
        static let hostname = "org.evsyukov.hermes.macos.tailnet.hostname"
    }

    init(node: any TailnetNode = UserSpaceTailnetNode(), defaults: UserDefaults = .standard) {
        self.node = node
        self.defaults = defaults
        let settings = Settings(
            enabled: defaults.bool(forKey: Key.enabled),
            controlURL: defaults.string(forKey: Key.controlURL) ?? "",
            hostname: defaults.string(forKey: Key.hostname) ?? Settings.hostname
        )
        self.settings = settings
        phase = settings.enabled ? .idle : .off
    }

    var isAvailable: Bool { node.isAvailable }
    var isEnabled: Bool { settings.enabled }
    var isRunning: Bool { status.isRunning }

    /// The control server the node joins, as a person reads it.
    var controlServerText: String {
        if let server = settings.controlStripped { return server }
        return "Tailscale"
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != settings.enabled else { return }
        settings.enabled = enabled
        defaults.set(enabled, forKey: Key.enabled)
        if !enabled {
            leave()
        } else {
            phase = .idle
        }
    }

    func setControlURL(_ text: String) {
        settings.controlURL = text
        defaults.set(text, forKey: Key.controlURL)
    }

    func setHostname(_ text: String) {
        settings.hostname = text
        defaults.set(text, forKey: Key.hostname)
    }

    /// The node's own settings: the control server normalized, the hostname as typed or the default.
    private var nodeSettings: TailnetNodeSettings {
        let hostname = settings.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        return TailnetNodeSettings(
            controlURL: settings.controlURL,
            authKey: "",
            hostname: hostname.isEmpty ? Settings.hostname : hostname
        )
    }

    /// Starts the node unless it runs, and waits until the tailnet is there. The proxy it returns is
    /// what the dashboard's sessions take.
    ///
    /// A node that waits for a sign-in keeps this waiting: the page opens in the browser, and the
    /// person finishing it there is what makes the node run.
    func bringUp(timeout: Duration = .seconds(180)) async throws -> TailnetProxy {
        guard node.isAvailable else { throw TailnetNodeError.notInThisBuild }
        if let proxy, status.isRunning { return proxy }

        if proxy == nil {
            let settings = nodeSettings
            let directory = Self.stateDirectory()
            let node = self.node
            phase = .starting
            Log.app.notice("tailnet: starting the node for \(settings.controlServer ?? "Tailscale", privacy: .public)")
            do {
                let started = try await Task.detached(priority: .userInitiated) {
                    try node.start(settings, directory: directory)
                }.value
                proxy = started
            } catch {
                Log.app.error("tailnet: the node did not start: \(ErrorMessage.of(error), privacy: .public)")
                phase = .failed(ErrorMessage.of(error))
                throw error
            }
            startPolling()
        }

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if status.isRunning, let proxy { return proxy }
            if case .failed(let message) = phase {
                throw TailnetJoinFailure(message: message)
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        throw TailnetNodeError.timedOut
    }

    /// Leaves the tailnet: the node closes, its state stays for the next start.
    func leave() {
        poller?.cancel()
        poller = nil
        let node = self.node
        _ = Task.detached(priority: .utility) { node.stop() }
        proxy = nil
        status = .stopped
        openedLogin = nil
        phase = settings.enabled ? .idle : .off
    }

    /// The last lines the node wrote. When it does not come up, this is the one thing that says why:
    /// the control server's answer, a socket the sandbox refused, a name it could not resolve.
    func logs() async -> String {
        let node = self.node
        return await Task.detached(priority: .utility) { node.logs() }.value
    }

    /// Opens the sign-in page the control server handed out, and the Tailscale app, which is the way
    /// onto the tailnet for a Mac that has one.
    func openLoginPage() {
        let url: URL?
        if case .needsLogin(let known) = phase {
            url = known
        } else {
            url = status.authURL
        }
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    private func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let node = self.node
                let status = await Task.detached(priority: .utility) { node.status() }.value
                guard !Task.isCancelled else { return }
                self.apply(status)
                // A node that runs is followed slowly: nothing on screen depends on a second.
                try? await Task.sleep(for: .milliseconds(status.isRunning ? 5000 : 1000))
            }
        }
    }

    private func apply(_ status: TailnetNodeStatus) {
        self.status = status
        switch status.state {
        case .running:
            phase = .running(status.dnsName ?? status.addresses.first)
            openedLogin = nil
        case .starting, .needsLogin:
            // Both wait for the browser: a node that starts under a fresh account shows the link
            // once the control server has made it.
            if let url = status.authURL {
                phase = .needsLogin(url)
                if url != openedLogin {
                    openedLogin = url
                    Log.app.notice("tailnet: sign-in needed, opening the page")
                    NSWorkspace.shared.open(url)
                }
            } else {
                phase = .starting
            }
        case .error:
            phase = .failed(status.error ?? "the tailnet node stopped")
        case .stopped:
            phase = .idle
        case .unknown:
            break
        }
    }

    /// Where the node keeps its key: the app's own container, so a Mac that leaves the tailnet and
    /// comes back is the same node.
    static func stateDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("Hermes/tailnet", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// The node's own refusal, carried as the sentence the window shows.
struct TailnetJoinFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension TailnetModel.Settings {
    /// The control server as the field means it: nil stands for Tailscale's own.
    var controlStripped: String? {
        TailnetControlServer.normalize(controlURL)
    }
}
