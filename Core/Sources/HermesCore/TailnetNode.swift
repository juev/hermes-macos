import Foundation

#if canImport(HermesTailnet)
import HermesTailnet
#endif

/// A tailnet this app joins itself: a userspace Tailscale node, bound from `tailnet/`, which speaks
/// to Tailscale's control plane or to a Headscale instance and reaches the dashboard from there.
///
/// The node needs no tunnel device and no VPN entitlement, so it runs beside the Tailscale app and
/// beside another VPN. What it produces is a proxy on `127.0.0.1`, and the transports of this client
/// send their requests through it — the dashboard, its socket and the files it hands over.
public struct TailnetNodeSettings: Sendable, Equatable {
    /// The control server: `https://headscale.example.org` for Headscale, empty for Tailscale.
    public var controlURL: String
    /// A Headscale pre-auth key, or empty to sign in through the link the node prints.
    public var authKey: String
    /// The name this Mac takes on the tailnet.
    public var hostname: String

    public init(controlURL: String = "", authKey: String = "", hostname: String = "hermes-macos") {
        self.controlURL = controlURL
        self.authKey = authKey
        self.hostname = hostname
    }

    /// The control server as the node wants it, or nil for Tailscale's own.
    public var controlServer: String? { TailnetControlServer.normalize(controlURL) }
}

/// The address a person types into the control server field, and what the node should be given.
public enum TailnetControlServer {
    /// `headscale.example.org/` reads as `https://headscale.example.org`; empty reads as nil, which
    /// is Tailscale's own control plane.
    public static func normalize(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme), components.host?.isEmpty == false else {
            return nil
        }
        if components.scheme == nil { components.scheme = "https" }
        components.query = nil
        components.fragment = nil
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url?.absoluteString
    }

    /// True for the control plane Tailscale runs, which the node reaches without a URL.
    public static func isTailscale(_ address: String) -> Bool {
        guard let host = URL(string: address)?.host?.lowercased() else { return false }
        return host == "controlplane.tailscale.com" || host == "login.tailscale.com"
    }
}

/// The local proxy of a running node. URLSession carries HTTPS and WSS through a CONNECT and a plain
/// HTTP request in absolute form, and the node answers both.
public struct TailnetProxy: Sendable, Equatable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// Reads what the node answered: `127.0.0.1:54321`.
    public init?(address: String) {
        let parts = address.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port) else { return nil }
        self.host = String(parts[0])
        self.port = port
    }

    /// What a session takes in `connectionProxyDictionary`.
    public var settings: [String: Any] {
        [
            "HTTPEnable": 1,
            "HTTPProxy": host,
            "HTTPPort": port,
            "HTTPSEnable": 1,
            "HTTPSProxy": host,
            "HTTPSPort": port
        ]
    }
}

