import XCTest
@testable import GeorgeCore

/// Live ownership between devices: who runs a workout, when the other device lets go, and how two
/// live copies of one workout are merged instead of saved over each other.
final class V7W2HandoverTests: XCTestCase {
    let here = "11111111-1111-1111-1111-111111111111"
    let there = "22222222-2222-2222-2222-222222222222"
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Owner value

    func testOwnerRoundTripsThroughItsStoredForm() {
        let owner = LiveOwner(id: here, kind: .mac)
        XCTAssertEqual(owner.raw, here + "|Mac")
        XCTAssertEqual(LiveOwner(raw: owner.raw), owner)
        XCTAssertEqual(LiveOwner(raw: there + "|iPhone")?.kind, .phone)
        XCTAssertEqual(LiveOwner(raw: there + "|iPad")?.kind, .pad)
    }

    func testMissingOrUnreadableOwnerMeansNobodyClaimsIt() {
        XCTAssertNil(LiveOwner(raw: nil))
        XCTAssertNil(LiveOwner(raw: ""))
        XCTAssertNil(LiveOwner(raw: "|Mac"))
        XCTAssertNil(LiveOwner(raw: "   |iPhone"))
        XCTAssertNil(LiveOwner(raw: "no separator"))
    }

    func testUnknownKindStillCountsAsAnOwner() {
        let owner = LiveOwner(raw: there + "|Headset")
        XCTAssertEqual(owner?.id, there)
        XCTAssertNil(owner?.kind)
        XCTAssertEqual(LiveOwner(id: there, kind: nil).raw, there + "|")
        XCTAssertEqual(LiveOwner(raw: there + "|")?.id, there)
    }

    // MARK: Verdict

    func testNoClaimOrOwnClaimKeepsTheWorkout() {
        XCTAssertEqual(LiveOwnership.verdict(stored: nil, storedClaimedAt: nil, localID: here, localClaimedAt: t0), .keep)
        XCTAssertEqual(LiveOwnership.verdict(stored: nil, storedClaimedAt: nil, localID: here, localClaimedAt: nil), .keep)
        let mine = LiveOwner(id: here, kind: .phone)
        XCTAssertEqual(LiveOwnership.verdict(stored: mine, storedClaimedAt: t0, localID: here, localClaimedAt: t0), .keep)
        // Our own claim, whatever time is stored with it.
        XCTAssertEqual(LiveOwnership.verdict(stored: mine, storedClaimedAt: nil, localID: here, localClaimedAt: nil), .keep)
    }

    func testANewerClaimElsewhereLetsGo() {
        let other = LiveOwner(id: there, kind: .mac)
        XCTAssertEqual(LiveOwnership.verdict(stored: other, storedClaimedAt: t0.addingTimeInterval(60), localID: here, localClaimedAt: t0), .letGo)
    }

    func testAClaimElsewhereWithoutOwnClaimLetsGo() {
        // An older build started it here (no claim), another device continued it.
        let other = LiveOwner(id: there, kind: .pad)
        XCTAssertEqual(LiveOwnership.verdict(stored: other, storedClaimedAt: t0, localID: here, localClaimedAt: nil), .letGo)
        XCTAssertEqual(LiveOwnership.verdict(stored: other, storedClaimedAt: nil, localID: here, localClaimedAt: nil), .letGo)
    }

    func testAnOlderClaimElsewhereIsAnsweredWithOurOwn() {
        let other = LiveOwner(id: there, kind: .phone)
        XCTAssertEqual(LiveOwnership.verdict(stored: other, storedClaimedAt: t0, localID: here, localClaimedAt: t0.addingTimeInterval(5)), .reclaim)
        XCTAssertEqual(LiveOwnership.verdict(stored: other, storedClaimedAt: nil, localID: here, localClaimedAt: t0), .reclaim)
    }

    func testClaimsAtTheSameMomentEndTheSameOnBothDevices() {
        // Each device sees the other's claim: exactly one of them keeps the workout.
        let onHere = LiveOwnership.verdict(stored: LiveOwner(id: there, kind: .mac), storedClaimedAt: t0, localID: here, localClaimedAt: t0)
        let onThere = LiveOwnership.verdict(stored: LiveOwner(id: here, kind: .phone), storedClaimedAt: t0, localID: there, localClaimedAt: t0)
        XCTAssertEqual(onHere, .letGo)
        XCTAssertEqual(onThere, .reclaim)
        // A few milliseconds apart (precision lost on the way): still the same moment, same answer.
        let near = t0.addingTimeInterval(0.004)
        XCTAssertEqual(LiveOwnership.verdict(stored: LiveOwner(id: there, kind: .mac), storedClaimedAt: near, localID: here, localClaimedAt: t0), .letGo)
        XCTAssertEqual(LiveOwnership.verdict(stored: LiveOwner(id: here, kind: .phone), storedClaimedAt: t0, localID: there, localClaimedAt: near), .reclaim)
    }

