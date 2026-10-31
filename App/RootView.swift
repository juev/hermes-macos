import SwiftUI

/// What the window shows: the dashboard address until one is connected, then its chats.
struct RootView: View {
    @State private var connection = ConnectionModel()

    var body: some View {
        content
            .task { prepareNotifications() }
            .task { await connection.restore() }
    }

    @ViewBuilder
    private var content: some View {
        if case .connected = connection.phase,
           let session = connection.dashboardSession,
           let gateway = connection.gatewaySession,
           let hub = connection.chatHub {
            ChatScreen(
                session: session,
                gateway: gateway,
                hub: hub,
                tailnet: connection.tailnet,
                gatewayState: connection.gateway,
                onDisconnect: { connection.disconnect() }
            )
                .id(session.endpoint)
        } else if connection.isRestoring {
            // The address is known and the tokens are being read: asking for the address again would
            // be asking a question the app can answer itself.
            RestoringView(address: connection.address)
        } else {
            ConnectView(model: connection)
        }
    }

    private func prepareNotifications() {
        TurnNotifier.shared.prepare()
    }
}
