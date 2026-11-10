import XCTest
@testable import GeorgeCore

final class KindAndParsingTests: XCTestCase {
    func testKindAliases() {
        XCTAssertEqual(WorkoutKind("Elastic Bands"), .band)
        XCTAssertEqual(WorkoutKind("STRETCHING"), .stretch)
        XCTAssertEqual(WorkoutKind("pre&mob"), .mobility)
        XCTAssertEqual(WorkoutKind("Weights"), .gym)
        XCTAssertEqual(WorkoutKind("Tennis Drills").rawValue, "tennis-drills")
        XCTAssertEqual(WorkoutKind("Tennis Drills").displayName, "Tennis Drills")
        XCTAssertFalse(WorkoutKind("pilates").isPreset)
    }

    func testLooseSeconds() {
        XCTAssertEqual(LooseParse.seconds("30"), 30)
        XCTAssertEqual(LooseParse.seconds("30s"), 30)
        XCTAssertEqual(LooseParse.seconds("45 sec"), 45)
        XCTAssertEqual(LooseParse.seconds("1:30"), 90)
        XCTAssertEqual(LooseParse.seconds("2 min"), 120)
        XCTAssertEqual(LooseParse.seconds("1h30m"), 5400)
        XCTAssertEqual(LooseParse.seconds("90''"), 90)
        XCTAssertNil(LooseParse.seconds("abc"))
        XCTAssertNil(LooseParse.seconds(""))
    }

    func testLooseMeters() {
        XCTAssertEqual(LooseParse.meters("400"), 400)
        XCTAssertEqual(LooseParse.meters("1.5km"), 1500)
        XCTAssertEqual(LooseParse.meters("1 mi")!, 1609.344, accuracy: 0.01)
    }

    func testFormat() {
        XCTAssertEqual(Format.number(12), "12")
        XCTAssertEqual(Format.number(12.5), "12.5")
        XCTAssertEqual(Format.shortDuration(45), "45s")
        XCTAssertEqual(Format.shortDuration(90), "1:30")
        XCTAssertEqual(Format.shortDuration(600), "10 min")
        XCTAssertEqual(Format.clock(3725), "1:02:05")
        XCTAssertEqual(Format.weight(20, unit: .lb), "44.09 lb")
    }

    func testCSVReaderQuotes() {
        let text = "a,b,c\n1,\"hello, world\",\"say \"\"hi\"\"\"\n2,\"multi\nline\",x\n"
        let rows = CSVReader.parse(text)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1].fields, ["1", "hello, world", "say \"hi\""])
        XCTAssertEqual(rows[2].fields, ["2", "multi\nline", "x"])
    }

    func testCSVSemicolonDetection() {
        let rows = CSVReader.parse("exercise;sets;reps\nSquat;3;10\n")
        XCTAssertEqual(rows[1].fields, ["Squat", "3", "10"])
    }
}

final class ProgramCSVTests: XCTestCase {
    func sampleText() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("samples/elastic-bands-tennis.csv")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testSampleImport() throws {
        let result = try ProgramCSV.parse(try sampleText())
        XCTAssertEqual(result.programs.count, 1)
        let program = result.programs[0]
        XCTAssertEqual(program.name, "Elastic Bands – Tennis")
        XCTAssertEqual(program.workouts.map(\.name), ["LOWER", "UPPER", "FULLY", "PRE&MOB"])

        let lower = program.workouts[0]
        XCTAssertEqual(lower.subtitle, "LOWER BODY + TENNIS CORE")
        XCTAssertEqual(lower.kind, .band)
        XCTAssertEqual(lower.scheduleDays, [2])
        XCTAssertEqual(lower.content.sections, ["WARM-UP", "MAIN", "TENNIS CORE"])
        // Jumping jacks is timed
        XCTAssertEqual(lower.content.blocks[0].items[0].mode, .time)
        XCTAssertEqual(lower.content.blocks[0].items[0].sets.first?.targetSeconds, 60)
        // Superset A
        let supersetA = lower.content.blocks.first { $0.items.count == 2 }
        XCTAssertNotNil(supersetA)
        XCTAssertEqual(supersetA?.style, .superset)
        XCTAssertEqual(supersetA?.rounds, 3)
        XCTAssertEqual(supersetA?.restAfterRoundSeconds, 60)
        // Circuit B with side plank timed
        let circuit = lower.content.blocks.first { $0.items.count == 3 }
        XCTAssertEqual(circuit?.style, .circuit)
        XCTAssertEqual(circuit?.items[2].mode, .time)
        XCTAssertEqual(circuit?.items[2].perSide, true)

        let upper = program.workouts[1]
        XCTAssertEqual(upper.scheduleDays, [3, 5])
        // Warm-up + working rows merged into one exercise
        let er = upper.content.allItems.first { $0.name == "External Rotation with Band" }
        XCTAssertEqual(er?.sets.count, 4)
        XCTAssertEqual(er?.sets.map(\.kind), [.warmup, .warmup, .working, .working])
        XCTAssertEqual(upper.content.allItems.filter { $0.name == "External Rotation with Band" }.count, 1)
        // Pyramid reps
        let row = upper.content.allItems.first { $0.name == "Band Bent-Over Row" }
        XCTAssertEqual(row?.sets.map(\.targetReps), ["15", "12", "12", "10"])
        XCTAssertEqual(row?.sets.first?.targetLoad, "heavy band")
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
    }

    func testRoundTrip() throws {
        let result = try ProgramCSV.parse(try sampleText())
        let program = result.programs[0]
        let exported = ProgramCSV.export(programName: program.name, workouts: program.workouts.map {
            ProgramCSV.ExportWorkout(name: $0.name, subtitle: $0.subtitle, kind: $0.kind, order: $0.order, scheduleDays: $0.scheduleDays, notes: $0.notes, content: $0.content)
        })
        let reparsed = try ProgramCSV.parse(exported)
        XCTAssertEqual(reparsed.programs.count, 1)
        let a = program.workouts
        let b = reparsed.programs[0].workouts
        XCTAssertEqual(a.map(\.name), b.map(\.name))
        for (wa, wb) in zip(a, b) {
            XCTAssertEqual(wa.content.structureSignature, wb.content.structureSignature, wa.name)
            XCTAssertEqual(wa.content.sections, wb.content.sections, wa.name)
            XCTAssertEqual(wa.scheduleDays, wb.scheduleDays)
            XCTAssertEqual(wa.kind, wb.kind)
            let setsA = wa.content.allItems.flatMap { $0.sets.map { [$0.targetReps ?? "", String($0.targetSeconds ?? 0), $0.kind.rawValue] } }
            let setsB = wb.content.allItems.flatMap { $0.sets.map { [$0.targetReps ?? "", String($0.targetSeconds ?? 0), $0.kind.rawValue] } }
            XCTAssertEqual(setsA, setsB, wa.name)
        }
    }

