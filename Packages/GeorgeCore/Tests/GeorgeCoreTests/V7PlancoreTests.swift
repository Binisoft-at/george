import XCTest
@testable import GeorgeCore

/// v7 lane "plancore": Update Template (#8), supersets after drops, swaps and warm-ups (#11),
/// numbers at the set – prefill, progression, plates (#17).
final class V7PlancoreTests: XCTestCase {
    // MARK: Helpers

    private func straight(_ name: String, sets: Int, reps: String, kg: Double?) -> WorkoutItem {
        WorkoutItem(name: name, sets: (0..<sets).map { _ in WorkoutSet(targetReps: reps, targetWeight: kg) })
    }

    private func superset(a: Int = 3, b: Int = 3) -> WorkoutContent {
        let first = straight("A", sets: a, reps: "8", kg: 40)
        let second = straight("B", sets: b, reps: "10", kg: nil)
        return WorkoutContent(blocks: [WorkoutBlock(style: .superset, restAfterRoundSeconds: 60, items: [first, second])])
    }

    private func names(_ content: WorkoutContent) -> [String] {
        content.executionOrder().map { ref in
            let item = content.item(at: ref)!
            let set = item.sets[ref.setIndex]
            return item.name + (set.kind == .warmup ? "w" : set.kind == .drop ? "d" : "")
        }
    }

    // MARK: #8 Update Template

    func testRangeSurvivesPlainTick() {
        let template = WorkoutContent(blocks: [WorkoutBlock(items: [straight("Bench", sets: 3, reps: "8-12", kg: 60)])])
        var session = template.freshCopy()
        for set in session.allItems[0].sets { session.toggleSet(id: set.id) }
        XCTAssertEqual(session.allItems[0].sets.map(\.reps), [8, 8, 8], "a plain tick logs the lower bound")
        let everything = session.asTemplate(mode: .everything, base: template)
        XCTAssertEqual(everything.allItems[0].sets.map(\.targetReps), ["8-12", "8-12", "8-12"])
        XCTAssertEqual(everything.allItems[0].sets.map(\.targetWeight), [60, 60, 60])
        let loads = session.asTemplate(mode: .loads, base: template)
        XCTAssertEqual(loads, template, "nothing heavier – the template stays as it is")
        XCTAssertTrue(session.templateChanges(into: template, mode: .everything).isEmpty)
        // A single-number target that was beaten becomes the new plan.
        var beaten = WorkoutContent(blocks: [WorkoutBlock(items: [straight("Curl", sets: 1, reps: "10", kg: 12)])])
        beaten.updateSet(id: beaten.allItems[0].sets[0].id) { $0.reps = 12; $0.weight = 12; $0.isDone = true }
        XCTAssertEqual(beaten.asTemplate().allItems[0].sets[0].targetReps, "12")
        // "Add exercise" with last time's sets as the plan promotes the same way.
        let ticked = WorkoutSet(targetReps: "8-12", reps: 8, weight: 50, isDone: true)
        XCTAssertEqual(ticked.promotedToTarget().targetReps, "8-12")
        XCTAssertEqual(ticked.promotedToTarget().targetWeight, 50)
    }

    func testFailedSetDoesNotLowerTarget() {
        let template = WorkoutContent(blocks: [WorkoutBlock(items: [straight("Squat", sets: 3, reps: "5", kg: 100)])])
        var session = template.freshCopy()
        let sets = session.allItems[0].sets
        session.toggleSet(id: sets[0].id)
        session.toggleSet(id: sets[1].id)
        session.updateSet(id: sets[2].id) { $0.reps = 3; $0.weight = 100; $0.isDone = true }
        let everything = session.asTemplate(mode: .everything, base: template)
        XCTAssertEqual(everything.allItems[0].sets.map(\.targetReps), ["5", "5", "5"])
        XCTAssertEqual(everything.allItems[0].sets.map(\.targetWeight), [100, 100, 100])
        XCTAssertEqual(session.asTemplate(mode: .loads, base: template), template)
    }

