import AppKit
import HermesCore
import UserNotifications

/// A banner for a turn that ends while the person is looking at something else. The window keeps the
/// socket open, so a long answer arrives whether or not it is in front.
@MainActor
final class TurnNotifier {
    static let shared = TurnNotifier()

    private let center = UNUserNotificationCenter.current()
    private var requested = false

    /// Asks for permission once, at launch, the way a chat app does — not at the moment the first
    /// answer finishes, when the person is somewhere else.
    func prepare() {
        guard !requested else { return }
        requested = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// A push of `hermes-push`: a turn that ended somewhere the socket does not reach — Telegram,
    /// Matrix, a cron run.
    func pushArrived(_ push: PushMessage) {
        prepare()
        let content = UNMutableNotificationContent()
        let platform = push.platform ?? ""
        content.title = platform.isEmpty ? "Hermes" : "Hermes · \(platform)"
        let words = PlainText.of(push.oneLine)
        content.body = words.isEmpty ? (push.job ?? "A turn is finished.") : words
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "push-\(UUID().uuidString)", content: content, trigger: nil))
    }

    /// A question the agent waits on is worth a banner even in front of the window: the turn is
    /// stopped until someone answers.
    func questionAsked(chat: String, approval: Approval) {
        prepare()
        let content = UNMutableNotificationContent()
        content.title = NotificationText.title(chat: chat)
        content.body = approval.summary.isEmpty ? approval.title : approval.summary
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "question-\(UUID().uuidString)", content: content, trigger: nil))
    }

    /// Posts what a finished turn says, when the window is not the thing in front.
    func turnFinished(chat: String, answer: String) {
        guard NotificationText.shouldNotify(appIsActive: NSApp.isActive) else { return }
        prepare()

        let content = UNMutableNotificationContent()
        content.title = NotificationText.title(chat: chat)
        content.body = NotificationText.preview(PlainText.of(answer))
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "turn-\(UUID().uuidString)", content: content, trigger: nil))
    }
}
