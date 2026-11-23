import XCTest
@testable import GeorgeCore

/// v7 lane "data": the workout log export, logging a workout afterwards, which calories to show,
/// merging records two devices made before they synced, and the sync health banner.
final class V7DataTests: XCTestCase {
    private let vienna = TimeZone(identifier: "Europe/Vienna")!

    private func viennaCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = vienna
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func rows(_ csv: String) -> [[String]] {
        CSVReader.parse(csv).map(\.fields)
    }

    // MARK: Log export (CSV)

    func testLogExportUsesLocalDay() {
        let calendar = viennaCalendar()
        // Planned for 20.11 (midnight in Vienna = 19.11 23:00 UTC) and marked done.
        let midnight = date(2026, 11, 20, in: calendar)
        let item = WorkoutItem(name: "Row", sets: [WorkoutSet(targetReps: "10")])
        let session = ProgramCSV.LogSession(
            date: midnight, title: "UPPER", program: "Gym", kind: .gym, durationSeconds: 45 * 60, status: "completed",
            content: WorkoutContent(blocks: [WorkoutBlock(items: [item])]), startedAt: date(2026, 11, 20, 18, 5, in: calendar),
            effort: 7, energyKcal: 312.4, notes: "Felt strong"
        )
        let table = rows(ProgramCSV.exportLog([session], timeZone: vienna))
        XCTAssertEqual(table.count, 2)
        let header = table[0]
        XCTAssertEqual(header, ProgramCSV.logHeader)
        let row = table[1]
        func value(_ column: String) -> String { row[header.firstIndex(of: column)!] }
        XCTAssertEqual(value("date"), "2026-11-20", "the local day, not the UTC day (19.11)")
        XCTAssertEqual(value("started_at"), "2026-11-20T18:05")
        XCTAssertEqual(value("effort"), "7")
        XCTAssertEqual(value("kcal"), "312")
        XCTAssertEqual(value("notes"), "Felt strong")
        XCTAssertEqual(value("exercise"), "Row")

        // In UTC the same moment is still the 19th – the time zone decides.
        let utc = rows(ProgramCSV.exportLog([session], timeZone: TimeZone(identifier: "UTC")!))
        XCTAssertEqual(utc[1][0], "2026-11-19")
    }

    func testActivityRowExported() {
        let calendar = viennaCalendar()
        let tennis = ProgramCSV.LogSession(
            date: date(2026, 11, 18, 17, 30, in: calendar), title: "Tennis", program: "", kind: WorkoutKind("tennis"),
            durationSeconds: 90 * 60, status: "completed", content: WorkoutContent(),
            startedAt: date(2026, 11, 18, 17, 30, in: calendar), effort: 6, energyKcal: 640, notes: ""
        )
        let item = WorkoutItem(name: "Squat", sets: [WorkoutSet(targetReps: "5"), WorkoutSet(targetReps: "5")])
        let gym = ProgramCSV.LogSession(
            date: date(2026, 11, 19, 18, 0, in: calendar), title: "LOWER", program: "Gym", kind: .gym,
            durationSeconds: 50 * 60, status: "partial", content: WorkoutContent(blocks: [WorkoutBlock(items: [item])])
        )
        let table = rows(ProgramCSV.exportLog([gym, tennis], timeZone: vienna))
        XCTAssertEqual(table.count, 4, "header + one row for the activity + one per set")
        let header = table[0]
        let activity = table[1]
        XCTAssertEqual(activity.count, header.count)
        XCTAssertEqual(activity[header.firstIndex(of: "session")!], "Tennis", "sorted by date: the activity comes first")
        XCTAssertEqual(activity[header.firstIndex(of: "type")!], "tennis")
        XCTAssertEqual(activity[header.firstIndex(of: "duration_min")!], "90")
        XCTAssertEqual(activity[header.firstIndex(of: "exercise")!], "")
        XCTAssertEqual(activity[header.firstIndex(of: "kcal")!], "640")
        XCTAssertEqual(activity[header.firstIndex(of: "effort")!], "6")
        // A session without effort or energy leaves those cells empty.
        XCTAssertEqual(table[2][header.firstIndex(of: "effort")!], "")
        XCTAssertEqual(table[2][header.firstIndex(of: "kcal")!], "")
        XCTAssertEqual(table[3][header.firstIndex(of: "set")!], "2")
    }

    // MARK: Logging afterwards

