import Foundation
import Testing
@testable import HermesCore

@Suite("A tailnet this app joins itself")
struct TailnetNodeTests {
    @Test("The node's answer when it runs")
    func running() {
        let status = TailnetNodeStatus.decode("""
        {"state":"Running","ips":["100.64.0.7","fd7a:115c:a1e0::7"],"name":"hermes-macos.mesh.internal.","authUrl":""}
        """)
        #expect(status.state == .running)
        #expect(status.isRunning)
        #expect(status.addresses == ["100.64.0.7", "fd7a:115c:a1e0::7"])
        // The node writes the MagicDNS name with the dot DNS names end in; a person reads it without.
        #expect(status.dnsName == "hermes-macos.mesh.internal")
        #expect(status.summary == "On the tailnet as hermes-macos.mesh.internal.")
    }

    @Test("The node waiting for a sign-in carries the link")
    func needsLogin() {
        let status = TailnetNodeStatus.decode("""
        {"state":"NeedsLogin","authUrl":"https://scale.evsyukov.org/register/nodekey:abc","ips":[]}
        """)
        #expect(status.state == .needsLogin)
        #expect(status.needsSignIn)
        #expect(!status.isRunning)
        #expect(status.authURL?.absoluteString == "https://scale.evsyukov.org/register/nodekey:abc")
        #expect(status.summary.contains("sign-in"))
    }

    @Test("A node that failed says why")
    func failed() {
        let status = TailnetNodeStatus.decode(#"{"state":"Stopped","error":"listen: operation not permitted"}"#)
        #expect(status.state == .stopped)
        #expect(status.error == "listen: operation not permitted")
        #expect(TailnetNodeStatus.decode(#"{"state":"Error","error":"no state directory"}"#).summary.contains("no state directory"))
    }

    @Test("A state this client does not know yet is not fatal")
    func unknownState() {
        #expect(TailnetNodeStatus.decode(#"{"state":"SomethingNew"}"#).state == .unknown)
        #expect(TailnetNodeStatus.decode(#"{"state":"Running","ips":"not-a-list"}"#).addresses.isEmpty)
        #expect(TailnetNodeStatus.decode("not json").state == .unknown)
        #expect(TailnetNodeStatus.decode("{}") == .stopped)
    }

    @Test("The control server a person types")
    func controlServer() {
        #expect(TailnetControlServer.normalize("") == nil)
        #expect(TailnetControlServer.normalize("   ") == nil)
        #expect(TailnetControlServer.normalize("scale.evsyukov.org") == "https://scale.evsyukov.org")
        #expect(TailnetControlServer.normalize(" https://scale.evsyukov.org/ ") == "https://scale.evsyukov.org")
        #expect(TailnetControlServer.normalize("http://headscale.local:8080/") == "http://headscale.local:8080")
        #expect(TailnetControlServer.normalize("https://scale.evsyukov.org/?x=1#frag") == "https://scale.evsyukov.org")
        #expect(TailnetControlServer.normalize("https://") == nil)
    }

    @Test("The settings an empty control server means")
    func settings() {
        #expect(TailnetNodeSettings().controlServer == nil)
        #expect(TailnetNodeSettings(controlURL: "scale.evsyukov.org").controlServer == "https://scale.evsyukov.org")
        #expect(TailnetNodeSettings().hostname == "hermes-macos")
    }

    @Test("The proxy the node hands out")
    func proxy() {
        let proxy = TailnetProxy(address: "127.0.0.1:54321")
        #expect(proxy?.host == "127.0.0.1")
        #expect(proxy?.port == 54321)
        #expect(TailnetProxy(address: "127.0.0.1") == nil)
        #expect(TailnetProxy(address: "127.0.0.1:0") == nil)
        #expect(TailnetProxy(address: "127.0.0.1:70000") == nil)
        #expect(TailnetProxy(address: "") == nil)
    }

    @Test("A session sends its requests through the node")
    func transport() {
        let proxy = TailnetProxy(host: "127.0.0.1", port: 4321)
        let http = URLSessionTransport(timeout: 5, proxy: proxy)
        #expect(http.proxySettings?["HTTPProxy"] as? String == "127.0.0.1")
        #expect(http.proxySettings?["HTTPSPort"] as? Int == 4321)
        #expect((http.proxySettings?["HTTPEnable"] as? Int ?? 0) == 1)
        #expect((http.proxySettings?["HTTPSEnable"] as? Int ?? 0) == 1)

        // The socket of the dashboard takes the same route, which is how a `wss` address is carried.
        let socket = URLSessionSocketTransport(timeout: 5, proxy: proxy)
        #expect(socket.proxySettings?["HTTPSProxy"] as? String == "127.0.0.1")
        #expect(socket.proxySettings?["HTTPSPort"] as? Int == 4321)

        // No node, no proxy dictionary: the session keeps what the system says.
        #expect(URLSessionTransport().proxySettings == nil)
        #expect(URLSessionSocketTransport().proxySettings == nil)
    }
}
