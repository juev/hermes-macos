import Foundation
import HermesCore
import HermesUI
import SwiftUI
import Testing

/// The pictures the README shows. Synthetic on purpose: no address, no chat and no name of a real
/// dashboard, so a public reader sees what the app looks like and nothing else.
///
///     HERMES_DOC_SCREENSHOTS=1 swift test --package-path Core --filter DocScreenshots
@Suite("Pictures for the README")
struct DocScreenshots {
    static let output = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("docs/screenshots", isDirectory: true)

    private static let dark = Color(red: 0.11, green: 0.12, blue: 0.14)
    private static let papers = Color(nsColor: .textBackgroundColor)

    static let sessions: [SessionSummary] = [
        SessionSummary(id: "s1", title: "Nightly build report", preview: "Three tests failed after the SDK bump…",
                       source: "cron", model: "gpt-6.1-sol", lastActive: Date(timeIntervalSinceNow: -120),
                       messageCount: 142, pinned: true, active: true),
        SessionSummary(id: "s2", title: "Release notes for 0.2", preview: "", source: "macos",
                       model: "deepseek-flash", lastActive: Date(timeIntervalSinceNow: -3_600), messageCount: 476, unread: true),
        SessionSummary(id: "s3", title: "Matrix: morning digest", preview: "", source: "matrix",
                       model: "deepseek-flash", lastActive: Date(timeIntervalSinceNow: -18_000), messageCount: 212),
        SessionSummary(id: "s4", title: "Telegram: what changed in memcue", preview: "", source: "telegram",
                       model: "deepseek-flash", lastActive: Date(timeIntervalSinceNow: -86_400), messageCount: 43),
        SessionSummary(id: "s5", title: "Incident on the build host", preview: "", source: "macos",
                       model: "deepseek-flash", lastActive: Date(timeIntervalSinceNow: -8 * 86_400), messageCount: 61)
    ]

    static var transcript: [ChatItem] {
        let question = UserBubble(
            key: "u1",
            text: "The nightly build failed — can you see why?",
            timestamp: Date(timeIntervalSinceNow: -3_600)
        )
        let answer = AssistantTurn(key: "a1", parts: [
            .reasoning("Reading the log tail first, then the failing test names."),
            .tool(ToolRun(id: "t1", name: "terminal", context: "$ xcodebuild test",
                          output: "[31/42] Testing SearchTests\n✗ providerSlug", done: true,
                          durationSeconds: 42.5, summary: "12 tests failed")),
            .tool(ToolRun(id: "t2", name: "read_file", context: "Tests/SearchTests.swift",
                          output: "line 42: #expect(hit.provider == \"deepseek\")", done: true, durationSeconds: 0.2)),
            .text("""
            The dashboard sends `slug` where the client reads `provider`, so every provider comes back empty.

            ```swift
            // SearchTests.swift
            #expect(hit.provider == "deepseek")   // the server said "slug"
            ```

            I can fix the parse or the test — the parse is the one that is wrong.
            """)
        ])
        let reply = UserBubble(key: "u2", text: "Fix the parse, and keep the test as it is.",
                               timestamp: Date(timeIntervalSinceNow: -1_800), sent: "Fix the parse, and keep the test as it is.")
        return [.user(question), .assistant(answer), .user(reply)]
    }

    @Test("Every picture")
    @MainActor
    func render() throws {
        guard ProcessInfo.processInfo.environment["HERMES_DOC_SCREENSHOTS"] == "1" else { return }
        try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)