    func testDocumentationExampleParses() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/CSV_FORMAT.md")
        let doc = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(doc.range(of: "```csv\n"))
        let end = try XCTUnwrap(doc.range(of: "```", range: start.upperBound..<doc.endIndex))
        let csv = String(doc[start.upperBound..<end.lowerBound])
        let result = try ProgramCSV.parse(csv)
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
        let upper = result.programs[0].workouts[0]
        XCTAssertEqual(upper.content.exerciseCount, 5)
        XCTAssertEqual(upper.content.sections, ["PREHAB", "MAIN", "CORE"])
        XCTAssertEqual(upper.content.blocks.first { $0.items.count == 2 }?.rounds, 4)
    }

    func testPoundsAndMissingColumn() throws {
        let csv = "workout,exercise,sets,reps,weight,unit\nPush,Bench Press,3,5,225,lb\n"
        let result = try ProgramCSV.parse(csv, defaultProgramName: "Gym")
        XCTAssertEqual(result.programs[0].name, "Gym")
        let weight = result.programs[0].workouts[0].content.allItems[0].sets[0].targetWeight ?? 0
        XCTAssertEqual(weight, 102.06, accuracy: 0.01)
        XCTAssertThrowsError(try ProgramCSV.parse("workout,sets\nA,3\n"))
    }

    func testGroupNumbersAndRounds() throws {
        let csv = """
        workout,group,exercise,sets,reps
        Day 1,A1,Push-up,3,10
        Day 1,A2,Row,3,10
        Day 1,,Plank,2,
        """
        let result = try ProgramCSV.parse(csv)
        let content = result.programs[0].workouts[0].content
        XCTAssertEqual(content.blocks.count, 2)
        XCTAssertEqual(content.blocks[0].style, .superset)
        let order = content.executionOrder().map { content.item(at: $0)!.name }
        XCTAssertEqual(order, ["Push-up", "Row", "Push-up", "Row", "Push-up", "Row", "Plank", "Plank"])
    }
}

final class ContentTests: XCTestCase {
    func makeContent() -> WorkoutContent {
        let a = WorkoutItem(name: "A", sets: [WorkoutSet(targetReps: "10", targetWeight: 20), WorkoutSet(targetReps: "8", targetWeight: 22.5)], restSeconds: 90)
        let b = WorkoutItem(name: "B", sets: [WorkoutSet(targetReps: "12"), WorkoutSet(targetReps: "12")])
        let c = WorkoutItem(name: "C", sets: [WorkoutSet(targetReps: "12"), WorkoutSet(targetReps: "12")])
        return WorkoutContent(blocks: [
            WorkoutBlock(style: .single, items: [a]),
            WorkoutBlock(style: .superset, restAfterRoundSeconds: 60, items: [b, c]),
        ])
    }

    func testToggleCopiesTargets() {
        var content = makeContent()
        let setID = content.blocks[0].items[0].sets[0].id
        XCTAssertTrue(content.toggleSet(id: setID))
        let set = content.set(id: setID)!
        XCTAssertEqual(set.reps, 10)
        XCTAssertEqual(set.weight, 20)
        XCTAssertEqual(content.completedSets, 1)
        XCTAssertEqual(content.volumeKg, 200)
        XCTAssertFalse(content.toggleSet(id: setID))
        XCTAssertNil(content.set(id: setID)?.doneAt)
    }

    func testRestRules() {
        let content = makeContent()
        let order = content.executionOrder()
        XCTAssertEqual(order.count, 6)
        XCTAssertEqual(content.restAfter(order[0], defaultRest: 120), 90) // straight set rest
        XCTAssertNil(content.restAfter(order[2], defaultRest: 120))       // B1 -> straight to C1
        XCTAssertEqual(content.restAfter(order[3], defaultRest: 120), 60) // after C1 -> round rest
    }

    func testNextPendingWraps() {
        var content = makeContent()
        let order = content.executionOrder()
        content.toggleSet(id: content.set(at: order[0])!.id)
        XCTAssertEqual(content.nextPendingSet(after: order[0]), order[1])
        XCTAssertEqual(content.nextPendingSet(after: order[5]), order[1])
    }

    func testGroupingOperations() {
        var content = makeContent()
        let aID = content.blocks[0].items[0].id
        content.groupWithNext(itemID: aID)
        XCTAssertEqual(content.blocks.count, 1)
        XCTAssertEqual(content.blocks[0].style, .circuit)
        content.ungroup(blockID: content.blocks[0].id)
        XCTAssertEqual(content.blocks.count, 3)
        XCTAssertTrue(content.blocks.allSatisfy { $0.style == .single })
    }

    func testMoveItemAcrossBlocks() {
        var content = makeContent()
        let cID = content.blocks[1].items[1].id
        content.moveItem(id: cID, by: 1) // leaves the superset
        XCTAssertEqual(content.blocks.count, 3)
        XCTAssertEqual(content.blocks[1].style, .single)
        XCTAssertEqual(content.blocks[2].items[0].name, "C")
    }

    func testFreshCopyAndTemplatePromotion() {
        var content = makeContent()
        let id = content.blocks[0].items[0].sets[0].id
        content.updateSet(id: id) { $0.reps = 12; $0.weight = 25; $0.isDone = true }
        let fresh = content.freshCopy()
        XCTAssertEqual(fresh.completedSets, 0)
        XCTAssertNotEqual(fresh.blocks[0].items[0].sets[0].id, id)
        XCTAssertEqual(fresh.blocks[0].items[0].sets[0].targetWeight, 20)
        let template = content.asTemplate()
        XCTAssertEqual(template.blocks[0].items[0].sets[0].targetReps, "12")
        XCTAssertEqual(template.blocks[0].items[0].sets[0].targetWeight, 25)
        XCTAssertFalse(content.structureDiffers(from: fresh))
    }

    func testCodableIsForwardCompatible() throws {
        let json = #"{"blocks":[{"items":[{"name":"Squat","sets":[{"targetReps":"5"}]}]}]}"#
        let content = WorkoutContent.decode(json.data(using: .utf8))
        XCTAssertEqual(content.allItems.first?.name, "Squat")
        XCTAssertEqual(content.blocks.first?.style, .single)
        XCTAssertEqual(content.allItems.first?.sets.first?.targetRepsValue, 5)
        let roundTrip = WorkoutContent.decode(content.encoded())
        XCTAssertEqual(roundTrip, content)
    }

    func testPrescription() {
        let item = WorkoutItem(name: "Row", sets: [WorkoutSet(targetReps: "12", targetLoad: "red band"), WorkoutSet(targetReps: "12", targetLoad: "red band")], perSide: true, restSeconds: 60)
        XCTAssertEqual(item.prescription(unit: .kg), "2 × 12 · red band · each side · rest 1 min")
    }
}

final class NamingAndDatesTests: XCTestCase {
    let calendar = Calendar.training(timeZone: TimeZone(identifier: "Europe/Vienna")!)

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testSessionTitle() {
        let namer = SessionNamer(calendar: calendar)
        XCTAssertEqual(namer.title(templateName: "UPPER", date: date(2026, 10, 29), indexInWeek: 3), "W44: 3 UPPER - 29.10")
        XCTAssertEqual(namer.title(templateName: "LOWER", date: date(2026, 10, 19), indexInWeek: 1), "W43: 1 LOWER - 19.10")
        let custom = SessionNamer(pattern: "{WD} {T} ({DATE})", calendar: calendar)
        XCTAssertEqual(custom.title(templateName: "FULLY", date: date(2026, 10, 25), indexInWeek: 1), "Sun FULLY (25.10.26)")
        XCTAssertEqual(namer.weekTitle(for: date(2026, 10, 29)), "W44 · 26 Oct – 1 Nov")
    }

