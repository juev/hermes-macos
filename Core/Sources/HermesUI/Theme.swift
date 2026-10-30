import SwiftUI

/// What the chat looks like: the one place a size, a weight, a colour or a distance is decided.
///
/// The reading surface is the answer, so the type is set for reading: a body a touch larger than
/// the system default, room between the lines, a measure short enough that the eye returns to the
/// left edge without effort, and everything that is not the answer — reasoning, tools, metadata —
/// set smaller and quieter so it can be skipped without being lost.
public enum Theme {
    public enum Fonts {
        /// The words of the agent.
        public static let answer = SwiftUI.Font.system(size: 14.5, weight: .regular)
        /// The words of the person, on one line of a bubble.
        public static let message = SwiftUI.Font.system(size: 14, weight: .regular)
        /// What the model thought before it answered: legible, never louder than the answer.
        public static let reasoning = SwiftUI.Font.system(size: 13, weight: .regular)
        public static let reasoningLabel = SwiftUI.Font.system(size: 11, weight: .medium)
        public static let toolName = SwiftUI.Font.system(size: 12, weight: .medium, design: .monospaced)
        public static let toolContext = SwiftUI.Font.system(size: 11.5, weight: .regular, design: .monospaced)
        public static let toolOutput = SwiftUI.Font.system(size: 11.5, weight: .regular, design: .monospaced)
        /// A code block in an answer: its own size, wider than a tool's log.
        public static let codeBlock = SwiftUI.Font.system(size: 12.5, weight: .regular, design: .monospaced)
        /// A `code` span inside a sentence.
        public static let inlineCode = SwiftUI.Font.system(size: 13, weight: .regular, design: .monospaced)
        public static let sessionTitle = SwiftUI.Font.system(size: 13, weight: .regular)
        public static let sessionMeta = SwiftUI.Font.system(size: 11, weight: .regular)
        public static let sectionLabel = SwiftUI.Font.system(size: 11, weight: .semibold)
        public static let detailTitle = SwiftUI.Font.system(size: 15, weight: .semibold)
    }

    public enum Metrics {
        /// A measure of about 80 characters at the reading size.
        public static let readingWidth: CGFloat = 720
        /// Between two turns: wide enough that a new voice is obvious at a glance.
        public static let turnSpacing: CGFloat = 28
        /// Between the parts of one answer: reasoning, words, tools.
        public static let partSpacing: CGFloat = 14
        public static let lineSpacing: CGFloat = 3.5
        public static let bubbleRadius: CGFloat = 14
        public static let contentPadding: CGFloat = 28
        public static let toolOutputMaxHeight: CGFloat = 260
    }

    public enum Palette {
        /// The person's side of the conversation, tinted so a turn is recognisable without reading.
        public static let messageBackground = Color.accentColor.opacity(0.12)
        /// A surface that reads as a surface in both light and dark: code, tool output.
        public static let toolBackground = Color.primary.opacity(0.05)
        public static let reasoningRule = Color(nsColor: .separatorColor)
        public static let inlineCode = Color.primary.opacity(0.07)
        public static let accentText = Color(nsColor: .secondaryLabelColor)
    }
}
