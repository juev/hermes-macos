import HermesCore
import SwiftUI

/// One window for everything that is not a chat: the dashboard this app talks to, and the push that
/// arrives when the app is in the background. The toolbar has one button, because there is one place.
struct SettingsView: View {
    @Bindable var push: PushModel
    let address: String
    let onChangeServer: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var tab = Tab.server

    enum Tab: Hashable {
        case server
        case push
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Server").tag(Tab.server)
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

            Button("Change server…") {
                dismiss()
                onChangeServer()
            }
            .help("Close this dashboard and go back to the address")

            Spacer(minLength: 0)
        }
    }
}
