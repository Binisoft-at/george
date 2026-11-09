import Foundation

/// A change of the weekly goal, effective from the week containing `effectiveFrom`.
public struct GoalChange: Codable, Hashable, Sendable {
    public var effectiveFrom: Date
    public var daysPerWeek: Int
    public init(effectiveFrom: Date, daysPerWeek: Int) {
        self.effectiveFrom = effectiveFrom
        self.daysPerWeek = daysPerWeek
    }
}

/// Something that counts as a workout day for the streak.
public struct ActivityEntry: Hashable, Sendable {
    public enum Source: String, Sendable { case george, health }
    public var date: Date
    public var minutes: Double
    public var isRescue: Bool
    public var source: Source

    public init(date: Date, minutes: Double, isRescue: Bool = false, source: Source = .george) {
        self.date = date
        self.minutes = minutes
        self.isRescue = isRescue
        self.source = source
    }
}

public struct StreakConfig: Sendable {
    /// Goal history sorted by date. The latest change at or before a week applies.
    public var goals: [GoalChange]
    public var defaultGoal: Int
    /// Saves (streak freezes) are earned every `weeksPerCredit` consecutive weeks with the goal met.
    public var weeksPerCredit: Int
    public var maxCredits: Int
    /// Automatically spend a save when a week is missed.
    public var autoUseCredits: Bool
    /// A "rescue" mini workout counts as two days (at most once per week).
    public var rescueCountsDouble: Bool

    public init(
        goals: [GoalChange] = [], defaultGoal: Int = 3, weeksPerCredit: Int = 2, maxCredits: Int = 3,
        autoUseCredits: Bool = true, rescueCountsDouble: Bool = true
    ) {
        self.goals = goals.sorted { $0.effectiveFrom < $1.effectiveFrom }
        self.defaultGoal = defaultGoal
        self.weeksPerCredit = max(1, weeksPerCredit)
        self.maxCredits = max(0, maxCredits)
        self.autoUseCredits = autoUseCredits
        self.rescueCountsDouble = rescueCountsDouble
    }

    public func goal(forWeekStarting weekStart: Date, calendar: Calendar) -> Int {
        var result = defaultGoal
        var matched = false
        for change in goals where calendar.weekStart(for: change.effectiveFrom) <= weekStart {
            result = change.daysPerWeek
            matched = true
        }
        // Weeks before the first recorded change use the earliest goal.
        if !matched, let first = goals.first { result = first.daysPerWeek }
        return max(0, min(7, result))
    }
}

public enum WeekOutcome: String, Codable, Sendable {
    /// Goal reached.
    case met
    /// Goal missed but a save was spent so the streak survives.
    case saved
    /// Marked as an excused break week (sick, vacation). Neutral.
    case excused
    /// Goal missed, streak reset.
    case missed
    /// The current week, still running.
    case inProgress
}

public struct WeekRecord: Hashable, Sendable, Identifiable {
    public var id: Date { weekStart }
    public var weekStart: Date
    public var goal: Int
    public var workoutDays: Int
    public var effectiveDays: Int
    public var hadRescue: Bool
    public var outcome: WeekOutcome
    public var creditsAfter: Int
    public var streakAfter: Int
}

public enum CurrentWeekStatus: String, Sendable {
    /// Goal already reached this week.
    case goalMet
    /// Enough days left with room to spare.
    case onTrack
    /// Every remaining day needs a workout.
    case tight
    /// Can't reach the goal with regular workouts, but a rescue mini workout today would save it.
    case rescueAvailable
    /// The goal is out of reach but a save (credit) will cover the week.
    case creditWillCover
    /// The streak will end this week.
    case atRisk
    /// No streak running yet (first week or after a break).
    case fresh
}

public struct DayDot: Hashable, Sendable, Identifiable {
    public var id: Date { date }
    public var date: Date
    public var didWorkout: Bool
    public var isToday: Bool
    public var isFuture: Bool
    public var letter: String
}

public struct CurrentWeek: Sendable {
    public var weekStart: Date
    public var goal: Int
    public var workoutDays: Int
    public var effectiveDays: Int
    public var neededDays: Int
    public var remainingDays: Int
    public var workedOutToday: Bool
    public var hadRescue: Bool
    public var status: CurrentWeekStatus
    public var dots: [DayDot]

    public var progress: Double { goal == 0 ? 1 : min(1, Double(effectiveDays) / Double(goal)) }
}

public struct StreakSummary: Sendable {
    public var currentWeeks: Int
    public var bestWeeks: Int
    public var streakWorkoutDays: Int
    public var totalWorkoutDays: Int
    public var credits: Int
    public var maxCredits: Int
    public var weeksUntilNextCredit: Int?
    public var thisWeek: CurrentWeek
    /// Oldest first.
    public var history: [WeekRecord]

    public var headline: String {
        switch thisWeek.status {
        case .goalMet: return "Week done — streak is safe"
        case .onTrack: return "\(thisWeek.neededDays) more day\(thisWeek.neededDays == 1 ? "" : "s") this week"
        case .tight: return "Every day counts now — \(thisWeek.neededDays) to go"
        case .rescueAvailable: return "Save your streak with a quick workout today"
        case .creditWillCover: return "A save will protect your streak this week"
        case .atRisk: return "Streak at risk this week"
        case .fresh: return thisWeek.neededDays == 0 ? "Goal reached" : "\(thisWeek.neededDays) workout\(thisWeek.neededDays == 1 ? "" : "s") to start a streak"
        }
    }
}

