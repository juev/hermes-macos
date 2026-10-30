import AppKit
import HermesCore
import SwiftUI
import Testing
@testable import HermesUI

/// The look of the chat, drawn without a window: `scripts/test.sh` leaves the images in
/// `build/snapshots/`, and a person can look at them without the test taking the screen.
@MainActor
@Suite("The look of the chat")
struct SnapshotTests {
    static let output = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // HermesUITests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // Core
        .deletingLastPathComponent()  // worktree root
        .appendingPathComponent("build/snapshots", isDirectory: true)

    static let sample: [ChatItem] = [
        .user(UserBubble(
            key: "u1",
            text: "Посмотри, почему падает сборка после обновления Xcode. И покажи, что там с сигнатурой.",
            attachments: [Attachment(path: "/tmp/build.log", name: "build.log", isImage: false)],
            timestamp: Date().addingTimeInterval(-86_400)
        )),
        .assistant(AssistantTurn(key: "a2", parts: [
            .reasoning("""
            The user reports a failing build after an Xcode update.
            Likely a stale derived data folder or a toolchain mismatch.
            Check the log first, then the SDK version.
            """),
            .text("Сборка падает на линковке: старые объектные файлы остались от предыдущего toolchain."),
            .tool(ToolRun(
                id: "call-1", name: "terminal",
                context: "xcodebuild -scheme Hermes build 2>&1 | tail -20",
                arguments: #"{"command":"xcodebuild -scheme Hermes build 2>&1 | tail -20"}"#,
                output: """
                Ld /Users/dev/Library/Developer/Xcode/DerivedData/Hermes/Build/Products/Debug/Hermes.app/Contents/MacOS/Hermes normal
                ld: warning: ignoring duplicated libraries
                Undefined symbols for architecture arm64:
                  "_OBJC_CLASS_$_NSApplication", referenced from: ...
                clang: error: linker command failed with exit code 1
                """
            )),
            .text("""
            Очистить DerivedData и пересобрать:

            1. `rm -rf ~/Library/Developer/Xcode/DerivedData/Hermes-*`
            2. `scripts/build.sh` — проект генерируется заново, кэш пустой.

            ```sh
            xcode-select -p   # должен печатать Xcode 27.1
            scripts/build.sh
            ```

            После этого линковка проходит; если нет — проверьте, что `xcode-select -p` смотрит на **Xcode 27.1**, а не на Command Line Tools.
            """)
        ])),
        .user(UserBubble(key: "u3", text: "Сработало. Спасибо!", timestamp: Date())),
        .assistant(AssistantTurn(key: "a4", parts: [
            .text("Рад, что помогло. Если снова всплывёт — проверьте, не держит ли старый Xcode свои модули в `/Library/Developer`."),
            .tool(ToolRun(
                id: "call-2", name: "read_file",
                context: "/Library/Developer/CommandLineTools",
                arguments: #"{"path":"/Library/Developer/CommandLineTools"}"#,
                output: "CommandLineTools\n"
            ))
        ]))
    ]

    static let sampleSessions: [SessionSummary] = [
        SessionSummary(id: "s1", title: "", preview: "Посмотри, почему падает сборка после обновления Xcode…",
                       source: "cron", model: "gpt-6.1-sol", lastActive: Date(timeIntervalSinceNow: -120),
                       messageCount: 142, pinned: true, active: true),
        SessionSummary(id: "s2", title: "План релиза 0.22.5", preview: "", source: "android",
                       model: "deepseek-flash", lastActive: Date(timeIntervalSinceNow: -3_600), messageCount: 476, unread: true),
        SessionSummary(id: "s3", title: "Матрица: утренний дайджест", preview: "", source: "matrix",
                       model: "deepseek-flash", lastActive: Date(timeIntervalSinceNow: -18_000), messageCount: 212),
        SessionSummary(id: "s4", title: "Телеграм: что нового в memcue", preview: "", source: "telegram",
                       model: "deepseek-flash", lastActive: Date(timeIntervalSinceNow: -86_400), messageCount: 43)
    ]

    private func write(_ image: NSImage?, to name: String) throws {
        let tiff = try #require(image?.tiffRepresentation, "no image was drawn")
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
        try png.write(to: Self.output.appendingPathComponent(name))
    }

