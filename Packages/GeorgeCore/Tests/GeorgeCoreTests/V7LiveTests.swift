import XCTest
@testable import GeorgeCore

/// v7 lane "live": what is due after out-of-order ticks, superset rests, and value-only edits.
final class V7LiveTests: XCTestCase {
    private func superset(sets: Int = 3, restAfterRound: Int? = 75) -> (WorkoutContent, a: WorkoutItem, b: WorkoutItem) {
        let a = WorkoutItem(name: "A", sets: (0..<sets).map { _ in WorkoutSet(targetReps: "8", targetWeight: 40) })
        let b = WorkoutItem(name: "B", sets: (0..<sets).map { _ in WorkoutSet(targetReps: "10") })
        let content = WorkoutContent(blocks: [WorkoutBlock(style: .superset, restAfterRoundSeconds: restAfterRound, items: [a, b])])
        return (content, a, b)
    }

    private func straight(sets: Int = 4, rest: Int? = 90) -> (WorkoutContent, WorkoutItem) {
        let item = WorkoutItem(name: "Press", sets: (0..<sets).map { _ in WorkoutSet(targetReps: "8", targetWeight: 50) }, restSeconds: rest)
        return (WorkoutContent(blocks: [WorkoutBlock(items: [item])]), item)
    }

    // MARK: Out-of-order ticks

    func testB1BeforeA1KeepsA1CurrentNoRest() throws {
        let (start, a, b) = superset()
        var content = start
        let a1 = try XCTUnwrap(content.locate(setID: a.sets[0].id))
        let b1 = try XCTUnwrap(content.locate(setID: b.sets[0].id))
        XCTAssertTrue(content.toggleSet(id: b.sets[0].id))
        XCTAssertEqual(content.currentAfterTick(b1, previous: a1, offPlan: false), a1, "A1 is still open: it stays due")
        XCTAssertNil(content.restAfterDone(b1, defaultRest: 90), "no round rest while A1 is open")
        // Now A1: the round is done, the round rest starts and A2 is next.
        XCTAssertTrue(content.toggleSet(id: a.sets[0].id))
        XCTAssertEqual(content.restAfterDone(a1, defaultRest: 90), 75)
        let a2 = try XCTUnwrap(content.locate(setID: a.sets[1].id))
        XCTAssertEqual(content.currentAfterTick(a1, previous: a1, offPlan: false), a2)
    }

    func testSet3BeforeSet2KeepsSet2Current() throws {
        let (start, item) = straight()
        var content = start
        let set1 = try XCTUnwrap(content.locate(setID: item.sets[0].id))
        let set2 = try XCTUnwrap(content.locate(setID: item.sets[1].id))
        let set3 = try XCTUnwrap(content.locate(setID: item.sets[2].id))
        let set4 = try XCTUnwrap(content.locate(setID: item.sets[3].id))
        content.toggleSet(id: item.sets[0].id)
        XCTAssertEqual(content.currentAfterTick(set1, previous: set1, offPlan: false), set2)
        content.toggleSet(id: item.sets[2].id)
        XCTAssertEqual(content.currentAfterTick(set3, previous: set2, offPlan: false), set2, "set 2 is still open")
        XCTAssertEqual(content.restAfterDone(set3, defaultRest: 120), 90, "straight sets rest after every set")
        content.toggleSet(id: item.sets[1].id)
        XCTAssertEqual(content.currentAfterTick(set2, previous: set2, offPlan: false), set4, "set 3 is done already")
    }

    func testRoundRestWhenRoundCompletedOutOfOrder() throws {
        let (start, a, b) = superset(restAfterRound: 60)
        var content = start
        let order = content.executionOrder()
        // In order: no rest after A1, the round rest after B1.
        XCTAssertNil(content.restAfter(order[0], defaultRest: 90))
        XCTAssertEqual(content.restAfter(order[1], defaultRest: 90), 60, "the plan still rests after the round's last set")
        // Out of order: B1 first, then A1 completes the round.
        content.toggleSet(id: b.sets[0].id)
        XCTAssertFalse(content.isRoundComplete(blockIndex: 0, round: 0))
        content.toggleSet(id: a.sets[0].id)
        XCTAssertTrue(content.isRoundComplete(blockIndex: 0, round: 0))
        XCTAssertEqual(content.restAfterDone(order[0], defaultRest: 90), 60, "A1 finished the round: round rest")
        XCTAssertNil(content.restAfterDone(order[2], defaultRest: 90), "A2 is not done – nothing to rest after yet")
    }

