import SwiftUI

/// What the window shows: the dashboard address until one is connected, then its chats.
struct RootView: View {
    @State private var connection = ConnectionModel()

    var body: some View {
        if case .connected = connection.phase, let session = connection.dashboardSession {
            ChatScreen(session: session)
                .id(session.endpoint)
        } else {
            ConnectView(model: connection)
        }
    }
}
