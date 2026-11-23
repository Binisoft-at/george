import XCTest
@testable import GeorgeCore

/// v7 review, Core numbers: huge typed numbers, Add Set after "Can't finish", the Progress days chart
/// and the rescue rule, templates an older George saved after a swap, Update Loads for holds, and
/// Plan Week around days that already count.
final class V7ReviewCoreTests: XCTestCase {
    private let calendar = Calendar.training(timeZone: TimeZone(identifier: "UTC")!)

    private func straight(_ name: String, sets: Int, reps: String, kg: Double?) -> WorkoutItem {
        WorkoutItem(name: name, sets: (0..<sets).map { _ in WorkoutSet(targetReps: reps, targetWeight: kg) })
    }

    private func superset() -> WorkoutContent {
        WorkoutContent(blocks: [WorkoutBlock(style: .superset, restAfterRoundSeconds: 60, items: [
            straight("A", sets: 3, reps: "8", kg: 40), straight("B", sets: 3, reps: "10", kg: nil),
        ])])
    }

    // MARK: Huge numbers

    func testHugeTypedNumberIsRejected() {
        XCTAssertNil(NumberParser.double("99999999999999999999"))
        XCTAssertNil(NumberParser.double("10000000"))
        XCTAssertEqual(NumberParser.double("9999999"), 9_999_999, "the live keypad's 7 digits still work")
        XCTAssertEqual(NumberParser.double("62,5"), 62.5)
        XCTAssertNil(NumberParser.int("99999999999999999999"))
    }

    func testSetValueNeverTraps() {
        var set = WorkoutSet(targetReps: "8")
        set.setValue(.reps, 1e20, inSession: true)
        XCTAssertEqual(set.reps, 9_999_999)
        set.setValue(.seconds, 1e20, inSession: false)
        XCTAssertEqual(set.targetSeconds, 9_999_999)
        set.setValue(.weight, .infinity, inSession: true)
        XCTAssertEqual(set.weight, 9_999_999)
        set.setValue(.meters, .nan, inSession: true)
        XCTAssertEqual(set.meters, 0)
        set.setValue(.reps, -3, inSession: true)
        XCTAssertEqual(set.reps, 0)
        set.setValue(.weight, 62.5, inSession: true)
        XCTAssertEqual(set.weight, 62.5)
    }

    func testFormatNumberNeverTraps() {
        XCTAssertEqual(Format.number(1e20), "100000000000000000000")
        XCTAssertEqual(Format.number(.infinity), "inf")
        XCTAssertEqual(Format.weight(1e20, unit: .kg), "100000000000000000000 kg")
        XCTAssertEqual(Format.number(12), "12")
        XCTAssertEqual(Format.number(-4), "-4")
        XCTAssertEqual(Format.number(62.5), "62.5")
    }

    // MARK: Add Set after "Can't finish"

    func testAddSetAfterLiveDropCopiesTheWorkingSet() throws {
        let template = superset()
        var session = template.freshCopy()
        let a = session.blocks[0].items[0]
        let b = session.blocks[0].items[1]
        for set in a.sets.prefix(2) + b.sets.prefix(3) { session.toggleSet(id: set.id) }
        // Last round of A: "Can't finish? Lower the weight", then "Add Set".
        try XCTUnwrap(session.dropWeight(setID: a.sets[2].id, repsDone: 5, newWeightKg: 30, applyToRemaining: false))
        session.addSet(to: a.id)
        let added = try XCTUnwrap(session.item(id: a.id)?.sets.last)
        XCTAssertEqual(added.kind, .working, "a set for another round, not a copy of today's drop set")
        XCTAssertEqual(added.targetWeight, 40)
        XCTAssertNil(added.addedLive)
        XCTAssertEqual(session.blocks[0].laneRoundCounts, [4, 3], "the added set is a fourth round")

        // Update Template: the drop set stays out, the added set goes in as a working set.
        for set in session.allItems.flatMap(\.sets) where !set.isDone { session.toggleSet(id: set.id) }
        let saved = session.asTemplate(mode: .everything, base: template)
        XCTAssertEqual(saved.blocks[0].items[0].sets.map(\.kind), [.working, .working, .working, .working])
        XCTAssertEqual(saved.blocks[0].items[0].sets.map(\.targetWeight), [40, 40, 40, 40])
    }

    func testSetStepperAfterLiveDropAddsWorkingSet() throws {
        var content = WorkoutContent(blocks: [WorkoutBlock(items: [straight("Bench", sets: 2, reps: "8", kg: 60)])])
        let item = content.allItems[0]
        content.toggleSet(id: item.sets[0].id)
        try XCTUnwrap(content.dropWeight(setID: item.sets[1].id, repsDone: 4, newWeightKg: 50, applyToRemaining: false))
        content.setSetCount(of: item.id, to: 4)
        let sets = try XCTUnwrap(content.item(id: item.id)?.sets)
        XCTAssertEqual(sets.map(\.kind), [.working, .working, .drop, .working])
        XCTAssertEqual(sets.last?.targetWeight, 60)
        XCTAssertNil(sets.last?.addedLive)
    }

    func testAddSetStillCopiesAPlannedDropSet() {
        // A drop set in the plan is not today's rescue: Add Set copies the last set as before.
        let bench = WorkoutItem(name: "Bench", sets: [WorkoutSet(targetReps: "8", targetWeight: 60),
                                                      WorkoutSet(kind: .drop, targetReps: "8", targetWeight: 45)])
        XCTAssertEqual(bench.makeNextSet().kind, .drop)
        XCTAssertEqual(bench.makeNextSet().targetWeight, 45)
    }

