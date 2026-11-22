import XCTest
@testable import GeorgeCore

final class V6Tests: XCTestCase {
    let calendar = Calendar.training(timeZone: TimeZone(identifier: "Europe/Vienna")!)

    func session(_ date: Date, sets: Int, muscles: [String], kind: WorkoutKind = .gym, weight: Double? = 20, reps: String = "10", name: String = "Press", mode: ExerciseMode = .reps) -> SessionRecord {
        var item = WorkoutItem(name: name, mode: mode, sets: (0..<sets).map { _ in WorkoutSet(targetReps: reps, targetWeight: weight) }, muscles: muscles)
        for i in item.sets.indices {
            item.sets[i].isDone = true
            item.sets[i].doneAt = date
        }
        return SessionRecord(id: UUID(), date: date, title: "S", kind: kind, durationSeconds: 3600, isCompleted: true, content: WorkoutContent(blocks: [WorkoutBlock(items: [item])]))
    }

    func contributions(_ item: WorkoutItem) -> [MuscleContribution] {
        MuscleResolver.contributions(primary: item.muscles, secondary: [], exerciseName: item.name)
    }

    // MARK: Analytics

    func testSteadyTrainingInTheFirstWeeksIsNotOverload() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 18))!
        var sessions: [SessionRecord] = []
        for week in 0..<4 {
            for d in [0, 2, 4] {
                sessions.append(session(calendar.addingDays(week * 7 + d, to: start), sets: 6, muscles: ["chest"]))
            }
        }
        let engine = MuscleEngine(events: MuscleEngine.events(from: sessions, contributions: contributions), calendar: calendar)
        for day in [14, 21, 26] {
            let now = calendar.addingDays(day, to: start)
            for group: MuscleGroup? in [nil, .chest] {
                let status = engine.loadSummary(group: group, days: 7, now: now).current.status
                XCTAssertTrue([.maintaining, .productive, .calibrating].contains(status), "day \(day) \(String(describing: group)): \(status)")
            }
        }
        let current = engine.loadSummary(group: .chest, days: 7, now: calendar.addingDays(26, to: start)).current
        XCTAssertEqual(current.percentOfUsual, 100, accuracy: 25)
    }

    func testProfileBandChangesTheVerdict() {
        XCTAssertEqual(MuscleEngine.classify(ratio: 1.25, recentRatios: []), .productive)
        XCTAssertEqual(MuscleEngine.classify(ratio: 1.25, recentRatios: [], band: 0.8...1.2), .fatigued)
        XCTAssertEqual(MuscleEngine.classify(ratio: 1.6, recentRatios: [], band: 0.8...1.2), .overtraining)
    }

    func testStretchingAddsLoadButNoSets() {
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 18))!
        let yoga = session(day, sets: 6, muscles: ["hamstrings"], kind: .yoga, weight: nil, name: "Forward Fold", mode: .time)
        let events = MuscleEngine.events(from: [yoga], contributions: contributions)
        XCTAssertFalse(events.isEmpty)
        XCTAssertEqual(events.reduce(0) { $0 + $1.sets }, 0)
        XCTAssertGreaterThan(events.reduce(0) { $0 + $1.load }, 0)
        XCTAssertTrue(MusclePlan.sets(of: yoga.content, completedOnly: true, kind: .yoga, contributions: contributions).isEmpty)
        XCTAssertEqual(MuscleFreshness.self == MuscleFreshness.self, true)
        XCTAssertEqual(FreshnessStatus.fatigued.displayName, "Recovering")
    }

    func testOtherSportsLoadMusclesWithoutSets() {
        let tennis = ExternalWorkout(activity: "tennis", name: "Tennis", start: Date(timeIntervalSince1970: 1_800_000_000), durationSeconds: 5400, effort: 7)
        let events = SportLoad.events(from: [tennis])
        XCTAssertTrue(events.contains { $0.group == .quads && $0.load > 1 })
        XCTAssertEqual(events.reduce(0) { $0 + $1.sets }, 0)
        XCTAssertTrue(SportLoad.events(from: [ExternalWorkout(activity: "tennis", name: "Tennis", start: Date(), durationSeconds: 120)]).isEmpty)
        XCTAssertTrue(SportLoad.events(from: [ExternalWorkout(activity: "chess", name: "Chess", start: Date(), durationSeconds: 3600)]).isEmpty)
    }

    func testOneHeavierSetIsOneRecordAndRepRecordsCount() {
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 18))!
        let before = session(day, sets: 3, muscles: ["chest"], weight: 60, reps: "8", name: "Bench")
        let heavier = session(calendar.addingDays(3, to: day), sets: 3, muscles: ["chest"], weight: 62.5, reps: "8", name: "Bench")
        let records = StatsEngine.newRecords(in: heavier, comparedTo: [before, heavier])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.metric, .weight)

        let moreReps = session(calendar.addingDays(3, to: day), sets: 3, muscles: ["chest"], weight: 60, reps: "10", name: "Bench")
        XCTAssertEqual(StatsEngine.newRecords(in: moreReps, comparedTo: [before]).map(\.metric), [.oneRepMax])

        let pushups = session(day, sets: 3, muscles: ["chest"], weight: nil, reps: "20", name: "Push-up")
        let morePushups = session(calendar.addingDays(2, to: day), sets: 3, muscles: ["chest"], weight: nil, reps: "25", name: "Push-up")
        let pr = StatsEngine.newRecords(in: morePushups, comparedTo: [pushups])
        XCTAssertEqual(pr.map(\.metric), [.reps])
        XCTAssertEqual(pr.first?.detail(), "25 reps")
    }

    func testComparisonWithLastTimeAndTrend() throws {
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 18))!
        var last = session(day, sets: 3, muscles: ["chest"], weight: 60, reps: "8", name: "Bench")
        last.title = "UPPER"
        var now = session(calendar.addingDays(7, to: day), sets: 3, muscles: ["chest"], weight: 65, reps: "8", name: "Bench")
        now.title = "UPPER"
        let comparison = try XCTUnwrap(StatsEngine.compare(now, templateID: nil, previous: [last]))
        XCTAssertEqual(comparison.up, 1)
        XCTAssertGreaterThan(comparison.volumeDelta, 0)
        XCTAssertEqual(comparison.exercises.first?.change(), "76 → 82.5 kg")
        XCTAssertNil(StatsEngine.compare(last, templateID: nil, previous: [now]))

        let trend = try XCTUnwrap(StatsEngine.trend(of: now.content.allItems[0].exerciseKey, in: [last, now], since: day))
        XCTAssertEqual(trend.measure, .oneRepMax)
        XCTAssertEqual(trend.points.count, 2)
        XCTAssertGreaterThan(trend.delta, 0)
        XCTAssertEqual(StatsEngine.topTrends(in: [last, now], since: day).count, 1)
    }

    // MARK: Live helpers

    func testSwapInStraightSetsMakesItsOwnBlock() throws {
        var content = WorkoutContent()
        let sets = (0..<3).map { _ in WorkoutSet(targetReps: "8", targetWeight: 80) }
        content.append(items: [WorkoutItem(name: "Leg Press", sets: sets)], asGroup: false)
        _ = content.toggleSet(id: content.allItems[0].sets[0].id)
        try XCTUnwrap(content.swapRemaining(itemID: content.allItems[0].id, with: WorkoutItem(name: "Squat")))
        XCTAssertEqual(content.blocks.count, 2)
        XCTAssertTrue(content.blocks.allSatisfy { $0.style == .single && $0.items.count == 1 })
    }

    func testSwapInSupersetContinuesTheRounds() throws {
        var content = WorkoutContent()
        let a = WorkoutItem(name: "A", sets: (0..<3).map { _ in WorkoutSet(targetReps: "8") })
        let b = WorkoutItem(name: "B", sets: (0..<3).map { _ in WorkoutSet(targetReps: "8") })
        content.append(items: [a, b], asGroup: true)
        _ = content.toggleSet(id: a.sets[0].id)
        _ = content.toggleSet(id: b.sets[0].id)
        let newID = try XCTUnwrap(content.swapRemaining(itemID: a.id, with: WorkoutItem(name: "A2")))
        let names = content.executionOrder().map { content.item(at: $0)!.name }
        XCTAssertEqual(names, ["A", "B", "A2", "B", "A2", "B"])
        XCTAssertEqual(content.item(id: newID)?.roundOffset, 1)
        // Rest only after B in each round.
        let order = content.executionOrder()
        XCTAssertNil(content.restAfter(order[2], defaultRest: 90))
        XCTAssertEqual(content.restAfter(order[3], defaultRest: 90), 90)
        XCTAssertEqual(content.roundGrid(ofBlock: 0).count, 3)
    }

    func testDropSetInSupersetFollowsItsSetWithoutRest() throws {
        var content = WorkoutContent()
        let a = WorkoutItem(name: "A", sets: (0..<3).map { _ in WorkoutSet(targetReps: "8", targetWeight: 50) })
        let b = WorkoutItem(name: "B", sets: (0..<3).map { _ in WorkoutSet(targetReps: "8") })
        content.append(items: [a, b], asGroup: true)
        content.dropWeight(setID: a.sets[0].id, repsDone: 5, newWeightKg: 40, applyToRemaining: false)
        let order = content.executionOrder()
        let labels = order.map { ref -> String in
            let item = content.item(at: ref)!
            return item.name + (item.sets[ref.setIndex].kind == .drop ? "d" : "")
        }
        XCTAssertEqual(labels, ["A", "Ad", "B", "A", "B", "A", "B"])
        XCTAssertNil(content.restAfter(order[0], defaultRest: 90), "no rest before the drop set")
        XCTAssertNil(content.restAfter(order[1], defaultRest: 90), "B follows in the same round")
        XCTAssertEqual(content.restAfter(order[2], defaultRest: 90), 90)
    }

    func testCurrentSetSurvivesEdits() throws {
        var content = WorkoutContent()
        let items = ["A", "B", "C"].map { WorkoutItem(name: $0, sets: (0..<2).map { _ in WorkoutSet(targetReps: "8") }) }
        content.append(items: items, asGroup: false)
        _ = content.toggleSet(id: items[0].sets[0].id)
        _ = content.toggleSet(id: items[0].sets[1].id)
        // B is current; the user skipped nothing.
        let current = items[1].sets[0].id
        let anchor = items[0].sets[1].id
        // Insert an exercise at the very start: B stays current.
        content.blocks.insert(WorkoutBlock(items: [WorkoutItem(name: "New", sets: [WorkoutSet(targetReps: "5")])]), at: 0)
        XCTAssertEqual(content.set(at: try XCTUnwrap(content.resolveCurrent(currentID: current, anchorID: anchor)))?.id, current)
        // Delete a done set before it: still B.
        content.removeSet(id: items[0].sets[0].id)
        XCTAssertEqual(content.set(at: try XCTUnwrap(content.resolveCurrent(currentID: current, anchorID: anchor)))?.id, current)
        // Delete the current set itself: the next open set after the anchor, not the new exercise at the top.
        content.removeSet(id: current)
        let next = try XCTUnwrap(content.resolveCurrent(currentID: current, anchorID: anchor))
        XCTAssertEqual(content.item(at: next)?.name, "B")
    }

    func testPauseShiftsThePace() {
        var pace = PaceTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        pace.setCompleted(at: t0, plannedRest: nil, workSeconds: 30)
        pace.shift(by: 300)
        pace.setStarted(at: t0.addingTimeInterval(390), plannedRest: 90)
        XCTAssertEqual(pace.lastGap?.delta ?? 99, 0, accuracy: 0.01)
    }

    func testProgressionRespectsTheDay() throws {
        let last = (0..<3).map { _ in WorkoutSet(targetReps: "8-10", targetWeight: 100, reps: 10, isDone: true) }
        let normal = try XCTUnwrap(ProgressionAdvisor.suggest(lastSets: last, mode: .reps, plan: nil, incrementKg: 2.5, intensity: .normal, loadStatus: .productive))
        XCTAssertEqual(normal.kind, .addWeight)
        let calm = try XCTUnwrap(ProgressionAdvisor.suggest(lastSets: last, mode: .reps, plan: nil, incrementKg: 2.5, intensity: .calm, loadStatus: nil))
        XCTAssertEqual(calm.kind, .keep)
        XCTAssertEqual(calm.weightKg, 100)
        let tired = try XCTUnwrap(ProgressionAdvisor.suggest(lastSets: last, mode: .reps, plan: nil, incrementKg: 2.5, intensity: .normal, loadStatus: .fatigued))
        XCTAssertEqual(tired.kind, .keep)
        let over = try XCTUnwrap(ProgressionAdvisor.suggest(lastSets: last, mode: .reps, plan: nil, incrementKg: 2.5, intensity: .hype, loadStatus: .overtraining))
        XCTAssertEqual(over.kind, .lighten)
        XCTAssertEqual(over.weightKg, 97.5)
    }

    func testWarmupsAndPlates() {
        let warmups = WarmupBuilder.sets(topKg: 100)
        XCTAssertEqual(warmups.map(\.targetWeight), [20, 50, 70, 85])
        XCTAssertEqual(warmups.map(\.targetReps), ["10", "5", "3", "1"])
        XCTAssertTrue(warmups.allSatisfy { $0.kind == .warmup })
        XCTAssertTrue(WarmupBuilder.sets(topKg: 20).isEmpty)
        XCTAssertEqual(PlateMath.perSide(totalKg: 100), [25, 15])
        XCTAssertEqual(PlateMath.text(totalKg: 62.5), "20 + 1.25 per side")
        XCTAssertEqual(PlateMath.text(totalKg: 20), "Empty bar")
        var content = WorkoutContent()
        content.append(items: [WorkoutItem(name: "Squat", sets: [WorkoutSet(targetReps: "5", targetWeight: 100)])], asGroup: false)
        XCTAssertEqual(content.addWarmups(to: content.allItems[0].id), 4)
        XCTAssertEqual(content.addWarmups(to: content.allItems[0].id), 0, "only once")
        XCTAssertEqual(content.allItems[0].sets.count, 5)
    }

    func testStreakRulesNeedTheMinutesForShortRoutines() {
        XCTAssertFalse(StreakRules.qualifies(minutes: 2, doneSets: 5, isRescue: false, kind: .stretch, minimumMinutes: 10, rescueMinutes: 10))
        XCTAssertTrue(StreakRules.qualifies(minutes: 2, doneSets: 5, isRescue: false, kind: .gym, minimumMinutes: 10, rescueMinutes: 10))
        XCTAssertTrue(StreakRules.qualifies(minutes: 12, doneSets: 0, isRescue: false, kind: .yoga, minimumMinutes: 10, rescueMinutes: 10))
        XCTAssertTrue(StreakRules.qualifies(minutes: 3, doneSets: 1, isRescue: true, kind: .mobility, minimumMinutes: 10, rescueMinutes: 10))
        XCTAssertEqual(WorkoutKind.yoga.defaultEffort, 3)
        XCTAssertEqual(WorkoutKind.gym.defaultEffort, 6)
    }

    func testPerformedState() {
        var content = WorkoutContent()
        content.append(items: [WorkoutItem(name: "A", sets: [WorkoutSet(targetReps: "5"), WorkoutSet(targetReps: "5")])], asGroup: false)
        XCTAssertEqual(content.performedState, .none)
        _ = content.toggleSet(id: content.allItems[0].sets[0].id)
        XCTAssertEqual(content.performedState, .some)
        content.markAllDone()
        XCTAssertEqual(content.performedState, .all)
    }

    func testWeekPlannerSpreadsTheRotation() {
        let monday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 9))!
        let templates = ["UPPER", "LOWER", "FULL"].map { PlannableTemplate(id: UUID(), name: $0, scheduleDays: []) }
        let plan = WeekPlanner.propose(templates: templates, rotationStart: 1, weeklyGoal: 3, trainedThisWeek: 0, busyDays: [], from: monday, calendar: calendar)
        XCTAssertEqual(plan.map(\.templateName), ["LOWER", "FULL", "UPPER"])
        let gaps = zip(plan.dropFirst(), plan).map { calendar.daysBetween($0.1.date, $0.0.date) }
        XCTAssertTrue(gaps.allSatisfy { $0 >= 2 }, "\(gaps)")

        let scheduled = [PlannableTemplate(id: UUID(), name: "LOWER", scheduleDays: [2]), PlannableTemplate(id: UUID(), name: "UPPER", scheduleDays: [6])]
        let weekly = WeekPlanner.propose(templates: scheduled, rotationStart: 0, weeklyGoal: 3, trainedThisWeek: 0,
                                         busyDays: [calendar.startOfDay(for: monday)], from: monday, calendar: calendar)
        XCTAssertEqual(weekly.map(\.templateName), ["UPPER"], "Monday is already planned")
        XCTAssertTrue(WeekPlanner.propose(templates: templates, rotationStart: 0, weeklyGoal: 3, trainedThisWeek: 3, busyDays: [], from: monday, calendar: calendar).isEmpty)
    }

    func testCoolDownFitsTheWorkout() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources/exercises.json")
        let catalog = try ExerciseCatalog(data: try Data(contentsOf: url))
        let legs = try XCTUnwrap(RoutineLibrary.coolDown(for: [.quads: 8, .hamstrings: 6, .glutes: 6], catalog: catalog))
        XCTAssertTrue(legs.kind.isFlow)
        XCTAssertEqual(RoutineLibrary.coolDown(for: [:], catalog: catalog)?.id, "post-workout")
    }

    // MARK: Watch

    func testWatchCommandsAreDroppedWhenStale() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let session = UUID()
        let oldStart = WatchCommandEnvelope(command: .startTemplate(UUID()), sentAt: now.addingTimeInterval(-600), sessionID: nil)
        XCTAssertFalse(oldStart.isFresh(activeSessionID: nil, now: now))
        let freshStart = WatchCommandEnvelope(command: .startTemplate(UUID()), sentAt: now.addingTimeInterval(-10), sessionID: nil)
        XCTAssertTrue(freshStart.isFresh(activeSessionID: nil, now: now))
        XCTAssertFalse(freshStart.isFresh(activeSessionID: session, now: now), "never replaces a running workout")
        let finishOther = WatchCommandEnvelope(command: .finish(effort: 6), sentAt: now, sessionID: UUID())
        XCTAssertFalse(finishOther.isFresh(activeSessionID: session, now: now))
        let finish = WatchCommandEnvelope(command: .finish(effort: 6), sentAt: now, sessionID: session)
        XCTAssertTrue(finish.isFresh(activeSessionID: session, now: now))

        let data = try WatchWire.encoder.encode(WatchCommandEnvelope(command: .completeSet(id: session, reps: 6, weightKg: 60), sessionID: session))
        let back = try WatchWire.decoder.decode(WatchCommandEnvelope.self, from: data)
        XCTAssertEqual(back.command, .completeSet(id: session, reps: 6, weightKg: 60))

        // An older phone's live state (without the new fields) still decodes.
        let state = WatchLiveState(sessionID: session, title: "T", kind: .gym, startedAt: now, accumulatedSeconds: 0, resumedAt: now, isPaused: false, restEndsAt: nil, restTotalSeconds: nil, currentSetID: nil, exercises: [], completedSets: 0, totalSets: 0)
        let decoded = try WatchWire.decoder.decode(WatchLiveState.self, from: WatchWire.encoder.encode(state))
        XCTAssertNil(decoded.usesStartButton)
    }
}

