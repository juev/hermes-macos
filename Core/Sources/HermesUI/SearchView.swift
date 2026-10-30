import HermesCore
import SwiftUI

/// The field over the chat list. It is its own view so the sidebar can put results under it the
/// moment it has something to show.
public struct SearchField: View {
    @Binding public var text: String

    public init(text: Binding<String>) {
        _text = text
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search the chats", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.sessionTitle)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.Palette.toolBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// The field as a picture: a text field cannot be drawn outside a window, and a snapshot of the
/// sidebar still has to show what the search looks like.
public struct SearchFieldChrome: View {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "Search the chats" : text)
                .font(Theme.Fonts.sessionTitle)
                .foregroundStyle(text.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            Spacer(minLength: 0)
            if !text.isEmpty {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.Palette.toolBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// What the search found: the chat, the message's role and the line around the match.
public struct SearchResultsView: View {
    public let hits: [SearchHit]
    public let query: String
    @Binding public var selection: SessionSummary.ID?

    public init(hits: [SearchHit], query: String, selection: Binding<SessionSummary.ID?>) {
        self.hits = hits
        self.query = query
        _selection = selection
    }

    public var body: some View {
        List(selection: $selection) {
            ForEach(hits) { hit in
                SearchResultRow(hit: hit, query: query)
                    .tag(hit.session.id)
            }
        }
        .listStyle(.sidebar)
    }
}

public struct SearchResultRow: View {
    public let hit: SearchHit
    public let query: String

    public init(hit: SearchHit, query: String) {
        self.hit = hit
        self.query = query
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(hit.session.label)
                    .font(Theme.Fonts.sessionTitle)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let role = hit.role, !role.isEmpty {
                    Text(role)
                        .font(Theme.Fonts.sessionMeta)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(Highlighting.attributed(PlainText.of(hit.oneLine), query: query))
                .font(Theme.Fonts.sessionMeta)
                .lineLimit(2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

/// Marks the words a person looked for, so a row of results reads as an answer to the question.
enum Highlighting {
    static func attributed(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return attributed }

        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let found = attributed[searchStart...].range(of: needle, options: [.caseInsensitive]) {
            attributed[found].inlinePresentationIntent = .stronglyEmphasized
            attributed[found].foregroundColor = .primary
            searchStart = found.upperBound
        }
        return attributed
    }
}