    func testBareDayGetsTheUsualTimeAndEndsByNow() {
        let calendar = viennaCalendar()
        let planned = date(2026, 11, 18, in: calendar) // week plans sit at midnight
        let now = date(2026, 11, 20, 9, 0, in: calendar)
        let usual = date(2026, 11, 16, 17, 40, in: calendar)
        XCTAssertEqual(PastLog.start(for: planned, minutes: 45, usualStart: usual, now: now, calendar: calendar),
                       date(2026, 11, 18, 17, 40, in: calendar))
        // No earlier workout (or one that sat at midnight itself): 18:00.
        XCTAssertEqual(PastLog.start(for: planned, minutes: 45, usualStart: nil, now: now, calendar: calendar),
                       date(2026, 11, 18, 18, 0, in: calendar))
        XCTAssertEqual(PastLog.start(for: planned, minutes: 45, usualStart: date(2026, 11, 10, in: calendar), now: now, calendar: calendar),
                       date(2026, 11, 18, 18, 0, in: calendar))
        // Today at 18:00 hasn't happened yet at 9:00: it moves so the workout ends by now.
        let today = date(2026, 11, 20, in: calendar)
        XCTAssertEqual(PastLog.start(for: today, minutes: 45, usualStart: nil, now: now, calendar: calendar),
                       now.addingTimeInterval(-45 * 60))
        // A real time of day is kept (when it ends by now).
        let picked = date(2026, 11, 19, 7, 15, in: calendar)
        XCTAssertEqual(PastLog.start(for: picked, minutes: 45, usualStart: usual, now: now, calendar: calendar), picked)
        // "Log Past Workout" from a template: started a workout's length ago, not ending in the future.
        XCTAssertEqual(PastLog.clamped(now, minutes: 40, now: now), now.addingTimeInterval(-40 * 60))
        XCTAssertTrue(PastLog.isBareDay(planned, calendar: calendar))
        XCTAssertFalse(PastLog.isBareDay(picked, calendar: calendar))
    }

    func testDefaultMinutesPreferRecentWorkouts() {
        // Median of the last five (the sixth is ignored), rounded to 5 minutes.
        let minutes: (Double) -> Double = { $0 * 60 }
        XCTAssertEqual(PastLog.defaultMinutes(recentDurations: [52, 61, 48, 55, 70, 10].map(minutes), estimatedSeconds: 1800, exerciseCount: 6), 55)
        // Two are enough; the median of two is their mean.
        XCTAssertEqual(PastLog.defaultMinutes(recentDurations: [minutes(50), minutes(60)], estimatedSeconds: 1800, exerciseCount: 6), 55)
        // One isn't: the estimate plus a minute per exercise (30 + 6 = 36 → 35).
        XCTAssertEqual(PastLog.defaultMinutes(recentDurations: [minutes(80)], estimatedSeconds: 1800, exerciseCount: 6), 35)
        // No estimate at all: 40.
        XCTAssertEqual(PastLog.defaultMinutes(recentDurations: [], estimatedSeconds: 0, exerciseCount: 0), 40)
        // Never below 5 or above 240.
        XCTAssertEqual(PastLog.defaultMinutes(recentDurations: [], estimatedSeconds: 30, exerciseCount: 0), 5)
        XCTAssertEqual(PastLog.defaultMinutes(recentDurations: [minutes(400), minutes(500)], estimatedSeconds: 0, exerciseCount: 0), 240)
    }

    // MARK: Calories

    func testMeasuredEnergyWinsAndEstimatesAreMarked() {
        let measured = EnergyDisplay.choose(measured: 406, estimated: 318)
        XCTAssertEqual(measured, EnergyDisplay(kcal: 406, isMeasured: true))
        XCTAssertEqual(measured?.text, "406 kcal")
        let estimate = EnergyDisplay.choose(measured: 0, estimated: 318.4)
        XCTAssertEqual(estimate?.isMeasured, false)
        XCTAssertEqual(estimate?.text, "≈318 kcal")
        XCTAssertEqual(estimate?.number, "≈318")
        XCTAssertEqual(estimate?.text(scaled: 0.5), "≈159 kcal")
        XCTAssertEqual(EnergyDisplay.choose(measured: nil, estimated: 250)?.text, "≈250 kcal")
        XCTAssertNil(EnergyDisplay.choose(measured: nil, estimated: 0))
    }

    // MARK: Duplicates from two devices

