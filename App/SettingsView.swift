import HermesCore
import SwiftUI

/// One window for everything that is not a chat: the dashboard this app talks to, the tailnet it can
/// join itself, and the push that arrives when the app is in the background. The toolbar has one
/// button, because there is one place.
struct SettingsView: View {
    @Bindable var push: PushModel
    @Bindable var tailnet: TailnetModel
    let address: String
    let onChangeServer: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var tab = Tab.server

    enum Tab: Hashable {
        case server
        case tailnet
        case push
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Server").tag(Tab.server)
                Text("Tailnet").tag(Tab.tailnet)
                Text("Notifications").tag(Tab.push)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Divider().padding(.top, 12)

            ScrollView {
                Group {
                    switch tab {
                    case .server: server
                    case .tailnet: TailnetSettingsForm(model: tailnet)
                    case .push: PushSettingsForm(model: push)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 460)
    }

    private var server: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dashboard")
                    .font(.system(size: 17, weight: .semibold))
                Text("This window works with one dashboard. Its address is kept, and the tokens that prove who you are live in the Keychain under that address.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("address").font(.caption).foregroundStyle(.secondary)
                Text(address)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("tailnet").font(.caption).foregroundStyle(.secondary)
                Text(tailnetLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Change server…") {
                dismiss()
                onChangeServer()
            }
            .help("Close this dashboard and go back to the address")

            Spacer(minLength: 0)
        }
    }

    /// What the tailnet is doing, in the place a person looks for the dashboard's address.
    private var tailnetLine: String {
        guard tailnet.isEnabled else {
            return "The built-in tailnet is off: this dashboard is reached the way this Mac reaches the network."
        }
        return tailnet.status.summary
    }
}

/// The settings of the tailnet this app joins itself: the control server — Tailscale, or a Headscale
/// instance — the name this Mac takes there, and where the node stands right now.
struct TailnetSettingsForm: View {
    @Bindable var model: TailnetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Built-in tailnet")
                    .font(.system(size: 17, weight: .semibold))
                Text("This app can carry a Tailscale node of its own: it joins the tailnet before it asks the dashboard anything, so a dashboard that only the tailnet reaches opens on a Mac without the Tailscale app. It takes no VPN slot, and another VPN keeps working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Join the tailnet from this app", isOn: Binding(
                get: { model.isEnabled },
                set: { model.setEnabled($0) }
            ))
            .disabled(!model.isAvailable)

            VStack(alignment: .leading, spacing: 10) {
                field(
                    "control server",
                    text: Binding(get: { model.settings.controlURL }, set: { model.setControlURL($0) }),
                    prompt: "empty for Tailscale, or https://scale.evsyukov.org"
                )
                field(
                    "this Mac's name on the tailnet",
                    text: Binding(get: { model.settings.hostname }, set: { model.setHostname($0) }),
                    prompt: "hermes-macos"
                )
            }
            .textFieldStyle(.roundedBorder)
            .disabled(!model.isEnabled)

            status

            HStack(spacing: 10) {
                Button("Join now") {
                    Task { try? await model.bringUp() }
                }
                .disabled(!model.isEnabled || !model.isAvailable)
                Button("Leave") { model.leave() }
                    .disabled(!model.isEnabled)
                Spacer()
            }

            Text("The node keeps its key on this Mac, so the next launch is the same node on the tailnet. A sign-in page opens in the browser when the control server asks for one. The browser does not go through this node: a dashboard that asks for a sign-in has to be signed in once without the route, and the tokens it keeps then work through the node.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .font(.system(.body, design: .monospaced))
        }
    }

    @ViewBuilder
    private var status: some View {
        if !model.isAvailable {
            Label("This build has no built-in tailnet node. Build it with scripts/build-tailnet.sh.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if case .failed(let message) = model.phase {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label(model.status.summary, systemImage: model.status.isRunning ? "network.badge.shield.half.filled" : "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .needsLogin = model.phase {
                    Button("Open the sign-in page") { model.openLoginPage() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                if model.isEnabled && !model.status.isRunning {
                    Text("Connect asks the node to join first, and the dashboard after it.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
