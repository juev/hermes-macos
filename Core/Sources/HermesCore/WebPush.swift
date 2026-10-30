import CryptoKit
import Foundation

/// The keys a push subscription holds: the private half of the pair the dashboard encrypted to, and
/// the auth secret both sides share.
public struct PushKeys: Sendable, Equatable {
    /// The subscription's private key, DER-encoded PKCS#8 as the client keeps it.
    public let privateKeyDER: Data
    /// The uncompressed public point, `p256dh` in the subscription, 65 bytes.
    public let publicKey: Data
    /// 16 bytes, `auth` in the subscription.
    public let authSecret: Data

    public init(privateKeyDER: Data, publicKey: Data, authSecret: Data) {
        self.privateKeyDER = privateKeyDER
        self.publicKey = publicKey
        self.authSecret = authSecret
    }

    /// A fresh subscription: a P-256 pair and a random auth secret.
    public init() throws {
        let key = P256.KeyAgreement.PrivateKey()
        privateKeyDER = key.derRepresentation
        publicKey = key.publicKey.x963Representation
        authSecret = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    }

    public var privateKey: P256.KeyAgreement.PrivateKey {
        get throws { try P256.KeyAgreement.PrivateKey(derRepresentation: privateKeyDER) }
    }
}

public enum WebPushError: Error, Equatable {
    /// The body is shorter than the header it announces.
    case malformedBody
    /// The key the dashboard used is not a P-256 point.
    case badServerKey
    /// The body does not open with these keys: another subscription, or a corrupted body.
    case cannotOpen
}

/// What arrives in a push from `hermes-push`: a finished turn, small enough to show without asking
/// the dashboard anything.
public struct PushMessage: Sendable, Equatable {
    public let type: String
    public let sessionID: String?
    public let platform: String?
    public let job: String?
    public let preview: String

    public init(type: String, sessionID: String? = nil, platform: String? = nil, job: String? = nil, preview: String = "") {
        self.type = type
        self.sessionID = sessionID
        self.platform = platform
        self.job = job
        self.preview = preview
    }

    public init(_ json: JSONValue) {
        self.init(
            type: json["type"]?.stringValue ?? "",
            sessionID: json["session_id"]?.scalarString,
            platform: json["platform"]?.stringValue,
            job: json["job"]?.scalarString,
            preview: json["preview"]?.stringValue ?? ""
        )
    }

    /// The line a notification shows: the preview folded to one line.
    public var oneLine: String {
        preview.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// The receiving half of Web Push (RFC 8291 with RFC 8188 content encoding), as `hermes-push` sends
/// it: the body is aes128gcm for one record, and only the holder of the subscription's key can open it.
public enum WebPush {
    /// The body of one push, opened into the JSON `hermes-push` sent.
    public static func decrypt(_ body: Data, keys: PushKeys) throws -> Data {
        // salt(16) | rs(4) | idlen(1) | keyid(idlen) | ciphertext
        guard body.count > 21 else { throw WebPushError.malformedBody }
        let salt = body.subdata(in: 0..<16)
        let headerEnd = 21
        let keyLength = Int(body[20])
        guard keyLength > 0, body.count > headerEnd + keyLength + 16 else { throw WebPushError.malformedBody }
        let serverKeyBytes = body.subdata(in: headerEnd..<(headerEnd + keyLength))
        let sealed = body.subdata(in: (headerEnd + keyLength)..<body.count)

        guard let serverKey = try? P256.KeyAgreement.PublicKey(x963Representation: serverKeyBytes) else {
            throw WebPushError.badServerKey
        }
        let privateKey = try keys.privateKey
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: serverKey)

        // RFC 8291 §3.4: the auth secret clears the shared secret, then the two public keys bind the
        // result to this subscription.
        let info = Data("WebPush: info".utf8) + Data([0]) + keys.publicKey + serverKeyBytes
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        let prkKey = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: sharedBytes), salt: keys.authSecret)
        let ikm = HKDF<SHA256>.expand(pseudoRandomKey: prkKey, info: info, outputByteCount: 32)

        // RFC 8188 §2.2: the salt picks the record, and the two labels give the key and the nonce.
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: ikm, salt: salt)
        let contentKey = HKDF<SHA256>.expand(
            pseudoRandomKey: prk,
            info: Data("Content-Encoding: aes128gcm".utf8) + Data([0]),
            outputByteCount: 16
        )
        let nonceKey = HKDF<SHA256>.expand(
            pseudoRandomKey: prk,
            info: Data("Content-Encoding: nonce".utf8) + Data([0]),
            outputByteCount: 12
        )
        let nonce = nonceKey.withUnsafeBytes { Data($0) }

        let ciphertext = sealed.dropLast(16)
        let tag = sealed.suffix(16)
        let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
        guard let plain = try? AES.GCM.open(box, using: contentKey) else {
            throw WebPushError.cannotOpen
        }
        return stripPadding(plain)
    }

    /// RFC 8188 ends a record with a delimiter — `2` for the last one — and pads with zeros after it.
    static func stripPadding(_ plain: Data) -> Data {
        guard let last = plain.last else { return plain }
        var cut = plain.count
        if last == 0x02 || last == 0x01 {
            cut -= 1
        } else {
            while cut > 0, plain[cut - 1] == 0 { cut -= 1 }
            if cut > 0, plain[cut - 1] == 0x01 || plain[cut - 1] == 0x02 { cut -= 1 }
        }
        return plain.subdata(in: 0..<cut)
    }
}
