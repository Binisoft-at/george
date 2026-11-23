import Foundation

/// How a week reads against its goal in Progress → Workout days, by the streak's rules: a week that
/// reached its goal counts, a break week (sick, travel) that didn't is neutral, any other is below.
public enum WeekGoalState: String, Hashable, Sendable {
    /// The goal was reached – a break week too, when you reached it anyway.
    case reached
    /// Marked as a break and the goal not reached: neutral, grey like the streak's history.
    case onBreak
    /// Below the goal.
    case below
}

/// A week's goal and how the week did against it (one bar of Progress → Workout days).
public struct WeekGoal: Hashable, Sendable {
    /// The goal the week had (`StreakConfig.goal(forWeekStarting:calendar:)`).
    public var goal: Int
    /// The week is marked as a break.
    public var isBreak: Bool
    public var state: WeekGoalState

    public init(goal: Int, isBreak: Bool, effectiveDays: Int) {
        self.goal = goal
        self.isBreak = isBreak
        state = Self.state(effectiveDays: effectiveDays, goal: goal, isBreak: isBreak)
    }

    /// `effectiveDays` as the streak counts them (`WeekStat.effectiveDays`, a rescue counts double).
    /// A break week with no workouts stays a break even when its goal is 0.
    public static func state(effectiveDays: Int, goal: Int, isBreak: Bool) -> WeekGoalState {
        if isBreak && (effectiveDays < goal || effectiveDays == 0) { return .onBreak }
        return effectiveDays >= goal ? .reached : .below
    }
}

public extension StatsEngine {
    /// Each week's goal and state, by week start. `breakWeeks`: the break weeks as stored (any date in
    /// the week), read in `calendar` like the streak reads them (`StreakEngine.evaluate(excusedWeeks:)`).
    static func weekGoals(_ weeks: [WeekStat], config: StreakConfig, breakWeeks: Set<Date>, calendar: Calendar) -> [Date: WeekGoal] {
        let breaks = Set(breakWeeks.map { calendar.weekStart(for: $0) })
        let pairs = weeks.map { week in
            (week.weekStart, WeekGoal(goal: config.goal(forWeekStarting: week.weekStart, calendar: calendar),
                                      isBreak: breaks.contains(week.weekStart), effectiveDays: week.effectiveDays))
        }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }
}
