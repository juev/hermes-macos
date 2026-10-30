import Foundation

/// The tokens the dashboard issued. The dashboard's own flow is `native_pkce`: the browser returns
/// a one-time code to the loopback address, the client trades it for these.
public struct Tokens: Sendable, Equatable, Codable {
    public let accessToken: String
    /// Empty when the identity provider does not rotate it; the old one stays valid.
    public let refreshToken: String
    /// Unix seconds; `0` means the server gave no expiry.
    public let expiresAt: Int64
    public let provider: String
    public let userID: String

    public init(accessToken: String, refreshToken: String = "", expiresAt: Int64 = 0, provider: String = "", userID: String = "") {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.provider = provider
        self.userID = userID
    }

    /// True while the access token can be sent; the caller passes the skew it wants before expiry.
    public func isValid(at now: Date = .now, skew: TimeInterval = 0) -> Bool {
        guard expiresAt != 0 else { return true }
        return Int64(now.timeIntervalSince1970) < expiresAt - Int64(skew)
    }

    public var canRefresh: Bool { !refreshToken.isEmpty }
}

public enum TokensError: Error, Equatable {
    case missingAccessToken
}

extension Tokens {
    /// Reads the answer of `auth/native/token` and `auth/native/refresh`. Fields a provider omits
    /// keep the value of [previous], because a refresh need not repeat the provider or the user.
    public init(serverAnswer json: JSONValue, previous: Tokens? = nil) throws {
        guard let accessToken = json["access_token"]?.stringValue, !accessToken.isEmpty else {
            throw TokensError.missingAccessToken
        }
        let refresh = json["refresh_token"]?.stringValue ?? ""
        let expiresAt = json["expires_at"]?.numericValue.map { Int64($0) } ?? 0
        let provider = json["provider"]?.stringValue ?? ""
        let userID = json["user_id"]?.stringValue ?? ""
        self.init(
            accessToken: accessToken,
            refreshToken: refresh.isEmpty ? previous?.refreshToken ?? "" : refresh,
            expiresAt: expiresAt == 0 ? previous?.expiresAt ?? 0 : expiresAt,
            provider: provider.isEmpty ? previous?.provider ?? "" : provider,
            userID: userID.isEmpty ? previous?.userID ?? "" : userID
        )
    }
}

/// What `/api/status` says before anyone signs in.
public struct ServerStatus: Sendable, Equatable {
    public let authRequired: Bool
    /// The flows the dashboard offers, `native_pkce` among them when the browser sign-in works.
    public let authFlows: [String]
    /// The identity providers it can send the browser to.
    public let authProviders: [String]
    public let version: String?

    public init(authRequired: Bool, authFlows: [String], authProviders: [String], version: String?) {
        self.authRequired = authRequired
        self.authFlows = authFlows
        self.authProviders = authProviders
        self.version = version
    }

    public init(_ json: JSONValue) {
        self.init(
            authRequired: json["auth_required"]?.boolValue ?? false,
            authFlows: json["auth_flows"]?.stringArray ?? [],
            authProviders: json["auth_providers"]?.stringArray ?? [],
            version: json["version"]?.stringValue
        )
    }

    public var supportsNativePKCE: Bool { authFlows.contains("native_pkce") }
}