    func testBuckets() {
        let now = date(2026, 10, 29)
        XCTAssertEqual(DateBucket.bucket(for: date(2026, 10, 29, 8), now: now, calendar: calendar), .today)
        XCTAssertEqual(DateBucket.bucket(for: date(2026, 10, 28), now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(DateBucket.bucket(for: date(2026, 10, 25), now: now, calendar: calendar), .previous7)
        XCTAssertEqual(DateBucket.bucket(for: date(2026, 10, 16), now: now, calendar: calendar), .previous30)
        XCTAssertEqual(DateBucket.bucket(for: date(2026, 6, 13), now: now, calendar: calendar), .month(year: 2026, month: 6))
        XCTAssertEqual(DateBucket.bucket(for: date(2025, 6, 13), now: now, calendar: calendar), .year(2025))
        XCTAssertEqual(DateBucket.bucket(for: date(2026, 11, 2), now: now, calendar: calendar), .upcoming)
        XCTAssertTrue(DateBucket.today < DateBucket.previous7)
        XCTAssertTrue(DateBucket.month(year: 2026, month: 9) < DateBucket.month(year: 2026, month: 6))
    }
}

final class StreakTests: XCTestCase {
    let calendar = Calendar.training(timeZone: TimeZone(identifier: "Europe/Vienna")!)

    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 18))!
    }

    /// Workouts on the given days of the week starting at `monday`.
    func week(_ monday: Date, days: [Int], rescue: Bool = false) -> [ActivityEntry] {
        days.map { ActivityEntry(date: calendar.addingDays($0, to: monday), minutes: 40, isRescue: rescue && $0 == days.last) }
    }

    func testMetWeeksEarnCredits() {
        let engine = StreakEngine(calendar: calendar)
        let start = date(2026, 9, 28) // Monday W40
        var entries: [ActivityEntry] = []
        for w in 0..<4 { entries += week(calendar.addingWeeks(w, to: start), days: [0, 2, 4]) }
        let now = calendar.addingDays(1, to: calendar.addingWeeks(4, to: start)) // Tuesday of week 5
        let summary = engine.evaluate(entries: entries, config: StreakConfig(defaultGoal: 3), now: now)
        XCTAssertEqual(summary.currentWeeks, 4)
        XCTAssertEqual(summary.credits, 2)
        XCTAssertEqual(summary.thisWeek.neededDays, 3)
        XCTAssertEqual(summary.thisWeek.remainingDays, 6)
        XCTAssertEqual(summary.thisWeek.status, .onTrack)
    }

    func testMissedWeekSpendsCredit() {
        let engine = StreakEngine(calendar: calendar)
        let start = date(2026, 9, 28)
        var entries: [ActivityEntry] = []
        entries += week(start, days: [0, 2, 4])
        entries += week(calendar.addingWeeks(1, to: start), days: [0, 2, 4])
        entries += week(calendar.addingWeeks(2, to: start), days: [1]) // missed
        entries += week(calendar.addingWeeks(3, to: start), days: [0, 2, 4])
        let now = calendar.addingWeeks(4, to: start)
        let summary = engine.evaluate(entries: entries, config: StreakConfig(defaultGoal: 3), now: now)
        XCTAssertEqual(summary.history.map(\.outcome), [.met, .met, .saved, .met])
        XCTAssertEqual(summary.currentWeeks, 3)
        XCTAssertEqual(summary.credits, 0)
    }

    func testMissWithoutCreditResets() {
        let engine = StreakEngine(calendar: calendar)
        let start = date(2026, 9, 28)
        var entries: [ActivityEntry] = []
        entries += week(start, days: [0, 2, 4])
        entries += week(calendar.addingWeeks(1, to: start), days: [1])
        entries += week(calendar.addingWeeks(2, to: start), days: [0, 2, 4])
        let summary = engine.evaluate(entries: entries, config: StreakConfig(defaultGoal: 3), now: calendar.addingWeeks(3, to: start))
        XCTAssertEqual(summary.history.map(\.outcome), [.met, .missed, .met])
        XCTAssertEqual(summary.currentWeeks, 1)
        XCTAssertEqual(summary.bestWeeks, 1)
    }

    func testRescueCountsDouble() {
        let engine = StreakEngine(calendar: calendar)
        let start = date(2026, 9, 28)
        var entries = week(start, days: [0, 2, 4])
        // Second week: only Monday + a rescue on Sunday -> 2 days + 1 bonus = 3
        entries += week(calendar.addingWeeks(1, to: start), days: [0])
        entries.append(ActivityEntry(date: calendar.addingDays(6, to: calendar.addingWeeks(1, to: start)), minutes: 10, isRescue: true))
        let summary = engine.evaluate(entries: entries, config: StreakConfig(defaultGoal: 3), now: calendar.addingWeeks(2, to: start))
        XCTAssertEqual(summary.history.map(\.outcome), [.met, .met])
        XCTAssertEqual(summary.currentWeeks, 2)
    }

    func testRescueStatusOnSunday() {
        let engine = StreakEngine(calendar: calendar)
        let start = date(2026, 9, 28)
        var entries = week(start, days: [0, 2, 4])
        let thisMonday = calendar.addingWeeks(1, to: start)
        entries += week(thisMonday, days: [0])
        let sunday = calendar.addingDays(6, to: thisMonday)
        let summary = engine.evaluate(entries: entries, config: StreakConfig(defaultGoal: 3, autoUseCredits: false), now: sunday)
        XCTAssertEqual(summary.thisWeek.neededDays, 2)
        XCTAssertEqual(summary.thisWeek.remainingDays, 1)
        XCTAssertEqual(summary.thisWeek.status, .rescueAvailable)
    }

    func testGoalHistory() {
        let engine = StreakEngine(calendar: calendar)
        let start = date(2026, 9, 28)
        var entries = week(start, days: [0, 2, 4])
        entries += week(calendar.addingWeeks(1, to: start), days: [0, 3])
        let config = StreakConfig(goals: [
            GoalChange(effectiveFrom: start, daysPerWeek: 3),
            GoalChange(effectiveFrom: calendar.addingWeeks(1, to: start), daysPerWeek: 2),
        ])
        let summary = engine.evaluate(entries: entries, config: config, now: calendar.addingWeeks(2, to: start))
        XCTAssertEqual(summary.history.map(\.goal), [3, 2])
        XCTAssertEqual(summary.currentWeeks, 2)
    }

    func testExcusedWeekIsNeutral() {
        let engine = StreakEngine(calendar: calendar)
        let start = date(2026, 9, 28)
        var entries = week(start, days: [0, 2, 4])
        entries += week(calendar.addingWeeks(2, to: start), days: [0, 2, 4])
        let summary = engine.evaluate(entries: entries, excusedWeeks: [calendar.addingWeeks(1, to: start)], config: StreakConfig(defaultGoal: 3, autoUseCredits: false), now: calendar.addingWeeks(3, to: start))
        XCTAssertEqual(summary.history.map(\.outcome), [.met, .excused, .met])
        XCTAssertEqual(summary.currentWeeks, 2)
    }
}