    func testLiveDropAndWarmupsNotPersisted() throws {
        let template = WorkoutContent(blocks: [WorkoutBlock(items: [straight("Bench", sets: 3, reps: "8", kg: 80)])])
        var session = template.freshCopy()
        let itemID = session.allItems[0].id
        XCTAssertEqual(session.addWarmups(to: itemID), 4)
        let working = session.allItems[0].sets.filter { $0.kind == .working }
        try XCTUnwrap(session.dropWeight(setID: working[0].id, repsDone: 5, newWeightKg: 70, applyToRemaining: false))
        XCTAssertTrue(session.allItems[0].sets.filter { $0.kind != .working }.allSatisfy { $0.addedLive == true })
        XCTAssertTrue(session.structureDiffers(from: template), "the workout itself has more sets")
        XCTAssertFalse(session.changesTemplateStructure(template), "…but none of them belong in the template")
        let saved = session.asTemplate(mode: .everything, base: template)
        XCTAssertEqual(saved.allItems[0].sets.count, 3)
        XCTAssertTrue(saved.allItems[0].sets.allSatisfy { $0.kind == .working && $0.addedLive == nil })
        XCTAssertEqual(saved.allItems[0].sets.map(\.targetReps), ["8", "8", "8"], "the failed 5 keeps the plan of 8")
        // The tag survives a round trip through storage, and a new workout starts without it.
        let decoded = WorkoutContent.decode(session.encoded())
        XCTAssertEqual(decoded.allItems[0].sets.map(\.addedLive), session.allItems[0].sets.map(\.addedLive))
        XCTAssertTrue(decoded.freshCopy().allItems[0].sets.allSatisfy { $0.addedLive == nil })
        // "Can't finish" at the planned weight isn't "heavier".
        XCTAssertTrue(session.templateChanges(into: template, mode: .loads).isEmpty)
    }

    func testSwapSplitMerged() throws {
        let template = superset()
        var session = template.freshCopy()
        let a = session.blocks[0].items[0]
        let b = session.blocks[0].items[1]
        session.toggleSet(id: a.sets[0].id)
        session.toggleSet(id: b.sets[0].id)
        var replacement = WorkoutItem(name: "A2", sets: [WorkoutSet(targetReps: "8")])
        replacement.exerciseID = "custom:a2"
        let newID = try XCTUnwrap(session.swapRemaining(itemID: a.id, with: replacement))
        for set in session.item(id: newID)!.sets {
            session.updateSet(id: set.id) { $0.weight = 24 }
            session.toggleSet(id: set.id)
        }
        let saved = session.asTemplate(mode: .everything, base: template)
        XCTAssertEqual(saved.blocks.count, 1)
        XCTAssertEqual(saved.blocks[0].items.map(\.name), ["A2", "B"], "the replacement takes A's place")
        XCTAssertEqual(saved.blocks[0].items[0].sets.count, 3, "with A's three rounds")
        XCTAssertEqual(saved.blocks[0].items[0].sets.map(\.targetWeight), [24, 24, 24])
        XCTAssertTrue(saved.allItems.allSatisfy { $0.roundOffset == nil })
        XCTAssertFalse(saved.blocks[0].setCountsDiffer)
        // Loads: A's done set counts for A; the replacement is not in the template.
        XCTAssertEqual(session.asTemplate(mode: .loads, base: template), template)
        XCTAssertEqual(session.templateChanges(into: template, mode: .everything), ["A2 added", "A removed"])
    }

    func testFreshCopyClearsFatigue() {
        var content = WorkoutContent(blocks: [WorkoutBlock(items: [straight("Row", sets: 2, reps: "10", kg: 50)])])
        content.updateItem(id: content.allItems[0].id) { $0.fatigue = 0.95 }
        XCTAssertNil(content.freshCopy().allItems[0].fatigue)
        XCTAssertNil(content.asTemplate().allItems[0].fatigue)
        XCTAssertNil(content.asTemplate(mode: .everything, base: nil).allItems[0].fatigue)
        var reset = content
        reset.resetProgress()
        XCTAssertNil(reset.allItems[0].fatigue)
    }

