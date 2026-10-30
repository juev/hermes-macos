import HermesCore
import SwiftUI

/// The settings of the push: which ntfy topic carries it and who may read that topic. A part of the
/// settings window, not a window of its own.
struct PushSettingsForm: View {
    @Bindable var model: PushModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hermes pushes to this Mac through hermes-push when a turn ends anywhere — a chat, Telegram, Matrix, a cron run. It needs an ntfy topic this Mac may read.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                field("ntfy server", text: $model.server, prompt: "https://ntfy.evsyukov.org")
                HStack(alignment: .bottom, spacing: 8) {
                    field("topic", text: $model.topic, prompt: "up…")
                    Button("Suggest") { model.topic = model.suggestedTopic }
                        .controlSize(.small)
                }
                field("user", text: $model.user, prompt: "the ntfy user that may read the topic")
                secureField("password", text: $model.password)
            }
            .textFieldStyle(.roundedBorder)

            status

            HStack(spacing: 10) {
                Button(model.isEnabled ? "Change" : "Turn on") {
                    Task { await model.enable() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.state == .connecting)

                Button("Send a test push") {
                    Task { await model.sendTest() }
                }
                .disabled(!model.isEnabled)

                if model.isEnabled {
                    Button("Turn off") { Task { await model.disable() } }
                }
            }

            Text("A test push goes to every subscriber, the phone included.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

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

    private func secureField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            SecureField("the password of that user", text: text)
                .font(.system(.body, design: .monospaced))
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .off:
            Label("Push is off.", systemImage: "bell.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .connecting:
            Label("Registering with the dashboard…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .on:
            Label("Push is on: the dashboard posts to \(model.topic.isEmpty ? "the topic" : model.topic).", systemImage: "bell.badge")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let detail = model.detail {
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
