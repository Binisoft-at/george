import XCTest
@testable import GeorgeCore

/// The Apple Watch's recording across a hand-over to a Mac (the watch-only link), the end time the
/// watch saves its recording with, late Discards, and what George says about it.
final class V7W3WatchlinkTests: XCTestCase {
    let here = "11111111-1111-1111-1111-111111111111"
    let mac = "22222222-2222-2222-2222-222222222222"
    let pad = "33333333-3333-3333-3333-333333333333"
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let id = UUID()

    private func link(ending: WatchOnlyLink.Ending? = nil, final: WatchMetrics? = nil) -> WatchOnlyLink {
        WatchOnlyLink(sessionID: id, recordingSince: t0, linkedAt: t0.addingTimeInterval(600), watchRecording: true,
                      watchFinal: final, ending: ending, endingSince: ending == nil ? nil : t0.addingTimeInterval(1800))
    }

    private func snapshot(live: WatchLiveState? = nil, upcoming: [WatchSessionSummary] = [], discarded: UUID? = nil,
                          finished: WatchFinishSummary? = nil, handedOver: WatchHandOver? = nil) -> WatchSnapshot {
        WatchSnapshot(generatedAt: t0, templates: [], upcoming: upcoming, streak: nil, live: live, unit: .kg,
                      discardedSessionID: discarded, lastFinished: finished, handedOver: handedOver)
    }

    // MARK: Hand-over

    func testOnlyAMacKeepsTheWatchRecording() {
        XCTAssertTrue(WatchOnlyLink.keepsRecording(newOwner: .mac, watchHeard: true, watchExpected: true, watchStopped: false))
        // Asked to record, not heard yet (a relaunch): kept as well.
        XCTAssertTrue(WatchOnlyLink.keepsRecording(newOwner: .mac, watchHeard: false, watchExpected: true, watchStopped: false))
        // An iPad or another iPhone saves the workout itself: the watch throws its recording away.
        XCTAssertFalse(WatchOnlyLink.keepsRecording(newOwner: .pad, watchHeard: true, watchExpected: true, watchStopped: false))
        XCTAssertFalse(WatchOnlyLink.keepsRecording(newOwner: .phone, watchHeard: true, watchExpected: true, watchStopped: false))
        XCTAssertFalse(WatchOnlyLink.keepsRecording(newOwner: nil, watchHeard: true, watchExpected: true, watchStopped: false))
        // No watch, or it stopped on the way (its part is saved and linked already).
        XCTAssertFalse(WatchOnlyLink.keepsRecording(newOwner: .mac, watchHeard: false, watchExpected: false, watchStopped: false))
        XCTAssertFalse(WatchOnlyLink.keepsRecording(newOwner: .mac, watchHeard: true, watchExpected: true, watchStopped: true))
    }

    func testWhileTheMacRunsItTheWatchKeepsRecording() {
        let now = t0.addingTimeInterval(3600)
        let running = WatchOnlyLink.SyncedWorkout.running(owner: LiveOwner(id: mac, kind: .mac), lastActivity: now.addingTimeInterval(-60))
        XCTAssertEqual(WatchOnlyLink.step(for: running, recordingSince: t0, localID: here, now: now), .keep)
        // Another Mac took it over from the first: still no Apple Health there.
        let otherMac = WatchOnlyLink.SyncedWorkout.running(owner: LiveOwner(id: pad, kind: .mac), lastActivity: now)
        XCTAssertEqual(WatchOnlyLink.step(for: otherMac, recordingSince: t0, localID: here, now: now), .keep)
        // Back on this iPhone: Continue Here picks the recording up.
        let back = WatchOnlyLink.SyncedWorkout.running(owner: LiveOwner(id: here, kind: .phone), lastActivity: now)
        XCTAssertEqual(WatchOnlyLink.step(for: back, recordingSince: t0, localID: here, now: now), .keep)
    }

    func testAnIPadTakingItOverFromTheMacEndsTheWatchRecording() {
        let now = t0.addingTimeInterval(3600)
        let onPad = WatchOnlyLink.SyncedWorkout.running(owner: LiveOwner(id: pad, kind: .pad), lastActivity: now)
        XCTAssertEqual(WatchOnlyLink.step(for: onPad, recordingSince: t0, localID: here, now: now), .discard)
        let unknown = WatchOnlyLink.SyncedWorkout.running(owner: LiveOwner(id: pad, kind: nil), lastActivity: now)
        XCTAssertEqual(WatchOnlyLink.step(for: unknown, recordingSince: t0, localID: here, now: now), .discard)
    }

