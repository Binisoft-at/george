import XCTest
@testable import GeorgeCore

final class PlanToolsTests: XCTestCase {
    let calendar = Calendar.training(timeZone: TimeZone(identifier: "Europe/Vienna")!)

    func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func repoFile(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
    }

    // MARK: Titles

    func testAutoTitleIsRecognisedButTypedTitlesAreNot() {
        let namer = SessionNamer(calendar: calendar)
        let tuesday = day(2026, 11, 10, 18)
        let generated = namer.title(templateName: "UPPER", date: tuesday, indexInWeek: 2)
        XCTAssertTrue(namer.isGenerated(generated, templateNames: ["UPPER"], date: tuesday))
        XCTAssertEqual(namer.generatedName(of: generated, templateNames: ["Workout", "UPPER"], date: tuesday), "UPPER")
        XCTAssertFalse(namer.isGenerated(generated, templateNames: ["UPPER"], date: day(2026, 11, 12)))
        XCTAssertFalse(namer.isGenerated("Heavy day with Tom", templateNames: ["UPPER"], date: tuesday))
        XCTAssertTrue(namer.isGenerated("", templateNames: ["UPPER"], date: tuesday))
    }

    // MARK: Import

    func testImportNamesGetANumberWhenTaken() {
        XCTAssertEqual(ImportNaming.uniqueName("UPPER", taken: ["LOWER"]), "UPPER")
        XCTAssertEqual(ImportNaming.uniqueName("UPPER", taken: ["upper"]), "UPPER (2)")
        XCTAssertEqual(ImportNaming.uniqueName("UPPER", taken: ["UPPER", "UPPER (2)"]), "UPPER (3)")
    }

    func testGymSampleParses() throws {
        let text = try String(contentsOf: repoFile("samples/gym-strength-block.csv"), encoding: .utf8)
        let result = try ProgramCSV.parse(text)
        XCTAssertEqual(result.programs.count, 1)
        XCTAssertEqual(result.programs[0].name, "Gym – Strength Block")
        XCTAssertEqual(result.programs[0].workouts.map(\.name), ["UPPER", "LOWER", "FULL"])
        XCTAssertEqual(result.programs[0].workouts.map(\.scheduleDays), [[2], [4], [6]])
    }

    // MARK: Performed state (status after edits)

    func testPerformedStateFollowsTicks() {
        var item = WorkoutItem(name: "Press", sets: [WorkoutSet(targetReps: "8"), WorkoutSet(targetReps: "8")])
        var content = WorkoutContent(blocks: [WorkoutBlock(items: [item])])
        XCTAssertEqual(content.performedState, .none)
        content.toggleSet(id: item.sets[0].id)
        XCTAssertEqual(content.performedState, .some)
        content.markAllDone()
        XCTAssertEqual(content.performedState, .all)
        content.resetProgress()
        XCTAssertEqual(content.performedState, .none)
        item.sets = []
        XCTAssertEqual(WorkoutContent(blocks: [WorkoutBlock(items: [item])]).performedState, .none)
    }

    // MARK: Streak rules

    func testShortCompletedRoutinesNeedTheMinutes() {
        // A 2-minute stretch doesn't count, a 2-minute logged strength session with 3 sets does.
        XCTAssertFalse(StreakRules.qualifies(minutes: 2, doneSets: 7, isRescue: false, kind: .stretch, minimumMinutes: 10, rescueMinutes: 10))
        XCTAssertTrue(StreakRules.qualifies(minutes: 2, doneSets: 3, isRescue: false, kind: .gym, minimumMinutes: 10, rescueMinutes: 10))
        XCTAssertTrue(StreakRules.qualifies(minutes: 12, doneSets: 0, isRescue: false, kind: WorkoutKind("tennis"), minimumMinutes: 10, rescueMinutes: 10))
        XCTAssertTrue(StreakRules.qualifies(minutes: 8, doneSets: 0, isRescue: true, kind: .mobility, minimumMinutes: 10, rescueMinutes: 10))
    }

    // MARK: Reordering