    func testLoadsModeRaisesMatchingWorkingSetsOnly() {
        let bench = WorkoutItem(name: "Bench", sets: [WorkoutSet(kind: .warmup, targetReps: "10", targetWeight: 20)]
            + (0..<3).map { _ in WorkoutSet(targetReps: "8-12", targetWeight: 60) })
        let template = WorkoutContent(blocks: [WorkoutBlock(items: [bench])])
        var session = template.freshCopy()
        let sets = session.allItems[0].sets
        session.updateSet(id: sets[0].id) { $0.weight = 30; $0.reps = 10; $0.isDone = true }
        session.updateSet(id: sets[1].id) { $0.weight = 62.5; $0.reps = 10; $0.isDone = true }
        session.updateSet(id: sets[2].id) { $0.weight = 62.5; $0.reps = 9; $0.isDone = true }
        session.updateSet(id: sets[3].id) { $0.weight = 55; $0.reps = 12; $0.isDone = true }
        let saved = session.asTemplate(mode: .loads, base: template)
        XCTAssertEqual(saved.allItems[0].sets.map(\.targetWeight), [20, 62.5, 62.5, 60], "warm-up kept, never lowered")
        XCTAssertEqual(saved.allItems[0].sets.map(\.targetReps), ["10", "8-12", "8-12", "8-12"])
        XCTAssertEqual(saved.allItems[0].sets.map(\.id), template.allItems[0].sets.map(\.id), "same template, same sets")
        XCTAssertEqual(session.templateChanges(into: template, mode: .loads), ["Bench 60→62.5 kg"])
    }

    func testTemplateChangeLines() {
        let template = WorkoutContent(blocks: [
            WorkoutBlock(items: [straight("Bench", sets: 4, reps: "8", kg: 60)]),
            WorkoutBlock(items: [straight("Row", sets: 3, reps: "10", kg: 50)]),
        ])
        var session = template.freshCopy()
        session.removeSet(id: session.allItems[0].sets[3].id)
        for set in session.allItems.flatMap(\.sets) { session.toggleSet(id: set.id) }
        for set in session.allItems[1].sets { session.updateSet(id: set.id) { $0.weight = 52.5 } }
        XCTAssertTrue(session.changesTemplateStructure(template))
        XCTAssertEqual(session.templateChanges(into: template, mode: .everything), ["Bench 4→3 sets", "Row 50→52.5 kg"])
        XCTAssertEqual(session.templateChanges(into: template, mode: .loads), ["Row 50→52.5 kg"])
    }

    // MARK: #11 Supersets

    func testDropInSupersetIsNotMismatch() {
        var content = superset()
        let a1 = content.blocks[0].items[0].sets[0].id
        content.dropWeight(setID: a1, repsDone: 5, newWeightKg: 30, applyToRemaining: false)
        XCTAssertFalse(content.blocks[0].setCountsDiffer)
        XCTAssertEqual(content.blocks[0].maxSetCount, 3)
        XCTAssertEqual(content.blocks[0].roundCount, 3)
        XCTAssertEqual(content.mismatchedGroupCount, 0)
        content.matchSetCounts(blockID: content.blocks[0].id)
        XCTAssertEqual(content.blocks[0].items.map(\.sets.count), [4, 3], "Match sets adds no round")
    }

    func testSwapInSupersetIsNotMismatch() throws {
        var content = superset()
        let a = content.blocks[0].items[0]
        content.toggleSet(id: a.sets[0].id)
        content.toggleSet(id: content.blocks[0].items[1].sets[0].id)
        try XCTUnwrap(content.swapRemaining(itemID: a.id, with: WorkoutItem(name: "A2")))
        XCTAssertEqual(content.blocks[0].lanes, [[0, 1], [2]])
        XCTAssertFalse(content.blocks[0].setCountsDiffer)
        XCTAssertEqual(content.blocks[0].maxSetCount, 3)
        XCTAssertEqual(content.blocks[0].roundCount, 3)
        XCTAssertEqual(content.blocks[0].firstOpenRound, 1)
    }

