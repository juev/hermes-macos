import HermesCore
import SwiftUI

/// The line under the toolbar that says the socket is not where it should be. A chat that has lost
/// its connection looks exactly like one where nothing happens, so it says so instead.
public struct ConnectionBanner: View {
    public let state: GatewaySession.State

    public init(state: GatewaySession.State) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 7) {
            switch state {
            case .connecting:
                ProgressView().controlSize(.mini)
            case .waiting:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9))
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9))
            case .idle, .ready, .stopped:
                EmptyView()
            }
            Text(words)
                .font(Theme.Fonts.sessionMeta)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Metrics.contentPadding)
        .padding(.vertical, 5)
        .background(Theme.Palette.toolBackground)
    }

    private var words: String {
        switch state {
        case .connecting: "Connecting to the dashboard…"
        case .waiting: "The connection dropped. Trying again…"
        case .failed(let reason): reason
        case .stopped: "The socket is closed; open another chat to connect again."
        case .idle, .ready: ""
        }
    }
}

/// The system clipboard, so an answer can leave the window.
public enum Clipboard {
    public static func copy(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
    }
}
