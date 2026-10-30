import Foundation

/// Whether this Mac is on a tailnet, and whether an address belongs to one.
///
/// A dashboard published only on the tailnet answers a name that resolves to an address from
/// `100.64.0.0/10` or `fd7a:115c:a1e0::/48` — Tailscale's two ranges. With Tailscale off, that address
/// has no route and a request to it hangs until the timeout, so the client asks the two questions
/// before it opens a connection and says what is wrong instead.
public enum Tailnet {
    /// `100.64.0.0/10`, the range a tailnet hands out.
    public static func isTailnet(ipv4 address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// `fd7a:115c:a1e0::/48`, the IPv6 range of a tailnet.
    public static func isTailnet(ipv6 address: String) -> Bool {
        let bare = address.split(separator: "%").first.map(String.init) ?? address
        let groups = bare.lowercased().split(separator: ":", omittingEmptySubsequences: false).prefix(3)
        guard groups.count == 3 else { return false }
        return groups.joined(separator: ":") == "fd7a:115c:a1e0"
    }

    public static func isTailnet(address: String) -> Bool {
        address.contains(":") ? isTailnet(ipv6: address) : isTailnet(ipv4: address)
    }

    /// True when [host] is a tailnet address itself or resolves to one. A name of a dashboard that
    /// lives on the tailnet is a public-looking name, so the answer is in the resolution.
    public static func isTailnet(host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !bare.isEmpty else { return false }
        if isTailnet(address: bare) { return true }
        return resolvedAddresses(of: bare).contains(where: isTailnet(address:))
    }

    /// True when any interface of this Mac carries a tailnet address, which is what Tailscale does
    /// while it runs.
    public static func isUp() -> Bool {
        addresses().contains(where: isTailnet(address:))
    }

    /// Every address of every interface of this Mac.
    public static func addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var addresses: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            if let address = interface.ifa_addr {
                let family = address.pointee.sa_family
                if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        addresses.append(text(host))
                    }
                }
            }
            pointer = interface.ifa_next
        }
        return addresses
    }

    /// The text of a name written into a C buffer, up to its first zero.
    private static func text(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The addresses a name resolves to, without opening a connection.
    public static func resolvedAddresses(of host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info else { return [] }
        defer { freeaddrinfo(info) }

        var addresses: [String] = []
        var pointer: UnsafeMutablePointer<addrinfo>? = first
        while let current = pointer {
            if let address = current.pointee.ai_addr {
                var number = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, current.pointee.ai_addrlen, &number, socklen_t(number.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.append(text(number))
                }
            }
            pointer = current.pointee.ai_next
        }
        return addresses
    }
}

/// A reason to stop before anything goes over the network.
public enum ConnectRefusal: Equatable, Sendable {
    /// The dashboard resolves to a tailnet address, and this Mac has no tailnet route: a request
    /// would hang for its whole timeout instead of failing.
    case tailnetIsDown
    /// The name only exists inside the tailnet and does not resolve at all without Tailscale.
    case tailnetNameNotResolved

    public var message: String {
        switch self {
        case .tailnetIsDown:
            return "This dashboard is on your tailnet, and Tailscale is not running on this Mac. Turn Tailscale on, then connect again."
        case .tailnetNameNotResolved:
            return "That name exists only inside your tailnet, and Tailscale is not running on this Mac. Turn Tailscale on, then connect again."
        }
    }
}

public enum ConnectPreflight {
    /// Names that a tailnet is the only place for.
    static let tailnetSuffixes = [".internal", ".ts.net", ".mesh"]

    public static func refusal(host: String?, addresses: [String], tailnetUp: Bool) -> ConnectRefusal? {
        guard let host, !host.isEmpty, !tailnetUp else { return nil }
        if addresses.contains(where: Tailnet.isTailnet(address:)) {
            return .tailnetIsDown
        }
        if addresses.isEmpty {
            let lowered = host.lowercased()
            if tailnetSuffixes.contains(where: lowered.hasSuffix) {
                return .tailnetNameNotResolved
            }
        }
        return nil
    }
}
