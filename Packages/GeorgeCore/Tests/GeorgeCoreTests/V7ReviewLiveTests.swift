import XCTest
@testable import GeorgeCore

/// v7 review, live workout: Discard on a device that took the workout over, and the end of a
/// workout ended from another device.
final class V7ReviewLiveTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    /// Press with four sets: two ticked in the first part (minute 10 and 20), one after continuing (minute 2000).
    private func continued() -> WorkoutContent {
        let sets = [
            WorkoutSet(targetReps: "8", targetWeight: 50, reps: 8, weight: 50, isDone: true, doneAt: at(10)),
            WorkoutSet(targetReps: "8", targetWeight: 50, reps: 8, weight: 50, isDone: true, doneAt: at(20)),
            WorkoutSet(targetReps: "8", targetWeight: 50, reps: 7, weight: 50, isDone: true, doneAt: at(2000), startedAt: at(1999)),
            WorkoutSet(targetReps: "8", targetWeight: 50),
        ]
        return WorkoutContent(blocks: [WorkoutBlock(items: [WorkoutItem(name: "Press", sets: sets, restSeconds: 90)])])
    }

    // MARK: Discard after Continue Here

    func testSavedBeforeKeepsTheEarlierPart() {
        // Stopped early on Monday (ended at minute 40), continued and taken over on Tuesday.
        let outcome = TakenOverDiscard.outcome(createdAt: t0, startedAt: t0, endedAt: at(40), now: at(2010))
        XCTAssertEqual(outcome, .keepEarlierPart(endedAt: at(40)), "never deleted: Monday's sets are saved")
    }

    func testPlannedBeforeGoesBackToThePlan() {
        // Planned days ago, started today on another device, taken over here.
        let outcome = TakenOverDiscard.outcome(createdAt: at(-3 * 1440), startedAt: at(0), endedAt: nil, now: at(30))
        XCTAssertEqual(outcome, .backToPlan)
    }

    func testMadeByItsStartIsDeleted() {
        // A template or an empty workout: made by the Start, a moment before it.
        XCTAssertEqual(TakenOverDiscard.outcome(createdAt: at(0), startedAt: at(0.5), endedAt: nil, now: at(30)), .delete)
        XCTAssertEqual(TakenOverDiscard.outcome(createdAt: at(0), startedAt: nil, endedAt: nil, now: at(1)), .delete)
    }

    func testTakingBackOnlyTheSetsSinceContinuing() {
        let kept = continued().takingBackSets(doneAfter: at(40))
        let sets = kept.allItems[0].sets
        XCTAssertEqual(sets.map(\.isDone), [true, true, false, false])
        XCTAssertEqual(sets[0].doneAt, at(10), "the earlier ticks stay as they were")
        XCTAssertNil(sets[2].doneAt)
        XCTAssertNil(sets[2].startedAt)
        XCTAssertEqual(sets[2].reps, 7, "numbers typed stay")
        XCTAssertFalse(TakenOverDiscard.earlierPartIsComplete(kept), "stopped early")
    }

    func testTakingBackEverySetForThePlan() {
        let plan = continued().takingBackSets(doneAfter: nil)
        XCTAssertEqual(plan.completedSets, 0)
        XCTAssertEqual(plan.totalSets, 4)
    }

    func testATickWithoutTimeCountsAsEarlier() {
        var content = continued()
        content.blocks[0].items[0].sets[1].doneAt = nil
        XCTAssertTrue(content.takingBackSets(doneAfter: at(40)).allItems[0].sets[1].isDone)
    }

    func testEarlierPartWithoutSetsIsComplete() {
        // "Just track time" (tennis): no sets, finished before.
        XCTAssertTrue(TakenOverDiscard.earlierPartIsComplete(WorkoutContent()))
    }

    func testEarlierActiveTimeNeverMoreThanItSpanned() {
        // 50 min spanned; 45 min active before continuing plus 20 min logged since (a pause): 50.
        XCTAssertEqual(TakenOverDiscard.earlierActiveSeconds(accumulated: 65 * 60, startedAt: at(0), endedAt: at(50)), 50 * 60)
        XCTAssertEqual(TakenOverDiscard.earlierActiveSeconds(accumulated: 45 * 60, startedAt: at(0), endedAt: at(50)), 45 * 60)
        XCTAssertEqual(TakenOverDiscard.earlierActiveSeconds(accumulated: 45 * 60, startedAt: nil, endedAt: at(50)), 45 * 60)
    }

    // MARK: Ended from another device

    private func running(lastSetAt minutes: Double) -> WorkoutContent {
        let sets = [
            WorkoutSet(targetReps: "8", reps: 8, isDone: true, doneAt: at(minutes - 5)),
            WorkoutSet(targetReps: "8", reps: 8, isDone: true, doneAt: at(minutes)),
            WorkoutSet(targetReps: "8"),
        ]
        return WorkoutContent(blocks: [WorkoutBlock(items: [WorkoutItem(name: "Row", sets: sets)])])
    }

    func testLeftIdleEndsAtTheLastSetPlusRest() {
        // Started at 17:00 (minute 0), last set at 18:00, "Start Stretch Anyway" at 22:30.
        let clock = LiveClock(startedAt: at(0), accumulatedSeconds: 0, resumedAt: at(0))
        let end = FinishTime.endFromOutside(clock: clock, kind: .gym, content: running(lastSetAt: 60), restSeconds: 90, now: at(330))
        XCTAssertEqual(end, at(61.5))
        XCTAssertEqual(clock.activeSeconds(until: end), 61.5 * 60, accuracy: 0.001)
    }

    func testIdleRuleAppliesToEveryKindWithSets() {
        // Under the 4 h limit, but 45 min with nothing done: still the last set + rest.
        let clock = LiveClock(startedAt: at(0), accumulatedSeconds: 0, resumedAt: at(0))
        let end = FinishTime.endFromOutside(clock: clock, kind: .stretch, content: running(lastSetAt: 30), restSeconds: 60, now: at(75))
        XCTAssertEqual(end, at(31))
    }

    func testRecentActivityEndsNow() {
        let clock = LiveClock(startedAt: at(0), accumulatedSeconds: 0, resumedAt: at(0))
        let end = FinishTime.endFromOutside(clock: clock, kind: .gym, content: running(lastSetAt: 50), restSeconds: 90, now: at(60))
        XCTAssertEqual(end, at(60))
    }

    func testNoSetsEndsNow() {
        // A run or tennis tracked by time: its time is the workout.
        let clock = LiveClock(startedAt: at(0), accumulatedSeconds: 0, resumedAt: at(0))
        let end = FinishTime.endFromOutside(clock: clock, kind: .cardio, content: WorkoutContent(), restSeconds: 90, now: at(120))
        XCTAssertEqual(end, at(120))
    }

    func testPausedClockKeepsItsActiveTime() {
        // Paused on the other device after 50 active minutes; ended there hours later.
        let clock = LiveClock(startedAt: at(0), accumulatedSeconds: 50 * 60, resumedAt: nil)
        let end = FinishTime.endFromOutside(clock: clock, kind: .gym, content: running(lastSetAt: 48), restSeconds: 90, now: at(300))
        XCTAssertEqual(end, at(49.5))
        XCTAssertEqual(clock.activeSeconds(until: end), 49.5 * 60, accuracy: 0.001, "never more than it spanned")
    }
}
