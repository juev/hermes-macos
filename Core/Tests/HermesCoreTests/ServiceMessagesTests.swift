import Foundation
import Testing
@testable import HermesCore

@Suite("What the dashboard wrote instead of a person")
struct ServiceMessagesTests {
    @Test("A cron delivery carries its job and its report")
    func cronReport() throws {
        let text = "[Cron delivery: morning-digest]\n\nEverything is green.\nNo alerts overnight."
        let report = try #require(ServiceMessages.cronReport(text))
        #expect(report.job == "morning-digest")
        #expect(report.report.hasPrefix("Everything is green."))

        #expect(ServiceMessages.cronReport("A person wrote this") == nil)
        #expect(ServiceMessages.cronReport("[Cron delivery: no closing bracket") == nil)
    }

    @Test("A cron prompt is an invocation without words of its own")
    func cronPrompt() throws {
        let text = "[IMPORTANT: You are running as a scheduled cron job.\nDeliver the digest."
        let parsed = try #require(ServiceMessages.invocation(text))
        #expect(parsed.invocation.cron)
        #expect(parsed.written.isEmpty)
        #expect(parsed.invocation.full == text)
    }

    @Test("A skill invocation keeps the words the person wrote")
    func skill() throws {
        let text = """
        [IMPORTANT: The user has invoked the "clean" skill.
        Do the work.
        The user has provided the following instruction alongside the skill invocation: tidy the folder

        [Runtime note: something for the agent]
        """
        let parsed = try #require(ServiceMessages.invocation(text))
        #expect(!parsed.invocation.cron)
        #expect(parsed.invocation.skills == ["clean"])
        #expect(parsed.written == "tidy the folder")
    }

    @Test("A bundle names every skill it loaded")
    func bundle() throws {
        let text = """
        [IMPORTANT: The user has invoked the "clean work" skill bundle,
        User instruction: run both

        [Loaded as part of the clean skill]
        """
        let parsed = try #require(ServiceMessages.invocation(text))
        #expect(parsed.invocation.skills == ["clean", "work"])
        #expect(parsed.written == "run both")
    }

    @Test("An auto-loaded skill leaves only what follows the directions")
    func autoLoaded() throws {
        let text = """
        [IMPORTANT: The "remember" skill is auto-loaded.
        Do this: read them, then run them with the terminal tool using the absolute path.
        What the person actually asked
        """
        let parsed = try #require(ServiceMessages.invocation(text))
        #expect(parsed.invocation.skills == ["remember"])
        #expect(parsed.written == "What the person actually asked")
    }

    @Test("A message written as it is is not an invocation")
    func plain() {
        #expect(ServiceMessages.invocation("Просто сообщение") == nil)
    }

    @Test("A reply carries what it answers")
    func quote() {
        let (quote, body) = ServiceMessages.splitQuote("[Replying to: \"the earlier line\"]\n\nAnd this is the answer")
        #expect(quote == "the earlier line")
        #expect(body == "And this is the answer")

        let bare = ServiceMessages.splitQuote("[Replying to: \"only a quote\"]")
        #expect(bare.quote == "only a quote")
        #expect(bare.text.isEmpty)

        let none = ServiceMessages.splitQuote("no quote here")
        #expect(none.quote == nil)
        #expect(none.text == "no quote here")
    }
}

/// The same shapes the Android client's `ServiceMessagesTest` holds, taken from Hermes Agent v0.22.5:
/// the port is right when it reads them the same way.
@Suite("The shapes the dashboard really writes")
struct ServiceMessagesRealShapeTests {
    private let cronHint = "[IMPORTANT: You are running as a scheduled cron job. DELIVERY: Your final response will be "
        + "automatically delivered to the user. SILENT: respond with exactly \"[SILENT]\" (nothing else). RECURSION: "
        + "NEVER create or update a cron job.]\n\n"

    private func skill(_ name: String) -> String {
        "[IMPORTANT: The user has invoked the \"\(name)\" skill, indicating they want you to follow its instructions. "
            + "The full skill content is loaded below.]\n\n---\nname: \(name)\n---\n# \(name)\n\nДелай **так**."
    }

    @Test("A cron report stands on its own under the name of its job")
    func report() throws {
        let text = "[Cron delivery: research-daily]\n**Тема:** NixOS и Ansible.\n\n**PR:** [#10](https://github.com/juev/research/pull/10)"
        let report = try #require(ServiceMessages.cronReport(text))
        #expect(report.job == "research-daily")
        #expect(report.report.hasPrefix("**Тема:** NixOS"))
    }

    @Test("The prompt of a cron run is a chip with no text of its own")
    func cronPrompt() throws {
        let text = cronHint + "## Your previous run's output\n```\nстарый отчёт\n```\n\nПроверь флот."
        let parsed = try #require(ServiceMessages.invocation(text))
        #expect(parsed.written.isEmpty)
        #expect(parsed.invocation.cron)
        #expect(parsed.invocation.skills.isEmpty)
    }

    @Test("A cron run with a skill names it")
    func cronWithSkill() throws {
        let text = skill("research-daily") + "\n\nThe user has provided the following instruction alongside the skill invocation: " + cronHint + "Опубликуй статью."
        let parsed = try #require(ServiceMessages.invocation(text))
        #expect(parsed.written.isEmpty)
        #expect(parsed.invocation.cron)
        #expect(parsed.invocation.skills == ["research-daily"])
    }

    @Test("A skill the person invoked shows the skill and what they wrote")
    func skillWithInstruction() throws {
        let text = skill("homelab") + "\n\nThe user has provided the following instruction alongside the skill invocation: проверь диски на loffe"
            + "\n\n[Runtime note: the session runs on telegram]"
        let parsed = try #require(ServiceMessages.invocation(text))
        #expect(parsed.written == "проверь диски на loffe")
        #expect(parsed.invocation.skills == ["homelab"])
        #expect(!parsed.invocation.cron)
        #expect(parsed.invocation.full == text)
    }

    @Test("A bare skill invocation has only the chip")
    func bareSkill() throws {
        let parsed = try #require(ServiceMessages.invocation(skill("homelab")))
        #expect(parsed.written.isEmpty)
        #expect(parsed.invocation.skills == ["homelab"])
    }

    @Test("A bundle takes the instruction before its skills")
    func bundle() throws {
        let text = "[IMPORTANT: The user has invoked the \"/clean /work\" skill bundle, loading 2 skills together. Treat every skill below as active guidance for this turn.]\n\n"
            + "Skills loaded: clean, work\n\nUser instruction: разбери почту\n\n[Loaded as part of the \"/clean /work\" skill bundle]\n\n# clean"
        let parsed = try #require(ServiceMessages.invocation(text))
        #expect(parsed.written == "разбери почту")
        #expect(parsed.invocation.skills == ["clean", "work"])
    }

    @Test("A skill loaded for a new session leaves the text the person typed")
    func autoLoaded() throws {
        let text = "[IMPORTANT: The \"inbox\" skill is auto-loaded. Follow its instructions for this session.]\n\n# inbox\n\n"
            + "Scripts live in the skill directory; then run them with the terminal tool using the absolute path.\n\nчто нового?"
        let parsed = try #require(ServiceMessages.invocation(text))
        #expect(parsed.written == "что нового?")
        #expect(parsed.invocation.skills == ["inbox"])
    }
}
