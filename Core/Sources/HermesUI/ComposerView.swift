import SwiftUI

/// Where a message is written. Return sends, Option+Return starts a new line — a chat is not a form,
/// and the person should not have to reach for the mouse to say something.
public struct ComposerView: View {
    @Binding public var text: String
    /// A turn runs: the field still takes words, the button turns into a stop.
    public let isRunning: Bool
    public let onSend: () -> Void
    public let onStop: () -> Void

    @FocusState private var focused: Bool

    public init(text: Binding<String>, isRunning: Bool, onSend: @escaping () -> Void, onStop: @escaping () -> Void) {
        _text = text
        self.isRunning = isRunning
        self.onSend = onSend
        self.onStop = onStop
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message Hermes", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.Fonts.message)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Theme.Palette.toolBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                if isRunning {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.secondary)
                    .clipShape(Circle())
                    .help("Stop the turn")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Circle())
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
                    .help("Send the message")
                }
            }
            .padding(.horizontal, Theme.Metrics.contentPadding)
            .padding(.vertical, 12)
        }
        .onAppear { focused = true }
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        onSend()
    }
}

/// The composer as a picture: a text field cannot be drawn outside a window.
public struct ComposerChrome: View {
    public let text: String
    public let isRunning: Bool

    public init(text: String, isRunning: Bool = false) {
        self.text = text
        self.isRunning = isRunning
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(alignment: .bottom, spacing: 10) {
                Text(text.isEmpty ? "Message Hermes" : text)
                    .font(Theme.Fonts.message)
                    .foregroundStyle(text.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Theme.Palette.toolBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor, in: Circle())
            }
            .padding(.horizontal, Theme.Metrics.contentPadding)
            .padding(.vertical, 12)
        }
    }
}
