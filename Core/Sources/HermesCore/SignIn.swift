import CryptoKit
import Foundation

/// A PKCE pair (RFC 7636) and the state that ties the callback to this sign-in.
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public let state: String

    public init(verifier: String, challenge: String, state: String) {
        self.verifier = verifier
        self.challenge = challenge
        self.state = state
    }

    /// A fresh pair: 32 random bytes for the verifier, 24 for the state, both base64url without
    /// padding, as the Kotlin client makes them.
    public static func make() -> PKCE {
        let verifier = randomURLSafe(byteCount: 32)
        return PKCE(verifier: verifier, challenge: challenge(for: verifier), state: randomURLSafe(byteCount: 24))
    }

    /// `BASE64URL(SHA256(ASCII(verifier)))`, the `S256` method the dashboard requires.
    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    static func randomURLSafe(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// What came back to the loopback address after the browser part of the sign-in.
public enum CallbackResult: Sendable, Equatable {
    case code(code: String, state: String)
    case error(code: String, description: String?)
}

public enum SignIn {
    /// The address the browser opens. The dashboard accepts a native redirect only on the loopback
    /// interface, and sends the browser on to the identity provider itself.
    public static func authorizeURL(
        endpoint: Endpoint,
        redirectURI: String,
        pkce: PKCE,
        provider: String? = nil
    ) -> URL {
        var items = [
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: pkce.state)
        ]
        if let provider, !provider.isEmpty {
            items.append(URLQueryItem(name: "provider", value: provider))
        }
        return endpoint.url("auth/native/authorize", query: items)
    }

    /// Reads the request target of the callback, `/callback?code=…&state=…`. Nil when the request is
    /// not the callback at all, e.g. a browser asking for its favicon.
    public static func parseCallback(_ target: String) -> CallbackResult? {
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        guard path == "/callback" else { return nil }
        let raw = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
        let query = queryParameters(raw)
        if let error = query["error"], !error.isEmpty {
            return .error(code: error, description: query["error_description"])
        }
        return .code(code: query["code"] ?? "", state: query["state"] ?? "")
    }

    /// A query string as a dictionary, percent-decoded. `+` is a space, as in a browser's form post.
    public static func queryParameters(_ raw: String) -> [String: String] {
        var parameters: [String: String] = [:]
        for pair in raw.split(separator: "&") where !pair.isEmpty {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = decode(parts.first.map(String.init) ?? "")
            let value = parts.count > 1 ? decode(String(parts[1])) : ""
            parameters[key] = value
        }
        return parameters
    }

    private static func decode(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
    }
}
