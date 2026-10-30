import SwiftUI

@main
struct HermesApp: App {
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