    func testMatchAfterSwapPadsReplacementOnly() throws {
        var content = superset(a: 3, b: 4)
        let a = content.blocks[0].items[0]
        content.toggleSet(id: a.sets[0].id)
        content.toggleSet(id: content.blocks[0].items[1].sets[0].id)
        let newID = try XCTUnwrap(content.swapRemaining(itemID: a.id, with: WorkoutItem(name: "A2")))
        XCTAssertTrue(content.blocks[0].setCountsDiffer)
        XCTAssertEqual(content.blocks[0].laneRoundCounts, [3, 4])
        content.matchSetCounts(blockID: content.blocks[0].id)
        XCTAssertEqual(content.blocks[0].items.map(\.name), ["A", "A2", "B"])
        XCTAssertEqual(content.blocks[0].items[0].sets.count, 1, "the swapped-out exercise stays as done")
        XCTAssertEqual(content.item(id: newID)?.sets.count, 3)
        XCTAssertFalse(content.blocks[0].setCountsDiffer)
        XCTAssertEqual(content.blocks[0].roundCount, 4)
        XCTAssertEqual(names(content), ["A", "B", "A2", "B", "A2", "B", "A2", "B"])
    }

    func testWarmupsInSupersetComeFirst() {
        var content = superset()
        let aID = content.blocks[0].items[0].id
        XCTAssertEqual(content.addWarmups(to: aID, barKg: 20), 3, "40 kg top: 20, 27.5, 35")
        XCTAssertEqual(names(content), ["Aw", "Aw", "Aw", "A", "B", "A", "B", "A", "B"])
        XCTAssertFalse(content.blocks[0].setCountsDiffer)
        XCTAssertEqual(content.blocks[0].roundCount, 3)
        let order = content.executionOrder()
        XCTAssertNil(content.restAfter(order[0], defaultRest: 90), "no round rest after a warm-up")
        XCTAssertNil(content.restAfter(order[2], defaultRest: 90), "nor after the last one")
        XCTAssertNil(content.restAfter(order[3], defaultRest: 90))
        XCTAssertEqual(content.restAfter(order[4], defaultRest: 90), 60)
        var ticked = content
        for ref in order.prefix(3) { ticked.toggleSet(id: ticked.set(at: ref)!.id) }
        XCTAssertNil(ticked.restAfterDone(order[2], defaultRest: 90), "the lead-in done: straight into round 1")
        XCTAssertTrue(content.blocks[0].hasOpenWarmup)
        XCTAssertEqual(content.roundGrid(ofBlock: 0).first?.first?.round, -1, "the board's first row is the lead-in")
        // Heavier: a longer lead-in, still before the first round.
        var heavy = WorkoutContent(blocks: [WorkoutBlock(style: .superset, items: [
            straight("A", sets: 2, reps: "5", kg: 100), straight("B", sets: 2, reps: "8", kg: 60),
        ])])
        heavy.addWarmups(to: heavy.blocks[0].items[0].id)
        heavy.addWarmups(to: heavy.blocks[0].items[1].id)
        XCTAssertEqual(names(heavy), ["Aw", "Aw", "Aw", "Aw", "Bw", "Bw", "Bw", "Bw", "A", "B", "A", "B"])
    }

    func testDoubleSwapKeepsTheRound() throws {
        var content = superset()
        let a = content.blocks[0].items[0]
        content.toggleSet(id: a.sets[0].id)
        content.toggleSet(id: content.blocks[0].items[1].sets[0].id)
        let first = try XCTUnwrap(content.swapRemaining(itemID: a.id, with: WorkoutItem(name: "A2")))
        let second = try XCTUnwrap(content.swapRemaining(itemID: first, with: WorkoutItem(name: "A3")))
        XCTAssertEqual(content.item(id: second)?.roundOffset, 1)
        XCTAssertEqual(names(content), ["A", "B", "A3", "B", "A3", "B"])
        XCTAssertFalse(content.blocks[0].setCountsDiffer)
    }