    func testATakeoverAlwaysClaimsAfterTheClaimItReplaces() {
        XCTAssertEqual(LiveOwnership.claimTime(now: t0, previous: nil), t0)
        XCTAssertEqual(LiveOwnership.claimTime(now: t0, previous: t0.addingTimeInterval(-30)), t0)
        // The other device's clock was ahead: still later than its claim.
        let ahead = t0.addingTimeInterval(4)
        let claimed = LiveOwnership.claimTime(now: t0, previous: ahead)
        XCTAssertGreaterThan(claimed, ahead)
        // The device that ran it lets go – also when the date lost a millisecond on the way – and
        // the new owner keeps it (whichever id is larger).
        for (newOwner, oldOwner) in [(here, there), (there, here)] {
            XCTAssertEqual(LiveOwnership.verdict(stored: LiveOwner(id: newOwner, kind: .phone), storedClaimedAt: claimed.addingTimeInterval(-0.001),
                                                 localID: oldOwner, localClaimedAt: ahead), .letGo)
            XCTAssertEqual(LiveOwnership.verdict(stored: LiveOwner(id: oldOwner, kind: .mac), storedClaimedAt: ahead.addingTimeInterval(-0.001),
                                                 localID: newOwner, localClaimedAt: claimed), .reclaim)
        }
        XCTAssertGreaterThan(LiveOwnership.claimTime(now: t0, previous: t0), t0.addingTimeInterval(LiveOwnership.sameMoment))
    }

    // MARK: Running elsewhere

    func testRunsElsewhereFollowsTheOwnerWhenThereIsOne() {
        let id = UUID()
        // Another install claims it: elsewhere, also when this device still holds it as its own.
        XCTAssertTrue(LiveOwnership.runsElsewhere(sessionID: id, ownedID: id, owner: LiveOwner(id: there, kind: .mac), localID: here))
        // This install claims it and started it: here.
        XCTAssertFalse(LiveOwnership.runsElsewhere(sessionID: id, ownedID: id, owner: LiveOwner(id: here, kind: .phone), localID: here))
        // No claim (older builds): the device-local id decides, as before.
        XCTAssertFalse(LiveOwnership.runsElsewhere(sessionID: id, ownedID: id, owner: nil, localID: here))
        XCTAssertTrue(LiveOwnership.runsElsewhere(sessionID: id, ownedID: UUID(), owner: nil, localID: here))
        XCTAssertTrue(LiveOwnership.runsElsewhere(sessionID: id, ownedID: nil, owner: nil, localID: here))
    }

    func testTextsNameTheKindOfDeviceNeverItsName() {
        let mac = LiveOwner(id: there, kind: .mac)
        XCTAssertEqual(LiveOwnership.runningTitle(owner: mac, localID: here, localKind: .phone), "Running on your Mac")
        XCTAssertEqual(LiveOwnership.continuedMessage(owner: mac, localID: here, localKind: .phone), "Continued on your Mac")
        XCTAssertEqual(LiveOwnership.continuedMessage(owner: LiveOwner(id: there, kind: .phone), localID: here, localKind: .phone),
                       "Continued on your other iPhone")
        XCTAssertEqual(LiveOwnership.runningTitle(owner: nil, localID: here, localKind: .pad), "Running on another device")
        XCTAssertEqual(LiveOwnership.runningTitle(owner: LiveOwner(id: there, kind: nil), localID: here, localKind: .pad), "Running on another device")
        // A claim of this very install (a workout left behind here) doesn't name this device.
        XCTAssertEqual(LiveOwnership.deviceName(of: LiveOwner(id: here, kind: .pad), localID: here, localKind: .pad), "another device")
    }

    // MARK: Merge

    private func set(_ reps: Int? = nil, weight: Double? = nil, doneAt: Date? = nil, id: UUID = UUID()) -> WorkoutSet {
        WorkoutSet(id: id, targetReps: "8", targetWeight: 50, reps: reps, weight: weight, isDone: doneAt != nil, doneAt: doneAt)
    }

    private func content(_ items: [WorkoutItem]) -> WorkoutContent {
        WorkoutContent(blocks: [WorkoutBlock(items: items)])
    }