final class V6TemplateTests: XCTestCase {
    func testLoadChangesAgainstTheTemplate() {
        var template = WorkoutContent()
        template.append(items: [WorkoutItem(name: "Deadlift", sets: [WorkoutSet(targetReps: "5", targetWeight: 100)]),
                                WorkoutItem(name: "Row", sets: [WorkoutSet(targetReps: "8", targetWeight: 60)])], asGroup: false)
        var session = template.freshCopy()
        session.updateSet(id: session.allItems[0].sets[0].id) { $0.weight = 105 }
        _ = session.toggleSet(id: session.allItems[0].sets[0].id)
        _ = session.toggleSet(id: session.allItems[1].sets[0].id)
        XCTAssertEqual(session.loadChanges(comparedTo: template), ["Deadlift 100 → 105 kg"])
    }
}

final class HowToTests: XCTestCase {
    func testStretchYogaAndMobilityHaveGuidance() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources/exercises.json")
        let catalog = try ExerciseCatalog(data: try Data(contentsOf: url))
        let guided = catalog.exercises.filter(\.needsGuidance)
        XCTAssertGreaterThan(guided.count, 300)
        for exercise in guided {
            XCTAssertGreaterThanOrEqual(exercise.steps.count, 3, exercise.name)
            for reference in exercise.references {
                XCTAssertTrue(reference.url.hasPrefix("https://"), reference.url)
                XCTAssertFalse(reference.site.isEmpty)
            }
        }
        let withPages = guided.filter { !$0.references.isEmpty }.count
        XCTAssertGreaterThanOrEqual(Double(withPages) / Double(guided.count), 0.9, "how-to pages for most moves")
        let pigeon = try XCTUnwrap(catalog.exercise(named: "Pigeon Pose"))
        XCTAssertEqual(pigeon.references.first?.site, "Yoga Journal")
        XCTAssertNotNil(catalog.exercise(named: "Plow Pose")?.caution)
    }
}