    func testAddSetWithOnlyLiveSetsMakesAWorkingSet() {
        var warmup = WorkoutSet(kind: .warmup, targetReps: "5", targetWeight: 20)
        warmup.addedLive = true
        let item = WorkoutItem(name: "Squat", sets: [warmup])
        let next = item.makeNextSet()
        XCTAssertEqual(next.kind, .working)
        XCTAssertNil(next.addedLive)
        XCTAssertEqual(next.targetWeight, 20)
    }

    // MARK: Progress days chart and the rescue rule

    func testWeeklyEffectiveDaysFollowTheStreak() throws {
        let monday = calendar.weekStart(for: Date(timeIntervalSince1970: 1_800_000_000))
        let now = calendar.addingWeeks(2, to: monday)
        let entries = [
            ActivityEntry(date: monday.addingTimeInterval(18 * 3600), minutes: 45),
            ActivityEntry(date: calendar.addingDays(2, to: monday).addingTimeInterval(18 * 3600), minutes: 8, isRescue: true),
        ]
        let config = StreakConfig(defaultGoal: 3)
        let streakWeek = try XCTUnwrap(StreakEngine(calendar: calendar).evaluate(entries: entries, config: config, now: now)
            .history.first { $0.weekStart == monday })
        XCTAssertEqual(streakWeek.effectiveDays, 3)
        XCTAssertEqual(streakWeek.outcome, .met)

        let weeks = StatsEngine.weekly([], calendar: calendar, weeks: 4, now: now, trainingDays: entries)
        let week = try XCTUnwrap(weeks.first { $0.weekStart == monday })
        XCTAssertEqual(week.workoutDays, 2)
        XCTAssertEqual(week.effectiveDays, streakWeek.effectiveDays, "the chart reads the week as the streak does")

        let plain = StatsEngine.weekly([], calendar: calendar, weeks: 4, now: now, trainingDays: entries, rescueCountsDouble: false)
        XCTAssertEqual(plain.first { $0.weekStart == monday }?.effectiveDays, 2)
        XCTAssertEqual(weeks.first { $0.weekStart == now }?.effectiveDays, 0)
    }

    // MARK: Templates saved by an older George after a swap

    /// [A ×1, A2 ×2 continuing A's rounds, B ×3]: what an older George saved after swapping A for A2.
    private func legacySwapTemplate() -> WorkoutContent {
        var a2 = straight("A2", sets: 2, reps: "8", kg: 24)
        a2.roundOffset = 1
        return WorkoutContent(blocks: [WorkoutBlock(style: .superset, restAfterRoundSeconds: 60, items: [
            straight("A", sets: 1, reps: "8", kg: 40), a2, straight("B", sets: 3, reps: "10", kg: nil),
        ])])
    }

    func testLegacySwapTemplateDoneAsPlannedIsUnchanged() {
        let template = legacySwapTemplate()
        var session = template.freshCopy()
        for set in session.allItems.flatMap(\.sets) { session.toggleSet(id: set.id) }
        XCTAssertFalse(session.changesTemplateStructure(template), "no 'You changed this workout' after every session")
        XCTAssertEqual(session.templateChanges(into: template, mode: .everything), [])
        XCTAssertEqual(session.templateChanges(into: template, mode: .loads), [])
    }

    func testLegacySwapTemplateStillSeesRealChanges() {
        let template = legacySwapTemplate()
        var session = template.freshCopy()
        let b = session.blocks[0].items[2]
        session.removeSet(id: b.sets[2].id)
        for set in session.allItems.flatMap(\.sets) { session.toggleSet(id: set.id) }
        XCTAssertTrue(session.changesTemplateStructure(template))
        XCTAssertEqual(session.templateChanges(into: template, mode: .everything), ["B 3→2 sets"])
    }

    // MARK: Update Loads for holds

    func testLongerHoldIsALoadChange() {
        let plank = WorkoutItem(name: "Plank", mode: .time, sets: [WorkoutSet(targetSeconds: 45)])
        let template = WorkoutContent(blocks: [WorkoutBlock(items: [plank])])
        var session = template.freshCopy()
        let id = session.allItems[0].sets[0].id
        session.updateSet(id: id) { $0.seconds = 60; $0.isDone = true }
        XCTAssertEqual(session.loadChanges(comparedTo: template), [], "the old weight-only rule misses it")
        XCTAssertFalse(session.changesTemplateStructure(template))
        XCTAssertEqual(session.templateChanges(into: template, mode: .loads), ["Plank 45s→1 min"],
                       "the finish card now offers Update Loads by this, as the workout's page does")
    }

    // MARK: Plan Week

    func testPlanWeekLeavesDaysThatCountFree() {
        let monday = calendar.weekStart(for: Date(timeIntervalSince1970: 1_800_000_000))
        let wednesday = calendar.addingDays(2, to: monday)
        let rotation = [PlannableTemplate(id: UUID(), name: "Full Body", scheduleDays: [])]
        // A George workout on Monday, tennis from Apple Health on Wednesday: both taken.
        let plan = WeekPlanner.propose(templates: rotation, rotationStart: 0, weeklyGoal: 3, trainedThisWeek: 2,
                                       busyDays: [monday, wednesday], from: wednesday, days: 5, calendar: calendar)
        XCTAssertEqual(plan.count, 1)
        XCTAssertFalse(plan.contains { $0.date == wednesday }, "a workout there would add no day")
        XCTAssertEqual(plan.first?.date, calendar.addingDays(4, to: monday), "Friday: a rest day after Wednesday")
    }
}
