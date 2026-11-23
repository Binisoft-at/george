import XCTest
@testable import GeorgeCore

/// Review of the watch-only link: Continue Here on a link whose end was already sent, the numbers a
/// part recording links with, and where the watch ends its recording.
final class V7W3WatchlinkReviewTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let id = UUID()

    private func link(recording: Bool = true, ending: WatchOnlyLink.Ending? = nil, final: WatchMetrics? = nil) -> WatchOnlyLink {
        WatchOnlyLink(sessionID: id, recordingSince: t0, linkedAt: t0.addingTimeInterval(600), watchRecording: recording,
                      watchFinal: final, ending: ending, endingSince: ending == nil ? nil : t0.addingTimeInterval(1800))
    }

    // MARK: Continue Here back on the iPhone

    func testContinueHerePicksUpARunningRecording() {
        XCTAssertEqual(link().resumption, WatchOnlyLink.Resumption(recording: true, final: nil))
        // Asked to record, never heard: nothing to pick up, Finish waits for the watch as usual.
        XCTAssertEqual(link(recording: false).resumption, WatchOnlyLink.Resumption(recording: false, final: nil))
    }

    func testContinueHereKeepsThePartAWatchSaved() {
        let final = WatchMetrics(healthWorkoutID: UUID(), endedAt: t0.addingTimeInterval(700), sessionID: id)
        XCTAssertEqual(link(final: final).resumption, WatchOnlyLink.Resumption(recording: false, final: final))
        // Told to end at the workout's last sign of life (left running on the Mac), then taken back:
        // the recording, still running or saved, is the workout's again – not ended or dropped.
        let end = WatchOnlyLink.Ending.save(at: t0.addingTimeInterval(3600))
        XCTAssertEqual(link(ending: end).resumption, WatchOnlyLink.Resumption(recording: true, final: nil))
        XCTAssertEqual(link(ending: end, final: final).resumption, WatchOnlyLink.Resumption(recording: false, final: final))
    }

    func testContinueHereDoesntCountOnARecordingTheWatchWasToldToDrop() {
        // Taken over by an iPad first (the watch dropped it, or is about to), then back here.
        XCTAssertNil(link(ending: .discard).resumption)
    }

    // MARK: The numbers a link brings

    func testARecordingUpToTheEndBringsItsNumbers() {
        let end = t0.addingTimeInterval(3600)
        let final = WatchMetrics(averageHeartRate: 120, activeEnergy: 400, healthWorkoutID: UUID(), endedAt: end, sessionID: id)
        XCTAssertEqual(link(ending: .save(at: end), final: final).linkedMetrics(workoutEnd: end), final)
        // The end the watch was told, when the session has none.
        XCTAssertEqual(link(ending: .save(at: end), final: final).linkedMetrics(workoutEnd: nil), final)
    }

    func testAPartRecordingLinksWithoutItsNumbers() {
        // An older watch saved its part at the hand-over; the workout went on for an hour on the Mac.
        let handOver = t0.addingTimeInterval(1200)
        let end = handOver.addingTimeInterval(3600)
        let workoutID = UUID()
        let part = WatchMetrics(heartRate: 130, averageHeartRate: 120, activeEnergy: 150, healthWorkoutID: workoutID, endedAt: handOver, sessionID: id)
        let linked = link(ending: .save(at: end), final: part).linkedMetrics(workoutEnd: end)
        XCTAssertEqual(linked?.healthWorkoutID, workoutID)
        XCTAssertEqual(linked?.endedAt, handOver)
        XCTAssertNil(linked?.averageHeartRate)
        XCTAssertNil(linked?.activeEnergy)
        XCTAssertNil(linked?.heartRate)
        // A few seconds short of the end (two clocks) still counts as up to the end.
        let close = WatchMetrics(averageHeartRate: 120, activeEnergy: 400, healthWorkoutID: workoutID, endedAt: end.addingTimeInterval(-20), sessionID: id)
        XCTAssertEqual(link(ending: .save(at: end), final: close).linkedMetrics(workoutEnd: end)?.activeEnergy, 400)
        XCTAssertNil(link().linkedMetrics(workoutEnd: end))
    }

    // MARK: Where the watch ends its recording

    func testTheEndNeverGoesBeforeAPauseHealthKitHolds() {
        let start = t0
        let now = t0.addingTimeInterval(10 * 3600)
        let phoneEnd = t0.addingTimeInterval(3600)
        // Paused and left running: the watch heard the pause a moment after the phone's end.
        let pauseHeard = phoneEnd.addingTimeInterval(1.5)
        XCTAssertEqual(WatchRecordingEnd.collectionEnd(requested: phoneEnd, startedAt: start, lastEvent: pauseHeard, now: now), pauseHeard)
        // Events before the end change nothing.
        XCTAssertEqual(WatchRecordingEnd.collectionEnd(requested: phoneEnd, startedAt: start, lastEvent: start.addingTimeInterval(600), now: now), phoneEnd)
        // Never after now.
        XCTAssertEqual(WatchRecordingEnd.collectionEnd(requested: phoneEnd, startedAt: start, lastEvent: now.addingTimeInterval(5), now: now), now)
        // No end asked: now, whatever the events.
        XCTAssertEqual(WatchRecordingEnd.collectionEnd(requested: nil, startedAt: start, lastEvent: pauseHeard, now: now), now)
    }

    func testAWatchFinishWaitsForAnEndFromThisRecording() {
        let recordingStart = t0.addingTimeInterval(7200)
        let earlierPart = WatchFinishSummary(sessionID: id, title: "UPPER", finishedAt: t0.addingTimeInterval(3600),
                                             durationSeconds: 3600, completedSets: 8, totalSets: 12)
        let old = WatchSnapshot(generatedAt: t0, templates: [], upcoming: [], streak: nil, live: nil, unit: .kg, lastFinished: earlierPart)
        // The phone's summary of the part before this recording isn't this recording's end.
        XCTAssertNil(WatchRecordingEnd.phoneEnd(for: id, in: old, recordingStart: recordingStart))
        let lastSet = recordingStart.addingTimeInterval(3600)
        let finished = WatchFinishSummary(sessionID: id, title: "UPPER", finishedAt: lastSet, durationSeconds: 3600, completedSets: 12, totalSets: 12)
        let new = WatchSnapshot(generatedAt: t0.addingTimeInterval(9 * 3600), templates: [], upcoming: [], streak: nil, live: nil, unit: .kg,
                                lastFinished: finished)
        XCTAssertEqual(WatchRecordingEnd.phoneEnd(for: id, in: new, recordingStart: recordingStart), lastSet)
        // Nothing from the phone yet, or a summary of another workout.
        XCTAssertNil(WatchRecordingEnd.phoneEnd(for: id, in: nil, recordingStart: recordingStart))
        XCTAssertNil(WatchRecordingEnd.phoneEnd(for: UUID(), in: new, recordingStart: recordingStart))
    }
}
