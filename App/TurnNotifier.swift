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

    /// Posts what a finished turn says, when the window is not the thing in front.
    func turnFinished(chat: String, answer: String) {
        guard NotificationText.shouldNotify(appIsActive: NSApp.isActive, runningTurnWasHere: true) else { return }
        prepare()

        let content = UNMutableNotificationContent()
        content.title = NotificationText.title(chat: chat)
        content.body = NotificationText.preview(answer)
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "turn-\(UUID().uuidString)", content: content, trigger: nil))
    }
}
