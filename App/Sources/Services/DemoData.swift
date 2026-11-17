import Foundation
import SwiftData
import GeorgeCore

/// Sample data for `-Demo` launches (CI screenshots) and the tour's practice page.
/// It lives in in-memory stores only and never syncs.
@MainActor
enum DemoData {
    /// A gym program with a few weeks of history, so Today, streaks, stats and muscles have something to show.
    static func seed(_ context: ModelContext) {
        let store = GeorgeStore(container: context.container)
        guard let program = importDemoProgram(into: store) else { return }
        store.settings.weeklyGoal = 3
        let templates = program.orderedTemplates
        guard !templates.isEmpty else { return }

        let calendar = store.calendar
        let today = calendar.startOfDay(for: Date())
        // Three workouts a week for four weeks, the last one two days ago.
        var index = 0
        for daysAgo in [26, 24, 22, 19, 17, 15, 12, 10, 8, 5, 3, 2] {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: today),
                  let date = calendar.date(bySettingHour: 18, minute: 15, second: 0, of: day) else { continue }
            let template = templates[index % templates.count]
            let session = store.logPastSession(from: template, date: date, minutes: 45 + (index % 3) * 10)
            session.effort = 6 + index % 3
            index += 1
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) {
            _ = store.makeSession(from: templates[index % templates.count], date: tomorrow, start: false)
        }
        store.settings.birthYear = calendar.component(.year, from: today) - 34
        store.settings.experienceRaw = TrainingExperience.intermediate.rawValue
        store.settings.goalRaw = TrainingGoal.muscle.rawValue
        // Nine weeks of energy check-ins with a four-week rhythm, so Insights → Energy has a pattern.
        for (date, level) in energyHistory(calendar: calendar, today: today) {
            context.insert(EnergyCheckIn(level: level, source: "today", date: date))
        }
        for session in store.fetchSessions() where session.status.isPerformed {
            session.energyBefore = energyLevel(daysAgo: calendar.daysBetween(calendar.startOfDay(for: session.date), today))
        }
        store.save()
    }

    /// A smooth 28-day rhythm (low around now) with a little fixed noise, on most days.
    static func energyLevel(daysAgo: Int) -> Int {
        let wave = cos(Double(daysAgo) / 28 * 2 * Double.pi + 0.6)
        let noise = Double((daysAgo * 37) % 7 - 3) * 0.12
        return min(5, max(1, Int((3.1 - 1.4 * wave + noise).rounded())))
    }

    private static func energyHistory(calendar: Calendar, today: Date) -> [(Date, Int)] {
        (0..<63).compactMap { daysAgo in
            guard daysAgo % 6 != 4 else { return nil } // a few days without a check-in
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
            let date = calendar.date(bySettingHour: 8, minute: 30, second: 0, of: day) ?? day
            return (date, energyLevel(daysAgo: daysAgo))
        }
    }

    /// Recovery signals for demo launches (no Health data in the simulator): HRV and sleep follow
    /// the same rhythm as the energy check-ins.
    static func healthSignals(calendar: Calendar, now: Date = Date()) -> [DailyHealthSignal] {
        let today = calendar.startOfDay(for: now)
        return (0..<63).map { daysAgo in
            let level = Double(energyLevel(daysAgo: daysAgo))
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
            let wobble = Double((daysAgo * 53) % 9 - 4)
            return DailyHealthSignal(day: day, hrvMs: 38 + level * 6 + wobble, restingHeartRate: 62 - level * 1.5 + wobble * 0.3,
                                     sleepHours: 5.9 + level * 0.35 + wobble * 0.05)
        }
    }

    /// The practice page: the demo program's templates, no history.
    static func seedPractice(_ context: ModelContext) {
        let store = GeorgeStore(container: context.container)
        _ = importDemoProgram(into: store)
    }

    /// The gym sample (`samples/gym-strength-block.csv`) – the same program the tour, the screenshots
    /// and Settings → Add Sample Program use.
    @discardableResult
    private static func importDemoProgram(into store: GeorgeStore) -> Program? {
        guard let parsed = GeorgeStore.SampleProgram.gym.parsed else { return nil }
        let programs = store.importPrograms(parsed.programs)
        guard let program = programs.first else { return nil }
        store.setActive(program)
        return program
    }
}
