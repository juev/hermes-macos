import HermesCore
import SwiftUI

/// A question the agent waits on, above the composer: an approval, a choice, a secret. It sits where
/// the message that would answer it is written, so a turn cannot stall behind a card nobody saw.
public struct QuestionCard: View {
    public let question: AgentQuestion
    public let onChoice: (String) -> Void
    public let onClarify: ([String: String?]) -> Void
    public let onCancel: () -> Void
    public let onSecret: (String) -> Void

    @State private var answers: [String: String] = [:]
    @State private var secret = ""

    public init(
        question: AgentQuestion,
        onChoice: @escaping (String) -> Void,
        onClarify: @escaping ([String: String?]) -> Void,
        onCancel: @escaping () -> Void,
        onSecret: @escaping (String) -> Void
    ) {
        self.question = question
        self.onChoice = onChoice
        self.onClarify = onClarify
        self.onCancel = onCancel
        self.onSecret = onSecret
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            cardBody
        }
        .padding(14)
        .background(Theme.Palette.toolBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.Palette.reasoningRule, lineWidth: 1)
        )
        .padding(.horizontal, Theme.Metrics.contentPadding)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var cardBody: some View {
        switch question {
        case .approval(let approval):
            ApprovalCardBody(approval: approval, onChoice: onChoice)
        case .clarify(let clarify):
            ClarifyCardBody(clarify: clarify, answers: $answers, onSend: onClarify)
        case .secret(let asking):
            SecretCardBody(secret: asking, value: $secret, onSend: onSecret)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
            Spacer(minLength: 0)
            Button("Dismiss") { onCancel() }
                .buttonStyle(.plain)
                .font(Theme.Fonts.sessionMeta)
                .foregroundStyle(.secondary)
        }
    }

    private var icon: String {
        switch question {
        case .approval(let approval):
            switch approval.kind {
            case .command: "exclamationmark.triangle"
            case .tool: "hammer"
            case .mcp: "server.rack"
            }
        case .clarify: "questionmark.bubble"
        case .secret: "key"
        }
    }

    private var title: String {
        switch question {
        case .approval(let approval): approval.title
        case .clarify: "The agent asks"
        case .secret(let secret): secret.isSudo ? "Sudo password" : "A secret is needed"
        }
    }
}

private struct ApprovalCardBody: View {
    let approval: Approval
    let onChoice: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !approval.command.isEmpty {
                Text(approval.command)
                    .font(Theme.Fonts.codeBlock)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(
                        Theme.Palette.messageBackground.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
            }
            if !approval.description.isEmpty {
                Text(approval.description)
                    .font(Theme.Fonts.reasoning)
                    .foregroundStyle(Theme.Palette.accentText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                ForEach(approval.choices, id: \.self) { choice in
                    if choice == "deny" {
                        Button(Approval.labels[choice] ?? choice.capitalized) { onChoice(choice) }
                            .buttonStyle(.bordered)
                    } else {
                        Button(Approval.labels[choice] ?? choice.capitalized) { onChoice(choice) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct ClarifyCardBody: View {
    let clarify: Clarify
    @Binding var answers: [String: String]
    let onSend: ([String: String?]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(clarify.questions) { question in
                ClarifyQuestionRow(question: question, answer: binding(for: question.id))
            }
            HStack {
                Button("Send") { onSend(answers.mapValues { $0 }) }
                    .buttonStyle(.borderedProminent)
                Spacer(minLength: 0)
            }
        }
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(
            get: { answers[id] ?? "" },
            set: { answers[id] = $0 }
        )
    }
}

private struct ClarifyQuestionRow: View {
    let question: Clarify.Question
    @Binding var answer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.text)
                .font(Theme.Fonts.answer)
                .fixedSize(horizontal: false, vertical: true)
            if question.choices.isEmpty {
                TextField("Your answer", text: $answer)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Fonts.answer)
            } else {
                HStack(spacing: 8) {
                    ForEach(question.choices, id: \.self) { choice in
                        if answer == choice {
                            Button(choice) { answer = choice }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button(choice) { answer = choice }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }
}

private struct SecretCardBody: View {
    let secret: Secret
    @Binding var value: String
    let onSend: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(secret.prompt)
                .font(Theme.Fonts.answer)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SecureField("Value", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Fonts.answer)
                    .onSubmit(send)
                Button(secret.isSudo ? "Unlock" : "Send") { send() }
                    .buttonStyle(.borderedProminent)
                    .disabled(value.isEmpty)
            }
        }
    }

    private func send() {
        guard !value.isEmpty else { return }
        onSend(value)
    }
}

/// The card as a picture: a text field cannot be drawn outside a window.
public struct QuestionCardChrome: View {
    public let question: AgentQuestion

    public init(question: AgentQuestion) {
        self.question = question
    }

    public var body: some View {
        QuestionCard(question: question, onChoice: { _ in }, onClarify: { _ in }, onCancel: {}, onSecret: { _ in })
    }
}
