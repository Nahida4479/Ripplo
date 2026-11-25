import Foundation
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    var onOpen: (() -> Void)?

    private let lock = NSLock()
    private var pending: [String: Any]?

    private static func validChat(_ s: String) -> Bool {
        s.range(of: "^([0-9A-HJKMNP-TV-Z]{16}|[A-Za-z0-9_-]{6,32})$", options: .regularExpression) != nil
    }

    func take() -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        let p = pending
        pending = nil
        return p
    }

    func show(title: String, body: String, chatId: String?) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        if let id = chatId, !id.isEmpty {
            c.userInfo = ["chatId": id]
            c.threadIdentifier = id
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["chatId"] as? String, Notifier.validChat(id) {
            lock.lock()
            pending = ["chatId": id]
            lock.unlock()
            DispatchQueue.main.async { self.onOpen?() }
        }
        completionHandler()
    }
}