    func testRoundRestFallsBackToTheLastExercisesRest() throws {
        let (start, a, b) = superset(restAfterRound: nil)
        var content = start
        content.updateItem(id: b.id) { $0.restSeconds = 45 }
        content.toggleSet(id: b.sets[0].id)
        content.toggleSet(id: a.sets[0].id)
        let a1 = try XCTUnwrap(content.locate(setID: a.sets[0].id))
        XCTAssertEqual(content.restAfterDone(a1, defaultRest: 90), 45, "the rest planned after the round's last exercise")
    }

    func testRoundWithOpenSetsComesFirst() throws {
        // A circuit of three; B1 was made current (A1 skipped) and done, then C1: A1 is still open in round 1.
        let items = ["A", "B", "C"].map { WorkoutItem(name: $0, sets: (0..<2).map { _ in WorkoutSet(targetReps: "10") }) }
        var content = WorkoutContent(blocks: [WorkoutBlock(style: .circuit, items: items)])
        let a1 = try XCTUnwrap(content.locate(setID: items[0].sets[0].id))
        let b1 = try XCTUnwrap(content.locate(setID: items[1].sets[0].id))
        let c1 = try XCTUnwrap(content.locate(setID: items[2].sets[0].id))
        content.toggleSet(id: items[1].sets[0].id)
        XCTAssertEqual(content.currentAfterTick(b1, previous: b1, offPlan: false), c1)
        content.toggleSet(id: items[2].sets[0].id)
        XCTAssertEqual(content.nextOpenSet(inRoundOf: c1), a1, "wraps to the start of the round")
        XCTAssertEqual(content.currentAfterTick(c1, previous: c1, offPlan: false), a1, "the round is finished first")
        XCTAssertNil(content.restAfterDone(c1, defaultRest: 90), "no rest while A1 is open")
    }

    func testOffPlanTickKeepsThePlanAndAdoptingFollows() throws {
        let bench = WorkoutItem(name: "Bench", sets: (0..<3).map { _ in WorkoutSet(targetReps: "8") })
        let row = WorkoutItem(name: "Row", sets: (0..<3).map { _ in WorkoutSet(targetReps: "8") })
        var content = WorkoutContent(blocks: [WorkoutBlock(items: [bench]), WorkoutBlock(items: [row])])
        let bench1 = try XCTUnwrap(content.locate(setID: bench.sets[0].id))
        let row1 = try XCTUnwrap(content.locate(setID: row.sets[0].id))
        let row2 = try XCTUnwrap(content.locate(setID: row.sets[1].id))
        content.toggleSet(id: row.sets[0].id)
        XCTAssertEqual(content.currentAfterTick(row1, previous: bench1, offPlan: true), bench1, "off plan: the plan keeps its place")
        // A second set there in a row: George follows (the caller passes offPlan: false).
        content.toggleSet(id: row.sets[1].id)
        XCTAssertNotEqual(content.currentAfterTick(row2, previous: bench1, offPlan: false), bench1)
    }

    func testOpenDropSetFollowsWithoutRest() throws {
        let (start, item) = straight(sets: 2)
        var content = start
        content.dropWeight(setID: item.sets[0].id, repsDone: 5, newWeightKg: 40, applyToRemaining: false)
        let first = try XCTUnwrap(content.locate(setID: item.sets[0].id))
        XCTAssertNil(content.restAfterDone(first, defaultRest: 90), "the drop set follows straight away")
    }

    func testStraightSetsWithoutRestGiveNil() throws {
        let (start, item) = straight(sets: 2, rest: 0)
        var content = start
        content.toggleSet(id: item.sets[0].id)
        let first = try XCTUnwrap(content.locate(setID: item.sets[0].id))
        XCTAssertNil(content.restAfterDone(first, defaultRest: 90))
    }

    // MARK: Value-only edits

    func testValueEditsKeepTheShape() {
        let (content, a, b) = superset()
        var typed = content
        typed.updateSet(id: a.sets[0].id) { $0.weight = 62.5 }
        typed.updateItem(id: b.id) { $0.name = "B2"; $0.notes = "slow" }
        XCTAssertTrue(content.hasSameSetsAndTicks(as: typed))

        var ticked = content
        ticked.toggleSet(id: a.sets[0].id)
        XCTAssertFalse(content.hasSameSetsAndTicks(as: ticked), "a tick moves what is due")

        var added = content
        added.addSet(to: a.id)
        XCTAssertFalse(content.hasSameSetsAndTicks(as: added))

        var removed = content
        removed.removeItem(id: b.id)
        XCTAssertFalse(content.hasSameSetsAndTicks(as: removed))

        var dropped = content
        dropped.updateSet(id: a.sets[1].id) { $0.kind = .drop }
        XCTAssertFalse(content.hasSameSetsAndTicks(as: dropped), "a drop set changes the order")
    }
}
