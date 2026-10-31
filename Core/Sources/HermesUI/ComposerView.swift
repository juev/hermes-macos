import AppKit
import HermesCore
import SwiftUI

/// Where a message is written. Return sends; Shift+Return and Option+Return start a new line — a chat is
/// not a form, and the person should not have to reach for the mouse to say something.
public struct ComposerView: View {
    @Binding public var text: String
    /// A turn runs: the field still takes words, the button turns into a stop.
    public let isRunning: Bool
    /// Files picked for this message, shown above the field until it is sent.
    public let drafts: [AttachmentDraft]
    public let onAttach: () -> Void
    public let onRemove: (AttachmentDraft) -> Void
    public let onSend: () -> Void
    public let onStop: () -> Void

    @FocusState private var focused: Bool

    public init(
        text: Binding<String>,
        isRunning: Bool,
        drafts: [AttachmentDraft] = [],
        onAttach: @escaping () -> Void = {},
        onRemove: @escaping (AttachmentDraft) -> Void = { _ in },
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        _text = text
        self.isRunning = isRunning
        self.drafts = drafts
        self.onAttach = onAttach
        self.onRemove = onRemove
        self.onSend = onSend
        self.onStop = onStop
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            if !drafts.isEmpty {
                HStack(spacing: 8) {
                    ForEach(drafts) { draft in
                        HStack(spacing: 5) {
                            Image(systemName: draft.isImage ? "photo" : "doc")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Text(draft.name)
                                .font(Theme.Fonts.sessionMeta)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                onRemove(draft)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Theme.Palette.toolBackground, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Metrics.contentPadding)
                .padding(.top, 10)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button(action: onAttach) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Attach a file or a picture")

                TextField("Message Hermes", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.Fonts.message)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit(send)
                    // Return sends on its own, and the two keys a person presses for a paragraph
                    // break insert one at the caret — the field editor is the text view this field
                    // edits, so the newline lands where the cursor is, not at the end.
                    .onKeyPress(phases: .down) { press in
                        guard press.key == .return else { return .ignored }
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                            if let editor = NSApplication.shared.keyWindow?.firstResponder as? NSTextView {
                                editor.insertNewline(nil)
                            } else {
                                text += "\n"
                            }
                            return .handled
                        }
                        send()
                        return .handled
                    }
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
    public let drafts: [String]

    public init(text: String, isRunning: Bool = false, drafts: [String] = []) {
        self.text = text
        self.isRunning = isRunning
        self.drafts = drafts
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            if !drafts.isEmpty {
                HStack(spacing: 8) {
                    ForEach(drafts, id: \.self) { name in
                        HStack(spacing: 5) {
                            Image(systemName: "doc").font(.system(size: 9)).foregroundStyle(.secondary)
                            Text(name).font(Theme.Fonts.sessionMeta).lineLimit(1)
                            Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Theme.Palette.toolBackground, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Metrics.contentPadding)
                .padding(.top, 10)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Image(systemName: "paperclip")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
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
