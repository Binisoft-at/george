import XCTest
@testable import GeorgeCore

/// Review of v7 wave 3, lane "numbers": the days chart's break weeks agree with the streak under every
/// streak setting it is rebuilt for (rescue counts double, the first weekday), and the plate hint stays
/// cheap for every number typed on the way to a stray one.
final class V7W3NumbersReviewTests: XCTestCase {
    let vienna = TimeZone(identifier: "Europe/Vienna")!

    func calendar(firstWeekday: Int = 2) -> Calendar {
        Calendar.training(firstWeekday: firstWeekday, timeZone: vienna)
    }

    /// Each finished week's chart state against the streak's outcome for the same entries and breaks.
    private func assertAgreesWithStreak(entries: [ActivityEntry], breaks: Set<Date>, config: StreakConfig, now: Date,
                                        calendar: Calendar, weeks count: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let weeks = StatsEngine.weekly([], calendar: calendar, weeks: count, now: now, trainingDays: entries,
                                       rescueCountsDouble: config.rescueCountsDouble)
        let goals = StatsEngine.weekGoals(weeks, config: config, breakWeeks: breaks, calendar: calendar)
        let summary = StreakEngine(calendar: calendar).evaluate(entries: entries, excusedWeeks: breaks, config: config, now: now)
        XCTAssertFalse(summary.history.isEmpty, file: file, line: line)
        for record in summary.history {
            let state = try XCTUnwrap(goals[record.weekStart]?.state, file: file, line: line)
            switch record.outcome {
            case .met: XCTAssertEqual(state, .reached, "\(record.weekStart)", file: file, line: line)
            case .excused: XCTAssertEqual(state, .onBreak, "\(record.weekStart)", file: file, line: line)
            case .missed, .saved: XCTAssertEqual(state, .below, "\(record.weekStart)", file: file, line: line)
            case .inProgress: XCTFail("no running week in the history", file: file, line: line)
            }
        }
        let current = try XCTUnwrap(goals[summary.thisWeek.weekStart]?.state, file: file, line: line)
        switch summary.thisWeek.status {
        case .goalMet: XCTAssertEqual(current, .reached, file: file, line: line)
        case .onBreak: XCTAssertEqual(current, .onBreak, file: file, line: line)
        default: XCTAssertEqual(current, .below, file: file, line: line)
        }
    }

    func testBreakWeekWithARescueFollowsTheRescueSetting() throws {
        let cal = calendar()
        let start = cal.weekStart(for: cal.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 12))!)
        // Week 0: 3 days. Week 1 (break): 2 days, one of them a rescue – 3 with "counts double", 2 without.
        // Week 2 (break, now): 1 day plus a rescue on the same day.
        var entries = [0, 2, 4].map { ActivityEntry(date: cal.addingDays($0, to: start).addingTimeInterval(18 * 3600), minutes: 40) }
        let week1 = cal.addingWeeks(1, to: start)
        entries.append(ActivityEntry(date: cal.addingDays(1, to: week1).addingTimeInterval(18 * 3600), minutes: 40))
        entries.append(ActivityEntry(date: cal.addingDays(3, to: week1).addingTimeInterval(18 * 3600), minutes: 15, isRescue: true))
        let week2 = cal.addingWeeks(2, to: start)
        entries.append(ActivityEntry(date: cal.addingDays(1, to: week2).addingTimeInterval(9 * 3600), minutes: 15, isRescue: true))
        let breaks: Set<Date> = [cal.addingDays(3, to: week1), week2]
        let now = cal.addingDays(2, to: week2).addingTimeInterval(20 * 3600)

        for double in [true, false] {
            let config = StreakConfig(defaultGoal: 3, autoUseCredits: false, rescueCountsDouble: double)
            try assertAgreesWithStreak(entries: entries, breaks: breaks, config: config, now: now, calendar: cal, weeks: 3)
            let weeks = StatsEngine.weekly([], calendar: cal, weeks: 3, now: now, trainingDays: entries, rescueCountsDouble: double)
            let goals = StatsEngine.weekGoals(weeks, config: config, breakWeeks: breaks, calendar: cal)
            // The rescue decides whether the break week reached its goal: the chart must be rebuilt when
            // the setting changes (StatsView keys its model on it).
            XCTAssertEqual(goals[week1]?.state, double ? .reached : .onBreak)
            XCTAssertEqual(goals[week2]?.state, .onBreak)
        }
    }

    func testBreaksStoredWithAnotherFirstWeekdayReadLikeTheStreak() throws {
        // Marked while weeks began on Monday, then Settings → week starts on Sunday.
        let monday = calendar(firstWeekday: 2)
        let sunday = calendar(firstWeekday: 1)
        let start = monday.weekStart(for: monday.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 12))!)
        let entries = (0..<6).flatMap { week in
            [0, 2].map { ActivityEntry(date: monday.addingDays($0, to: monday.addingWeeks(week, to: start)).addingTimeInterval(18 * 3600), minutes: 40) }
        }
        let breaks: Set<Date> = [monday.addingWeeks(2, to: start), monday.addingWeeks(4, to: start)]
        let now = monday.addingDays(3, to: monday.addingWeeks(5, to: start))
        let config = StreakConfig(defaultGoal: 3, autoUseCredits: false)
        try assertAgreesWithStreak(entries: entries, breaks: breaks, config: config, now: now, calendar: sunday, weeks: 6)
        try assertAgreesWithStreak(entries: entries, breaks: breaks, config: config, now: now, calendar: monday, weeks: 6)
    }

    func testEveryKeystrokeOnTheWayToAStrayNumberIsCheap() {
        // 9, 99, 999 … 9,999,999 in kg and lb with each plate set: a hint only up to the cap, no more
        // than the plate limit, and a quick answer either way.
        let sets: [[Double]] = [[25, 20, 15, 10, 5, 2.5, 1.25], [25, 20, 15, 10, 5, 2.5],
                                [45, 35, 25, 10, 5, 2.5].map { WeightUnit.lb.toKilograms($0) }]
        for unit in [WeightUnit.kg, .lb] {
            for plates in sets {
                var typed = 0.0
                for _ in 0..<7 {
                    typed = typed * 10 + 9
                    let kg = unit.toKilograms(typed)
                    let load = PlateMath.load(totalKg: kg, barKg: 20, plates: plates)
                    if (kg - 20) / 2 > PlateMath.maxPerSideKg + 0.001 {
                        XCTAssertNil(load, "\(typed) \(unit)")
                        XCTAssertNil(PlateMath.text(totalKg: kg, barKg: 20, plates: plates, unit: unit))
                    } else if kg >= 20 {
                        XCTAssertNotNil(load, "\(typed) \(unit)")
                    }
                    XCTAssertLessThanOrEqual(load?.perSide.count ?? 0, PlateMath.maxPlatesPerSide)
                }
            }
        }
    }
}