    func testLeftRunningOnTheMacEndsAtItsLastSignOfLife() {
        let last = t0.addingTimeInterval(1800)
        let now = last.addingTimeInterval(RunningWorkout.staleAfter + 60)
        let left = WatchOnlyLink.SyncedWorkout.running(owner: LiveOwner(id: mac, kind: .mac), lastActivity: last)
        XCTAssertEqual(WatchOnlyLink.step(for: left, recordingSince: t0, localID: here, now: now), .end(at: last))
    }

    func testFinishedOnTheMacEndsAtItsEndAndDiscardedOrDeletedThrowsItAway() {
        let now = t0.addingTimeInterval(7200)
        let end = t0.addingTimeInterval(3900)
        XCTAssertEqual(WatchOnlyLink.step(for: .performed(endedAt: end), recordingSince: t0, localID: here, now: now), .end(at: end))
        XCTAssertEqual(WatchOnlyLink.step(for: .performed(endedAt: nil), recordingSince: t0, localID: here, now: now), .end(at: now))
        XCTAssertEqual(WatchOnlyLink.step(for: .deleted, recordingSince: t0, localID: here, now: now), .discard)
        XCTAssertEqual(WatchOnlyLink.step(for: .notDone, recordingSince: t0, localID: here, now: now), .discard)
        // A continued workout discarded on the Mac keeps only its earlier part, which ended before
        // this recording began: the recording goes.
        let earlierEnd = t0.addingTimeInterval(-3600)
        XCTAssertEqual(WatchOnlyLink.step(for: .performed(endedAt: earlierEnd), recordingSince: t0, localID: here, now: now), .discard)
    }

    // MARK: What the snapshot says

    func testSnapshotCarriesKeepEndOrDiscard() {
        XCTAssertEqual(link().handOver, WatchHandOver(sessionID: id))
        let end = t0.addingTimeInterval(3900)
        XCTAssertEqual(link(ending: .save(at: end)).handOver, WatchHandOver(sessionID: id, endedAt: end))
        XCTAssertEqual(link(ending: .discard).handOver, WatchHandOver(sessionID: id, discard: true))
        // The watch's recording ended on its own while the Mac ran it: nothing to keep.
        XCTAssertNil(link(final: WatchMetrics(endedAt: t0.addingTimeInterval(700), sessionID: id)).handOver)
    }

    func testSnapshotWithTheNewFieldStillDecodesOnBothSides() throws {
        let sent = snapshot(handedOver: WatchHandOver(sessionID: id, endedAt: t0))
        let data = try WatchWire.encoder.encode(sent)
        XCTAssertEqual(try WatchWire.decoder.decode(WatchSnapshot.self, from: data).handedOver, sent.handedOver)
        // From an older phone: no field, no hand-over.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["handedOver"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try WatchWire.decoder.decode(WatchSnapshot.self, from: old).handedOver)
    }

    // MARK: The watch's verdict

    func testWatchKeepsSavesOrDiscardsByTheHandOver() {
        let end = t0.addingTimeInterval(3900)
        XCTAssertEqual(WatchRecordingEnd.verdict(for: id, in: snapshot(handedOver: WatchHandOver(sessionID: id))), .keep)
        XCTAssertEqual(WatchRecordingEnd.verdict(for: id, in: snapshot(handedOver: WatchHandOver(sessionID: id, endedAt: end))), .save(at: end))
        XCTAssertEqual(WatchRecordingEnd.verdict(for: id, in: snapshot(handedOver: WatchHandOver(sessionID: id, discard: true))), .discard)
        // A hand-over of another workout says nothing about this one.
        XCTAssertEqual(WatchRecordingEnd.verdict(for: id, in: snapshot(handedOver: WatchHandOver(sessionID: UUID()))), .save(at: nil))
    }

    func testWatchUsesThePhonesFinishTimeAndDiscards() {
        let finishedAt = t0.addingTimeInterval(3000)
        let summary = WatchFinishSummary(sessionID: id, title: "UPPER", finishedAt: finishedAt, durationSeconds: 3000, completedSets: 10, totalSets: 12)
        XCTAssertEqual(WatchRecordingEnd.verdict(for: id, in: snapshot(finished: summary)), .save(at: finishedAt))
        XCTAssertEqual(WatchRecordingEnd.verdict(for: UUID(), in: snapshot(finished: summary)), .save(at: nil))
        XCTAssertEqual(WatchRecordingEnd.verdict(for: id, in: snapshot(discarded: id)), .discard)
        let planned = WatchSessionSummary(id: id, title: "UPPER", kind: .gym, date: t0, status: "planned")
        XCTAssertEqual(WatchRecordingEnd.verdict(for: id, in: snapshot(upcoming: [planned])), .discard)
        XCTAssertEqual(WatchRecordingEnd.verdict(for: id, in: nil), .save(at: nil))
    }

