import XCTest
@testable import GeorgeCore

/// v7 review, Apple Health and the watch: the watch's running totals only for the workout's own
/// time, a continued workout's numbers for both parts, no made-up effort, effort scores read again
/// while they may still come, and "Mark not done" for older phones.
final class V7ReviewHealthwatchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    // MARK: The watch's running totals

    func testWatchTotalsFitAWorkoutThatEndsNow() {
        XCTAssertTrue(MeasuredNumbers.watchTotalsFit(workoutEnd: now, countedUntil: now))
        // Finish waited for the watch, the watch ended a moment later.
        XCTAssertTrue(MeasuredNumbers.watchTotalsFit(workoutEnd: now, countedUntil: at(1)))
        // A watch Finish that arrives late: its totals stop at the tap, which is the end.
        XCTAssertTrue(MeasuredNumbers.watchTotalsFit(workoutEnd: at(-120), countedUntil: at(-120)))
        // The workout went on here after the tap: the totals cover less, never more.
        XCTAssertTrue(MeasuredNumbers.watchTotalsFit(workoutEnd: at(-10), countedUntil: at(-40)))
    }

    func testWatchTotalsDontFitAWorkoutEndedAtItsLastSetHoursAgo() {
        // Left running overnight, finished at the last set + rest: the watch counted 13 more hours.
        XCTAssertFalse(MeasuredNumbers.watchTotalsFit(workoutEnd: at(-13 * 60), countedUntil: now))
        // "End at last set" on the finish sheet, 40 minutes ago.
        XCTAssertFalse(MeasuredNumbers.watchTotalsFit(workoutEnd: at(-40), countedUntil: now))
        // Just over the slack.
        XCTAssertFalse(MeasuredNumbers.watchTotalsFit(workoutEnd: now, countedUntil: now.addingTimeInterval(MeasuredNumbers.watchTotalsSlack + 1)))
    }

    // MARK: A continued workout

    func testContinuedWorkoutAddsCaloriesAndWeighsHeartRateByTime() {
        // Part 1: 45 min, 320 kcal, avg 130, max 170. Part 2: 15 min, 90 kcal, avg 150, max 165.
        let earlier = MeasuredNumbers(averageHeartRate: 130, maxHeartRate: 170, activeEnergy: 320)
        let part = MeasuredNumbers(averageHeartRate: 150, maxHeartRate: 165, activeEnergy: 90)
        let whole = MeasuredNumbers.combined(earlier: earlier, earlierSeconds: 45 * 60, part: part, partSeconds: 15 * 60)
        XCTAssertEqual(whole.activeEnergy ?? 0, 410, accuracy: 0.001)
        XCTAssertEqual(whole.averageHeartRate ?? 0, 135, accuracy: 0.001)
        XCTAssertEqual(whole.maxHeartRate, 170, "the higher maximum stays")
    }

    func testOnePartsCaloriesAreNotTheWholeWorkouts() {
        // Part 1 had no measured calories (George's estimate): part 2's 90 kcal aren't the workout's.
        let whole = MeasuredNumbers.combined(earlier: MeasuredNumbers(averageHeartRate: 120), earlierSeconds: 2700,
                                             part: MeasuredNumbers(averageHeartRate: 140, maxHeartRate: 160, activeEnergy: 90), partSeconds: 900)
        XCTAssertNil(whole.activeEnergy)
        XCTAssertEqual(whole.averageHeartRate ?? 0, 125, accuracy: 0.001)
        XCTAssertEqual(whole.maxHeartRate, 160)
        // Part 2 without numbers: part 1's stand (nothing is cleared).
        let kept = MeasuredNumbers.combined(earlier: MeasuredNumbers(averageHeartRate: 130, maxHeartRate: 170, activeEnergy: 320), earlierSeconds: 2700,
                                            part: MeasuredNumbers(), partSeconds: 900)
        XCTAssertEqual(kept.averageHeartRate, 130)
        XCTAssertEqual(kept.maxHeartRate, 170)
        XCTAssertNil(kept.activeEnergy)
    }

    func testStoredZerosCountAsNotMeasured() {
        // HealthMetrics keeps 0 for "none".
        let none = MeasuredNumbers(averageHeartRate: 0, maxHeartRate: 0, activeEnergy: 0)
        XCTAssertTrue(none.isEmpty)
        let whole = MeasuredNumbers.combined(earlier: none, earlierSeconds: 2700,
                                             part: MeasuredNumbers(averageHeartRate: 140, activeEnergy: 90), partSeconds: 900)
        XCTAssertEqual(whole.averageHeartRate, 140)
        XCTAssertNil(whole.activeEnergy)
        // No active time known: a plain average.
        let untimed = MeasuredNumbers.combined(earlier: MeasuredNumbers(averageHeartRate: 120), earlierSeconds: 0,
                                               part: MeasuredNumbers(averageHeartRate: 140), partSeconds: 0)
        XCTAssertEqual(untimed.averageHeartRate ?? 0, 130, accuracy: 0.001)
    }

    // MARK: Effort

    func testSaveWithoutRatingStoresNoEffort() {
        XCTAssertEqual(FinishRating.stored(nil), 0)
        XCTAssertEqual(FinishRating.stored(0), 0)
        XCTAssertEqual(FinishRating.stored(7), 7)
        XCTAssertEqual(FinishRating.stored(12), 10)
        // The calorie estimate still uses the kind's usual effort.
        XCTAssertEqual(FinishRating.forEstimate(0, kind: .yoga), WorkoutKind.yoga.defaultEffort)
        XCTAssertEqual(FinishRating.forEstimate(0, kind: .gym), WorkoutKind.gym.defaultEffort)
        XCTAssertEqual(FinishRating.forEstimate(8, kind: .yoga), 8)
    }

    func testEffortScoresAreReadAgainWhileTheyMayStillCome() {
        let day: TimeInterval = 86_400
        // Never read: always asked.
        XCTAssertTrue(HealthEffortLookup.needsLookup(known: false, score: nil, endedAt: now.addingTimeInterval(-30 * day), now: now))
        // Read as "none" an hour after the match: asked again (rated in Fitness tonight).
        XCTAssertTrue(HealthEffortLookup.needsLookup(known: true, score: nil, endedAt: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(HealthEffortLookup.needsLookup(known: true, score: nil, endedAt: now.addingTimeInterval(-6 * day), now: now))
        // After a week "none" stays.
        XCTAssertFalse(HealthEffortLookup.needsLookup(known: true, score: nil, endedAt: now.addingTimeInterval(-8 * day), now: now))
        // A score found is kept.
        XCTAssertFalse(HealthEffortLookup.needsLookup(known: true, score: 9, endedAt: now.addingTimeInterval(-3600), now: now))
    }

    // MARK: Watch protocol

    func testMarkNotDoneUsesUndoSetOnlyForPhonesThatReadIt() throws {
        let setID = UUID()
        let newPhone = WatchSnapshot(templates: [], upcoming: [], streak: nil, live: nil, unit: .kg)
        XCTAssertEqual(newPhone.protocolVersion, WatchSnapshot.currentProtocolVersion)
        XCTAssertEqual(WatchCommand.markNotDone(setID, phone: newPhone), .undoSet(setID))
        // An older phone (no version) or none heard yet: a toggle, which unticks a done set too.
        let oldPhone = WatchSnapshot(templates: [], upcoming: [], streak: nil, live: nil, unit: .kg, protocolVersion: nil)
        XCTAssertEqual(WatchCommand.markNotDone(setID, phone: oldPhone), .toggleSet(setID))
        XCTAssertEqual(WatchCommand.markNotDone(setID, phone: nil), .toggleSet(setID))

        // The version travels with the snapshot, and a snapshot without it still decodes.
        let decoded = try JSONDecoder().decode(WatchSnapshot.self, from: JSONEncoder().encode(newPhone))
        XCTAssertEqual(decoded.protocolVersion, WatchSnapshot.currentProtocolVersion)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(newPhone)) as? [String: Any])
        json["protocolVersion"] = nil
        let older = try JSONDecoder().decode(WatchSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(older.protocolVersion)
        XCTAssertEqual(WatchCommand.markNotDone(setID, phone: older), .toggleSet(setID))
    }
}
