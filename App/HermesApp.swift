import SwiftUI

@main
struct HermesApp: App {
    var body: some Scene {
        WindowGroup {
            ConnectView()
        }
        .defaultSize(width: 760, height: 560)
        .commands {
            CommandGroup(after: .appInfo) {
                Divider()
                Link("Hermes Agent on the web", destination: URL(string: "https://github.com/NousResearch/hermes-agent")!)
            }
        }
    }
}
