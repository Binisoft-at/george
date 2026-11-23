import XCTest
@testable import GeorgeCore

/// Progress tab, exercise charts, time by type and the muscle-engine fast paths.
final class InsightsTests: XCTestCase {
    let calendar = Calendar.training(timeZone: TimeZone(identifier: "Europe/Vienna")!)

    func session(_ date: Date, sets: [(reps: Int, weight: Double?)], name: String = "Bench", muscles: [String] = ["chest"],
                 kind: WorkoutKind = .gym, mode: ExerciseMode = .reps, seconds: Int? = nil, duration: Double = 3600) -> SessionRecord {
        var item = WorkoutItem(name: name, mode: mode, sets: sets.map { WorkoutSet(targetReps: String($0.reps), targetWeight: $0.weight) }, muscles: muscles)
        for i in item.sets.indices {
            item.sets[i].isDone = true
            item.sets[i].doneAt = date
            if let seconds { item.sets[i].seconds = seconds }
        }
        return SessionRecord(id: UUID(), date: date, title: "S", kind: kind, durationSeconds: duration, isCompleted: true,
                             content: WorkoutContent(blocks: [WorkoutBlock(items: [item])]))
    }

    func contributions(_ item: WorkoutItem) -> [MuscleContribution] {
        MuscleResolver.contributions(primary: item.muscles, secondary: [], exerciseName: item.name)
    }

