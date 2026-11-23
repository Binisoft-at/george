import XCTest
@testable import GeorgeCore

/// v7 lane "numbersA": averages over short histories, records, e1RM rounding, working sets and
/// volume, training days, and the "no load called sets" wording rule.
final class V7NumbersATests: XCTestCase {
    let calendar = Calendar.training(timeZone: TimeZone(identifier: "Europe/Vienna")!)

    /// A Monday at 18:00.
    var monday: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 18))! }

    func item(_ name: String = "Bench", sets: [WorkoutSet], kind: WorkoutKind? = nil, mode: ExerciseMode = .reps,
              perSide: Bool = false, muscles: [String] = ["chest"]) -> WorkoutItem {
        WorkoutItem(name: name, kind: kind, mode: mode, sets: sets, perSide: perSide, muscles: muscles)
    }

    func done(_ reps: Int, _ weight: Double?, kind: SetKind = .working, at date: Date? = nil) -> WorkoutSet {
        WorkoutSet(kind: kind, targetReps: String(reps), targetWeight: weight, reps: reps, weight: weight, isDone: true, doneAt: date)
    }

    func hold(_ seconds: Int) -> WorkoutSet {
        WorkoutSet(targetSeconds: seconds, seconds: seconds, isDone: true)
    }

    func session(_ date: Date, items: [WorkoutItem], kind: WorkoutKind = .gym, minutes: Double = 60) -> SessionRecord {
        SessionRecord(id: UUID(), date: date, title: "S", kind: kind, durationSeconds: minutes * 60, isCompleted: true,
                      content: WorkoutContent(blocks: items.map { WorkoutBlock(items: [$0]) }))
    }

    func contributions(_ item: WorkoutItem) -> [MuscleContribution] {
        MuscleResolver.contributions(primary: item.muscles, secondary: [], exerciseName: item.name)
    }

    // MARK: Averages over the weeks with data

    func testEightWeeksOfTwelveSetsAverageTwelveOverAYear() {
        // One session of 12 chest sets every Monday for 8 weeks; the 1-year range ends after week 8.
        let sessions = (0..<8).map { week -> SessionRecord in
            let date = calendar.addingWeeks(week, to: monday)
            return session(date, items: [item(sets: (0..<12).map { _ in done(10, 60, at: date) })])
        }
        let engine = MuscleEngine(events: MuscleEngine.events(from: sessions, contributions: contributions), calendar: calendar)
        let now = calendar.addingWeeks(8, to: calendar.weekStart(for: monday))
        let year = DateInterval(start: calendar.addingDays(-365, to: now), end: now)
        // (± the daylight-saving hour in between.)
        XCTAssertEqual(engine.weeksCovered(in: year, now: now), 8, accuracy: 0.02)
        let chest = engine.totals(in: year, now: now).first { $0.group == .chest }
        XCTAssertEqual(chest?.sets, 96)
        XCTAssertEqual(chest?.setsPerWeek ?? 0, 12, accuracy: 0.05)

        // A range inside the history still averages over its own length.
        let fourWeeks = DateInterval(start: calendar.addingWeeks(-4, to: now), end: now)
        XCTAssertEqual(engine.totals(in: fourWeeks, now: now).first { $0.group == .chest }?.setsPerWeek ?? 0, 12, accuracy: 0.01)
        // Never less than one week.
        XCTAssertEqual(MuscleEngine(events: [], calendar: calendar).weeksCovered(in: year, now: now), 52.14, accuracy: 0.01)
        let lastDay = DateInterval(start: calendar.addingDays(-1, to: now), end: now)
        XCTAssertEqual(engine.weeksCovered(in: lastDay, now: now), 1)

        // The footers say what the average is over.
        XCTAssertEqual(MuscleEngine.averageCaption(weeksCovered: engine.weeksCovered(in: year, now: now), rangeWeeks: 52.14),
                       "Average of the last 8 weeks with data")
        XCTAssertEqual(MuscleEngine.averageCaption(weeksCovered: 11.9, rangeWeeks: 12), "Average per week in this range")
        XCTAssertEqual(MuscleEngine.averageCaption(weeksCovered: 1, rangeWeeks: 4), "Average of the last week with data")
    }

    // MARK: Comparing with the period before

    func testCoverageOfThePreviousPeriod() {
        let first = session(monday, items: [item(sets: [done(8, 60)])])
        let before = DateInterval(start: calendar.addingWeeks(-12, to: monday), end: calendar.addingDays(-1, to: monday))
        XCTAssertEqual(StatsEngine.coverage(of: [first], in: before), .noHistory)
        XCTAssertEqual(StatsEngine.coverage(of: [], in: before), .noHistory)
        let around = DateInterval(start: calendar.addingWeeks(-2, to: monday), end: calendar.addingWeeks(2, to: monday))
        XCTAssertEqual(StatsEngine.coverage(of: [first], in: around), .partial)
        let later = DateInterval(start: calendar.addingWeeks(1, to: monday), end: calendar.addingWeeks(3, to: monday))
        XCTAssertEqual(StatsEngine.coverage(of: [first], in: later), .complete)
    }

    // MARK: Records

    func testFirstSessionIsNoRecordInEitherFunction() {
        let first = session(monday, items: [item(sets: [done(5, 100)])])
        XCTAssertTrue(StatsEngine.newRecords(in: first, comparedTo: [first]).isEmpty)
        XCTAssertTrue(StatsEngine.recordsSet(in: [first], since: calendar.addingDays(-7, to: monday)).isEmpty)

        // The second, heavier session is one – in both.
        let second = session(calendar.addingDays(3, to: monday), items: [item(sets: [done(5, 105)])])
        XCTAssertEqual(StatsEngine.newRecords(in: second, comparedTo: [first, second]).map(\.metric), [.weight])
        let inRange = StatsEngine.recordsSet(in: [second, first], since: calendar.addingDays(-7, to: monday))
        XCTAssertEqual(inRange.map(\.metric), [.weight])
        XCTAssertEqual(inRange.first?.value, 105)
        // A lighter third session sets nothing new; the record keeps its date.
        let third = session(calendar.addingDays(6, to: monday), items: [item(sets: [done(5, 102.5)])])
        let all = StatsEngine.recordsSet(in: [first, second, third], since: calendar.addingDays(-7, to: monday))
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.date, second.date)
        // Records before the range don't show.
        XCTAssertTrue(StatsEngine.recordsSet(in: [first, second, third], since: calendar.addingDays(5, to: monday)).isEmpty)
    }

    func testLongerYogaHoldIsNoRecordButALongerPlankIs() {
        let yoga30 = session(monday, items: [item("Pigeon", sets: [hold(30)], mode: .time, muscles: ["glutes"])], kind: .yoga)
        let yoga45 = session(calendar.addingDays(2, to: monday), items: [item("Pigeon", sets: [hold(45)], mode: .time, muscles: ["glutes"])], kind: .yoga)
        XCTAssertTrue(StatsEngine.newRecords(in: yoga45, comparedTo: [yoga30, yoga45]).isEmpty)
        XCTAssertTrue(StatsEngine.recordsSet(in: [yoga30, yoga45], since: monday).isEmpty)
        // A stretch item inside a gym workout doesn't count either (the item's own kind wins).
        let stretch30 = session(monday, items: [item("Hamstring stretch", sets: [hold(30)], kind: .stretch, mode: .time)])
        let stretch45 = session(calendar.addingDays(2, to: monday), items: [item("Hamstring stretch", sets: [hold(45)], kind: .stretch, mode: .time)])
        XCTAssertTrue(StatsEngine.recordsSet(in: [stretch30, stretch45], since: monday).isEmpty)

        let plank30 = session(monday, items: [item("Plank", sets: [hold(30)], mode: .time, muscles: ["abs"])])
        let plank45 = session(calendar.addingDays(2, to: monday), items: [item("Plank", sets: [hold(45)], mode: .time, muscles: ["abs"])])
        XCTAssertEqual(StatsEngine.newRecords(in: plank45, comparedTo: [plank30, plank45]).map(\.metric), [.duration])
        XCTAssertEqual(StatsEngine.recordsSet(in: [plank30, plank45], since: monday).map(\.metric), [.duration])
        // A planned time that was never logged is no record.
        let unlogged = session(calendar.addingDays(4, to: monday), items: [item("Plank", sets: [WorkoutSet(targetSeconds: 90, isDone: true)], mode: .time, muscles: ["abs"])])
        XCTAssertTrue(StatsEngine.newRecords(in: unlogged, comparedTo: [plank30, plank45, unlogged]).isEmpty)
    }

    // MARK: e1RM rounding

    func testEstimatesRoundInTheDisplayUnit() {
        // 95 kg × 2 → 101.33 kg e1RM.
        let e1rm = StatsEngine.oneRepMax(weight: 95, reps: 2)
        XCTAssertEqual(Format.estimate(e1rm, unit: .kg), "101.5 kg")
        XCTAssertEqual(Format.estimate(e1rm, unit: .lb), "223 lb")
        XCTAssertEqual(Format.estimate(96.4, unit: .lb), "213 lb")
        XCTAssertEqual(Format.estimate(100.2, unit: .kg), "100 kg")
        XCTAssertEqual(Format.estimateValue(e1rm, unit: .kg), 101.5)

        let record = PersonalRecord(exerciseKey: "fedb:Bench", exerciseName: "Bench", metric: .oneRepMax, value: e1rm, date: monday)
        XCTAssertEqual(record.detail(unit: .kg), "e1RM 101.5 kg")
        XCTAssertEqual(record.detail(unit: .lb), "e1RM 223 lb")

        let comparison = ExerciseComparison(exerciseKey: "fedb:Bench", exerciseName: "Bench", measure: .oneRepMax,
                                            before: 96.4, now: e1rm, direction: .up)
        XCTAssertEqual(comparison.change(unit: .kg), "96.5 → 101.5 kg")
        XCTAssertEqual(comparison.change(unit: .lb), "213 → 223 lb")
    }

    // MARK: Working sets and volume

    func testPerSideItemWithWarmUpCountsWorkingVolumeOnBothSides() {
        let row = item("One-arm row", sets: [done(10, 10, kind: .warmup), done(10, 20), done(10, 20)], perSide: true, muscles: ["lats"])
        XCTAssertEqual(row.workingSets, 2)
        XCTAssertEqual(row.workingVolumeKg, 800)
        let first = session(monday, items: [row])
        XCTAssertEqual(first.content.workingSets, 2)
        XCTAssertEqual(first.content.workingVolumeKg, 800)
        // The old total still counts the warm-up.
        XCTAssertEqual(first.content.completedSets, 3)
        XCTAssertEqual(first.content.volumeKg, 1000)

        // Progress tiles, the weekly chart, the exercise chart and the comparison agree.
        let interval = DateInterval(start: calendar.addingDays(-1, to: monday), end: calendar.addingDays(1, to: monday))
        let totals = StatsEngine.totals(of: [first], in: interval)
        XCTAssertEqual(totals.sets, 2)
        XCTAssertEqual(totals.volumeKg, 800)
        let week = StatsEngine.weekly([first], calendar: calendar, weeks: 1, now: monday)
        XCTAssertEqual(week.first?.sets, 2)
        XCTAssertEqual(week.first?.volumeKg, 800)
        let points = StatsEngine.history(of: row.exerciseKey, in: [first])
        XCTAssertEqual(points.first?.volume, 800)
        XCTAssertEqual(ExerciseProgress.samples(points, metric: .volume).first?.value, 800)

        let heavier = item("One-arm row", sets: [done(10, 22.5), done(10, 22.5)], perSide: true, muscles: ["lats"])
        let second = session(calendar.addingDays(3, to: monday), items: [heavier])
        let comparison = StatsEngine.compare(second, templateID: nil, previous: [first, second])
        XCTAssertEqual(comparison?.volumeDelta, 900 - 800)
    }

    // MARK: Training days

    func testShortStretchIsNoTrainingDayAndHealthWorkoutsCountWhenOn() {
        let stretch = TrainingDays.Workout(date: monday, minutes: 8, doneSets: 6, kind: .stretch)
        let strength = TrainingDays.Workout(date: calendar.addingDays(1, to: monday), minutes: 4, doneSets: 3, kind: .gym)
        let full = TrainingDays.Workout(date: calendar.addingDays(2, to: monday), minutes: 45, doneSets: 12, kind: .gym)
        let rescue = TrainingDays.Workout(date: calendar.addingDays(3, to: monday), minutes: 5, doneSets: 1, isRescue: true, kind: .gym)
        let tennis = ActivityEntry(date: calendar.addingDays(4, to: monday), minutes: 90, source: .health)
        let shortWalk = ActivityEntry(date: calendar.addingDays(5, to: monday), minutes: 6, source: .health)

        let off = TrainingDays.entries(workouts: [stretch, strength, full, rescue], health: [tennis, shortWalk], countHealth: false,
                                       minimumMinutes: 10, rescueMinutes: 5)
        XCTAssertEqual(off.count, 3)
        XCTAssertFalse(TrainingDays.isTrainingDay(monday, in: off, calendar: calendar))
        XCTAssertTrue(TrainingDays.isTrainingDay(calendar.addingDays(1, to: monday), in: off, calendar: calendar))
        XCTAssertEqual(TrainingDays.days(inWeekStarting: monday, entries: off, calendar: calendar), 3)

        let on = TrainingDays.entries(workouts: [stretch, strength, full, rescue], health: [tennis, shortWalk], countHealth: true,
                                      minimumMinutes: 10, rescueMinutes: 5)
        XCTAssertEqual(TrainingDays.days(inWeekStarting: monday, entries: on, calendar: calendar), 4)

        // The Progress chart counts the same days as the streak.
        let records = [
            session(monday, items: [item(sets: [done(10, 0)])], kind: .stretch, minutes: 8),
            session(calendar.addingDays(2, to: monday), items: [item(sets: [done(10, 60)])], minutes: 45),
        ]
        let weekEnd = calendar.addingDays(6, to: monday)
        XCTAssertEqual(StatsEngine.weekly(records, calendar: calendar, weeks: 1, now: weekEnd).first?.workoutDays, 2)
        XCTAssertEqual(StatsEngine.weekly(records, calendar: calendar, weeks: 1, now: weekEnd, trainingDays: on).first?.workoutDays, 4)
        XCTAssertEqual(StatsEngine.weekly(records, calendar: calendar, weeks: 1, now: weekEnd, trainingDays: on).first?.sessions, 2)

        // Same list as the streak.
        let streak = StreakEngine(calendar: calendar).evaluate(entries: on, config: StreakConfig(defaultGoal: 3), now: weekEnd)
        XCTAssertEqual(streak.thisWeek.workoutDays, 4)
    }

    // MARK: Wording

    /// Effort-weighted load (`.load`, `acute`) is never called "sets" in the app's strings.
    func testNoLoadNumberIsCalledSets() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("App/Sources")
        guard FileManager.default.fileExists(atPath: sources.path) else { throw XCTSkip("App sources not found") }
        let pattern = try NSRegularExpression(pattern: #"\\\([^)]*(\.load\b|\bacute\b)[^"]*\bsets\b"#)
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift", let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if pattern.firstMatch(in: line, range: range) != nil {
                    offenders.append("\(file.lastPathComponent):\(number + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "Load is effort-weighted – say “Load”, not “sets”")
    }
}