    func testASetDoneOnTheOtherDeviceIsKept() {
        let a = set(), b = set()
        let item = WorkoutItem(name: "Press", sets: [a, b])
        var theirs = content([item])
        theirs.blocks[0].items[0].sets[0] = set(8, weight: 52.5, doneAt: t0, id: a.id)
        let mine = content([item])
        let merged = WorkoutContent.mergedLive(mine: mine, theirs: theirs)
        let first = merged.allItems[0].sets[0]
        XCTAssertTrue(first.isDone)
        XCTAssertEqual(first.reps, 8)
        XCTAssertEqual(first.weight, 52.5)
        XCTAssertEqual(first.doneAt, t0)
        XCTAssertEqual(merged.completedSets, 1)
        XCTAssertEqual(merged.totalSets, 2)
    }

    func testDoneOnBothSidesTakesTheLaterTick() {
        let id = UUID()
        let mine = content([WorkoutItem(name: "Row", sets: [set(10, weight: 40, doneAt: t0, id: id)])])
        let theirs = content([WorkoutItem(id: mine.allItems[0].id, name: "Row", sets: [set(9, weight: 42, doneAt: t0.addingTimeInterval(30), id: id)])])
        let merged = WorkoutContent.mergedLive(mine: mine, theirs: theirs)
        XCTAssertEqual(merged.allItems[0].sets[0].reps, 9)
        XCTAssertEqual(merged.allItems[0].sets[0].weight, 42)
        XCTAssertEqual(merged.allItems[0].sets[0].doneAt, t0.addingTimeInterval(30))
        // The other way round: ours is later.
        let reversed = WorkoutContent.mergedLive(mine: theirs, theirs: mine)
        XCTAssertEqual(reversed.allItems[0].sets[0].reps, 9)
    }

    func testDoneOnOneSideStaysDoneWithItsNumbers() {
        let id = UUID()
        let itemID = UUID()
        let mine = content([WorkoutItem(id: itemID, name: "Row", sets: [set(10, weight: 40, doneAt: t0, id: id)])])
        // Unticked there in the meantime (or never ticked): the tick here counts.
        let theirs = content([WorkoutItem(id: itemID, name: "Row", sets: [set(nil, weight: 45, id: id)])])
        let merged = WorkoutContent.mergedLive(mine: mine, theirs: theirs)
        XCTAssertTrue(merged.allItems[0].sets[0].isDone)
        XCTAssertEqual(merged.allItems[0].sets[0].reps, 10)
        XCTAssertEqual(merged.allItems[0].sets[0].weight, 40)
        XCTAssertEqual(merged.allItems[0].sets[0].doneAt, t0)
    }

    func testOpenSetsKeepTheNumbersTypedHere() {
        let id = UUID()
        let itemID = UUID()
        let mine = content([WorkoutItem(id: itemID, name: "Squat", sets: [set(weight: 100, id: id)])])
        let theirs = content([WorkoutItem(id: itemID, name: "Squat", sets: [set(weight: 90, id: id)])])
        let merged = WorkoutContent.mergedLive(mine: mine, theirs: theirs)
        XCTAssertEqual(merged.allItems[0].sets[0].weight, 100)
        XCTAssertFalse(merged.allItems[0].sets[0].isDone)
    }

    func testSetsAddedOnTheOtherDeviceAreKeptInPlace() {
        let s1 = set(), s2 = set()
        let itemID = UUID()
        let mine = content([WorkoutItem(id: itemID, name: "Deadlift", sets: [s1, s2])])
        // Warm-ups go in front there, a drop set after the first working set.
        let w1 = set(), w2 = set(), drop = set(6, weight: 30, doneAt: t0)
        let theirs = content([WorkoutItem(id: itemID, name: "Deadlift", sets: [w1, w2, s1, drop, s2])])
        let merged = WorkoutContent.mergedLive(mine: mine, theirs: theirs)
        XCTAssertEqual(merged.allItems[0].sets.map(\.id), [w1.id, w2.id, s1.id, drop.id, s2.id])
        XCTAssertTrue(merged.allItems[0].sets[3].isDone)
    }

    func testSetsAddedHereStay() {
        let s1 = set()
        let itemID = UUID()
        let extra = set(5, weight: 20, doneAt: t0)
        let mine = content([WorkoutItem(id: itemID, name: "Curl", sets: [s1, extra])])
        let theirs = content([WorkoutItem(id: itemID, name: "Curl", sets: [s1])])
        let merged = WorkoutContent.mergedLive(mine: mine, theirs: theirs)
        XCTAssertEqual(merged.allItems[0].sets.map(\.id), [s1.id, extra.id])
    }

