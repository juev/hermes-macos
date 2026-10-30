import SwiftUI

@main
struct HermesApp: App {
    init() {
        // Before anything reads a secret: what earlier builds kept in three Keychain items becomes
        // the one this build opens, so a launch asks for a password once.
        VaultMigration.runIfNeeded(vault: AppSecrets.vault)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Divider()
                Link("Hermes Agent on the web", destination: URL(string: "https://github.com/NousResearch/hermes-agent")!)
            }
        }
    }
}
