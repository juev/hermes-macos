import HermesCore
import SwiftUI

/// The first screen of a new install: the address of a dashboard, then the sign-in it asks for.
/// Everything is checked before it goes over the network, so a typo costs a moment rather than a
/// browser sign-in that fails at the end.
struct ConnectView: View {
    @State private var model = ConnectionModel()
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
        case .checking:
            Text("Asking the dashboard what it needs…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .waitingForBrowser:
            Text("Finish signing in in your browser. The dashboard needs to confirm who you are.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .connected(let status):
            Label {
                Text(verbatim: "Connected to \(model.endpoint?.base.host ?? "the dashboard")" + (status.version.map { " · v\($0)" } ?? ""))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .font(.caption)
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
            }
        }
    }

    private var footer: some View {
        Text("The address stays on this Mac. The tokens are kept in your keychain.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

#Preview {
    ConnectView()
}