    func testSettingsMergeKeepsOldestAndTakesTheLastEdit() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // iPhone: set up weeks ago, edited since. Mac: fresh defaults made before its first sync.
        let iPhone = DuplicateMerge.Stamp(createdAt: t0, updatedAt: t0.addingTimeInterval(86_400))
        let macFresh = DuplicateMerge.Stamp(createdAt: t0.addingTimeInterval(30 * 86_400), updatedAt: t0.addingTimeInterval(30 * 86_400 + 0.01))
        let plan = DuplicateMerge.plan([macFresh, iPhone])
        XCTAssertEqual(plan?.keep, 1, "the oldest copy stays on every device")
        XCTAssertEqual(plan?.source, 1, "fresh defaults never win over real settings")

        // The Mac changed the goal after that: its values win, the old record stays.
        let macEdited = DuplicateMerge.Stamp(createdAt: macFresh.createdAt, updatedAt: macFresh.createdAt.addingTimeInterval(600))
        let edited = DuplicateMerge.plan([iPhone, macEdited])
        XCTAssertEqual(edited?.keep, 0)
        XCTAssertEqual(edited?.source, 1)

        // Nobody edited anything: the oldest keeps its own values.
        let fresh = DuplicateMerge.plan([macFresh, DuplicateMerge.Stamp(createdAt: t0, updatedAt: t0)])
        XCTAssertEqual(fresh?.keep, 1)
        XCTAssertEqual(fresh?.source, 1)
        XCTAssertNil(DuplicateMerge.plan([]))

        // Field by field: the newest copy's choice, unless it still has the default there.
        XCTAssertEqual(DuplicateMerge.pick("lb", over: "kg", default: "kg"), "lb")
        XCTAssertEqual(DuplicateMerge.pick("kg", over: "lb", default: "kg"), "lb", "a new device's default doesn't reset a choice")
        XCTAssertEqual(DuplicateMerge.pick(4, over: 3, default: 3), 4)
        XCTAssertEqual(DuplicateMerge.pick(2, over: 7, default: 2), 7)
    }

    func testExerciseNotesAndLinksAreJoined() {
        XCTAssertEqual(DuplicateMerge.joinedNotes(["", "Seat 4, red band", " Seat 4, red band ", "Grip wide"]), "Seat 4, red band\n\nGrip wide")
        XCTAssertEqual(DuplicateMerge.joinedNotes(["", "  "]), "")
        XCTAssertEqual(DuplicateMerge.unionLinks([["https://a", "https://b"], ["https://b", "", "https://c"]]), ["https://a", "https://b", "https://c"])
        XCTAssertEqual(DuplicateMerge.groups(["x", "y", "x", "z", "y", "x"]), [[0, 2, 5], [1, 4]])
        XCTAssertEqual(DuplicateMerge.groups(["x", "y"]), [])
    }

    // MARK: Sync health

    func testSyncHealthLevels() {
        let now = Date(timeIntervalSince1970: 5_000_000)
        XCTAssertEqual(SyncHealth.evaluate(storage: .memory(reason: nil), account: .unknown, lastError: nil, errorSince: nil, now: now).level, .critical)
        XCTAssertEqual(SyncHealth.evaluate(storage: .memory(reason: nil), account: .unknown, lastError: nil, errorSince: nil, now: now).title,
                       "Not being saved – restart George")
        XCTAssertEqual(SyncHealth.evaluate(storage: .local(reason: "No iCloud"), account: .unknown, lastError: nil, errorSince: nil, now: now).level, .warning)
        XCTAssertEqual(SyncHealth.evaluate(storage: .iCloud, account: .noAccount, lastError: nil, errorSince: nil, now: now).level, .warning)
        XCTAssertEqual(SyncHealth.evaluate(storage: .iCloud, account: .unavailable, lastError: nil, errorSince: nil, now: now).level, .warning)
        XCTAssertEqual(SyncHealth.evaluate(storage: .iCloud, account: .unknown, lastError: nil, errorSince: nil, now: now), .ok, "still checking")
        XCTAssertEqual(SyncHealth.evaluate(storage: .iCloud, account: .available, lastError: nil, errorSince: nil, now: now), .ok)
        XCTAssertEqual(SyncHealth.evaluate(storage: .demo, account: .unknown, lastError: nil, errorSince: nil, now: now), .ok)
        // A sync error shows once it lasts 15 minutes.
        let fresh = SyncHealth.evaluate(storage: .iCloud, account: .available, lastError: "Quota", errorSince: now.addingTimeInterval(-60), now: now)
        XCTAssertEqual(fresh, .ok)
        let lasting = SyncHealth.evaluate(storage: .iCloud, account: .available, lastError: "Quota", errorSince: now.addingTimeInterval(-16 * 60), now: now)
        XCTAssertEqual(lasting.level, .warning)
        XCTAssertEqual(lasting.detail, "Quota")
    }
}
