import XCTest
@testable import GeorgeCore

/// v7 wave 3, measured numbers of a two-part workout (stopped early, continued later): both parts
/// measured → calories added, heart rate weighted by time, the higher maximum; otherwise George's
/// estimate and no heart rate. The first part's numbers outlive Finish for the watch's late numbers.
final class V7W3MeasuredTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    // MARK: The combine rule

    func testBothPartsMeasuredMakeTheWholeWorkout() {
        // Part 1: 40 min, 300 kcal, avg 120, max 165. Part 2: 20 min, 150 kcal, avg 150, max 172.
        let whole = MeasuredNumbers.combined(
            earlier: MeasuredNumbers(averageHeartRate: 120, maxHeartRate: 165, activeEnergy: 300), earlierSeconds: 40 * 60,
            part: MeasuredNumbers(averageHeartRate: 150, maxHeartRate: 172, activeEnergy: 150), partSeconds: 20 * 60)
        XCTAssertEqual(whole.activeEnergy ?? 0, 450, accuracy: 0.001)
        XCTAssertEqual(whole.averageHeartRate ?? 0, 130, accuracy: 0.001, "weighted 2:1 by active time")
        XCTAssertEqual(whole.maxHeartRate, 172)
        // Shown as measured.
        XCTAssertEqual(EnergyDisplay.choose(measured: whole.activeEnergy, estimated: 380), EnergyDisplay(kcal: 450, isMeasured: true))
    }

    func testOnlyTheContinuedPartMeasuredShowsTheEstimate() {
        // The watch recorded part 2 only (iPhone without Health, or no row for part 1 on this device).
        let whole = MeasuredNumbers.combined(earlier: MeasuredNumbers(), earlierSeconds: 2400,
                                             part: MeasuredNumbers(averageHeartRate: 150, activeEnergy: 150), partSeconds: 1200)
        XCTAssertTrue(whole.isEmpty)
        let shown = EnergyDisplay.choose(measured: whole.activeEnergy, estimated: 380)
        XCTAssertEqual(shown, EnergyDisplay(kcal: 380, isMeasured: false))
        XCTAssertEqual(shown?.text, "≈380 kcal")
    }

    func testOnlyTheFirstPartMeasuredShowsTheEstimate() {
        // Part 1 on the watch, part 2 on the iPhone alone: part 1's calories aren't the workout's.
        let whole = MeasuredNumbers.combined(earlier: MeasuredNumbers(averageHeartRate: 120, activeEnergy: 300), earlierSeconds: 2400,
                                             part: MeasuredNumbers(), partSeconds: 1200)
        XCTAssertNil(whole.activeEnergy)
        XCTAssertNil(whole.averageHeartRate, "heart rate of one part only is left out")
        XCTAssertEqual(EnergyDisplay.choose(measured: whole.activeEnergy, estimated: 380)?.isMeasured, false)
    }

    func testEachNumberNeedsBothParts() {
        // iPhone path: heart rate from Apple Health for both parts, calories measured for part 1 only.
        let whole = MeasuredNumbers.combined(
            earlier: MeasuredNumbers(averageHeartRate: 110, maxHeartRate: 150, activeEnergy: 200), earlierSeconds: 1800,
            part: MeasuredNumbers(averageHeartRate: 140, maxHeartRate: 160), partSeconds: 1800)
        XCTAssertNil(whole.activeEnergy)
        XCTAssertEqual(whole.averageHeartRate ?? 0, 125, accuracy: 0.001)
        XCTAssertEqual(whole.maxHeartRate, 160)
        // The watch gives no maximum: none for the whole workout when one part lacks it.
        let watch = MeasuredNumbers.combined(
            earlier: MeasuredNumbers(averageHeartRate: 110, maxHeartRate: 150, activeEnergy: 200), earlierSeconds: 1800,
            part: MeasuredNumbers(averageHeartRate: 140, activeEnergy: 100), partSeconds: 1800)
        XCTAssertNil(watch.maxHeartRate)
        XCTAssertEqual(watch.activeEnergy ?? 0, 300, accuracy: 0.001)
    }

    func testThreePartsCombineStepByStep() {
        // Continued twice: the stored whole of parts 1+2 is the earlier part of part 3.
        let firstTwo = MeasuredNumbers.combined(earlier: MeasuredNumbers(averageHeartRate: 120, activeEnergy: 100), earlierSeconds: 600,
                                                part: MeasuredNumbers(averageHeartRate: 150, activeEnergy: 100), partSeconds: 600)
        let all = MeasuredNumbers.combined(earlier: firstTwo, earlierSeconds: 1200,
                                           part: MeasuredNumbers(averageHeartRate: 135, activeEnergy: 50), partSeconds: 1200)
        XCTAssertEqual(all.activeEnergy ?? 0, 250, accuracy: 0.001)
        XCTAssertEqual(all.averageHeartRate ?? 0, 135, accuracy: 0.001)
        // A whole stored as "none" (zeros) stays none.
        let stored = MeasuredNumbers(averageHeartRate: 0, maxHeartRate: 0, activeEnergy: 0)
        XCTAssertTrue(MeasuredNumbers.combined(earlier: stored, earlierSeconds: 1200, part: MeasuredNumbers(averageHeartRate: 135, activeEnergy: 50),
                                               partSeconds: 1200).isEmpty)
    }

    // MARK: Which time is the continued part's

    func testPartStartIsWhenItWasContinued() {
        XCTAssertEqual(MeasuredNumbers.partStart(continuedAt: at(-20), earlierEndedAt: at(-300), partSeconds: 900, end: now), at(-20))
    }

    func testPartStartWithoutContinueTimeNeverReachesIntoTheGap() {
        // Taken over on another device: the last 15 active minutes before the end, all inside part 2.
        XCTAssertEqual(MeasuredNumbers.partStart(continuedAt: nil, earlierEndedAt: at(-300), partSeconds: 900, end: now), at(-15))
        // Never before part 1 ended.
        XCTAssertEqual(MeasuredNumbers.partStart(continuedAt: nil, earlierEndedAt: at(-10), partSeconds: 900, end: now), at(-10))
        XCTAssertEqual(MeasuredNumbers.partStart(continuedAt: nil, earlierEndedAt: nil, partSeconds: 900, end: now), at(-15))
        // No active time since continuing: an empty window.
        XCTAssertEqual(MeasuredNumbers.partStart(continuedAt: nil, earlierEndedAt: at(-300), partSeconds: -5, end: now), now)
    }

    // MARK: The first part after Finish

    private func earlier(_ id: UUID = UUID(), finishedAt: Date? = nil, partBegan: Date? = nil) -> EarlierPartNumbers {
        EarlierPartNumbers(sessionID: id, numbers: MeasuredNumbers(averageHeartRate: 120, maxHeartRate: 160, activeEnergy: 300),
                           seconds: 2400, partSeconds: 1200, partBegan: partBegan, finishedAt: finishedAt ?? now)
    }

    func testLateWatchNumbersOfTheContinuedPartJoinTheFirstPart() {
        let kept = earlier(partBegan: at(-25))
        // At Finish the watch's totals hadn't come: estimate, no heart rate.
        XCTAssertTrue(kept.whole(with: MeasuredNumbers()).isEmpty)
        // Its final numbers come late: the whole workout's, not part 2's alone.
        let final = MeasuredNumbers(averageHeartRate: 150, activeEnergy: 140)
        let whole = kept.whole(with: final)
        XCTAssertEqual(whole.activeEnergy ?? 0, 440, accuracy: 0.001)
        XCTAssertEqual(whole.averageHeartRate ?? 0, 130, accuracy: 0.001)
        // The same message twice gives the same numbers.
        XCTAssertEqual(kept.whole(with: final), whole)
    }

    func testARecordingThatEndedBeforeContinuingIsTheFirstParts() {
        let kept = earlier(partBegan: at(-25))
        XCTAssertFalse(kept.isLaterPart(recordingEndedAt: at(-60)))
        XCTAssertTrue(kept.isLaterPart(recordingEndedAt: at(-1)))
        XCTAssertTrue(kept.isLaterPart(recordingEndedAt: nil), "an older watch sends no end")
        XCTAssertTrue(earlier().isLaterPart(recordingEndedAt: at(-60)), "unknown continue time")
    }

    func testKeptForThreeDaysNewestFirst() {
        let id = UUID()
        let old = earlier(id, finishedAt: at(-4 * 24 * 60))
        let fresh = earlier(finishedAt: at(-5))
        XCTAssertEqual(EarlierPartNumbers.pruned([old, fresh], now: now), [fresh])
        // Continued once more: the newer one replaces it.
        var parts = EarlierPartNumbers.adding(earlier(id, finishedAt: at(-30)), to: [fresh], now: now)
        let again = earlier(id, finishedAt: at(-1))
        parts = EarlierPartNumbers.adding(again, to: parts, now: now)
        XCTAssertEqual(parts, [again, fresh])
        var many: [EarlierPartNumbers] = []
        for minute in 0..<30 {
            many = EarlierPartNumbers.adding(earlier(finishedAt: at(-Double(minute))), to: many, now: now)
        }
        XCTAssertEqual(many.count, EarlierPartNumbers.limit)
        XCTAssertEqual(many.first?.finishedAt, now)
    }

    func testKeptNumbersSurviveEncoding() throws {
        let kept = earlier(partBegan: at(-25))
        let back = try JSONDecoder().decode([EarlierPartNumbers].self, from: JSONEncoder().encode([kept]))
        XCTAssertEqual(back, [kept])
        let empty = EarlierPartNumbers(sessionID: UUID(), numbers: MeasuredNumbers(), seconds: 0, partSeconds: 60,
                                       partBegan: nil, finishedAt: now)
        XCTAssertEqual(try JSONDecoder().decode(EarlierPartNumbers.self, from: JSONEncoder().encode(empty)), empty)
    }
}