    func testSwapAfterWarmupsAndDropCountsRoundsNotSets() throws {
        var content = superset()
        let a = content.blocks[0].items[0]
        content.addWarmups(to: a.id)
        for set in content.blocks[0].items[0].sets where set.kind == .warmup { content.toggleSet(id: set.id) }
        content.dropWeight(setID: a.sets[0].id, repsDone: 5, newWeightKg: 30, applyToRemaining: false)
        let drop = try XCTUnwrap(content.blocks[0].items[0].sets.first { $0.kind == .drop })
        content.toggleSet(id: drop.id)
        content.toggleSet(id: content.blocks[0].items[1].sets[0].id)
        let newID = try XCTUnwrap(content.swapRemaining(itemID: a.id, with: WorkoutItem(name: "A2")))
        XCTAssertEqual(content.item(id: newID)?.roundOffset, 1, "three warm-ups, a set and its drop set: one round")
        XCTAssertFalse(content.blocks[0].setCountsDiffer)
        XCTAssertEqual(names(content).filter { $0 != "Aw" }, ["A", "Ad", "B", "A2", "B", "A2", "B"])
    }

    // MARK: #17 Numbers at the set

    func testPrefillSkipsWarmupsAndDrops() {
        let previous = [
            WorkoutSet(kind: .warmup, reps: 10, weight: 20, isDone: true),
            WorkoutSet(kind: .warmup, reps: 5, weight: 50, isDone: true),
            WorkoutSet(kind: .warmup, reps: 3, weight: 70, isDone: true),
            WorkoutSet(reps: 8, weight: 100, isDone: true),
            WorkoutSet(kind: .drop, reps: 6, weight: 80, isDone: true),
            WorkoutSet(reps: 8, weight: 100, isDone: true),
            WorkoutSet(reps: 7, weight: 102.5, isDone: true),
        ]
        var content = WorkoutContent(blocks: [WorkoutBlock(items: [straight("Squat", sets: 3, reps: "8", kg: nil)])])
        content.applyPrevious { _ in previous }
        XCTAssertEqual(content.allItems[0].sets.map(\.targetWeight), [100, 100, 102.5])
        // Planned warm-ups take last time's warm-ups; a planned drop set takes the drop set.
        let planned = WorkoutItem(name: "Squat", sets: [
            WorkoutSet(kind: .warmup, targetReps: "10"), WorkoutSet(targetReps: "8"), WorkoutSet(kind: .drop, targetReps: "8"),
        ])
        var withWarmup = WorkoutContent(blocks: [WorkoutBlock(items: [planned])])
        withWarmup.applyPrevious { _ in previous }
        XCTAssertEqual(withWarmup.allItems[0].sets.map(\.targetWeight), [20, 100, 80])
        // The "last time" chip pairs the same way.
        let item = withWarmup.allItems[0]
        XCTAssertEqual(WorkoutSet.matchingPrevious(item.sets[1], in: item, previous: previous)?.weight, 100)
        XCTAssertNil(WorkoutSet.matchingPrevious(item.sets[0], in: item, previous: previous.filter { $0.kind != .warmup }))
    }

    func testPlannedDropDoesNotBlockProgression() throws {
        let last = (0..<3).map { _ in WorkoutSet(targetReps: "8-12", targetWeight: 60, reps: 12, weight: 60, isDone: true) }
            + [WorkoutSet(kind: .drop, targetReps: "8", reps: 8, weight: 45, rpe: 10, isDone: true)]
        let suggestion = try XCTUnwrap(ProgressionAdvisor.suggest(lastSets: last, mode: .reps, plan: nil, incrementKg: 2.5))
        XCTAssertEqual(suggestion.kind, .addWeight)
        XCTAssertEqual(suggestion.weightKg, 62.5)
        let adjusted = try XCTUnwrap(ProgressionAdvisor.suggest(lastSets: last, mode: .reps, plan: nil, incrementKg: 2.5, intensity: .normal, loadStatus: .overtraining))
        XCTAssertEqual(adjusted.weightKg, 57.5, "toned down from the top working weight, not the drop")
    }

