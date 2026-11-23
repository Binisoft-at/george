import XCTest
@testable import GeorgeCore

/// v7 wave 3, lane "numbers": the plate hint gives up on absurd loads, and break weeks read as
/// neutral in Progress → Workout days, as in the streak.
final class V7W3NumbersTests: XCTestCase {
    let vienna = TimeZone(identifier: "Europe/Vienna")!
    var calendar: Calendar { Calendar.training(timeZone: vienna) }

    func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 18) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    // MARK: Plate math cap

    func testHugeLoadGivesNoPlateHint() {
        // 9,999,999 typed on the live keypad: no plates, no text – and no 200,000 plates built.
        XCTAssertNil(PlateMath.load(totalKg: 9_999_999))
        XCTAssertNil(PlateMath.text(totalKg: 9_999_999))
        XCTAssertNil(PlateMath.perSide(totalKg: 9_999_999))
        let pounds = [45, 35, 25, 10, 5, 2.5].map { WeightUnit.lb.toKilograms($0) }
        let lb = WeightUnit.lb.toKilograms(9_999_999)
        XCTAssertNil(PlateMath.load(totalKg: lb, barKg: WeightUnit.lb.toKilograms(45), plates: pounds))
        XCTAssertNil(PlateMath.text(totalKg: lb, barKg: WeightUnit.lb.toKilograms(45), plates: pounds, unit: .lb))
    }

    func testNonFiniteLoadGivesNoPlateHint() {
        XCTAssertNil(PlateMath.load(totalKg: .infinity))
        XCTAssertNil(PlateMath.load(totalKg: .nan))
        XCTAssertNil(PlateMath.text(totalKg: 100, barKg: .nan))
    }

    func testPerSideCapIsInclusive() throws {
        // 1,000 kg a side still gets its plates; a quarter kilo more doesn't.
        let load = try XCTUnwrap(PlateMath.load(totalKg: 20 + 2 * PlateMath.maxPerSideKg))
        XCTAssertEqual(load.perSide.count, 40)
        XCTAssertTrue(load.perSide.allSatisfy { $0 == 25 })
        XCTAssertTrue(load.isExact)
        XCTAssertNil(PlateMath.load(totalKg: 20 + 2 * PlateMath.maxPerSideKg + 0.5))
    }

    func testPoundPlatesUpTo2200lbPerSide() throws {
        let pounds = [45, 35, 25, 10, 5, 2.5].map { WeightUnit.lb.toKilograms($0) }
        let bar = WeightUnit.lb.toKilograms(45)
        let total = WeightUnit.lb.toKilograms(45 + 2 * 2200)
        let load = try XCTUnwrap(PlateMath.load(totalKg: total, barKg: bar, plates: pounds))
        XCTAssertLessThanOrEqual(load.perSide.count, PlateMath.maxPlatesPerSide)
        XCTAssertTrue(load.isExact)
    }

    func testPlateCountLimit() throws {
        let small = [1.25]
        let atLimit = 20 + 2 * 1.25 * Double(PlateMath.maxPlatesPerSide)
        XCTAssertEqual(try XCTUnwrap(PlateMath.load(totalKg: atLimit, plates: small)).perSide.count, PlateMath.maxPlatesPerSide)
        XCTAssertNil(PlateMath.load(totalKg: atLimit + 2.5, plates: small))
        XCTAssertNil(PlateMath.text(totalKg: atLimit + 2.5, plates: small))
    }

    func testEverydayLoadsUnchanged() {
        XCTAssertEqual(PlateMath.perSide(totalKg: 100), [25, 15])
        XCTAssertEqual(PlateMath.text(totalKg: 20), "Empty bar")
        XCTAssertEqual(PlateMath.text(totalKg: 62.5), "20 + 1.25 per side")
        XCTAssertNil(PlateMath.load(totalKg: 15), "below the bar")
        XCTAssertEqual(PlateMath.text(totalKg: 300), "25 + 25 + 25 + 25 + 25 + 15 per side")
    }

    // MARK: Break weeks in Workout days

    func testStateRules() {
        XCTAssertEqual(WeekGoal.state(effectiveDays: 3, goal: 3, isBreak: false), .reached)
        XCTAssertEqual(WeekGoal.state(effectiveDays: 1, goal: 3, isBreak: false), .below)
        XCTAssertEqual(WeekGoal.state(effectiveDays: 1, goal: 3, isBreak: true), .onBreak)
        XCTAssertEqual(WeekGoal.state(effectiveDays: 0, goal: 3, isBreak: true), .onBreak)
        // A break week whose goal was met anyway stays "goal reached", as in the streak.
        XCTAssertEqual(WeekGoal.state(effectiveDays: 4, goal: 3, isBreak: true), .reached)
        // No goal: reached, unless it's a break with nothing done.
        XCTAssertEqual(WeekGoal.state(effectiveDays: 0, goal: 0, isBreak: false), .reached)
        XCTAssertEqual(WeekGoal.state(effectiveDays: 0, goal: 0, isBreak: true), .onBreak)
        XCTAssertEqual(WeekGoal.state(effectiveDays: 1, goal: 0, isBreak: true), .reached)
    }

    func testWeekGoalsMarkBreakWeeksLikeTheStreak() throws {
        let start = date(2026, 9, 28) // Monday
        // Week 0: 3 days (met). Week 1: 1 day, break. Week 2: 1 day, no break. Week 3: 4 days, break.
        // Week 4 (now): 0 days, break.
        let plan: [[Int]] = [[0, 2, 4], [1], [3], [0, 1, 2, 3], []]
        var entries: [ActivityEntry] = []
        for (week, days) in plan.enumerated() {
            for day in days {
                entries.append(ActivityEntry(date: calendar.addingDays(day, to: calendar.addingWeeks(week, to: start)), minutes: 40))
            }
        }
        // Stored as any day of the week (a Wednesday evening, a Sunday).
        let breaks: Set<Date> = [
            calendar.addingDays(2, to: calendar.addingWeeks(1, to: start)),
            calendar.addingDays(6, to: calendar.addingWeeks(3, to: start)),
            calendar.addingWeeks(4, to: start),
        ]
        let now = calendar.addingDays(3, to: calendar.addingWeeks(4, to: start))
        let config = StreakConfig(defaultGoal: 3, autoUseCredits: false)
        let weeks = StatsEngine.weekly([], calendar: calendar, weeks: 5, now: now, trainingDays: entries)
        XCTAssertEqual(weeks.count, 5)
        let goals = StatsEngine.weekGoals(weeks, config: config, breakWeeks: breaks, calendar: calendar)
        let states = weeks.map { goals[$0.weekStart]?.state }
        XCTAssertEqual(states, [.reached, .onBreak, .below, .reached, .onBreak])
        XCTAssertEqual(weeks.map { goals[$0.weekStart]?.isBreak }, [false, true, false, true, true])
        XCTAssertTrue(goals.values.allSatisfy { $0.goal == 3 })

        // The streak agrees on the finished weeks: excused ↔ break, met ↔ reached, missed ↔ below.
        let summary = StreakEngine(calendar: calendar).evaluate(entries: entries, excusedWeeks: breaks, config: config, now: now)
        XCTAssertEqual(summary.thisWeek.status, .onBreak)
        for record in summary.history {
            let state = try XCTUnwrap(goals[record.weekStart]?.state)
            switch record.outcome {
            case .met: XCTAssertEqual(state, .reached)
            case .excused: XCTAssertEqual(state, .onBreak)
            case .missed: XCTAssertEqual(state, .below)
            default: XCTFail("unexpected \(record.outcome)")
            }
        }
    }

    func testWeekGoalsFollowGoalChanges() {
        let start = date(2026, 9, 28)
        let entries = [0, 1].map { ActivityEntry(date: calendar.addingDays($0, to: calendar.addingWeeks(1, to: start)), minutes: 40) }
        let now = calendar.addingDays(5, to: calendar.addingWeeks(1, to: start))
        // Goal 2 from week 1 on, 4 before.
        let config = StreakConfig(goals: [GoalChange(effectiveFrom: start, daysPerWeek: 4),
                                          GoalChange(effectiveFrom: calendar.addingWeeks(1, to: start), daysPerWeek: 2)])
        let weeks = StatsEngine.weekly([], calendar: calendar, weeks: 2, now: now, trainingDays: entries)
        let goals = StatsEngine.weekGoals(weeks, config: config, breakWeeks: [], calendar: calendar)
        XCTAssertEqual(weeks.map { goals[$0.weekStart]?.goal }, [4, 2])
        XCTAssertEqual(weeks.map { goals[$0.weekStart]?.state }, [.below, .reached])
    }

    func testBreakWeekOutsideTheRangeIsIgnored() {
        let start = date(2026, 9, 28)
        let now = calendar.addingDays(2, to: start)
        let weeks = StatsEngine.weekly([], calendar: calendar, weeks: 1, now: now, trainingDays: [])
        let goals = StatsEngine.weekGoals(weeks, config: StreakConfig(defaultGoal: 3), breakWeeks: [calendar.addingWeeks(-3, to: start)],
                                          calendar: calendar)
        let monday = calendar.weekStart(for: start)
        XCTAssertEqual(goals.count, 1)
        XCTAssertEqual(goals[monday]?.state, .below)
        XCTAssertEqual(goals[monday]?.isBreak, false)
    }
}