/// Weekly-goal streaks with saves.
///
/// * A week counts when the number of distinct workout days reaches that week's goal.
/// * Every `weeksPerCredit` consecutive successful weeks earn a save (capped).
/// * A missed week spends a save automatically (if enabled) so the streak survives.
/// * A rescue mini workout counts double once per week ("finish a small workout now").
/// * Excused weeks are neutral.
///
/// Everything is derived from history, so it is deterministic and sync-safe.
public struct StreakEngine: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .training()) {
        self.calendar = calendar
    }

    public func evaluate(entries: [ActivityEntry], excusedWeeks: Set<Date> = [], config: StreakConfig, now: Date = Date()) -> StreakSummary {
        let thisWeekStart = calendar.weekStart(for: now)
        let excused = Set(excusedWeeks.map { calendar.weekStart(for: $0) })
        var byWeek: [Date: [ActivityEntry]] = [:]
        for entry in entries where entry.date <= now.addingTimeInterval(60) {
            byWeek[calendar.weekStart(for: entry.date), default: []].append(entry)
        }
        let allDays = Set(entries.filter { $0.date <= now.addingTimeInterval(60) }.map { calendar.startOfDay(for: $0.date) })

        var history: [WeekRecord] = []
        var credits = 0
        var runMet = 0
        var streak = 0
        var best = 0
        var streakDays = 0

        if let firstDate = byWeek.keys.min() {
            var week = firstDate
            var guardCounter = 0
            while week < thisWeekStart && guardCounter < 2000 {
                guardCounter += 1
                let weekEntries = byWeek[week] ?? []
                let days = Set(weekEntries.map { calendar.startOfDay(for: $0.date) }).count
                let hadRescue = weekEntries.contains { $0.isRescue }
                let goal = config.goal(forWeekStarting: week, calendar: calendar)
                let effective = days + (hadRescue && config.rescueCountsDouble && days > 0 ? 1 : 0)
                let outcome: WeekOutcome
                if effective >= goal && (goal > 0 || days > 0 || streak > 0) {
                    outcome = .met
                    runMet += 1
                    streak += 1
                    streakDays += days
                    if runMet % config.weeksPerCredit == 0 {
                        credits = min(config.maxCredits, credits + 1)
                    }
                } else if excused.contains(week) {
                    outcome = .excused
                    streakDays += days
                } else if config.autoUseCredits && credits > 0 && streak > 0 {
                    outcome = .saved
                    credits -= 1
                    streakDays += days
                } else {
                    outcome = .missed
                    streak = 0
                    streakDays = 0
                    runMet = 0
                }
                best = max(best, streak)
                history.append(WeekRecord(
                    weekStart: week, goal: goal, workoutDays: days, effectiveDays: effective,
                    hadRescue: hadRescue, outcome: outcome, creditsAfter: credits, streakAfter: streak
                ))
                week = calendar.addingWeeks(1, to: week)
            }
        }

        // Current week
        let currentEntries = byWeek[thisWeekStart] ?? []
        let today = calendar.startOfDay(for: now)
        let workoutDaySet = Set(currentEntries.map { calendar.startOfDay(for: $0.date) })
        let days = workoutDaySet.count
        let hadRescue = currentEntries.contains { $0.isRescue }
        let goal = config.goal(forWeekStarting: thisWeekStart, calendar: calendar)
        let effective = days + (hadRescue && config.rescueCountsDouble && days > 0 ? 1 : 0)
        let needed = max(0, goal - effective)
        let dayIndex = max(0, min(6, calendar.daysBetween(thisWeekStart, today)))
        let remaining = 7 - dayIndex
        let workedOutToday = workoutDaySet.contains(today)
        let available = remaining - (workedOutToday ? 1 : 0)

        var currentWeeks = streak
        var currentStreakDays = streakDays + days
        let status: CurrentWeekStatus
        if needed == 0 {
            status = .goalMet
            currentWeeks += 1
        } else if needed < available {
            status = streak == 0 ? .fresh : .onTrack
        } else if needed == available {
            status = streak == 0 ? .fresh : .tight
        } else if config.rescueCountsDouble && !hadRescue && !workedOutToday && needed <= available + 1 {
            status = streak == 0 ? .fresh : .rescueAvailable
        } else if config.rescueCountsDouble && !hadRescue && workedOutToday && needed <= 1 {
            status = streak == 0 ? .fresh : .rescueAvailable
        } else if config.autoUseCredits && credits > 0 && streak > 0 {
            status = .creditWillCover
        } else {
            status = streak == 0 ? .fresh : .atRisk
        }
        if currentWeeks == 0 { currentStreakDays = days }
        best = max(best, currentWeeks)

        let letters = ["S", "M", "T", "W", "T", "F", "S"]
        var dots: [DayDot] = []
        for offset in 0..<7 {
            let date = calendar.addingDays(offset, to: thisWeekStart)
            let weekday = calendar.component(.weekday, from: date) - 1
            dots.append(DayDot(
                date: date,
                didWorkout: workoutDaySet.contains(date),
                isToday: date == today,
                isFuture: date > today,
                letter: letters[max(0, min(6, weekday))]
            ))
        }

        let thisWeek = CurrentWeek(
            weekStart: thisWeekStart, goal: goal, workoutDays: days, effectiveDays: effective,
            neededDays: needed, remainingDays: remaining, workedOutToday: workedOutToday,
            hadRescue: hadRescue, status: status, dots: dots
        )

        var untilNext: Int? = nil
        if credits < config.maxCredits {
            let progress = runMet % config.weeksPerCredit
            untilNext = config.weeksPerCredit - progress
        }

        return StreakSummary(
            currentWeeks: currentWeeks,
            bestWeeks: best,
            streakWorkoutDays: currentStreakDays,
            totalWorkoutDays: allDays.count,
            credits: credits,
            maxCredits: config.maxCredits,
            weeksUntilNextCredit: untilNext,
            thisWeek: thisWeek,
            history: history
        )
    }
}