    func testFailedStraightSetStillLightens() throws {
        var last = [
            WorkoutSet(targetReps: "8-12", targetWeight: 60, reps: 9, weight: 60, isDone: true),
            WorkoutSet(targetReps: "8-12", targetWeight: 60, reps: 8, weight: 60, isDone: true),
            WorkoutSet(targetReps: "8-12", targetWeight: 60, reps: 6, weight: 60, rpe: 10, isDone: true),
        ]
        last.append(WorkoutSet(kind: .drop, targetReps: "2", reps: 2, weight: 50, isDone: true))
        let suggestion = try XCTUnwrap(ProgressionAdvisor.suggest(lastSets: last, mode: .reps, plan: nil, incrementKg: 2.5))
        XCTAssertEqual(suggestion.kind, .lighten)
        XCTAssertEqual(suggestion.weightKg, 57.5)
        // Only drop sets: they are judged themselves.
        let onlyDrops = [WorkoutSet(kind: .drop, targetReps: "10", reps: 10, weight: 40, isDone: true)]
        XCTAssertEqual(ProgressionAdvisor.suggest(lastSets: onlyDrops, mode: .reps, plan: nil, incrementKg: 2.5)?.weightKg, 42.5)
    }

    func testEffortPromptTargetsTheLastNonDropSet() {
        let s1 = WorkoutSet(targetReps: "8", isDone: true)
        let s2 = WorkoutSet(targetReps: "8", isDone: true)
        let drop = WorkoutSet(kind: .drop, targetReps: "6", isDone: true)
        let item = WorkoutItem(name: "Bench", sets: [s1, s2, drop])
        XCTAssertFalse(EffortPrompt.shouldAsk(after: s2, in: item, askedSoFar: 0), "the drop set follows straight away")
        XCTAssertTrue(EffortPrompt.shouldAsk(after: drop, in: item, askedSoFar: 0))
        XCTAssertEqual(EffortPrompt.target(in: item)?.id, s2.id)
        var answered = item
        answered.sets[1].rpe = 9
        XCTAssertFalse(EffortPrompt.shouldAsk(after: drop, in: answered, askedSoFar: 0))
    }

    func testNoSmallPlates62_5() throws {
        let noSmall: [Double] = [25, 20, 15, 10, 5, 2.5]
        let load = try XCTUnwrap(PlateMath.load(totalKg: 62.5, barKg: 20, plates: noSmall))
        XCTAssertEqual(load.perSide, [20])
        XCTAssertEqual(load.missingPerSideKg, 1.25, accuracy: 0.0001)
        XCTAssertEqual(load.loadedKg, 60)
        XCTAssertFalse(load.isExact)
        XCTAssertEqual(PlateMath.text(totalKg: 62.5, plates: noSmall), "20 per side ≈ 60 kg")
        XCTAssertEqual(PlateMath.text(totalKg: 62.5), "20 + 1.25 per side")
        XCTAssertEqual(PlateMath.text(totalKg: 21, plates: noSmall), "Empty bar ≈ 20 kg")
        XCTAssertTrue(PlateMath.load(totalKg: 60, plates: noSmall)?.isExact == true)
    }

    func testPoundPlatesOnKgBar() throws {
        let pounds = [45.0, 35, 25, 10, 5, 2.5].map { WeightUnit.lb.toKilograms($0) }
        // 100 kg on a 20 kg bar can't be built from pound plates.
        let load = try XCTUnwrap(PlateMath.load(totalKg: 100, barKg: 20, plates: pounds))
        XCTAssertFalse(load.isExact)
        XCTAssertEqual(load.missingPerSideKg, 0.31, accuracy: 0.01)
        XCTAssertEqual(PlateMath.text(totalKg: 100, barKg: 20, plates: pounds, unit: .lb), "45 + 35 + 5 + 2.5 per side ≈ 219.1 lb")
        // 135 lb on a 45 lb bar is exact, despite the conversions.
        let bar = WeightUnit.lb.toKilograms(45)
        XCTAssertEqual(PlateMath.text(totalKg: WeightUnit.lb.toKilograms(135), barKg: bar, plates: pounds, unit: .lb), "45 per side")
    }
}