final class StatsTests: XCTestCase {
    func testRecordsAndHistory() {
        func session(_ day: Double, weight: Double, reps: Int) -> SessionRecord {
            var set = WorkoutSet(targetReps: String(reps), targetWeight: weight)
            set.isDone = true
            set.reps = reps
            set.weight = weight
            let item = WorkoutItem(exerciseID: "fedb:Squat", name: "Squat", sets: [set])
            return SessionRecord(id: UUID(), date: Date(timeIntervalSince1970: day * 86_400), title: "S", kind: .gym, durationSeconds: 3600, isCompleted: true, content: WorkoutContent(blocks: [WorkoutBlock(items: [item])]))
        }
        let sessions = [session(1, weight: 100, reps: 5), session(8, weight: 105, reps: 5), session(15, weight: 102.5, reps: 8)]
        let history = StatsEngine.history(of: "fedb:Squat", in: sessions)
        XCTAssertEqual(history.map(\.bestWeight), [100, 105, 102.5])
        let records = StatsEngine.newRecords(in: sessions[1], comparedTo: sessions)
        XCTAssertTrue(records.contains { $0.metric == .weight && $0.value == 105 })
        let last = StatsEngine.lastPerformance(of: "fedb:Squat", in: sessions, before: Date(timeIntervalSince1970: 10 * 86_400))
        XCTAssertEqual(last?.first?.weight, 105)
        XCTAssertEqual(StatsEngine.oneRepMax(weight: 100, reps: 5), 116.666, accuracy: 0.01)
    }

    func testEnergy() {
        let kcal = EnergyEstimator.kilocalories(kind: .gym, durationSeconds: 3600, bodyMassKg: 80)
        XCTAssertEqual(kcal, 400, accuracy: 0.1)
    }
}

final class LibraryTests: XCTestCase {
    func testBundledLibraryDecodes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources/exercises.json")
        let catalog = try ExerciseCatalog(data: try Data(contentsOf: url))
        XCTAssertGreaterThan(catalog.exercises.count, 1000)
        XCTAssertNotNil(catalog.exercise(named: "band face pull"))
        XCTAssertNotNil(catalog.exercise(named: "Adho Mukha Svanasana"))
        let bands = catalog.search("row", kind: .band)
        XCTAssertFalse(bands.isEmpty)
        XCTAssertTrue(bands.allSatisfy { $0.kind == .band })
        let face = catalog.exercise(named: "Band Face Pull")!
        XCTAssertEqual(catalog.imageURLs(for: face).first?.absoluteString, "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Face_Pull/0.jpg")
        let item = face.makeItem()
        XCTAssertEqual(item.sets.count, 3)
        XCTAssertEqual(item.exerciseID, "george:band-face-pull")
    }

    func testYouTubeHelpers() {
        let url = URL(string: "https://www.youtube.com/watch?v=abc123XYZ")!
        XCTAssertEqual(TutorialLinks.youtubeID(from: url), "abc123XYZ")
        XCTAssertEqual(TutorialLinks.youtubeID(from: URL(string: "https://youtu.be/xyz")!), "xyz")
        XCTAssertEqual(TutorialLinks.youtubeID(from: URL(string: "https://youtube.com/shorts/s1")!), "s1")
        XCTAssertNotNil(TutorialLinks.youtubeSearch(for: "Band Face Pull", kind: .band))
    }
}

final class WatchProtocolTests: XCTestCase {
    func testCommandRoundTrip() {
        let id = UUID()
        let message = WatchWire.pack(WatchCommand.toggleSet(id), as: .command)
        XCTAssertEqual(WatchWire.type(of: message), .command)
        XCTAssertEqual(WatchWire.unpack(message, as: WatchCommand.self), .toggleSet(id))
        let finish = WatchWire.pack(WatchCommand.finish(effort: 7), as: .command)
        XCTAssertEqual(WatchWire.unpack(finish, as: WatchCommand.self), .finish(effort: 7))
    }

    func testLiveElapsed() {
        let start = Date(timeIntervalSince1970: 1000)
        let state = WatchLiveState(sessionID: UUID(), title: "T", kind: .gym, startedAt: start, accumulatedSeconds: 60, resumedAt: start, isPaused: false, restEndsAt: nil, restTotalSeconds: nil, currentSetID: nil, exercises: [], completedSets: 0, totalSets: 0)
        XCTAssertEqual(state.elapsed(at: Date(timeIntervalSince1970: 1030)), 90)
    }
}

final class MuscleTests: XCTestCase {
    let calendar = Calendar.training(timeZone: TimeZone(identifier: "Europe/Vienna")!)

    func testResolver() {
        let row = MuscleResolver.contributions(primary: ["middle back", "lats"], secondary: ["biceps"], exerciseName: "Band Bent-Over Row")
        XCTAssertEqual(Set(row.map(\.group)), [.upperBack, .lats, .biceps])
        XCTAssertEqual(row.first { $0.group == .biceps }?.weight, 0.5)
        let chop = MuscleResolver.contributions(primary: ["abdominals"], secondary: [], exerciseName: "Band High-to-Low Woodchop")
        XCTAssertEqual(chop.first { $0.group == .obliques }?.weight, 1)
        let raise = MuscleResolver.contributions(primary: ["abdominals"], secondary: [], exerciseName: "Hanging Leg Raise")
        XCTAssertEqual(raise.first { $0.group == .hipFlexors }?.weight, 0.5)
        XCTAssertNil(MuscleGroup.from(libraryName: "spleen"))
    }

    func session(_ date: Date, sets: Int, muscles: [String], secondary: [String] = [], kind: SetKind = .working) -> SessionRecord {
        var item = WorkoutItem(name: "Press", sets: (0..<sets).map { _ in WorkoutSet(kind: kind, targetReps: "10", targetWeight: 20) }, muscles: muscles)
        for i in item.sets.indices {
            item.sets[i].isDone = true
            item.sets[i].doneAt = date
        }
        item.notes = secondary.joined(separator: ",")
        return SessionRecord(id: UUID(), date: date, title: "S", kind: .gym, durationSeconds: 3600, isCompleted: true, content: WorkoutContent(blocks: [WorkoutBlock(items: [item])]))
    }

    func contributions(_ item: WorkoutItem) -> [MuscleContribution] {
        MuscleResolver.contributions(primary: item.muscles, secondary: (item.notes ?? "").split(separator: ",").map(String.init), exerciseName: item.name)
    }

