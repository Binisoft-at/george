import XCTest
@testable import GeorgeCore

/// v7 lane "mac": a workout running on another device (parallel start guard, stale workouts) and
/// the short header texts of the Mac and iPad screens.
final class V7MacTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func content(done: [Date?]) -> WorkoutContent {
        let sets = done.map { WorkoutSet(targetReps: "8", isDone: $0 != nil, doneAt: $0) }
        return WorkoutContent(blocks: [WorkoutBlock(items: [WorkoutItem(name: "Row", sets: sets)])])
    }

    // MARK: Stale workouts

    func testLastActivityIsTheNewestSign() {
        let started = now.addingTimeInterval(-3600)
        let tick = now.addingTimeInterval(-600)
        let resumed = now.addingTimeInterval(-1200)
        let workout = content(done: [now.addingTimeInterval(-1800), tick, nil])
        XCTAssertEqual(RunningWorkout.lastActivity(startedAt: started, resumedAt: resumed, content: workout), tick)
        XCTAssertEqual(RunningWorkout.lastActivity(startedAt: started, resumedAt: nil, content: content(done: [nil])), started)
        XCTAssertNil(RunningWorkout.lastActivity(startedAt: nil, resumedAt: nil, content: WorkoutContent()))
    }

    func testStartedSetCountsAsActivity() {
        var workout = content(done: [nil])
        workout.blocks[0].items[0].sets[0].startedAt = now.addingTimeInterval(-60)
        XCTAssertFalse(RunningWorkout.isStale(startedAt: now.addingTimeInterval(-20 * 3600), resumedAt: nil, content: workout, now: now))
    }

    func testStaleAfterAboutHalfADay() {
        let started = now.addingTimeInterval(-13 * 3600)
        XCTAssertTrue(RunningWorkout.isStale(startedAt: started, resumedAt: nil, content: content(done: [nil]), now: now))
        // A set ticked an hour ago: still running.
        XCTAssertFalse(RunningWorkout.isStale(startedAt: started, resumedAt: nil, content: content(done: [now.addingTimeInterval(-3600)]), now: now))
        // Just under the limit.
        XCTAssertFalse(RunningWorkout.isStale(startedAt: now.addingTimeInterval(-11 * 3600), resumedAt: nil, content: content(done: [nil]), now: now))
        // No date at all: nothing can be running.
        XCTAssertTrue(RunningWorkout.isStale(startedAt: nil, resumedAt: nil, content: WorkoutContent(), now: now))
    }

    func testEndedStatus() {
        XCTAssertTrue(RunningWorkout.endedStatusIsPartial(content(done: [now, nil])))
        XCTAssertFalse(RunningWorkout.endedStatusIsPartial(content(done: [nil, nil])))
    }

    func testProgressLine() {
        XCTAssertEqual(RunningWorkout.progressLine(title: "UPPER", content: content(done: [now, now, nil])), "UPPER · 2/3 sets")
        XCTAssertEqual(RunningWorkout.progressLine(title: "", content: WorkoutContent()), "Workout")
    }

    // MARK: Start decision

    func testNothingRunningStarts() {
        XCTAssertEqual(RunningWorkout.decide(targetID: nil, targetIsActive: false, runningHereID: nil, ownedID: nil, elsewhereID: nil), .start)
        XCTAssertEqual(RunningWorkout.decide(targetID: UUID(), targetIsActive: false, runningHereID: nil, ownedID: nil, elsewhereID: nil), .start)
    }

    func testRunningHereAsksOrShows() {
        let here = UUID()
        XCTAssertEqual(RunningWorkout.decide(targetID: here, targetIsActive: true, runningHereID: here, ownedID: here, elsewhereID: nil), .showRunning)
        XCTAssertEqual(RunningWorkout.decide(targetID: nil, targetIsActive: false, runningHereID: here, ownedID: here, elsewhereID: nil), .askRunningHere)
        // Something running here wins over a workout elsewhere: that dialog comes first.
        XCTAssertEqual(RunningWorkout.decide(targetID: UUID(), targetIsActive: false, runningHereID: here, ownedID: here, elsewhereID: UUID()), .askRunningHere)
    }

    func testWorkoutElsewhereBlocksAParallelStart() {
        let elsewhere = UUID()
        // "Start UPPER" on the Mac while the iPhone trains.
        XCTAssertEqual(RunningWorkout.decide(targetID: nil, targetIsActive: false, runningHereID: nil, ownedID: nil, elsewhereID: elsewhere), .askRunningElsewhere(elsewhere))
        // A list's "Continue" on the workout the iPhone runs: asks, never a second live copy.
        XCTAssertEqual(RunningWorkout.decide(targetID: elsewhere, targetIsActive: true, runningHereID: nil, ownedID: nil, elsewhereID: elsewhere), .askRunningElsewhere(elsewhere))
        // An active workout that isn't shown as elsewhere (e.g. a stale one) still asks.
        let stale = UUID()
        XCTAssertEqual(RunningWorkout.decide(targetID: stale, targetIsActive: true, runningHereID: nil, ownedID: nil, elsewhereID: nil), .askRunningElsewhere(stale))
    }

    func testOwnWorkoutResumesWithoutAsking() {
        // This device started it, the app was relaunched and hasn't attached it yet.
        let own = UUID()
        XCTAssertEqual(RunningWorkout.decide(targetID: own, targetIsActive: true, runningHereID: nil, ownedID: own, elsewhereID: nil), .start)
    }

    func testTakesOver() {
        let id = UUID()
        XCTAssertTrue(RunningWorkout.takesOver(targetIsActive: true, targetID: id, runningHereID: nil, ownedID: nil))
        XCTAssertFalse(RunningWorkout.takesOver(targetIsActive: true, targetID: id, runningHereID: nil, ownedID: id))
        XCTAssertFalse(RunningWorkout.takesOver(targetIsActive: true, targetID: id, runningHereID: id, ownedID: nil))
        XCTAssertFalse(RunningWorkout.takesOver(targetIsActive: false, targetID: id, runningHereID: nil, ownedID: nil))
        XCTAssertFalse(RunningWorkout.takesOver(targetIsActive: true, targetID: nil, runningHereID: nil, ownedID: nil))
    }

    // MARK: Header texts

    func testKindLeftOutWhenProgramStartsWithIt() {
        XCTAssertEqual(HeaderSummary.kindAndProgram(kind: "Gym", program: "Gym – Strength Block"), ["Gym – Strength Block"])
        XCTAssertEqual(HeaderSummary.kindAndProgram(kind: "Gym", program: "gym"), ["gym"])
        XCTAssertEqual(HeaderSummary.kindAndProgram(kind: "Gym", program: "Elastic Bands"), ["Gym", "Elastic Bands"])
        // Only a whole word counts.
        XCTAssertEqual(HeaderSummary.kindAndProgram(kind: "Gym", program: "Gymnastics"), ["Gym", "Gymnastics"])
        XCTAssertEqual(HeaderSummary.kindAndProgram(kind: "Gym", program: nil), ["Gym", "No program"])
        XCTAssertEqual(HeaderSummary.kindAndProgram(kind: "Gym", program: ""), ["Gym", "No program"])
    }

    func testProgramCounts() {
        XCTAssertEqual(HeaderSummary.programCounts(workouts: 13, templates: 3), "13 workouts · 3 templates")
        XCTAssertEqual(HeaderSummary.programCounts(workouts: 1, templates: 1), "1 workout · 1 template")
        XCTAssertEqual(HeaderSummary.programCounts(workouts: 0, templates: 2), "0 workouts · 2 templates")
    }
}
