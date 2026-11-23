import XCTest
@testable import GeorgeCore

/// v7 wave 3 review of the "measured" lane: numbers a device kept for one part of a workout that was
/// continued and ended later (on another device, or from outside) never stand for the whole workout.
final class V7W3MeasuredReviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 3_000_000)

    private func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    func testNumbersKeptAtFinishCoverTheWorkout() {
        // Kept at Finish (or when the watch's numbers came later): the workout's.
        XCTAssertTrue(MeasuredNumbers.keptNumbersCover(workoutEnd: at(-60), keptAt: at(-60)))
        XCTAssertTrue(MeasuredNumbers.keptNumbersCover(workoutEnd: at(-60), keptAt: at(-1)))
        // The watch's Finish tap a few seconds ahead of the iPhone's clock.
        XCTAssertTrue(MeasuredNumbers.keptNumbersCover(workoutEnd: at(-60), keptAt: at(-60).addingTimeInterval(-5)))
        // No end (not finished): nothing to compare.
        XCTAssertTrue(MeasuredNumbers.keptNumbersCover(workoutEnd: nil, keptAt: at(-600)))
    }

    func testNumbersKeptBeforeAContinuedPartAreOnePartsOnly() {
        // Part 1 finished here at -90 (numbers kept), continued on the iPad and finished there at -10.
        XCTAssertFalse(MeasuredNumbers.keptNumbersCover(workoutEnd: at(-10), keptAt: at(-90)))
        let part1 = MeasuredNumbers(averageHeartRate: 120, maxHeartRate: 160, activeEnergy: 300)
        let shown = part1.shown(workoutEnd: at(-10), keptAt: at(-90))
        XCTAssertTrue(shown.isEmpty, "the estimate is shown, and no heart rate")
        XCTAssertEqual(EnergyDisplay.choose(measured: shown.activeEnergy, estimated: 410), EnergyDisplay(kcal: 410, isMeasured: false))
        // The same numbers kept after that end (this device finished the whole workout) stand.
        XCTAssertEqual(part1.shown(workoutEnd: at(-10), keptAt: at(-9)), part1)
    }

    func testThreePartsAcrossDevicesDontAddOnePartAsTwo() {
        // Part 1 here (kept at -120), part 2 on the iPad (ended -60), part 3 here: the earlier parts
        // (1 and 2, 40 min) have no numbers on this device – only part 1's, kept before part 2 ended.
        let kept = MeasuredNumbers(averageHeartRate: 120, activeEnergy: 150)
        let earlier = kept.shown(workoutEnd: at(-60), keptAt: at(-120))
        let whole = MeasuredNumbers.combined(earlier: earlier, earlierSeconds: 2400,
                                             part: MeasuredNumbers(averageHeartRate: 140, activeEnergy: 100), partSeconds: 1200)
        XCTAssertNil(whole.activeEnergy, "not 150 + 100 as measured for three parts")
        XCTAssertNil(whole.averageHeartRate)
        // Two parts, both on this device: part 1's numbers (kept at its Finish) join part 2's.
        let twoParts = MeasuredNumbers.combined(earlier: kept.shown(workoutEnd: at(-120), keptAt: at(-120)), earlierSeconds: 2400,
                                                part: MeasuredNumbers(averageHeartRate: 150, activeEnergy: 100), partSeconds: 1200)
        XCTAssertEqual(twoParts.activeEnergy ?? 0, 250, accuracy: 0.001)
        XCTAssertEqual(twoParts.averageHeartRate ?? 0, 130, accuracy: 0.001)
    }

    func testTheFirstPartsLateRecordingIsntTheRunningParts() {
        // Stopped early at -10 (the watch ended its recording then), continued at -9: the first part's
        // final numbers come at -8, while the second part runs.
        XCTAssertTrue(MeasuredNumbers.isEarlierRecording(endedAt: at(-10), partBegan: at(-9)))
        // The running part's own recording ended (the watch stopped on the way): its own.
        XCTAssertFalse(MeasuredNumbers.isEarlierRecording(endedAt: at(-2), partBegan: at(-9)))
        // Unknown times (an older watch, an older start snapshot): the running part's, as before.
        XCTAssertFalse(MeasuredNumbers.isEarlierRecording(endedAt: nil, partBegan: at(-9)))
        XCTAssertFalse(MeasuredNumbers.isEarlierRecording(endedAt: at(-10), partBegan: nil))
        // After Finish the kept numbers judge the same way.
        let kept = EarlierPartNumbers(sessionID: UUID(), numbers: MeasuredNumbers(), seconds: 600, partSeconds: 300,
                                      partBegan: at(-9), finishedAt: now)
        for ended in [at(-10), at(-9), at(-2)] {
            XCTAssertEqual(kept.isLaterPart(recordingEndedAt: ended), !MeasuredNumbers.isEarlierRecording(endedAt: ended, partBegan: at(-9)))
        }
    }

    func testTakenOverContinuedWorkoutSavesOnlyTheNewPartToHealth() {
        // Part 1 -120…-90 (30 min, in Apple Health already), continued on the iPad, taken over here
        // with Continue Here, finished now after 20 more active minutes: no continue time on this device.
        let start = at(-120), end = now
        let partSeconds = 50.0 * 60 - 30 * 60
        let partStart = MeasuredNumbers.partStart(continuedAt: nil, earlierEndedAt: at(-90), partSeconds: partSeconds, end: end)
        let span = FinishTime.healthSpan(start: start, end: end, activeSeconds: 50 * 60, continuedAt: partStart,
                                         activeBeforeContinuing: 30 * 60, watchStoppedAt: nil, pauses: [])
        XCTAssertEqual(span?.start, at(-20), "not part 1 again")
        XCTAssertEqual(span?.activeSeconds ?? 0, 20 * 60, accuracy: 0.001)
        // Nothing done since continuing: nothing more to save.
        let none = MeasuredNumbers.partStart(continuedAt: nil, earlierEndedAt: at(-90), partSeconds: 0, end: end)
        XCTAssertNil(FinishTime.healthSpan(start: start, end: end, activeSeconds: 30 * 60, continuedAt: none,
                                           activeBeforeContinuing: 30 * 60, watchStoppedAt: nil, pauses: []))
    }
}