    var day: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 18))! }

    // MARK: Exercise progress

    func testHeavierTripleAfterTenRepsIsNotAnE1RMRecord() throws {
        let first = session(day, sets: [(10, 75), (10, 75)])
        let second = session(calendar.addingDays(3, to: day), sets: [(3, 80)])
        let third = session(calendar.addingDays(6, to: day), sets: [(8, 80)])
        let key = first.content.allItems[0].exerciseKey
        let points = StatsEngine.history(of: key, in: [first, second, third])
        XCTAssertEqual(ExerciseProgress.metrics(for: points, mode: .reps), [.oneRepMax, .topSet, .volume])

        let e1rm = ExerciseProgress.samples(points, metric: .oneRepMax)
        XCTAssertEqual(e1rm.map(\.isRecord), [false, false, true])
        let top = ExerciseProgress.samples(points, metric: .topSet)
        XCTAssertEqual(top.map(\.isRecord), [false, true, false])
        XCTAssertEqual(top[1].value, 80)
        XCTAssertEqual(top[1].reps, 3)
        let volume = try XCTUnwrap(ExerciseProgress.samples(points, metric: .volume).first)
        XCTAssertEqual(volume.value, 1500)
    }

    func testBodyweightSessionsAreTheirOwnRepsSeries() {
        let pushups = session(day, sets: [(20, nil), (15, nil)], name: "Push-up")
        let weighted = session(calendar.addingDays(2, to: day), sets: [(10, 10)], name: "Push-up")
        let more = session(calendar.addingDays(4, to: day), sets: [(25, nil), (20, nil)], name: "Push-up")
        let key = pushups.content.allItems[0].exerciseKey
        let points = StatsEngine.history(of: key, in: [pushups, weighted, more])
        XCTAssertEqual(ExerciseProgress.metrics(for: points, mode: .reps), [.oneRepMax, .topSet, .volume, .reps])
        let reps = ExerciseProgress.samples(points, metric: .reps)
        XCTAssertEqual(reps.map(\.value), [35, 45])
        XCTAssertEqual(reps.map(\.isRecord), [false, true])
        XCTAssertEqual(ExerciseProgress.samples(points, metric: .oneRepMax).count, 1)

        let onlyBodyweight = StatsEngine.history(of: key, in: [pushups, more])
        XCTAssertEqual(ExerciseProgress.metrics(for: onlyBodyweight, mode: .reps), [.reps])
    }

    func testHoldsChartTheLongestHold() {
        let plank = session(day, sets: [(0, nil)], name: "Plank", muscles: ["abs"], mode: .time, seconds: 45)
        let longer = session(calendar.addingDays(2, to: day), sets: [(0, nil)], name: "Plank", muscles: ["abs"], mode: .time, seconds: 60)
        let points = StatsEngine.history(of: plank.content.allItems[0].exerciseKey, in: [plank, longer])
        XCTAssertEqual(ExerciseProgress.metrics(for: points, mode: .time), [.seconds])
        XCTAssertEqual(ExerciseProgress.samples(points, metric: .seconds).map(\.value), [45, 60])
    }

    // MARK: Progress tab

    func testPeriodTotalsAndRecordsInTheRange() {
        let old = session(calendar.addingDays(-60, to: day), sets: [(8, 100)])
        let recent = session(day, sets: [(8, 90), (8, 90)])
        let heavier = session(calendar.addingDays(2, to: day), sets: [(5, 105)], name: "Squat", muscles: ["quads"])
        // A record beats an earlier best (v7): the first squat ever is none, this lighter one sets the bar.
        let firstSquat = session(calendar.addingDays(-50, to: day), sets: [(5, 100)], name: "Squat", muscles: ["quads"])
        let all = [old, firstSquat, recent, heavier]
        let interval = DateInterval(start: calendar.addingDays(-7, to: day), end: calendar.addingDays(7, to: day))
        let totals = StatsEngine.totals(of: all, in: interval)
        XCTAssertEqual(totals.workouts, 2)
        XCTAssertEqual(totals.sets, 3)
        XCTAssertEqual(totals.volumeKg, 8 * 90 * 2 + 5 * 105)

        // The bench record is 60 days old; only the squat record falls in the range – one entry for it.
        let records = StatsEngine.recordsSet(in: all, since: interval.start)
        XCTAssertEqual(records.map(\.exerciseName), ["Squat"])
        XCTAssertEqual(records.first?.metric, .weight)
    }

    func testTimeByTypeIncludesHealthWorkouts() {
        let gym = session(day, sets: [(8, 50)], duration: 3600)
        let yoga = session(day, sets: [(0, nil)], name: "Flow", kind: .yoga, mode: .time, seconds: 30, duration: 1200)
        let tennis = ExternalWorkout(activity: "tennis", name: "Tennis", start: day, durationSeconds: 5400)
        let healthYoga = ExternalWorkout(activity: "yoga", name: "Yoga", start: day, durationSeconds: 1800)
        let outside = ExternalWorkout(activity: "running", name: "Running", start: calendar.addingDays(-40, to: day), durationSeconds: 1800)
        let interval = DateInterval(start: calendar.addingDays(-7, to: day), end: calendar.addingDays(1, to: day))
        let rows = StatsEngine.timeByType([gym, yoga], external: [tennis, healthYoga, outside], in: interval)
        XCTAssertEqual(rows.map(\.title), ["Tennis", "Gym", "Yoga"])
        XCTAssertEqual(rows.first { $0.title == "Yoga" }?.minutes, 50)
        XCTAssertEqual(rows.first { $0.title == "Yoga" }?.includesHealth, true)
        XCTAssertEqual(rows.first { $0.title == "Gym" }?.includesHealth, false)
    }

    // MARK: Muscle engine

    func testFreshnessSeriesMatchesSinglePoints() {
        var sessions: [SessionRecord] = []
        for offset in [0, 2, 4, 7, 9] {
            sessions.append(session(calendar.addingDays(offset, to: day), sets: Array(repeating: (8, 60), count: 6), muscles: ["chest", "triceps"]))
        }
        let engine = MuscleEngine(events: MuscleEngine.events(from: sessions, contributions: contributions), calendar: calendar)
        let start = calendar.addingDays(5, to: day)
        let series = engine.freshnessSeries(of: .chest, from: start, to: start.addingTimeInterval(7 * 86_400), stepHours: 6)
        XCTAssertEqual(series.count, 29)
        for sample in series {
            XCTAssertEqual(sample.freshness, engine.freshness(of: .chest, at: sample.date).freshness, accuracy: 0.005)
        }
        XCTAssertLessThan(series.map(\.freshness).min() ?? 1, 0.8)
    }

    func testTenThousandEventsStayFast() {
        // ~2 years of 4 workouts a week, 3 exercises × 4 sets, 3–4 muscles each ≈ 15k events.
        var sessions: [SessionRecord] = []
        let start = calendar.addingDays(-730, to: day)
        for index in 0..<416 {
            let date = start.addingTimeInterval(Double(index) * 7 * 86_400 / 4)
            var record = session(date, sets: Array(repeating: (8, 60), count: 4), name: "Bench", muscles: ["chest", "triceps", "shoulders"])
            var squat = WorkoutItem(name: "Squat", mode: .reps, sets: (0..<4).map { _ in WorkoutSet(targetReps: "5", targetWeight: 100) }, muscles: ["quads", "glutes", "adductors"])
            var row = WorkoutItem(name: "Row", mode: .reps, sets: (0..<4).map { _ in WorkoutSet(targetReps: "10", targetWeight: 50) }, muscles: ["upper back", "lats", "biceps", "forearms"])
            for i in 0..<4 {
                squat.sets[i].isDone = true
                squat.sets[i].doneAt = date
                row.sets[i].isDone = true
                row.sets[i].doneAt = date
            }
            record.content.blocks.append(WorkoutBlock(items: [squat]))
            record.content.blocks.append(WorkoutBlock(items: [row]))
            sessions.append(record)
        }
        let events = MuscleEngine.events(from: sessions, contributions: contributions)
        XCTAssertGreaterThan(events.count, 10_000)
        let clock = Date()
        let engine = MuscleEngine(events: events, calendar: calendar)
        _ = engine.freshness(at: day)
        _ = engine.freshnessSeries(of: .chest, from: calendar.addingDays(-4, to: day), to: calendar.addingDays(3, to: day))
        _ = engine.loadSummary(days: 365, now: day)
        for group in MuscleGroup.allCases { _ = engine.loadSummary(group: group, days: 1, now: day) }
        _ = engine.totals(in: DateInterval(start: calendar.addingDays(-84, to: day), end: day))
        XCTAssertLessThan(Date().timeIntervalSince(clock), 5, "Muscle analytics got slow with a long history")
    }
}