/// What the node says about itself, read from the JSON `Status` of the library.
public struct TailnetNodeStatus: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case stopped = "Stopped"
        case starting = "Starting"
        case needsLogin = "NeedsLogin"
        case running = "Running"
        case error = "Error"
        case unknown = "Unknown"

        /// A state the library may grow into and this client does not know yet.
        public init(raw: String) {
            self = State(rawValue: raw) ?? .unknown
        }
    }

    public var state: State
    /// Where a person signs the node in, when the control server asks for that.
    public var authURL: URL?
    public var addresses: [String]
    /// The MagicDNS name of this Mac on the tailnet, without its trailing dot.
    public var dnsName: String?
    /// What the node said when it could not answer: a state, not a sentence for a person.
    public var error: String?

    public init(
        state: State = .stopped,
        authURL: URL? = nil,
        addresses: [String] = [],
        dnsName: String? = nil,
        error: String? = nil
    ) {
        self.state = state
        self.authURL = authURL
        self.addresses = addresses
        self.dnsName = dnsName
        self.error = error
    }

    public static let stopped = TailnetNodeStatus()

    public var isRunning: Bool { state == .running }

    /// A node that is up and reachable but waiting for the person to sign it in.
    public var needsSignIn: Bool { state == .needsLogin }

    /// One line for the settings window.
    public var summary: String {
        switch state {
        case .running:
            if let dnsName, !dnsName.isEmpty { return "On the tailnet as \(dnsName)." }
            if let address = addresses.first { return "On the tailnet as \(address)." }
            return "On the tailnet."
        case .starting:
            return "Joining the tailnet…"
        case .needsLogin:
            return "Waiting for a sign-in in the browser."
        case .error:
            return "The tailnet node stopped: \(error ?? "it did not say why")."
        case .stopped:
            return "Not on the tailnet: the node is not running."
        case .unknown:
            return "The tailnet node did not answer."
        }
    }

    /// The node's answer, which is JSON whatever the state.
    public static func decode(_ json: String) -> TailnetNodeStatus {
        guard let value = try? JSONValue.decode(Data(json.utf8)) else { return TailnetNodeStatus(state: .unknown) }
        var status = TailnetNodeStatus(state: State(raw: value["state"]?.stringValue ?? "Stopped"))
        if let text = value["authUrl"]?.stringValue, !text.isEmpty {
            status.authURL = URL(string: text)
        }
        status.addresses = value["ips"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        if let name = value["name"]?.stringValue, !name.isEmpty {
            status.dnsName = name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        if let error = value["error"]?.stringValue, !error.isEmpty {
            status.error = error
        }
        return status
    }
}

public enum TailnetNodeError: Error, Equatable {
    /// The build carries no node: `Core/Artifacts/HermesTailnet.xcframework` was not built.
    case notInThisBuild
    /// The node started but named no proxy address.
    case noProxy(String)
    /// The node did not come up in the time the client waited: a sign-in nobody finished, or a
    /// control server that does not answer.
    case timedOut

    public var message: String {
        switch self {
        case .notInThisBuild:
            return "This build has no built-in tailnet node. Build it with scripts/build-tailnet.sh."
        case .noProxy(let answer):
            return "The tailnet node named no proxy: \(answer.isEmpty ? "nothing" : answer)."
        case .timedOut:
            return "The tailnet node did not come up. If a sign-in page opened in the browser, finish it there and connect again."
        }
    }
}

extension TailnetNodeError: LocalizedError {
    public var errorDescription: String? { message }
}

/// The node behind the app's tailnet route: whatever carries it, the same four calls.
public protocol TailnetNode: Sendable {
    /// False when this build was made without the library, which the route then says instead of
    /// pretending to join.
    var isAvailable: Bool { get }
    /// Starts the node and returns the proxy that becomes usable once it runs. The state directory
    /// keeps the node key between launches.
    func start(_ settings: TailnetNodeSettings, directory: URL) throws -> TailnetProxy
    func stop()
    func status() -> TailnetNodeStatus
    func logs() -> String
}

/// The node of this build, bound from the Go package in `tailnet/`. Without the library in the build
/// the same type exists and says so: the app is not built in two shapes.
public struct UserSpaceTailnetNode: TailnetNode {
    public init() {}

    public var isAvailable: Bool {
        #if canImport(HermesTailnet)
        return true
        #else
        return false
        #endif
    }

    public func start(_ settings: TailnetNodeSettings, directory: URL) throws -> TailnetProxy {
        #if canImport(HermesTailnet)
        // gomobile exports the four functions of the Go package as C functions named after it, so
        // this is the whole binding: `HermesnetStart` answers "host:port" or fills the error.
        var failure: NSError?
        let answer = HermesnetStart(
            directory.path,
            settings.controlServer ?? "",
            settings.authKey,
            settings.hostname,
            &failure
        )
        if let failure { throw failure }
        guard let proxy = TailnetProxy(address: answer) else {
            throw TailnetNodeError.noProxy(answer)
        }
        return proxy
        #else
        _ = settings
        _ = directory
        throw TailnetNodeError.notInThisBuild
        #endif
    }

    public func stop() {
        #if canImport(HermesTailnet)
        HermesnetStop()
        #endif
    }

    public func status() -> TailnetNodeStatus {
        #if canImport(HermesTailnet)
        return TailnetNodeStatus.decode(HermesnetStatus())
        #else
        return .stopped
        #endif
    }

    public func logs() -> String {
        #if canImport(HermesTailnet)
        return HermesnetLogs()
        #else
        return ""
        #endif
    }
}
