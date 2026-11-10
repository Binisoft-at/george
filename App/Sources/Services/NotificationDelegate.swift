import Foundation
import UserNotifications

/// While George is open, the voice coach announces the end of a rest itself – the notification then
/// stays silent instead of playing a second "Go!".
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.identifier == "george.rest" { return [] }
        return [.banner, .sound]
    }
}