    func testMovedBlockJoinsTheSectionItLandsIn() {
        func block(_ name: String, _ section: String) -> WorkoutBlock {
            WorkoutBlock(section: section, items: [WorkoutItem(name: name)])
        }
        var content = WorkoutContent(blocks: [block("Bench", "MAIN"), block("Row", "MAIN"), block("Curl", "ARMS"), block("Dips", "ARMS")])
        // Curl up to second place: now in MAIN.
        content.moveBlocksAdoptingSection(fromOffsets: IndexSet(integer: 2), toOffset: 1)
        XCTAssertEqual(content.allItems.map(\.name), ["Bench", "Curl", "Row", "Dips"])
        XCTAssertEqual(content.blocks.map(\.section), ["MAIN", "MAIN", "MAIN", "ARMS"])
        // Bench to the end: ARMS.
        content.moveBlocksAdoptingSection(fromOffsets: IndexSet(integer: 0), toOffset: 4)
        XCTAssertEqual(content.allItems.map(\.name), ["Curl", "Row", "Dips", "Bench"])
        XCTAssertEqual(content.blocks.last?.section, "ARMS")
        // Dips to the top: takes the section of the block after it.
        content.moveBlocksAdoptingSection(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(content.allItems.map(\.name), ["Dips", "Curl", "Row", "Bench"])
        XCTAssertEqual(content.blocks.first?.section, "MAIN")
    }

    // MARK: All sets

    func testAllSetsChangesOnlyOpenWorkingSets() {
        let warmup = WorkoutSet(kind: .warmup, targetReps: "10", targetWeight: 20)
        var done = WorkoutSet(targetReps: "5", targetWeight: 100)
        done.isDone = true
        done.reps = 5
        done.weight = 100
        let item = WorkoutItem(name: "Deadlift", sets: [warmup, done, WorkoutSet(targetReps: "5", targetWeight: 100), WorkoutSet(targetReps: "5", targetWeight: 100)])
        var content = WorkoutContent(blocks: [WorkoutBlock(items: [item])])
        content.adjustOpenSets(of: item.id, .weight, by: 2.5, inSession: true)
        let sets = content.item(id: item.id)!.sets
        XCTAssertEqual(sets.map(\.targetWeight), [20, 100, 102.5, 102.5])
        XCTAssertEqual(content.allSetsValue(.weight, of: item.id, inSession: true), 102.5)
        content.setOpenSets(of: item.id, .reps, to: 3, inSession: false)
        XCTAssertEqual(content.item(id: item.id)!.sets.map(\.targetReps), ["10", "5", "3", "3"])
        content.setSetCount(of: item.id, to: 6)
        XCTAssertEqual(content.item(id: item.id)!.sets.count, 6)
        content.setSetCount(of: item.id, to: 1)
        // The done set stays, so does nothing else that's done.
        XCTAssertEqual(content.item(id: item.id)!.sets.count, 1)
        XCTAssertTrue(content.item(id: item.id)!.sets[0].isDone)
    }

    // MARK: Reminders

    func testTrainingRemindersAndStreakAtRisk() {
        // Monday 16 Nov 2026, 9:00. Week starts Monday.
        let now = day(2026, 11, 16, 9)
        let monday = day(2026, 11, 16)
        let workouts = [monday: "UPPER", day(2026, 11, 18): "LOWER", day(2026, 11, 20): "FULL", day(2026, 11, 25): "UPPER"]
        let reminders = ReminderPlanner.plan(now: now, workouts: workouts, neededThisWeek: 3, weekStart: monday,
                                             minutesAfterMidnight: 18 * 60, calendar: calendar)
        XCTAssertEqual(reminders.filter { $0.kind == .training }.count, 3)
        XCTAssertEqual(reminders.first?.fireDate, day(2026, 11, 16, 18))
        XCTAssertEqual(reminders.first?.title, "Time for UPPER")
        // Last chance for 3 days is Friday – a training day, so the streak line is folded into it.
        XCTAssertFalse(reminders.contains { $0.kind == .streak })
        XCTAssertTrue(reminders.first { $0.fireDate == day(2026, 11, 20, 18) }!.body.contains("3 more workout days"))

        // Goal met: no streak reminder; evening already past: today's reminder is left out.
        let late = ReminderPlanner.plan(now: day(2026, 11, 16, 20), workouts: workouts, neededThisWeek: 0, weekStart: monday,
                                        minutesAfterMidnight: 18 * 60, calendar: calendar)
        XCTAssertEqual(late.map(\.title), ["Time for LOWER", "Time for FULL"])

        // No training days planned, one day missing: a streak reminder on Sunday.
        let risk = ReminderPlanner.plan(now: now, workouts: [:], neededThisWeek: 1, weekStart: monday,
                                        minutesAfterMidnight: 18 * 60, calendar: calendar)
        XCTAssertEqual(risk.count, 1)
        XCTAssertEqual(risk.first?.kind, .streak)
        XCTAssertEqual(risk.first?.fireDate, day(2026, 11, 22, 18))
    }

    func testRescueRoutinesAreTheClosestInLength() throws {
        let catalog = try ExerciseCatalog(data: try Data(contentsOf: repoFile("App/Resources/exercises.json")))
        let routines = RoutineLibrary.closest(toMinutes: 10, count: 3, catalog: catalog)
        XCTAssertEqual(routines.count, 3)
        let distances = routines.map { abs($0.content(using: catalog).estimatedSeconds() - 600) }
        XCTAssertEqual(distances, distances.sorted())
        let others = RoutineLibrary.all.filter { r in !routines.contains { $0.id == r.id } }
        let worstChosen = distances.max() ?? 0
        for other in others {
            XCTAssertGreaterThanOrEqual(abs(other.content(using: catalog).estimatedSeconds() - 600), worstChosen)
        }
    }
}
