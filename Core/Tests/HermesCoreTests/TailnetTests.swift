import Testing
@testable import HermesCore

@Suite("A dashboard on the tailnet")
struct TailnetTests {
    @Test("The IPv4 range Tailscale hands out")
    func ipv4Range() {
        #expect(Tailnet.isTailnet(ipv4: "100.64.0.2"))
        #expect(Tailnet.isTailnet(ipv4: "100.127.255.254"))
        #expect(!Tailnet.isTailnet(ipv4: "100.63.255.255"))
        #expect(!Tailnet.isTailnet(ipv4: "100.128.0.1"))
        #expect(!Tailnet.isTailnet(ipv4: "192.168.1.1"))
        #expect(!Tailnet.isTailnet(ipv4: "not-an-address"))
        #expect(!Tailnet.isTailnet(ipv4: "100.64.0"))
        #expect(!Tailnet.isTailnet(ipv4: "100.999.0.1"))
    }

    @Test("The IPv6 range")
    func ipv6Range() {
        #expect(Tailnet.isTailnet(ipv6: "fd7a:115c:a1e0::8"))
        #expect(Tailnet.isTailnet(ipv6: "FD7A:115C:A1E0:0000::0002"))
        #expect(Tailnet.isTailnet(ipv6: "fd7a:115c:a1e0::2%en0"))
        #expect(!Tailnet.isTailnet(ipv6: "fd7a:115c:a1e1::8"))
        #expect(!Tailnet.isTailnet(ipv6: "fe80::1"))
        #expect(!Tailnet.isTailnet(ipv6: "2001:db8::1"))
    }

    @Test("An address is read as the right family")
    func family() {
        #expect(Tailnet.isTailnet(address: "100.64.0.2"))
        #expect(Tailnet.isTailnet(address: "fd7a:115c:a1e0::8"))
        #expect(!Tailnet.isTailnet(address: "127.0.0.1"))
        #expect(!Tailnet.isTailnet(address: "::1"))
    }

    @Test("A name that resolves to a tailnet address is a tailnet host")
    func localhost() {
        // A test must not need the network; a loopback name is one that resolves anywhere.
        #expect(!Tailnet.isTailnet(host: "127.0.0.1"))
        #expect(!Tailnet.isTailnet(host: "localhost"))
        #expect(!Tailnet.isTailnet(host: ""))
    }

    @Test("This Mac has at least one address")
    func addresses() {
        #expect(!Tailnet.addresses().isEmpty)
    }

    @Test("The refusal is the tailnet's and nothing else")
    func refusal() {
        // A public name that resolves to a tailnet address.
        #expect(ConnectPreflight.refusal(host: "hermes.example.test", addresses: ["100.64.0.2"], tailnetUp: false) == .tailnetIsDown)
        #expect(ConnectPreflight.refusal(host: "hermes.example.test", addresses: ["100.64.0.2"], tailnetUp: true) == nil)
        // A public dashboard: not the tailnet's business.
        #expect(ConnectPreflight.refusal(host: "hermes.example.test", addresses: ["203.0.113.7"], tailnetUp: false) == nil)
        // A name that only a tailnet has.
        #expect(ConnectPreflight.refusal(host: "loffe.mesh.internal", addresses: [], tailnetUp: false) == .tailnetNameNotResolved)
        #expect(ConnectPreflight.refusal(host: "loffe.mesh.internal", addresses: [], tailnetUp: true) == nil)
        #expect(ConnectPreflight.refusal(host: "loffe.example.ts.net", addresses: [], tailnetUp: false) == .tailnetNameNotResolved)
        #expect(ConnectPreflight.refusal(host: "nowhere.example.test", addresses: [], tailnetUp: false) == nil)
        #expect(ConnectPreflight.refusal(host: nil, addresses: ["100.64.0.2"], tailnetUp: false) == nil)
        #expect(ConnectPreflight.refusal(host: "", addresses: ["100.64.0.2"], tailnetUp: false) == nil)
        #expect(ConnectRefusal.tailnetIsDown.message.contains("Tailscale"))
        #expect(ConnectRefusal.tailnetNameNotResolved.message.contains("tailnet"))
    }
}