        try write(consoleWindow(dark: false), "window.png", width: 1180)
        try write(consoleWindow(dark: true), "window-dark.png", width: 1180)
        try write(tableAnswer, "table.png", width: 860)
        try write(transcriptLight, "transcript.png", width: 900)
        try write(transcriptDark, "transcript-dark.png", width: 900)
        try write(sessionsList, "sessions.png", width: 320)
        try write(searchList, "search.png", width: 320)
        try write(questionCard, "question.png", width: 640)
        try write(files, "files.png", width: 640)
        try write(composer, "composer.png", width: 640)
    }

    /// The whole window, drawn the way it is built: the chat list on the left, the chat on the right,
    /// the composer under it. The frames around it are drawn here, because a picture of a view is not
    /// a picture of a window.
    private func consoleWindow(dark: Bool) -> some View {
        let scheme: ColorScheme = dark ? .dark : .light
        let paper = dark ? Self.dark : Self.papers
        let sidebar = dark ? Color(red: 0.15, green: 0.16, blue: 0.18) : Color(nsColor: .windowBackgroundColor)

        return VStack(spacing: 0) {
            // The title bar the app gets from the system.
            HStack(spacing: 8) {
                ForEach([Color(red: 0.93, green: 0.42, blue: 0.38),
                         Color(red: 0.96, green: 0.75, blue: 0.32),
                         Color(red: 0.35, green: 0.80, blue: 0.36)], id: \.self) { color in
                    Circle().fill(color).frame(width: 12, height: 12)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(sidebar)

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    SearchFieldChrome(text: "")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    Divider()
                    ForEach(Sidebar.sections(Self.sessions), id: \.group) { section in
                        Text(Sidebar.title(for: section.group))
                            .font(Theme.Fonts.sectionLabel)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.top, 14)
                            .padding(.bottom, 2)
                        ForEach(section.chats.prefix(2)) { chat in
                            SessionRow(session: chat)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                    }
                    Spacer(minLength: 0)
                    Divider()
                    HStack(spacing: 6) {
                        Image(systemName: "archivebox").font(.system(size: 10))
                        Text("Archive").font(Theme.Fonts.sessionMeta)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                }
                .frame(width: 300)
                .background(sidebar)

                Divider()

                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Nightly build report")
                            .font(Theme.Fonts.chatTitle)
                        Text("gpt-6.1-sol · cron · 142 messages · in 6.4M · out 37k · included")
                            .font(Theme.Fonts.sessionMeta)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Metrics.contentPadding)
                    .padding(.vertical, 9)
                    .background(.bar)
                    .overlay(alignment: .bottom) { Divider() }

                    // Drawn whole rather than scrolled: a picture of a scroll view is an empty
                    // scroll view, and these are the views the app draws all the same.
                    TranscriptContent(items: Self.transcript)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .clipped()
                    ComposerChrome(text: "Compare it with yesterday's run.")
                }
                .background(paper)
            }
            .frame(height: 720)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .environment(\.colorScheme, scheme)
    }

    /// An answer with a table in it: the shape the agent reaches for when it compares things.
    private var tableAnswer: some View {
        MarkdownText("""
        All four hosts are quiet at the moment.

        | Host | Load average | CPU | RAM free | Disk |
        |---|---|---:|---:|---:|
        | build-1 | 0.42 | 3% | 47 GB | 341 GB |
        | build-2 | 0.11 | 1% | 3,8 GB | 61 GB |
        | jobs | 1.08 | 12% | 900 MB | 24 GB |
        | archive | 0.07 | 2% | 2,1 GB | 8,4 TB |

        Only `jobs` is above where it usually sits: the nightly backup upload is running.
        """)
        .padding(Theme.Metrics.contentPadding)
        .frame(width: 800, alignment: .leading)
        .background(Self.papers)
        .environment(\.colorScheme, .light)
    }

    private var transcriptLight: some View {
        TranscriptContent(items: Self.transcript)
            .frame(width: 860, alignment: .leading)
            .background(Self.papers)
            .environment(\.colorScheme, .light)
    }

    private var transcriptDark: some View {
        TranscriptContent(items: Self.transcript)
            .frame(width: 860, alignment: .leading)
            .background(Self.dark)
            .environment(\.colorScheme, .dark)
    }

    private var sessionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Sidebar.sections(Self.sessions), id: \.group) { section in
                Text(Sidebar.title(for: section.group))
                    .font(Theme.Fonts.sectionLabel)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 2)
                ForEach(section.chats) { chat in
                    SessionRow(session: chat)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)
    }

    private var searchList: some View {
        let hits = [
            SearchHit(session: Self.sessions[1], snippet: "release notes for the macOS client, 0.1.0", role: "assistant"),
            SearchHit(session: Self.sessions[1], snippet: "the release workflow builds a disk image", role: "tool"),
            SearchHit(session: Self.sessions[2], snippet: "morning digest: the release is out", role: "user")
        ]
        return VStack(alignment: .leading, spacing: 0) {
            SearchFieldChrome(text: "release")
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Divider()
            ForEach(SearchGrouping.byChat(hits)) { match in
                ChatMatchRow(match: match, query: "release")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 220, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)
    }

    private var questionCard: some View {
        QuestionCard(
            question: .approval(Approval(
                id: "q1",
                kind: .command,
                command: "rm -rf ~/Library/Developer/Xcode/DerivedData/Hermes-*",
                description: "The agent wants to remove the build cache before a clean build.",
                choices: ["once", "always", "deny"]
            )),
            onChoice: { _ in },
            onClarify: { _ in },
            onCancel: {},
            onSecret: { _ in }
        )
        .padding(20)
        .background(Self.papers)
        .environment(\.colorScheme, .light)
    }

    private var files: some View {
        DeliveredFilesView(paths: ["/tmp/build/report.md", "/tmp/build/search.png"], load: nil, open: nil)
            .padding(20)
            .background(Self.papers)
            .environment(\.colorScheme, .light)
    }

    private var composer: some View {
        VStack {
            Spacer()
            ComposerView(
                text: .constant("Check the provider parse in SearchTests"),
                isRunning: false,
                onAttach: {},
                onRemove: { _ in },
                onSend: {},
                onStop: {}
            )
        }
        .frame(height: 140)
        .background(Self.papers)
        .environment(\.colorScheme, .light)
    }

    @MainActor
    private func write(_ view: some View, _ name: String, width: CGFloat) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            Issue.record("could not draw \(name)")
            return
        }
        try png.write(to: Self.output.appendingPathComponent(name))
    }
}