    func testExercisesAndBlocksOnlyOneSideHasAreKept() {
        let press = WorkoutItem(name: "Press", sets: [set()])
        let row = WorkoutItem(name: "Row", sets: [set()])
        let block = WorkoutBlock(items: [press, row])
        let mine = WorkoutContent(blocks: [block])
        // There: an exercise added between the two, and a new block at the end.
        let fly = WorkoutItem(name: "Fly", sets: [set(12, weight: 10, doneAt: t0)])
        let plank = WorkoutItem(name: "Plank", mode: .time, sets: [set()])
        var theirBlock = block
        theirBlock.items = [press, fly, row]
        let theirs = WorkoutContent(blocks: [theirBlock, WorkoutBlock(items: [plank])])
        let merged = WorkoutContent.mergedLive(mine: mine, theirs: theirs)
        XCTAssertEqual(merged.blocks.count, 2)
        XCTAssertEqual(merged.blocks[0].items.map(\.name), ["Press", "Fly", "Row"])
        XCTAssertEqual(merged.blocks[1].items.map(\.name), ["Plank"])
        XCTAssertEqual(merged.completedSets, 1)
        // An exercise added here stays too.
        let back = WorkoutContent.mergedLive(mine: theirs, theirs: mine)
        XCTAssertEqual(back.allItems.map(\.name), ["Press", "Fly", "Row", "Plank"])
    }

    func testAnExerciseMovedToAnotherBlockIsNotDoubled() {
        let a = WorkoutItem(name: "A", sets: [set()])
        let b = WorkoutItem(name: "B", sets: [set()])
        let first = WorkoutBlock(items: [a])
        let second = WorkoutBlock(items: [b])
        let mine = WorkoutContent(blocks: [first, second])
        // There, B was moved into the first block (a superset) and its set ticked.
        var movedB = b
        movedB.sets[0] = set(8, weight: 20, doneAt: t0, id: b.sets[0].id)
        var theirFirst = first
        theirFirst.items = [a, movedB]
        let theirs = WorkoutContent(blocks: [theirFirst])
        let merged = WorkoutContent.mergedLive(mine: mine, theirs: theirs)
        XCTAssertEqual(merged.allItems.map(\.name), ["A", "B"])
        XCTAssertEqual(Set(merged.allItems.flatMap { $0.sets.map(\.id) }).count, 2)
        // The tick made there is kept on B wherever it sits.
        XCTAssertEqual(merged.completedSets, 1)
    }

    func testSameCopyMergesToItself() {
        let item = WorkoutItem(name: "Press", sets: [set(8, weight: 50, doneAt: t0), set()], fatigue: 0.5)
        let mine = content([item])
        XCTAssertEqual(WorkoutContent.mergedLive(mine: mine, theirs: mine), mine)
    }

    func testFatigueAnsweredThereIsKept() {
        let itemID = UUID()
        let s = set()
        let mine = content([WorkoutItem(id: itemID, name: "Press", sets: [s])])
        let theirs = content([WorkoutItem(id: itemID, name: "Press", sets: [s], fatigue: 0.75)])
        XCTAssertEqual(WorkoutContent.mergedLive(mine: mine, theirs: theirs).allItems[0].fatigue, 0.75)
    }

    // MARK: Written elsewhere

    func testWrittenElsewhereOnlyWhenTheStoredCopyChanged() throws {
        let mine = content([WorkoutItem(name: "Press", sets: [set()])])
        let data = try mine.encodedData()
        XCTAssertNil(WorkoutContent.writtenElsewhere(stored: data, lastSeen: data))
        XCTAssertNil(WorkoutContent.writtenElsewhere(stored: nil, lastSeen: data))
        XCTAssertNil(WorkoutContent.writtenElsewhere(stored: Data(), lastSeen: data))
        var changed = mine
        changed.blocks[0].items[0].sets[0].isDone = true
        changed.blocks[0].items[0].sets[0].doneAt = t0
        let other = try changed.encodedData()
        XCTAssertEqual(WorkoutContent.writtenElsewhere(stored: other, lastSeen: data)?.completedSets, 1)
        // First save after a launch with nothing seen yet: still merged.
        XCTAssertNotNil(WorkoutContent.writtenElsewhere(stored: other, lastSeen: nil))
    }

    func testUnreadableOrNewerCopiesAreNotMerged() throws {
        let mine = content([WorkoutItem(name: "Press", sets: [set()])])
        let data = try mine.encodedData()
        XCTAssertNil(WorkoutContent.writtenElsewhere(stored: Data("not json".utf8), lastSeen: data))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = WorkoutContent.currentVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(WorkoutContent.writtenElsewhere(stored: newer, lastSeen: data))
    }
}
