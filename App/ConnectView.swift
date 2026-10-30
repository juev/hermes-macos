import HermesCore
import SwiftUI

/// The first screen of a new install: the address of a dashboard. It checks the address before
/// anything goes over the network, so a typo costs a moment and not a sign-in that fails at the end.
struct ConnectView: View {
    @State private var address = ""

    private var endpoint: Endpoint? { Endpoint(address: address) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hermes")
                    .font(.largeTitle.weight(.semibold))
                Text("Connect to the dashboard of your Hermes Agent.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Server address")
                    .font(.subheadline.weight(.medium))
                TextField("hermes.example.test:8443", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(maxWidth: 420)
                if address.isEmpty {
                    Text("A bare host name gets https. A dashboard on the tailnet answers on its MagicDNS name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let endpoint {
                    Text(endpoint.base.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("That is not an address.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Button("Continue") {}
                .keyboardShortcut(.defaultAction)
                .disabled(endpoint == nil)

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#Preview {
    ConnectView()
}