    func testEventsAndTotals() {
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 18))!
        let events = MuscleEngine.events(from: [session(day, sets: 4, muscles: ["chest"], secondary: ["triceps"])], contributions: contributions)
        XCTAssertEqual(events.count, 8)
        let engine = MuscleEngine(events: events, calendar: calendar)
        let totals = engine.totals(in: DateInterval(start: day.addingTimeInterval(-86_400), end: day.addingTimeInterval(86_400)))
        XCTAssertEqual(totals.first { $0.group == .chest }?.sets, 4)
        XCTAssertEqual(totals.first { $0.group == .triceps }?.sets, 2)
        XCTAssertEqual(totals.first { $0.group == .chest }?.volumeKg, 800)
        XCTAssertEqual(totals.first { $0.group == .triceps }?.volumeKg, 400)
        XCTAssertEqual(engine.exercises(for: .chest, in: DateInterval(start: day.addingTimeInterval(-60), end: day.addingTimeInterval(60))).first?.sets, 4)
    }

    func testFreshnessRecovers() {
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 18))!
        let engine = MuscleEngine(events: MuscleEngine.events(from: [session(day, sets: 8, muscles: ["quadriceps"])], contributions: contributions), calendar: calendar)
        let right = engine.freshness(of: .quads, at: day.addingTimeInterval(60))
        XCTAssertLessThan(right.freshness, 0.3)
        XCTAssertEqual(right.status, .depleted)
        XCTAssertTrue(right.isCalibrating)
        XCTAssertGreaterThan(right.hoursUntilRecovered, 24)
        let later = engine.freshness(of: .quads, at: day.addingTimeInterval(right.hoursUntilRecovered * 3600 + 60))
        XCTAssertGreaterThanOrEqual(later.freshness, 0.8)
        XCTAssertEqual(later.status, .recovered)
        let threeDays = engine.freshness(of: .quads, at: day.addingTimeInterval(72 * 3600))
        XCTAssertGreaterThan(threeDays.freshness, 0.85)
        XCTAssertEqual(engine.freshness(of: .biceps, at: day).freshness, 1)
        // Warm-up sets barely fatigue.
        let warm = MuscleEngine(events: MuscleEngine.events(from: [session(day, sets: 3, muscles: ["chest"], kind: .warmup)], contributions: contributions), calendar: calendar)
        XCTAssertGreaterThan(warm.freshness(of: .chest, at: day.addingTimeInterval(60)).freshness, 0.9)
    }

    func testLoadStatuses() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 18))!
        var sessions: [SessionRecord] = []
        // 10 steady weeks, 3 sessions/week.
        for week in 0..<10 {
            for d in [0, 2, 4] {
                sessions.append(session(calendar.addingDays(week * 7 + d, to: start), sets: 6, muscles: ["chest"]))
            }
        }
        let steadyNow = calendar.addingDays(10 * 7 - 1, to: start)
        var engine = MuscleEngine(events: MuscleEngine.events(from: sessions, contributions: contributions), calendar: calendar)
        let steady = engine.loadSummary(days: 30, now: steadyNow)
        XCTAssertEqual(steady.history.count, 30)
        XCTAssertTrue([.maintaining, .productive].contains(steady.current.status), "\(steady.current.status)")
        XCTAssertGreaterThan(steady.current.chronic, 0)
        XCTAssertEqual(steady.current.optimalLow, steady.current.chronic * 0.8, accuracy: 0.001)

        // Two weeks off -> detraining.
        let offNow = calendar.addingDays(14, to: steadyNow)
        XCTAssertEqual(engine.loadSummary(days: 7, now: offNow).current.status, .detraining)

        // A huge week -> fatigued or overtraining.
        var spike = sessions
        for d in 0..<6 { spike.append(session(calendar.addingDays(70 + d, to: start), sets: 14, muscles: ["chest"])) }
        engine = MuscleEngine(events: MuscleEngine.events(from: spike, contributions: contributions), calendar: calendar)
        let spiked = engine.loadSummary(days: 7, now: calendar.addingDays(75, to: start))
        XCTAssertTrue([.fatigued, .overtraining].contains(spiked.current.status), "\(spiked.current.status)")
        XCTAssertEqual(spiked.breakdown.reduce(0) { $0 + $1.days }, 7)

        // Brand new user -> calibrating.
        let fresh = MuscleEngine(events: MuscleEngine.events(from: [session(start, sets: 5, muscles: ["chest"])], contributions: contributions), calendar: calendar)
        XCTAssertEqual(fresh.loadSummary(days: 7, now: calendar.addingDays(2, to: start)).current.status, .calibrating)
    }

    func testRangesAndPlan() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12))!
        let week = MuscleRange.week.interval(endingAt: now, calendar: calendar)
        XCTAssertEqual(week.duration, 7 * 86_400, accuracy: 3700)
        let previous = MuscleRange.week.interval(endingAt: now, offset: 1, calendar: calendar)
        XCTAssertEqual(previous.end, week.start)
        let ytd = MuscleRange.yearToDate.interval(endingAt: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.month, from: ytd.start), 1)
        let content = WorkoutContent(blocks: [WorkoutBlock(items: [WorkoutItem(name: "Squat", sets: [WorkoutSet(targetReps: "5"), WorkoutSet(kind: .warmup, targetReps: "5")], muscles: ["quadriceps"])])])
        let plan = MusclePlan.sets(of: content, completedOnly: false, contributions: contributions)
        XCTAssertEqual(plan[.quads], 1)
    }

    func testBodyMapParsesAndCoversAllMuscles() {
        var covered = Set<MuscleGroup>()
        for side in BodyMap.Side.allCases {
            for region in BodyMap.regions(side) {
                let elements = SVGPath.parse(region.path)
                XCTAssertGreaterThan(elements.count, 2, region.path)
                if case .move = elements.first! {} else { XCTFail("must start with move") }
                covered.insert(region.group)
            }
        }
        XCTAssertEqual(covered, Set(MuscleGroup.allCases))
        for shape in BodyMap.silhouette { XCTAssertFalse(SVGPath.parse(shape.path).isEmpty) }
        let relative = SVGPath.parse("m10 10 l5 0 h5 v5 c1 1 2 2 3 3 z")
        XCTAssertEqual(relative[1], .line(x: 15, y: 10))
        XCTAssertEqual(relative[3], .line(x: 20, y: 15))
        XCTAssertEqual(SVGPath.mirrored([.move(x: 60, y: 1)]), [.move(x: 140, y: 1)])
    }
}

final class TourTests: XCTestCase {
    func testCatalogIsValid() {
        XCTAssertEqual(GeorgeTour.catalog.problems(), [])
        XCTAssertEqual(GeorgeTour.catalog.allSteps.first?.id, "welcome")
    }

    func testSnapshotFollowsContent() {
        var content = WorkoutContent()
        let empty = GeorgeTourSnapshot(content: content, unit: .kg, startTapped: false)
        XCTAssertEqual(empty.exerciseCount, 0)
        content.append(items: [WorkoutItem(name: "Bench Press", sets: [WorkoutSet(), WorkoutSet()]),
                               WorkoutItem(name: "Row", sets: [WorkoutSet()])], asGroup: true)
        let grouped = GeorgeTourSnapshot(content: content, unit: .kg, startTapped: false)
        XCTAssertEqual(grouped.exerciseCount, 2)
        XCTAssertEqual(grouped.setCount, 3)
        XCTAssertEqual(grouped.groupedExerciseCount, 2)
        XCTAssertEqual(grouped.exerciseNames, ["Bench Press", "Row"])
    }
}

final class V2Tests: XCTestCase {
    func testNumberParserAcceptsCommaAndDot() {
        XCTAssertEqual(NumberParser.double("62,5"), 62.5)
        XCTAssertEqual(NumberParser.double("62.5"), 62.5)
        XCTAssertEqual(NumberParser.double(" 62,5 kg"), 62.5)
        XCTAssertEqual(NumberParser.double("7."), 7)
        XCTAssertEqual(NumberParser.double(",5"), 0.5)
        XCTAssertNil(NumberParser.double(""))
        XCTAssertNil(NumberParser.double("1.2.3"))
        XCTAssertEqual(NumberParser.int("8,6"), 9)
    }

