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

        try write(transcriptLight, "transcript.png", width: 900)
        try write(transcriptDark, "transcript-dark.png", width: 900)
        try write(sessionsList, "sessions.png", width: 320)
        try write(searchList, "search.png", width: 320)
        try write(questionCard, "question.png", width: 640)
        try write(files, "files.png", width: 640)
        try write(composer, "composer.png", width: 640)
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
