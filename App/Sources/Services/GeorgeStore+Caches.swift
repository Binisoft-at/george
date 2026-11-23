import Foundation
import SwiftData
import GeorgeCore

/// What Today, the streak card, Up next and the reminders ask for on every redraw, kept until what it
/// is made of changes. Before, each redraw built a new calendar on every use (inside loops too),
/// fetched every workout several times and ran the streak over the whole log. Used by the store only
/// (on the main actor).
final class StoreCaches {
    struct CalendarKey: Equatable {
        var firstWeekday: Int
        var timeZone: TimeZone
    }

    struct ProfileKey: Equatable {
        var birthYear: Int
        var experience: String
        var goal: String
        var year: Int
    }

    /// The training days are made of the workouts and streak settings (`revision`, the settings
    /// record) and the Apple Health workouts passed in; the streaks also of the calendar.
    struct TrainingKey: Equatable {
        var revision: Int
        var settings: ObjectIdentifier
        var settingsUpdatedAt: Date
        var health: [ActivityEntry]
        var calendar: CalendarKey
    }

    struct Training {
        let key: TrainingKey
        let entries: [ActivityEntry]
        /// Streaks worked out from these entries (today's, a recap's day), most recent first.
        var streaks: [(now: Date, summary: StreakSummary)] = []
    }

    struct SuggestionKey: Hashable {
        var revision: Int
        var program: UUID
        var day: Date
    }

    /// A template, or none (no suggestion is a result too).
    struct Suggestion {
        let template: WorkoutTemplate?
    }

    var calendar: (key: CalendarKey, value: Calendar)?
    var profile: (key: ProfileKey, value: TrainingProfile)?
    /// Most recent first. A few: callers pass different Health lists (none, or Apple Health's).
    var trainings: [Training] = []
    var performedToday: (revision: Int, day: Date, sessions: [WorkoutSession])?
    var suggestions: [SuggestionKey: Suggestion] = [:]
}

extension GeorgeStore {
    // MARK: Calendar and profile

    /// The training calendar, built once per week start and time zone.
    func cachedCalendar() -> Calendar {
        let key = StoreCaches.CalendarKey(firstWeekday: settings.weekStartsOn, timeZone: TimeZone.current)
        if let cached = caches.calendar, cached.key == key { return cached.value }
        let value = Calendar.training(firstWeekday: key.firstWeekday, timeZone: key.timeZone)
        caches.calendar = (key: key, value: value)
        return value
    }

    /// Settings → Your Profile as a `TrainingProfile`, made again only when what it's made of changes.
    func cachedProfile() -> TrainingProfile {
        let cal = calendar
        let s = settings
        let key = StoreCaches.ProfileKey(birthYear: birthYear, experience: s.experienceRaw, goal: s.goalRaw,
                                         year: cal.component(.year, from: Date()))
        if let cached = caches.profile, cached.key == key { return cached.value }
        let value = TrainingProfile(birthYear: key.birthYear, experienceRaw: key.experience, goalRaw: key.goal, calendar: cal)
        caches.profile = (key: key, value: value)
        return value
    }

    // MARK: Training days and streak

    /// The days that count as training (`uncachedTrainingEntries`): the streak, the Progress days
    /// chart, the Today hero and Plan Week. Kept until a save changes something, the streak settings
    /// or the Apple Health workouts change.
    func trainingEntries(healthEntries: [ActivityEntry] = []) -> [ActivityEntry] {
        prepareTraining(healthEntries: healthEntries)
        return caches.trainings[0].entries
    }

    /// Puts the training days for these Health workouts first in `caches.trainings` (made when missing).
    private func prepareTraining(healthEntries: [ActivityEntry]) {
        let s = settings
        let cal = calendar
        let key = StoreCaches.TrainingKey(revision: revision, settings: ObjectIdentifier(s),
                                          settingsUpdatedAt: s.updatedAt, health: healthEntries,
                                          calendar: StoreCaches.CalendarKey(firstWeekday: cal.firstWeekday, timeZone: cal.timeZone))
        // What an older revision was made of is gone.
        caches.trainings.removeAll { $0.key.revision != key.revision }
        if let index = caches.trainings.firstIndex(where: { $0.key == key }) {
            if index != 0 {
                let found = caches.trainings.remove(at: index)
                caches.trainings.insert(found, at: 0)
            }
            return
        }
        let entries = uncachedTrainingEntries(healthEntries: healthEntries)
        caches.trainings.insert(StoreCaches.Training(key: key, entries: entries), at: 0)
        if caches.trainings.count > 3 { caches.trainings.removeLast() }
    }

    /// The streak as of `now` (default: now). Shown again from the cache while nothing changed, on the
    /// same day, unless a workout dated later today starts counting (`StreakEngine.evaluatesAlike`).
    /// A past workout's recap passes its end, so it shows the streak of that day, not today's.
    func streakSummary(healthEntries: [ActivityEntry] = [], now: Date = Date()) -> StreakSummary {
        let engine = StreakEngine(calendar: calendar)
        prepareTraining(healthEntries: healthEntries)
        let entries = caches.trainings[0].entries
        if let hit = caches.trainings[0].streaks.first(where: { engine.evaluatesAlike(entries: entries, at: $0.now, and: now) }) {
            return hit.summary
        }
        let excused = (try? context.fetch(FetchDescriptor<ExcusedWeek>())) ?? []
        let summary = engine.evaluate(entries: entries, excusedWeeks: Set(excused.map(\.weekStart)),
                                      config: settings.streakConfig, now: now)
        caches.trainings[0].streaks.insert((now: now, summary: summary), at: 0)
        if caches.trainings[0].streaks.count > 4 { caches.trainings[0].streaks.removeLast() }
        return summary
    }

    // MARK: Today

    /// Workouts done today, the latest first (`uncachedPerformedToday`) – fetched again only when the
    /// log or the day changes.
    func performedToday() -> [WorkoutSession] {
        let today = calendar.startOfDay(for: Date())
        // Each one still done: marking a workout not done may not move the history (when the history
        // index hadn't seen it as done yet).
        if let cached = caches.performedToday, cached.revision == historyRevision, cached.day == today,
           cached.sessions.allSatisfy({ $0.modelContext != nil && !$0.isDeleted && $0.status.isPerformed }) {
            return cached.sessions
        }
        let sessions = uncachedPerformedToday()
        caches.performedToday = (revision: historyRevision, day: today, sessions: sessions)
        return sessions
    }

    /// The template for a day (`uncachedSuggestedTemplate`), kept per revision, program and day.
    func suggestedTemplate(in program: Program?, on date: Date = Date()) -> WorkoutTemplate? {
        guard let program else { return nil }
        let key = StoreCaches.SuggestionKey(revision: revision, program: program.id, day: calendar.startOfDay(for: date))
        if let cached = caches.suggestions[key] {
            guard let template = cached.template else { return nil }
            // A template deleted meanwhile (an import that hasn't moved the revision yet) is looked up again.
            if template.modelContext != nil && !template.isDeleted { return template }
        }
        if caches.suggestions.count >= 16 || caches.suggestions.keys.contains(where: { $0.revision != key.revision }) {
            caches.suggestions.removeAll()
        }
        let template = uncachedSuggestedTemplate(in: program, on: date)
        caches.suggestions[key] = StoreCaches.Suggestion(template: template)
        return template
    }
}
