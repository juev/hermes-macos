import HermesCore

/// The one Keychain item this app opens, shared by the tokens of the dashboard and the secrets of the
/// push, so a launch asks for a password once.
enum AppSecrets {
    static let vault = KeychainVault()
}