    func testSessionEditsShowWhatWasTyped() {
        var open = WorkoutSet(targetReps: "8-12", targetWeight: 60)
        open.setValue(.weight, 62.5, inSession: true)
        XCTAssertEqual(open.weight, 62.5)
        XCTAssertEqual(open.targetWeight, 62.5, "an open set's plan follows")
        XCTAssertEqual(open.value(.weight, inSession: true), 62.5)

        var done = WorkoutSet(targetReps: "8", targetWeight: 60, reps: 8, weight: 60, isDone: true)
        done.setValue(.reps, 10, inSession: true)
        XCTAssertEqual(done.reps, 10)
        XCTAssertEqual(done.targetReps, "8", "a finished set keeps its plan for comparison")
        XCTAssertEqual(done.label(mode: .reps, unit: .kg), "10 × 60 kg")

        var template = WorkoutSet(targetReps: "10", targetWeight: 20)
        template.setValue(.weight, 22.5, inSession: false)
        XCTAssertNil(template.weight)
        XCTAssertEqual(template.targetWeight, 22.5)
        XCTAssertEqual(WorkoutSet(targetReps: "8-12").targetRepsRange, 8...12)
    }

    func testApplyToFollowingSetsSkipsDoneOnes() {
        var content = WorkoutContent()
        let first = WorkoutSet(targetReps: "8", targetWeight: 60, reps: 8, weight: 60, isDone: true)
        let second = WorkoutSet(targetReps: "8", targetWeight: 60)
        let third = WorkoutSet(targetReps: "8", targetWeight: 60)
        content.append(items: [WorkoutItem(name: "Bench", sets: [first, second, third])])
        content.updateSet(id: second.id) { $0.setValue(.weight, 65, inSession: true) }
        content.applyToFollowingSets(from: second.id, inSession: true)
        XCTAssertEqual(content.set(id: third.id)?.effectiveWeight, 65)
        XCTAssertEqual(content.set(id: first.id)?.effectiveWeight, 60)
    }

    func testMatchSetCounts() {
        var content = WorkoutContent()
        let a = WorkoutItem(name: "Row", sets: [WorkoutSet(targetReps: "10"), WorkoutSet(targetReps: "10"), WorkoutSet(targetReps: "10")])
        let b = WorkoutItem(name: "Face Pull", sets: [WorkoutSet(targetReps: "15")])
        content.append(items: [a, b], asGroup: true)
        XCTAssertEqual(content.mismatchedGroupCount, 1)
        content.matchSetCounts(blockID: content.blocks[0].id)
        XCTAssertEqual(content.blocks[0].items.map(\.sets.count), [3, 3])
        XCTAssertEqual(content.blocks[0].items[1].sets.last?.targetReps, "15")
        XCTAssertEqual(content.mismatchedGroupCount, 0)
        content.matchSetCounts(blockID: content.blocks[0].id, to: 2)
        XCTAssertEqual(content.blocks[0].items.map(\.sets.count), [2, 2])
    }

    func testPaceTrackerMomentum() {
        var pace = PaceTracker(slack: 30)
        let start = Date(timeIntervalSince1970: 1_000)
        pace.setCompleted(at: start, expectedGap: nil)
        pace.setCompleted(at: start.addingTimeInterval(100), expectedGap: 120)
        pace.setCompleted(at: start.addingTimeInterval(210), expectedGap: 120)
        XCTAssertEqual(pace.onTimeStreak, 2)
        XCTAssertEqual(pace.level, .onFire)
        XCTAssertEqual(pace.overdueSeconds(at: start.addingTimeInterval(210 + 200), expectedGap: 120), 50)
        pace.setCompleted(at: start.addingTimeInterval(210 + 600), expectedGap: 120)
        XCTAssertEqual(pace.onTimeStreak, 0)
        XCTAssertLessThan(pace.momentum, 0.75)
        XCTAssertEqual(CoachIntensity.from(energy: 1), .calm)
        XCTAssertEqual(CoachIntensity.from(energy: 5), .hype)
    }

    func testProgression() {
        let plan = WorkoutSet(targetReps: "8-12", targetWeight: 60)
        let easy = [WorkoutSet(targetReps: "8-12", reps: 10, weight: 60, rpe: 7, isDone: true)]
        XCTAssertEqual(ProgressionAdvisor.suggest(lastSets: easy, mode: .reps, plan: plan, incrementKg: 2.5)?.kind, .addWeight)
        XCTAssertEqual(ProgressionAdvisor.suggest(lastSets: easy, mode: .reps, plan: plan, incrementKg: 2.5)?.weightKg, 62.5)
        let topped = [WorkoutSet(targetReps: "8-12", reps: 12, weight: 60, isDone: true), WorkoutSet(targetReps: "8-12", reps: 12, weight: 60, isDone: true)]
        XCTAssertEqual(ProgressionAdvisor.suggest(lastSets: topped, mode: .reps, plan: plan, incrementKg: 2.5)?.kind, .addWeight)
        let hard = [WorkoutSet(targetReps: "8-12", reps: 9, weight: 60, rpe: 9, isDone: true)]
        let next = ProgressionAdvisor.suggest(lastSets: hard, mode: .reps, plan: plan, incrementKg: 2.5)
        XCTAssertEqual(next?.kind, .addReps)
        XCTAssertEqual(next?.reps, 10)
        let failed = [WorkoutSet(targetReps: "8-12", reps: 6, weight: 60, rpe: 10, isDone: true)]
        XCTAssertEqual(ProgressionAdvisor.suggest(lastSets: failed, mode: .reps, plan: plan, incrementKg: 2.5)?.kind, .lighten)
        XCTAssertNil(ProgressionAdvisor.suggest(lastSets: nil, mode: .reps, plan: plan, incrementKg: 2.5))
    }

    func testEffortPromptOnlyAfterLastWorkingSet() {
        let warmup = WorkoutSet(kind: .warmup, targetReps: "10", isDone: true)
        let s1 = WorkoutSet(targetReps: "8", isDone: true)
        let s2 = WorkoutSet(targetReps: "8", isDone: true)
        let item = WorkoutItem(name: "Squat", sets: [warmup, s1, s2])
        XCTAssertFalse(EffortPrompt.shouldAsk(after: s1, in: item, askedSoFar: 0))
        XCTAssertTrue(EffortPrompt.shouldAsk(after: s2, in: item, askedSoFar: 0))
        XCTAssertFalse(EffortPrompt.shouldAsk(after: s2, in: item, askedSoFar: EffortPrompt.defaultLimit))
        XCTAssertEqual(EffortPrompt.rpe(forRepsInReserve: 2), 8)
    }