    // MARK: End time

    func testCollectionEndsAtTheCorrectedTimeOnlyInsideTheRecording() {
        let start = t0
        let now = t0.addingTimeInterval(10 * 3600)
        let lastSet = t0.addingTimeInterval(3600)
        XCTAssertEqual(WatchRecordingEnd.collectionEnd(requested: lastSet, startedAt: start, now: now), lastSet)
        // Nothing asked, an end after now, or one before the recording began: now.
        XCTAssertEqual(WatchRecordingEnd.collectionEnd(requested: nil, startedAt: start, now: now), now)
        XCTAssertEqual(WatchRecordingEnd.collectionEnd(requested: now.addingTimeInterval(5), startedAt: start, now: now), now)
        XCTAssertEqual(WatchRecordingEnd.collectionEnd(requested: start.addingTimeInterval(-60), startedAt: start, now: now), now)
        XCTAssertEqual(WatchRecordingEnd.collectionEnd(requested: start, startedAt: start, now: now), now)
        XCTAssertEqual(WatchRecordingEnd.collectionEnd(requested: lastSet, startedAt: nil, now: now), lastSet)
    }

    func testWatchFinishWaitsForThePhoneOnlyWhenTheEndMayMoveEarlier() {
        XCTAssertTrue(WatchRecordingEnd.waitsForPhoneEnd(kind: .gym, activeSeconds: FinishTime.strengthLimit + 60))
        XCTAssertFalse(WatchRecordingEnd.waitsForPhoneEnd(kind: .gym, activeSeconds: 3600))
        // No believable limit (a long hike, yoga retreat): the tap is the end.
        XCTAssertFalse(WatchRecordingEnd.waitsForPhoneEnd(kind: .cardio, activeSeconds: 10 * 3600))
    }

    func testMovedEndSendsTheWorkoutsOwnNumbers() {
        let end = t0.addingTimeInterval(3600)
        XCTAssertTrue(WatchRecordingEnd.endMovedEarlier(collectionEnd: end, sessionEnd: end.addingTimeInterval(8 * 3600)))
        XCTAssertFalse(WatchRecordingEnd.endMovedEarlier(collectionEnd: end, sessionEnd: end.addingTimeInterval(5)))
    }

    // MARK: Settling

    func testWatchPacketsUpdateTheLink() {
        var link = link()
        link.watchRecording = false
        let live = link.receiving(WatchMetrics(heartRate: 120, sessionID: id), now: t0)
        XCTAssertTrue(live.watchRecording)
        XCTAssertNil(live.watchFinal)
        let saved = UUID()
        let stoppedAt = t0.addingTimeInterval(4000)
        let final = live.receiving(WatchMetrics(averageHeartRate: 110, activeEnergy: 300, healthWorkoutID: saved, endedAt: stoppedAt, sessionID: id), now: t0)
        XCTAssertFalse(final.watchRecording)
        XCTAssertEqual(final.watchWorkoutID, saved)
        XCTAssertEqual(final.watchStoppedAt, stoppedAt)
        // A late live packet doesn't make it record again.
        XCTAssertFalse(final.receiving(WatchMetrics(heartRate: 100, sessionID: id), now: t0).watchRecording)
        // A final packet without an end gets the time it arrived.
        let arrived = t0.addingTimeInterval(5000)
        XCTAssertEqual(live.receiving(WatchMetrics(healthWorkoutID: saved, sessionID: id), now: arrived).watchStoppedAt, arrived)
    }

