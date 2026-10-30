import SwiftUI

/// A chat named by a person instead of by the start of its first message.
struct RenameChatSheet: View {
    @State private var title: String
    private let onSave: (String) -> Void
    private let onCancel: () -> Void

    init(title: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _title = State(initialValue: title)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename the chat")
                .font(.system(size: 15, weight: .semibold))
            TextField("A name", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 380)
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}
