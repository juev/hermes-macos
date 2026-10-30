import SwiftUI

/// What the window shows: the dashboard address until one is connected, then its chats.
struct RootView: View {
    @State private var connection = ConnectionModel()

    var body: some View {
        content
            .task { prepareNotifications() }
    }

    @ViewBuilder
    private var content: some View {
        if case .connected = connection.phase, let session = connection.dashboardSession, let gateway = connection.gatewaySession {
            ChatScreen(session: session, gateway: gateway)
                .id(session.endpoint)
        } else {
            ConnectView(model: connection)
        }
    }

    private func prepareNotifications() {
        TurnNotifier.shared.prepare()
    }
}