    func testSettlementLinksDeletesOrWaits() {
        let saved = UUID()
        let final = WatchMetrics(healthWorkoutID: saved, endedAt: t0.addingTimeInterval(3900), sessionID: id)
        let unsaved = WatchMetrics(endedAt: t0.addingTimeInterval(3900), sessionID: id)
        let end = WatchOnlyLink.Ending.save(at: t0.addingTimeInterval(3900))
        XCTAssertEqual(link().settlement(sessionExists: true, sessionPerformed: false), .wait)
        XCTAssertEqual(link(ending: end).settlement(sessionExists: true, sessionPerformed: true), .wait)
        XCTAssertEqual(link(ending: end, final: final).settlement(sessionExists: true, sessionPerformed: true), .link(saved))
        // Ended at its last sign of life on the Mac, not ended there yet: linked once it is.
        XCTAssertEqual(link(ending: end, final: final).settlement(sessionExists: true, sessionPerformed: false), .wait)
        XCTAssertEqual(link(ending: end, final: final).settlement(sessionExists: false, sessionPerformed: false), .drop)
        XCTAssertEqual(link(ending: end, final: unsaved).settlement(sessionExists: true, sessionPerformed: true), .drop)
        XCTAssertEqual(link(ending: .discard).settlement(sessionExists: false, sessionPerformed: false), .wait)
        XCTAssertEqual(link(ending: .discard, final: final).settlement(sessionExists: true, sessionPerformed: true), .deleteWatchWorkout(saved))
        XCTAssertEqual(link(ending: .discard, final: unsaved).settlement(sessionExists: true, sessionPerformed: true), .drop)
    }

    func testLinkExpires() {
        let open = link()
        XCTAssertFalse(open.isExpired(now: open.linkedAt.addingTimeInterval(86_400)))
        XCTAssertTrue(open.isExpired(now: open.linkedAt.addingTimeInterval(WatchOnlyLink.lifetime + 1)))
        let ending = link(ending: .discard)
        let since = try! XCTUnwrap(ending.endingSince)
        XCTAssertFalse(ending.isExpired(now: since.addingTimeInterval(3600)))
        XCTAssertTrue(ending.isExpired(now: since.addingTimeInterval(WatchOnlyLink.settleTime + 1)))
    }

    func testLinkSurvivesARelaunch() throws {
        let stored = link(ending: .save(at: t0.addingTimeInterval(3900)),
                          final: WatchMetrics(averageHeartRate: 120, healthWorkoutID: UUID(), endedAt: t0, sessionID: id))
        let data = try JSONEncoder().encode(stored)
        XCTAssertEqual(try JSONDecoder().decode(WatchOnlyLink.self, from: data), stored)
    }

    // MARK: Late Discard, wording

    func testDiscardClosesFromTheTapFinishForGood() {
        let tap = t0.addingTimeInterval(100)
        XCTAssertEqual(WatchClosing.closedFrom(.discard, tappedAt: tap), tap)
        XCTAssertEqual(WatchClosing.closedFrom(.finish(effort: 6), tappedAt: tap), .distantFuture)
        XCTAssertEqual(WatchClosing.closedFrom(.finish(effort: nil), tappedAt: tap), .distantFuture)
    }

    func testWatchStopWordingSaysWhoSavesWhat() {
        XCTAssertEqual(WatchStopWording.liveNotice(savedPart: true), "Apple Watch stopped recording – George saves the rest from iPhone")
        XCTAssertTrue(WatchStopWording.liveNotice(savedPart: false).contains("whole workout"))
        XCTAssertTrue(WatchStopWording.finishLine(savedPart: true).contains("the rest is saved from iPhone"))
        XCTAssertTrue(WatchStopWording.finishLine(savedPart: false).contains("the whole workout is saved from iPhone"))
    }

    func testEndedMessageNamesTheOtherDevice() {
        XCTAssertEqual(LiveOwnership.endedMessage(title: "UPPER", owner: LiveOwner(id: pad, kind: .pad), localID: here, localKind: .phone),
                       "UPPER was ended on your iPad")
        XCTAssertEqual(LiveOwnership.endedMessage(title: "UPPER", owner: LiveOwner(id: mac, kind: .phone), localID: here, localKind: .phone),
                       "UPPER was ended on your other iPhone")
        // No claim, an unknown kind, or this device's own claim (an older George ended it): "another device".
        XCTAssertEqual(LiveOwnership.endedMessage(title: "UPPER", owner: nil, localID: here, localKind: .phone), "UPPER was ended on another device")
        XCTAssertEqual(LiveOwnership.endedMessage(title: "UPPER", owner: LiveOwner(id: pad, kind: nil), localID: here, localKind: .phone),
                       "UPPER was ended on another device")
        XCTAssertEqual(LiveOwnership.endedMessage(title: "UPPER", owner: LiveOwner(id: here, kind: .phone), localID: here, localKind: .phone),
                       "UPPER was ended on another device")
        XCTAssertEqual(LiveOwnership.endedMessage(title: " ", owner: nil, localID: here, localKind: .phone), "The workout was ended on another device")
    }
}
