import SwiftUI
import BinisoftKit
import GeorgeCore
#if os(iOS)
import UserNotifications
#endif

/// Settings → Streak → Reminders (iPhone/iPad, off by default): a reminder on training days – days
/// with a planned workout or a template scheduled on that weekday – at the chosen time, and one
/// "streak at risk" reminder on the last day the weekly goal can still be reached.
/// Rescheduled whenever the data changes and when the app goes to the background.
@MainActor
enum ReminderScheduler {
    static let identifierPrefix = "george.reminder."
    static let categoryIdentifier = "george.training"
    /// Default reminder time: 17:30.
    nonisolated static let defaultMinutes = 17 * 60 + 30

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: Prefs.trainingReminders) }

    static var minutesAfterMidnight: Int {
        UserDefaults.standard.object(forKey: Prefs.reminderMinutes) as? Int ?? defaultMinutes
    }

    /// Asks for permission to notify. False when declined (the toggle then stays off).
    static func requestPermission() async -> Bool {
        #if os(iOS)
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            AppLog.warning("Notifications: \(error.localizedDescription)", category: "reminders")
            return false
        }
        #else
        return false
        #endif
    }

    /// Replaces George's pending reminders with the ones for the coming week.
    static func reschedule(store: GeorgeStore, healthEntries: [ActivityEntry] = []) {
        #if os(iOS)
        let center = UNUserNotificationCenter.current()
        let enabled = isEnabled
        let calendar = store.calendar
        let reminders: [PlannedReminder]
        if enabled {
            // The streak is kept for the day by the store (no walk over the whole log per reschedule).
            let week = store.streakSummary(healthEntries: healthEntries).thisWeek
            reminders = ReminderPlanner.plan(
                now: Date(), workouts: store.reminderWorkouts(), neededThisWeek: week.neededDays, weekStart: week.weekStart,
                minutesAfterMidnight: minutesAfterMidnight, rescueMinutes: store.settings.rescueMinutes, calendar: calendar
            )
        } else {
            reminders = []
        }
        Task {
            let pending = await center.pendingNotificationRequests()
            let ours = pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ours)
            guard enabled else { return }
            for reminder in reminders {
                let content = UNMutableNotificationContent()
                content.title = reminder.title
                content.body = reminder.body
                content.sound = .default
                content.categoryIdentifier = categoryIdentifier
                content.userInfo = ["george.reminder": reminder.kind.rawValue]
                let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fireDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let request = UNNotificationRequest(identifier: identifierPrefix + reminder.id, content: content, trigger: trigger)
                try? await center.add(request)
            }
        }
        #endif
    }

    /// Removes every pending George reminder (the toggle was switched off).
    static func cancelAll() {
        #if os(iOS)
        let center = UNUserNotificationCenter.current()
        Task {
            let pending = await center.pendingNotificationRequests()
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) })
        }
        #endif
    }
}

/// Keeps the reminders current: after data changes (debounced) and when the app goes to the background.
private struct ReminderSchedulingModifier: ViewModifier {
    @Environment(GeorgeStore.self) private var store
    @Environment(HealthKitManager.self) private var health
    @Environment(\.scenePhase) private var scenePhase
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onChange(of: store.revision) { _, _ in schedule(after: 2) }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { schedule(after: 0) }
            }
            .task { schedule(after: 3) }
    }

    private func schedule(after seconds: Double) {
        #if os(iOS)
        guard ReminderScheduler.isEnabled else { return }
        pending?.cancel()
        pending = Task { @MainActor in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled else { return }
            ReminderScheduler.reschedule(store: store, healthEntries: health.externalWorkouts)
        }
        #endif
    }
}

extension View {
    /// Reschedules training reminders when the data or the scene phase changes. Attach once, high up.
    func reminderScheduling() -> some View {
        modifier(ReminderSchedulingModifier())
    }
}
