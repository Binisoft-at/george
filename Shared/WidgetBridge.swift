#if !os(watchOS)
import Foundation
import BinisoftKitCore
#if os(iOS)
import WidgetKit
#endif

/// What the Home and Lock Screen widgets show. The app writes it to the shared App Group
/// (`<group>/George/widgets.json`, see WidgetBridge); only this small summary goes there.
struct WidgetSnapshot: Codable, Hashable {
    struct Workout: Codable, Hashable {
        var title: String
        /// "6 exercises · 45 min".
        var detail: String
        var symbol: String
        /// A planned session (true) or the program's suggestion (false).
        var isPlanned: Bool
        var programName: String
        /// The day a planned session is planned for (nil for a suggestion and in older snapshots).
        /// The widget says "Today" or "Missed · Tue" from it as its timeline moves on.
        var plannedDay: Date? = nil
    }

    struct Streak: Codable, Hashable {
        var weeks: Int
        var doneDays: Int
        var goal: Int
        var headline: String
        /// One per day of the week, starting at `weekStart`.
        var dots: [Bool]
        var weekStart: Date
    }

    /// The workout running right now (the widget says so instead of suggesting another one).
    struct Live: Codable, Hashable {
        var title: String
        var symbol: String
    }

    var next: Workout?
    var streak: Streak?
    var live: Live?
    var updatedAt: Date

    static let fileName = "widgets.json"

    /// Same content apart from the time stamp.
    func hasSameContent(as other: WidgetSnapshot?) -> Bool {
        guard var other else { return false }
        other.updatedAt = updatedAt
        return self == other
    }

    /// Gallery preview and first run.
    static let placeholder = WidgetSnapshot(
        next: Workout(title: "Upper Body", detail: "6 exercises · 45 min", symbol: "dumbbell.fill", isPlanned: false, programName: "Strength"),
        streak: Streak(weeks: 4, doneDays: 2, goal: 3, headline: "1 more day this week",
                       dots: [true, false, true, false, false, false, false], weekStart: Date()),
        live: nil,
        updatedAt: Date()
    )
}

extension WidgetSnapshot.Streak {
    /// The dots for the week that contains `date` (all open once the snapshot's week is over).
    func dots(on date: Date, calendar: Calendar = .current) -> [Bool] {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: weekStart), to: calendar.startOfDay(for: date)).day ?? 0
        guard days < 7 else { return Array(repeating: false, count: 7) }
        return dots
    }

    /// Index of `date` in the week (nil outside the snapshot's week).
    func todayIndex(on date: Date, calendar: Calendar = .current) -> Int? {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: weekStart), to: calendar.startOfDay(for: date)).day ?? -1
        return (0..<7).contains(days) ? days : nil
    }

    /// Days done in the week that contains `date`: the snapshot's count while its week runs, 0 once
    /// it is over (the same rule as SnapshotTiming.doneDays in GeorgeCore, which this target can't use).
    func doneDays(on date: Date, calendar: Calendar = .current) -> Int {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: weekStart), to: calendar.startOfDay(for: date)).day ?? 0
        return days < 7 ? doneDays : 0
    }

    /// One-letter weekday names in the order of `dots`.
    func letters(calendar: Calendar = .current) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.component(.weekday, from: weekStart) - 1
        return (0..<7).map { symbols[(first + $0) % 7] }
    }
}

extension WidgetSnapshot.Workout {
    /// "Today", "Missed · Tue" or "Up next" as of `date` – a timeline entry at midnight must not call
    /// yesterday's plan "Today" (the same rule as SnapshotTiming.plan in GeorgeCore).
    func caption(on date: Date, updatedAt: Date, calendar: Calendar = .current) -> String {
        guard isPlanned else { return "Up next" }
        guard let plannedDay else {
            // An older snapshot without the day: planned for the day it was written.
            return calendar.isDate(updatedAt, inSameDayAs: date) ? "Today" : "Up next"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: plannedDay)).day ?? 0
        if days == 0 { return "Today" }
        if days < 0 { return "Missed · \(plannedDay.formatted(.dateTime.weekday(.abbreviated)))" }
        return "Up next"
    }
}

/// The widget snapshot in the shared App Group: `<group>/George/widgets.json`.
enum WidgetBridge {
    /// The app's folder in the shared group (the same name as `AppInfo.name`).
    static let appFolder = "George"

    @MainActor private static var lastPublished: WidgetSnapshot?

    static var folder: URL? {
        guard let group = AppIdentifiers.main.sharedAppGroup,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return root.appendingPathComponent(appFolder, isDirectory: true)
    }

    /// Writes the snapshot and reloads the widgets – only when the content changed.
    @MainActor
    static func publish(_ snapshot: WidgetSnapshot) {
        #if os(iOS)
        guard !snapshot.hasSameContent(as: lastPublished), let folder else { return }
        do {
            try SnapshotFile<WidgetSnapshot>(folder: folder, name: WidgetSnapshot.fileName).write(snapshot)
            lastPublished = snapshot
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            AppLog.warning("Widget snapshot not written: \(error.localizedDescription)", category: "widgets")
        }
        #endif
    }

    static func read() -> WidgetSnapshot? {
        guard let folder else { return nil }
        return SnapshotFile<WidgetSnapshot>(folder: folder, name: WidgetSnapshot.fileName).read()
    }
}
#endif