    func testEnergyCycleAndWeekdays() {
        let calendar = Calendar.training(timeZone: TimeZone(identifier: "UTC")!)
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        var entries: [EnergyEntry] = []
        for day in 0..<84 where day % 3 != 2 {
            let value = 3 + 1.8 * sin(Double(day) / 28 * 2 * .pi)
            entries.append(EnergyEntry(date: calendar.addingDays(day, to: start), level: Int(value.rounded())))
        }
        let insights = EnergyAnalysis.analyze(entries: entries, calendar: calendar, now: calendar.addingDays(84, to: start))
        XCTAssertNil(insights.needMoreData)
        XCTAssertNotNil(insights.cycle)
        XCTAssertEqual(Double(insights.cycle?.periodDays ?? 0), 28, accuracy: 3)

        let few = EnergyAnalysis.analyze(entries: Array(entries.prefix(10)), calendar: calendar, now: calendar.addingDays(20, to: start))
        XCTAssertNil(few.cycle)
        XCTAssertNotNil(few.needMoreData)

        let flat = (0..<60).map { EnergyEntry(date: calendar.addingDays($0, to: start), level: 3) }
        XCTAssertNil(EnergyAnalysis.analyze(entries: flat, calendar: calendar, now: calendar.addingDays(60, to: start)).cycle)
    }

    func testProfileRecommendations() {
        let young = TrainingProfile(age: 25, experience: .intermediate, goal: .muscle)
        XCTAssertEqual(young.weeklySets, 10...16)
        XCTAssertEqual(young.recoveryScale, 1)
        let older = TrainingProfile(age: 65, experience: .beginner, goal: .fitness)
        XCTAssertGreaterThan(older.recoveryScale, 1.2)
        XCTAssertEqual(older.repRange, 10...15)
        XCTAssertFalse(older.notes.isEmpty)
        let fromSettings = TrainingProfile(birthYear: 1990, experienceRaw: "advanced", goalRaw: "strength",
                                           now: Calendar.training().date(from: DateComponents(year: 2026, month: 6, day: 1))!)
        XCTAssertEqual(fromSettings.age, 36)
        XCTAssertEqual(fromSettings.goal, .strength)

        let event = MuscleEvent(date: Date(timeIntervalSince1970: 0), sessionID: UUID(), group: .quads, load: 5, sets: 5, volumeKg: 0, exerciseKey: "squat", exerciseName: "Squat")
        let later = Date(timeIntervalSince1970: 36 * 3600)
        let normal = MuscleEngine(events: [event]).freshness(of: .quads, at: later).freshness
        let slower = MuscleEngine(events: [event], recoveryScale: 1.3).freshness(of: .quads, at: later).freshness
        XCTAssertLessThan(slower, normal)
    }

    func testTourV2CatalogAndMatchStep() {
        XCTAssertEqual(GeorgeTour.catalog.problems(), [])
        XCTAssertEqual(GeorgeTour.catalog.steps(newerThan: 1).map(\.id), ["whats-new", "match", "finish"])
    }

    func testBodyReadinessFromHealthSignals() {
        let calendar = Calendar.training()
        let today = calendar.startOfDay(for: calendar.date(from: DateComponents(year: 2026, month: 5, day: 30))!)
        var signals = (1...20).map { DailyHealthSignal(day: calendar.addingDays(-$0, to: today), hrvMs: 60, restingHeartRate: 55, sleepHours: 7) }
        signals.append(DailyHealthSignal(day: today, hrvMs: 48, restingHeartRate: 61, sleepHours: 5.5))
        let tired = BodyReadiness.evaluate(signals, now: today.addingTimeInterval(9 * 3600), calendar: calendar)
        XCTAssertEqual(tired?.score, -3)
        XCTAssertEqual(tired?.suggestedIntensity, .calm)
        XCTAssertEqual(tired?.suggestedEnergy, 1)
        XCTAssertEqual(tired?.summary, "HRV 20 % below your usual · resting HR +6 · 5.5 h sleep")

        signals[signals.count - 1] = DailyHealthSignal(day: today, hrvMs: 70, restingHeartRate: 51, sleepHours: 8)
        XCTAssertEqual(BodyReadiness.evaluate(signals, now: today, calendar: calendar)?.suggestedIntensity, .hype)
        // Too little history: only sleep counts.
        let short = [DailyHealthSignal(day: today, hrvMs: 40, sleepHours: 7)]
        XCTAssertNil(BodyReadiness.evaluate(short, now: today, calendar: calendar)?.hrvChange)
        XCTAssertNil(BodyReadiness.evaluate([], now: today, calendar: calendar))
    }

    func testValenceAndCorrelation() {
        XCTAssertEqual(EnergyEntry.level(fromValence: -1), 1)
        XCTAssertEqual(EnergyEntry.level(fromValence: 0), 3)
        XCTAssertEqual(EnergyEntry.level(fromValence: 1), 5)
        let calendar = Calendar.training()
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        let entries = (0..<12).map { EnergyEntry(date: calendar.addingDays($0, to: start), level: 1 + $0 % 5) }
        let sleep = (0..<12).map { (date: calendar.addingDays($0, to: start), value: 5.0 + Double($0 % 5) * 0.6) }
        XCTAssertEqual(EnergyAnalysis.correlation(entries: entries, series: sleep, calendar: calendar) ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(EnergyAnalysis.strengthWord(0.7), "strong")
        XCTAssertNil(EnergyAnalysis.strengthWord(0.1))
        XCTAssertNil(EnergyAnalysis.correlation(entries: Array(entries.prefix(4)), series: sleep, calendar: calendar))
    }

    func testRelativePerformance() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            PerformanceSample(date: day, group: "UPPER", volumeKg: 1000, completion: 1),
            PerformanceSample(date: day.addingTimeInterval(86400), group: "UPPER", volumeKg: 1200, completion: 1),
            PerformanceSample(date: day.addingTimeInterval(2 * 86400), group: "UPPER", volumeKg: 1100, completion: 1),
            PerformanceSample(date: day.addingTimeInterval(3 * 86400), group: "YOGA", volumeKg: 0, completion: 0.5),
            PerformanceSample(date: day.addingTimeInterval(4 * 86400), group: "YOGA", volumeKg: 0, completion: 1),
            PerformanceSample(date: day.addingTimeInterval(5 * 86400), group: "ONCE", volumeKg: 500, completion: 1),
        ]
        let values = EnergyAnalysis.relativePerformance(samples).map(\.value)
        XCTAssertEqual(values.count, 5)
        XCTAssertEqual(values[0], 1000.0 / 1100, accuracy: 0.0001)
        XCTAssertEqual(values[3], 0.5)
    }
}

