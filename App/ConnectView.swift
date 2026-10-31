import HermesCore
import SwiftUI

/// The first screen of a new install: the address of a dashboard, then the sign-in it asks for.
/// Everything is checked before it goes over the network, so a typo costs a moment rather than a
/// browser sign-in that fails at the end.
struct ConnectView: View {
    @Bindable var model: ConnectionModel
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            form
                .padding(.top, 28)
            Spacer(minLength: 24)
            footer
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { addressFocused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hermes")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .tracking(-0.5)
            Text("A client for the dashboard of your Hermes Agent.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Server address")
                .font(.subheadline.weight(.medium))
            TextField("hermes.example.test:8443", text: $model.address)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($addressFocused)
                .frame(maxWidth: 380)
                .disabled(model.isBusy)
                .onSubmit { model.connect() }

            hint
                .frame(height: 34, alignment: .topLeading)

            tailnetRoute

            HStack(spacing: 12) {
                Button(model.isBusy ? "Connecting…" : "Connect") { model.connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canConnect)

                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                    Button("Cancel", role: .cancel) { model.cancel() }
                        .buttonStyle(.link)
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var hint: some View {
        switch model.phase {
        case .idle:
            VStack(alignment: .leading, spacing: 4) {
                if model.address.isEmpty {
                    Text("A bare host name gets https. A dashboard on the tailnet answers on its MagicDNS name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let endpoint = model.endpoint {
                    Text(endpoint.base.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("That is not an address.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        case .checking:
            Text("Asking the dashboard what it needs…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .joiningTailnet:
            VStack(alignment: .leading, spacing: 4) {
                Text("Joining the tailnet before asking the dashboard…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.tailnet.status.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if case .needsLogin = model.tailnet.phase {
                    Button("Open the sign-in page") { model.tailnet.openLoginPage() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        case .waitingForBrowser:
            Text("Finish signing in in your browser. The dashboard needs to confirm who you are.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .connected(let status):
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(verbatim: "Connected to \(model.endpoint?.base.host ?? "the dashboard")" + (status.version.map { " · v\($0)" } ?? ""))
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.caption)
                Text(gatewayText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if model.needsTailscale {
                    Button("Open Tailscale") { model.openTailscale() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                if case .needsLogin = model.tailnet.phase {
                    Button("Open the sign-in page") { model.tailnet.openLoginPage() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    /// The route onto a tailnet this app joins itself. It belongs on this screen rather than behind
    /// Settings: the dashboard that needs it is the one that would open the window Settings lives in.
    private var tailnetRoute: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .frame(maxWidth: 380)
                .padding(.vertical, 2)
            Toggle("Reach the dashboard through the built-in tailnet", isOn: Binding(
                get: { model.tailnet.isEnabled },
                set: { model.tailnet.setEnabled($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            .disabled(model.isBusy || (!model.tailnet.isAvailable && !model.tailnet.isEnabled))

            if model.tailnet.isEnabled {
                VStack(alignment: .leading, spacing: 3) {
                    Text("control server — a Headscale instance, or empty for Tailscale")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("https://headscale.example.org", text: Binding(
                        get: { model.tailnet.settings.controlURL },
                        set: { model.tailnet.setControlURL($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: 380)
                    .disabled(model.isBusy)
                }
                tailnetState
            }

            if !model.tailnet.isAvailable {
                Text("This build carries no tailnet node: Settings → Tailnet says how to build one.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Where the node stands, and the one button that moves it along.
    private var tailnetState: some View {
        HStack(spacing: 10) {
            Text(model.tailnet.status.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if case .needsLogin = model.tailnet.phase {
                Button("Open the sign-in page") { model.tailnet.openLoginPage() }
                    .buttonStyle(.link)
                    .font(.caption2)
            }
            if model.tailnet.isRunning {
                Button("Leave") { model.tailnet.leave() }
                    .buttonStyle(.link)
                    .font(.caption2)
            } else {
                Button("Join now") { Task { try? await model.tailnet.bringUp() } }
                    .buttonStyle(.link)
                    .font(.caption2)
                    .disabled(model.isBusy || !model.tailnet.isAvailable)
            }
            Spacer(minLength: 0)
        }
    }

    private var gatewayText: String {
        switch model.gateway {
        case .idle, .connecting: return "Opening the socket…"
        case .ready: return "The socket is ready."
        case .waiting: return "The socket dropped. Trying again…"
        case .failed(let reason): return reason
        case .stopped: return "The socket is closed."
        }
    }

    private var footer: some View {
        Text("The address stays on this Mac. The tokens are kept in your keychain.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

#Preview {
    ConnectView(model: ConnectionModel())
}
