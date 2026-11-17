import Foundation
import UserNotifications

/// While George is open, the voice coach announces the end of a rest itself – the notification then
/// stays silent instead of playing a second "Go!". Training reminders carry a "Start" action.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationDelegate()

    /// The category of training-day reminders (`ReminderScheduler.categoryIdentifier`).
    static let trainingCategory = "george.training"
    static let startAction = "george.start"

    /// Starts the next workout (set by the app: planned today, else the suggested template).
    var onStartNextWorkout: (@MainActor () -> Void)?

    /// Registers the reminder's "Start" button.
    static func registerCategories() {
        let start = UNNotificationAction(identifier: startAction, title: "Start Workout", options: [.foreground])
        let category = UNNotificationCategory(identifier: trainingCategory, actions: [start], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.identifier == "george.rest" { return [] }
        return [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.categoryIdentifier == Self.trainingCategory,
              response.actionIdentifier == Self.startAction else { return }
        let start = onStartNextWorkout
        await MainActor.run { start?() }
    }
}