    @Test("The transcript")
    func transcript() throws {
        let content = TranscriptContent(items: Self.sample)
            .frame(width: 820, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        try write(renderer.nsImage, to: "transcript.png")
        #expect(FileManager.default.fileExists(atPath: Self.output.appendingPathComponent("transcript.png").path))
    }

    @Test("The transcript in the dark")
    func transcriptDark() throws {
        let content = TranscriptContent(items: Self.sample)
            .frame(width: 820, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        try write(renderer.nsImage, to: "transcript-dark.png")
        #expect(FileManager.default.fileExists(atPath: Self.output.appendingPathComponent("transcript-dark.png").path))
    }

    @Test("The results of a search")
    func search() throws {
        let hits = [
            SearchHit(session: Self.sampleSessions[0], snippet: "...command not found\n---\n#!/bin/sh\n# >>>Hermes<<< wrapper", role: "tool"),
            SearchHit(session: Self.sampleSessions[1], snippet: "Сборка падает на линковке, Hermes 27.1 не видит SDK", role: "assistant"),
            SearchHit(session: Self.sampleSessions[2], snippet: "утренний дайджест по hermes: 12 сообщений", role: "user")
        ]
        let list = VStack(alignment: .leading, spacing: 0) {
            SearchFieldChrome(text: "hermes")
            ForEach(hits) { hit in
                SearchResultRow(hit: hit, query: "hermes")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 320, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: list)
        renderer.scale = 2
        try write(renderer.nsImage, to: "search.png")
        #expect(FileManager.default.fileExists(atPath: Self.output.appendingPathComponent("search.png").path))
    }

    @Test("The files the agent delivered")
    func deliveredFiles() throws {
        // A picture made on the spot, so the card shows what a loaded image looks like.
        let picture = NSImage(size: NSSize(width: 208, height: 136))
        picture.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 208, height: 136).fill()
        NSColor.white.withAlphaComponent(0.8).setFill()
        NSRect(x: 24, y: 40, width: 160, height: 10).fill()
        NSRect(x: 24, y: 62, width: 110, height: 10).fill()
        picture.unlockFocus()
        let png = try #require(picture.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))

        let files = DeliveredFilesView(
            paths: ["/opt/hermes/reports/build.png", "/opt/hermes/reports/0.22.5.md", "/opt/hermes/reports/logs.tar.gz"],
            load: { path in
                if path.hasSuffix(".png") { return png }
                throw URLError(.fileDoesNotExist)
            },
            open: { _ in }
        )
        let view = VStack(alignment: .leading, spacing: 16) {
            Text("Build report")
                .font(Theme.Fonts.answer)
            files
        }
        .padding(24)
        .frame(width: 480, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        try write(renderer.nsImage, to: "files.png")
        #expect(FileManager.default.fileExists(atPath: Self.output.appendingPathComponent("files.png").path))
    }

    @Test("The question the agent waits on")
    func question() throws {
        let cards = VStack(alignment: .leading, spacing: 12) {
            QuestionCardChrome(question: .approval(Approval(
                id: "1",
                kind: .command,
                command: "rm -rf ~/Library/Developer/Xcode/DerivedData/Hermes-*",
                description: "Deletes files outside the workspace",
                choices: ["once", "always", "deny"]
            )))
            QuestionCardChrome(question: .approval(Approval(
                id: "2",
                kind: .mcp,
                command: "Send the digest to the channel #general?",
                description: "matrix.send_message",
                choices: ["once", "deny"]
            )))
        }
        .padding(.vertical, 20)
        .frame(width: 820, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: cards)
        renderer.scale = 2
        try write(renderer.nsImage, to: "question.png")
        #expect(FileManager.default.fileExists(atPath: Self.output.appendingPathComponent("question.png").path))
    }

    @Test("The composer")
    func composer() throws {
        let composer = VStack(spacing: 0) {
            ComposerChrome(text: "Посмотри, почему падает сборка после обновления Xcode", drafts: ["build.log", "screenshot.png"])
            ComposerChrome(text: "", isRunning: true)
        }
        .frame(width: 820, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: composer)
        renderer.scale = 2
        try write(renderer.nsImage, to: "composer.png")
        #expect(FileManager.default.fileExists(atPath: Self.output.appendingPathComponent("composer.png").path))
    }

    @Test("A row of the chat list")
    func sessions() throws {
        let list = VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.sampleSessions) { session in
                SessionRow(session: session)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 320, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: list)
        renderer.scale = 2
        try write(renderer.nsImage, to: "sessions.png")
        #expect(FileManager.default.fileExists(atPath: Self.output.appendingPathComponent("sessions.png").path))
    }
}