final class V3Tests: XCTestCase {
    func testPaceRecordsPlannedVersusActualRest() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var pace = PaceTracker(slack: 30)
        pace.setCompleted(at: t0, plannedRest: nil, workSeconds: 30)          // first set
        XCTAssertTrue(pace.gaps.isEmpty)
        // Planned 90 s rest, started after 130 s → 40 s behind.
        XCTAssertEqual(pace.waitingDelta(at: t0.addingTimeInterval(100), plannedRest: 90) ?? 0, 10, accuracy: 0.001)
        pace.setStarted(at: t0.addingTimeInterval(130), plannedRest: 90)
        XCTAssertNil(pace.waitingDelta(at: t0.addingTimeInterval(140), plannedRest: 90))
        XCTAssertEqual(pace.workingSeconds(at: t0.addingTimeInterval(160)), 30, accuracy: 0.001)
        pace.setCompleted(at: t0.addingTimeInterval(160), plannedRest: 90, workSeconds: 30)
        XCTAssertEqual(pace.gaps.count, 1)
        XCTAssertEqual(pace.lastGap?.delta ?? 0, 40, accuracy: 0.001)
        // Ticked without Start: start estimated as work seconds before the tick → 60 s rest, 30 s ahead.
        pace.setCompleted(at: t0.addingTimeInterval(160 + 60 + 30), plannedRest: 90, workSeconds: 30)
        XCTAssertEqual(pace.lastGap?.delta ?? 0, -30, accuracy: 0.001)
        XCTAssertEqual(pace.totalDelta, 10, accuracy: 0.001)
        XCTAssertEqual(WorkoutPace.deltaText(130), "2:10 behind plan")
        XCTAssertEqual(WorkoutPace.deltaText(-40), "0:40 ahead of plan")
        XCTAssertEqual(WorkoutPace.deltaText(5), "on plan")
        XCTAssertEqual(WorkoutPace.signed(40), "+0:40")
        XCTAssertFalse(WorkoutPace.tips(for: pace, restRange: 90...180).isEmpty)
    }

    func testRemainingAndPlannedTime() {
        var content = WorkoutContent()
        content.append(items: [WorkoutItem(name: "Bike", mode: .time, sets: [WorkoutSet(targetSeconds: 300)]),
                               WorkoutItem(name: "Squat", sets: [WorkoutSet(targetReps: "5"), WorkoutSet(targetReps: "5")], restSeconds: 120)],
                       asGroup: false)
        let planned = WorkoutPace.plannedSeconds(of: content, defaultRest: 90)
        // Bike 310 + rest after bike (item rest default 90) + squat 30 + 120 + 30
        XCTAssertEqual(planned, 310 + 90 + 30 + 120 + 30, accuracy: 0.001)
        let bikeID = content.allItems[0].sets[0].id
        _ = content.toggleSet(id: bikeID)
        XCTAssertEqual(WorkoutPace.remainingSeconds(in: content, defaultRest: 90), 30 + 120 + 30, accuracy: 0.001)
    }

    func testCoachScriptTalksAboutTheSetThatsDue() {
        let item = WorkoutItem(name: "Bench Press", sets: [
            WorkoutSet(kind: .warmup, targetReps: "10", targetWeight: 40),
            WorkoutSet(targetReps: "8", targetWeight: 60), WorkoutSet(targetReps: "8", targetWeight: 62.5), WorkoutSet(targetReps: "8", targetWeight: 62.5),
        ])
        XCTAssertEqual(CoachScript.setUp(item: item, set: item.sets[1], unit: .kg, isFirst: false), "Bench Press, set 1 of 3: 8 reps at 60 kilos.")
        XCTAssertEqual(CoachScript.setUp(item: item, set: item.sets[3], unit: .kg, isFirst: false), "Bench Press, last set: 8 reps at 62.5 kilos.")
        XCTAssertEqual(CoachScript.setUp(item: item, set: item.sets[0], unit: .kg, isFirst: true), "First up: Bench Press, warm-up set: 10 reps at 40 kilos.")
        let bike = WorkoutItem(name: "Bike", mode: .time, sets: [WorkoutSet(targetSeconds: 300)])
        XCTAssertEqual(CoachScript.setUp(item: bike, set: bike.sets[0], unit: .kg, isFirst: true), "First up: Bike: 5 minutes.")
        XCTAssertEqual(CoachScript.restStart(seconds: 90, next: (item, item.sets[2]), sameExercise: true), "Rest 90 seconds.")
        XCTAssertEqual(CoachScript.restStart(seconds: 90, next: (bike, bike.sets[0]), sameExercise: false), "Rest 90 seconds. Up next: Bike.")
        XCTAssertEqual(CoachScript.overRest(seconds: 42), "40 seconds over your rest.")
        XCTAssertEqual(CoachScript.go(next: (item, item.sets[2]), unit: .kg), "Go! Bench Press, set 2 of 3.")
        XCTAssertNil(CoachScript.cheer(streak: 1, seed: 3))
        XCTAssertFalse(CoachCue.motivation.isOnByDefault)
    }

    func testStartedAtAndFatigueAreStoredAndOptional() throws {
        var item = WorkoutItem(name: "Squat", sets: [WorkoutSet(targetReps: "5", startedAt: Date(timeIntervalSince1970: 100))])
        item.fatigue = 0.75
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(WorkoutItem.self, from: data)
        XCTAssertEqual(decoded.fatigue, 0.75)
        XCTAssertEqual(decoded.sets[0].startedAt, Date(timeIntervalSince1970: 100))
        let old = try JSONDecoder().decode(WorkoutItem.self, from: Data(#"{"name":"Row","sets":[{"targetReps":"8"}]}"#.utf8))
        XCTAssertNil(old.fatigue)
        XCTAssertNil(old.sets[0].startedAt)
        XCTAssertNil(item.sets[0].clearedCopy().startedAt)
    }

    func testSubjectiveFatigueScalesMuscleLoad() {
        func load(fatigue: Double?) -> Double {
            var item = WorkoutItem(name: "Squat", sets: [WorkoutSet(targetReps: "5", isDone: true)])
            item.fatigue = fatigue
            var content = WorkoutContent()
            content.append(items: [item], asGroup: false)
            let record = SessionRecord(id: UUID(), date: Date(timeIntervalSince1970: 0), title: "", kind: .gym, durationSeconds: 60, isCompleted: true, content: content)
            let events = MuscleEngine.events(from: [record], contributions: { _ in [MuscleContribution(group: .quads, weight: 1)] })
            return events.reduce(0) { $0 + $1.load }
        }
        XCTAssertEqual(load(fatigue: 0.5), load(fatigue: nil), accuracy: 0.0001)
        XCTAssertGreaterThan(load(fatigue: 1), load(fatigue: nil))
        XCTAssertLessThan(load(fatigue: 0), load(fatigue: nil))
    }

    func testFuzzyLibraryMatch() {
        func ex(_ id: String, _ name: String, images: [String] = []) -> LibraryExercise {
            LibraryExercise(id: id, name: name, kind: .gym, category: "strength", primary: ["chest"], images: images)
        }
        let catalog = ExerciseCatalog(file: LibraryFile(exercises: [
            ex("a", "Barbell Bench Press - Medium Grip", images: ["a/0.jpg"]),
            ex("b", "Barbell Incline Bench Press - Medium Grip", images: ["b/0.jpg"]),
            ex("c", "Dumbbell Bicep Curl", images: ["c/0.jpg"]),
            ex("d", "Plank"),
        ]))
        XCTAssertEqual(catalog.match(for: WorkoutItem(name: "Barbell Bench Press"))?.id, "a")
        XCTAssertEqual(catalog.match(for: WorkoutItem(name: "DB Bicep Curls"))?.id, "c")
        XCTAssertEqual(catalog.match(for: WorkoutItem(name: "plank"))?.id, "d")
        XCTAssertNil(catalog.match(for: WorkoutItem(name: "Bike")))
        XCTAssertNil(catalog.match(for: WorkoutItem(name: "Bench")), "one shared word of four isn't the same movement")
    }
}
