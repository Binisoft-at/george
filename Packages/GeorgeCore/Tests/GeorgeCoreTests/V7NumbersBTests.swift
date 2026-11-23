import XCTest
@testable import GeorgeCore

/// v7 lane "numbersB": streak edge cases (break week, the next save, reminders across daylight-saving
/// changes), the freshness rules for the watch and the widgets, Plan This Week, and the energy rhythm.
final class V7NumbersBTests: XCTestCase {
    let vienna = TimeZone(identifier: "Europe/Vienna")!
    var calendar: Calendar { Calendar.training(timeZone: vienna) }
    var sundayFirst: Calendar { Calendar.training(firstWeekday: 1, timeZone: vienna) }

    func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 18, calendar: Calendar? = nil) -> Date {
        (calendar ?? self.calendar).date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    /// Workouts on the given day offsets from `start`.
    func entries(_ start: Date, days: [Int], calendar: Calendar? = nil) -> [ActivityEntry] {
        days.map { ActivityEntry(date: (calendar ?? self.calendar).addingDays($0, to: start), minutes: 40) }
    }

    // MARK: Streak – break week

    func testExcusedCurrentWeekIsCalm() {
        let engine = StreakEngine(calendar: calendar)
        let start = date(2026, 9, 28) // Monday
        var history: [ActivityEntry] = []
        for w in 0..<3 { history += entries(calendar.addingWeeks(w, to: start), days: [0, 2, 4]) }
        let thisMonday = calendar.addingWeeks(3, to: start)
        let sunday = calendar.addingDays(6, to: thisMonday)
        // One day trained, Sunday: without the break this is "at risk" / "rescue".
        let all = history + entries(thisMonday, days: [0])
        let config = StreakConfig(defaultGoal: 3, autoUseCredits: false)
        let normal = engine.evaluate(entries: all, config: config, now: sunday)
        XCTAssertNotEqual(normal.thisWeek.status, .onBreak)
        XCTAssertGreaterThan(normal.thisWeek.neededDays, 0)

        let summary = engine.evaluate(entries: all, excusedWeeks: [calendar.addingDays(2, to: thisMonday)], config: config, now: sunday)
        XCTAssertEqual(summary.thisWeek.status, .onBreak)
        XCTAssertEqual(summary.thisWeek.neededDays, 0, "no reminders, no rescue")
        XCTAssertEqual(summary.headline, "Break week — your streak is safe")
        XCTAssertEqual(summary.currentWeeks, 3)
        // The reminders follow neededDays: nothing about the streak in a break week.
        let reminders = ReminderPlanner.plan(now: calendar.addingDays(-1, to: sunday), workouts: [:], neededThisWeek: summary.thisWeek.neededDays,
                                             weekStart: thisMonday, minutesAfterMidnight: 17 * 60 + 30, calendar: calendar)
        XCTAssertTrue(reminders.isEmpty)

        // Goal met in a break week: simply met.
        let met = engine.evaluate(entries: history + entries(thisMonday, days: [0, 1, 2]), excusedWeeks: [thisMonday], config: config, now: sunday)
        XCTAssertEqual(met.thisWeek.status, .goalMet)
        XCTAssertEqual(met.currentWeeks, 4)
    }

    func testExcusedCurrentWeekIsCalmSundayFirst() {
        let cal = sundayFirst
        let engine = StreakEngine(calendar: cal)
        let start = date(2026, 9, 27, calendar: cal) // Sunday
        var history: [ActivityEntry] = []
        for w in 0..<2 { history += entries(cal.addingWeeks(w, to: start), days: [1, 3, 5], calendar: cal) }
        let thisSunday = cal.addingWeeks(2, to: start)
        let saturday = cal.addingDays(6, to: thisSunday)
        let summary = engine.evaluate(entries: history, excusedWeeks: [cal.addingDays(4, to: thisSunday)],
                                      config: StreakConfig(defaultGoal: 3), now: saturday)
        XCTAssertEqual(summary.thisWeek.weekStart, cal.startOfDay(for: thisSunday))
        XCTAssertEqual(summary.thisWeek.status, .onBreak)
        XCTAssertEqual(summary.thisWeek.neededDays, 0)
        XCTAssertEqual(summary.currentWeeks, 2)
        // Without a running streak the break still asks for nothing.
        let fresh = engine.evaluate(entries: [], excusedWeeks: [thisSunday], config: StreakConfig(defaultGoal: 3), now: saturday)
        XCTAssertEqual(fresh.thisWeek.status, .onBreak)
        XCTAssertEqual(fresh.headline, "Break week — no goal this week")
    }

    // MARK: Streak – the next save

    func testGoalMetWeekCountsTowardSave() {
        let engine = StreakEngine(calendar: calendar)
        let start = date(2026, 9, 28)
        let thisMonday = calendar.addingWeeks(1, to: start)
        let thursday = calendar.addingDays(3, to: thisMonday)
        let config = StreakConfig(defaultGoal: 3, weeksPerCredit: 2)
        let past = entries(start, days: [0, 2, 4])

        // One met week behind, this week's goal met: the save comes when this week ends.
        let met = engine.evaluate(entries: past + entries(thisMonday, days: [0, 1, 2]), config: config, now: thursday)
        XCTAssertEqual(met.thisWeek.status, .goalMet)
        XCTAssertEqual(met.credits, 0)
        XCTAssertEqual(met.weeksUntilNextCredit, 0)

        // Not met yet: this week is the one still needed.
        let running = engine.evaluate(entries: past + entries(thisMonday, days: [0]), config: config, now: thursday)
        XCTAssertEqual(running.weeksUntilNextCredit, 1)

        // First week met: one more after this one.
        let first = engine.evaluate(entries: entries(thisMonday, days: [0, 1, 2]), config: config, now: thursday)
        XCTAssertEqual(first.weeksUntilNextCredit, 1)

        // A save every week: a met week always ends with one.
        let weekly = engine.evaluate(entries: past + entries(thisMonday, days: [0, 1, 2]),
                                     config: StreakConfig(defaultGoal: 3, weeksPerCredit: 1), now: thursday)
        XCTAssertEqual(weekly.weeksUntilNextCredit, 0)
    }

    // MARK: Reminders across daylight saving

    func testReminderKeepsClockTimeAcrossDST() throws {
        let cal = calendar
        // Sunday 28 March 2027 (23 hours) and Sunday 31 October 2027 (25 hours) in Vienna.
        for (y, m, d) in [(2027, 3, 28), (2027, 10, 31)] {
            let sunday = cal.startOfDay(for: date(y, m, d))
            let monday = cal.weekStart(for: sunday)
            let saturdayNoon = date(y, m, d - 1, hour: 12)
            let training = ReminderPlanner.plan(now: saturdayNoon, workouts: [sunday: "UPPER"], neededThisWeek: 0, weekStart: monday,
                                                minutesAfterMidnight: 17 * 60 + 30, calendar: cal)
            XCTAssertEqual(training.count, 1)
            let fire = try XCTUnwrap(training.first?.fireDate)
            XCTAssertEqual(cal.component(.hour, from: fire), 17, "\(y)-\(m)-\(d)")
            XCTAssertEqual(cal.component(.minute, from: fire), 30)
            XCTAssertTrue(cal.isDate(fire, inSameDayAs: sunday))

            let streak = ReminderPlanner.plan(now: saturdayNoon, workouts: [:], neededThisWeek: 1, weekStart: monday,
                                              minutesAfterMidnight: 8 * 60, calendar: cal)
            XCTAssertEqual(streak.first?.kind, .streak)
            XCTAssertEqual(streak.first.map { cal.component(.hour, from: $0.fireDate) }, 8)
            XCTAssertEqual(streak.first.map { cal.component(.minute, from: $0.fireDate) }, 0)
        }
    }

    // MARK: Watch and widgets

    func testSnapshotTimingMovesOnWithTheWeek() {
        let cal = calendar
        let monday = cal.startOfDay(for: date(2026, 11, 16))
        let sundayNight = date(2026, 11, 22, hour: 23)
        let nextMonday = cal.addingDays(7, to: monday)
        XCTAssertEqual(SnapshotTiming.doneDays(3, weekStart: monday, on: sundayNight, calendar: cal), 3)
        XCTAssertEqual(SnapshotTiming.doneDays(3, weekStart: monday, on: nextMonday, calendar: cal), 0, "Monday: a new week, not last week's 3 of 3")
        XCTAssertEqual(SnapshotTiming.doneDays(3, weekStart: nil, on: nextMonday, calendar: cal), 3, "older phones: as sent")
        XCTAssertEqual(SnapshotTiming.dots([true, false, true, false, false, false, false], weekStart: monday, on: nextMonday, calendar: cal),
                       Array(repeating: false, count: 7))

        let tuesday = cal.addingDays(1, to: monday)
        XCTAssertEqual(SnapshotTiming.plan(tuesday, on: date(2026, 11, 17, hour: 7), calendar: cal), .today)
        // The midnight entry: yesterday's plan is missed, not "Today".
        XCTAssertEqual(SnapshotTiming.plan(tuesday, on: cal.addingDays(2, to: monday), calendar: cal), .missed(tuesday))
        XCTAssertEqual(SnapshotTiming.plan(tuesday, on: monday, calendar: cal), .later(tuesday))
    }

    func testWatchStreakCarriesItsWeek() throws {
        let monday = calendar.startOfDay(for: date(2026, 11, 16))
        let streak = WatchStreak(weeks: 4, doneDays: 3, goal: 3, credits: 1, headline: "Week done", dots: [true, false, true, false, false, false, false], weekStart: monday)
        let decoded = try WatchWire.decoder.decode(WatchStreak.self, from: WatchWire.encoder.encode(streak))
        XCTAssertEqual(decoded.weekStart, monday)
        // From an older phone (no week): still decodes.
        let old = #"{"weeks":4,"doneDays":2,"goal":3,"credits":0,"headline":"","dots":[true,false]}"#
        let legacy = try WatchWire.decoder.decode(WatchStreak.self, from: Data(old.utf8))
        XCTAssertNil(legacy.weekStart)
        XCTAssertEqual(legacy.doneDays, 2)
    }

    // MARK: Plan This Week

    let rotation = ["UPPER", "LOWER", "FULL"].map { PlannableTemplate(id: UUID(), name: $0, scheduleDays: []) }

    func testPlannedSessionsCountTowardGoal() {
        let cal = calendar
        let monday = cal.startOfDay(for: date(2026, 11, 16))
        let tuesday = cal.addingDays(1, to: monday)
        let thursday = cal.addingDays(3, to: monday)
        let plan = WeekPlanner.propose(templates: rotation, rotationStart: 0, weeklyGoal: 3, trainedThisWeek: 0,
                                       plannedDays: [tuesday, thursday], busyDays: [tuesday, thursday], from: monday, calendar: cal)
        XCTAssertEqual(plan.count, 1, "two planned + one = the goal of 3, not five")
        // With a rest day next to the planned ones.
        XCTAssertEqual(plan.first?.date, cal.addingDays(5, to: monday))

        // Goal already covered by plans and training: nothing to add.
        XCTAssertTrue(WeekPlanner.propose(templates: rotation, rotationStart: 0, weeklyGoal: 3, trainedThisWeek: 1,
                                          plannedDays: [tuesday, thursday], busyDays: [tuesday, thursday], from: monday, calendar: cal).isEmpty)
    }

    func testThursdayPlanMeetsThisWeek() {
        let cal = calendar
        let thursday = cal.startOfDay(for: date(2026, 11, 19))
        let nextMonday = cal.addingDays(4, to: thursday)
        let plan = WeekPlanner.propose(templates: rotation, rotationStart: 0, weeklyGoal: 3, trainedThisWeek: 0,
                                       busyDays: [], from: thursday, calendar: cal)
        let thisWeek = plan.filter { $0.date < nextMonday }
        XCTAssertEqual(thisWeek.count, 3, "the goal is still reachable this week: \(plan.map(\.date))")
        // Next week's Mon–Wed get their share of the goal, not all of it.
        XCTAssertLessThanOrEqual(plan.count - thisWeek.count, 1)
        XCTAssertEqual(Set(plan.map(\.date)).count, plan.count)

        let trainedOnce = WeekPlanner.propose(templates: rotation, rotationStart: 0, weeklyGoal: 3, trainedThisWeek: 1,
                                              busyDays: [], from: thursday, calendar: cal)
        XCTAssertEqual(trainedOnce.filter { $0.date < nextMonday }.count, 2)
        // Spread: no two on back-to-back days when there's room.
        let days = trainedOnce.filter { $0.date < nextMonday }.map(\.date)
        XCTAssertEqual(cal.daysBetween(days[0], days[1]), 2)
    }

    func testThursdayPlanMeetsThisWeekSundayFirst() {
        let cal = sundayFirst
        let thursday = cal.startOfDay(for: date(2026, 11, 19, calendar: cal))
        let nextSunday = cal.addingDays(3, to: thursday)
        XCTAssertEqual(cal.weekStart(for: nextSunday), nextSunday)
        let plan = WeekPlanner.propose(templates: rotation, rotationStart: 0, weeklyGoal: 3, trainedThisWeek: 0,
                                       busyDays: [], from: thursday, calendar: cal)
        // Thu, Fri, Sat are all that's left of this week – all three, before the week ends on Saturday.
        XCTAssertEqual(plan.filter { $0.date < nextSunday }.count, 3)
        // Sun–Wed of next week: about half of next week's goal.
        XCTAssertEqual(plan.filter { $0.date >= nextSunday }.count, 2)
        XCTAssertEqual(plan.map(\.templateName), ["UPPER", "LOWER", "FULL", "UPPER", "LOWER"])
    }

    func testMixedScheduledAndRotation() {
        let cal = calendar
        let monday = cal.startOfDay(for: date(2026, 11, 16))
        // UPPER on Mondays (weekday 2), LOWER and FULL without weekdays.
        let templates = [PlannableTemplate(id: UUID(), name: "UPPER", scheduleDays: [2])] + rotation.dropFirst()
        let plan = WeekPlanner.propose(templates: templates, rotationStart: 0, weeklyGoal: 3, trainedThisWeek: 0,
                                       busyDays: [], from: monday, calendar: cal)
        XCTAssertEqual(plan.map(\.templateName), ["UPPER", "LOWER", "FULL"], "the others are proposed too")
        XCTAssertEqual(plan.first?.date, monday)
        let gaps = zip(plan.dropFirst(), plan).map { cal.daysBetween($0.1.date, $0.0.date) }
        XCTAssertTrue(gaps.allSatisfy { $0 >= 2 }, "\(gaps)")

        // Only scheduled templates: their weekdays are the plan, as before.
        let scheduledOnly = [PlannableTemplate(id: UUID(), name: "LOWER", scheduleDays: [2]), PlannableTemplate(id: UUID(), name: "UPPER", scheduleDays: [6])]
        let weekly = WeekPlanner.propose(templates: scheduledOnly, rotationStart: 0, weeklyGoal: 3, trainedThisWeek: 0,
                                         busyDays: [], from: monday, calendar: cal)
        XCTAssertEqual(weekly.map(\.templateName), ["LOWER", "UPPER"])
    }

    // MARK: Energy rhythm

    /// A small deterministic generator (SplitMix64).
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func energy(_ levels: [Int?], from start: Date) -> [EnergyEntry] {
        levels.enumerated().compactMap { offset, level in
            level.map { EnergyEntry(date: calendar.addingDays(offset, to: start), level: $0) }
        }
    }

    func cycle(_ levels: [Int?], from start: Date) -> EnergyCycle? {
        EnergyAnalysis.analyze(entries: energy(levels, from: start), calendar: calendar,
                               now: calendar.addingDays(levels.count, to: start)).cycle
    }

    func testRandomEnergyHasNoRhythm() {
        let start = date(2026, 1, 5, hour: 9)
        var found = 0
        for seed in 0..<100 {
            var generator = SeededGenerator(state: UInt64(seed) &* 7919 &+ 17)
            let levels: [Int?] = (0..<42).map { _ in Int.random(in: 1...5, using: &generator) }
            if cycle(levels, from: start) != nil { found += 1 }
        }
        XCTAssertLessThanOrEqual(found, 5, "a 'rhythm' in \(found) of 100 random series")
    }

    func testStepAndDeclineAreNoRhythm() {
        let start = date(2026, 1, 5, hour: 9)
        for length in [42, 60, 84] {
            for split in [length / 3, length / 2, 2 * length / 3] {
                let step: [Int?] = (0..<length).map { $0 < split ? 4 : 2 }
                XCTAssertNil(cycle(step, from: start), "step at \(split) of \(length)")
            }
            let decline: [Int?] = (0..<length).map { Int((5 - 3 * Double($0) / Double(length - 1)).rounded()) }
            XCTAssertNil(cycle(decline, from: start), "decline over \(length)")
        }
    }

    func testRealRhythmIsStillFound() {
        let start = date(2026, 1, 5, hour: 9)
        // A 4-week rhythm over 12 weeks, two of three days logged.
        let levels: [Int?] = (0..<84).map { day in
            day % 3 == 2 ? nil : Int((3 + 1.8 * sin(Double(day) / 28 * 2 * .pi)).rounded())
        }
        let found = cycle(levels, from: start)
        XCTAssertNotNil(found)
        XCTAssertEqual(Double(found?.periodDays ?? 0), 28, accuracy: 3)
        XCTAssertGreaterThanOrEqual(found?.strength ?? 0, 0.5)
        // Its next low lies in a trough of the wave (around day 21 of each 28).
        if let low = found?.nextLow {
            let phase = calendar.daysBetween(start, low) % 28
            XCTAssertTrue((17...25).contains(phase), "phase \(phase)")
        }

        // Fewer than 60 % of the days logged: too much is filled in to judge.
        let sparse: [Int?] = (0..<84).map { day in
            day % 2 == 1 ? nil : Int((3 + 1.8 * sin(Double(day) / 28 * 2 * .pi)).rounded())
        }
        XCTAssertNil(cycle(sparse, from: start))
    }
}
