import XCTest
@testable import GeorgeCore

/// v7 wave 2, lane "finish": when a finished workout ended, what Apple Health gets for it, and how
/// the watch's own Health workout is linked (never twice, never a junk one).
final class V7W2FinishTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    // MARK: End time

    func testFinishTheNextMorningEndsAtTheLastSetForStrength() {
        // Started 14 h ago, last set 13 h ago, the clock ran on all night.
        let start = at(-14 * 60)
        let lastSet = at(-13 * 60)
        let clock = LiveClock(startedAt: start, accumulatedSeconds: 0, resumedAt: start)
        let suggested = FinishTime.suggestedEnd(lastActivity: lastSet, restSeconds: 90, pausedAt: nil, now: now)
        XCTAssertEqual(suggested, lastSet.addingTimeInterval(90))
        let end = FinishTime.resolvedEnd(requested: nil, chosen: false, clock: clock, kind: .gym, suggestedEnd: suggested, now: now)
        XCTAssertEqual(end, suggested)
        XCTAssertEqual(clock.activeSeconds(until: end), 3600 + 90, accuracy: 0.001)

        // A tennis match isn't cut, and a time chosen on the finish sheet is kept.
        XCTAssertEqual(FinishTime.resolvedEnd(requested: nil, chosen: false, clock: clock, kind: .sport, suggestedEnd: suggested, now: now), now)
        XCTAssertEqual(FinishTime.resolvedEnd(requested: now, chosen: true, clock: clock, kind: .gym, suggestedEnd: suggested, now: now), now)
        XCTAssertEqual(FinishTime.resolvedEnd(requested: at(-30), chosen: true, clock: clock, kind: .gym, suggestedEnd: suggested, now: now), at(-30))
    }

    func testANormalWorkoutKeepsItsEnd() {
        let start = at(-75)
        let clock = LiveClock(startedAt: start, accumulatedSeconds: 0, resumedAt: start)
        let suggested = FinishTime.suggestedEnd(lastActivity: at(-2), restSeconds: 120, pausedAt: nil, now: now)
        XCTAssertEqual(suggested, now, "never later than now")
        XCTAssertEqual(FinishTime.resolvedEnd(requested: nil, chosen: false, clock: clock, kind: .gym, suggestedEnd: suggested, now: now), now)
    }

    func testEndsAreClampedIntoTheWorkout() {
        let start = at(-60)
        let clock = LiveClock(startedAt: start, accumulatedSeconds: 0, resumedAt: start)
        // A watch tap with a clock a little ahead, and a time before the start.
        XCTAssertEqual(FinishTime.resolvedEnd(requested: at(1), chosen: false, clock: clock, kind: .gym, suggestedEnd: nil, now: now), now)
        XCTAssertEqual(FinishTime.resolvedEnd(requested: at(-90), chosen: true, clock: clock, kind: .gym, suggestedEnd: nil, now: now), start)
        // The watch's Finish counts from its tap, also when it arrives an hour later …
        XCTAssertEqual(FinishTime.resolvedEnd(requested: at(-50), chosen: false, clock: clock, kind: .gym, suggestedEnd: nil, now: now), at(-50))
        XCTAssertEqual(FinishTime.resolvedEnd(requested: at(-50), chosen: false, clock: clock, kind: .gym, suggestedEnd: nil,
                                              lastActivity: at(-55), now: now), at(-50))
        // … unless the workout went on here after the tap.
        XCTAssertEqual(FinishTime.resolvedEnd(requested: at(-50), chosen: false, clock: clock, kind: .gym, suggestedEnd: nil,
                                              lastActivity: at(-20), now: now), at(-20))
        // A time chosen on the finish sheet stays as chosen.
        XCTAssertEqual(FinishTime.resolvedEnd(requested: at(-50), chosen: true, clock: clock, kind: .gym, suggestedEnd: nil,
                                              lastActivity: at(-20), now: now), at(-50))
    }

    func testRestAfterTheLastSetIsCappedAndAPauseCanBeTheEnd() {
        let last = at(-200)
        XCTAssertEqual(FinishTime.suggestedEnd(lastActivity: last, restSeconds: 3600, pausedAt: nil, now: now), last.addingTimeInterval(FinishTime.maxRest))
        XCTAssertEqual(FinishTime.suggestedEnd(lastActivity: last, restSeconds: -5, pausedAt: nil, now: now), last)
        XCTAssertEqual(FinishTime.suggestedEnd(lastActivity: last, restSeconds: 60, pausedAt: at(-150), now: now), at(-150))
    }

    func testIdleTime() {
        XCTAssertEqual(FinishTime.idleSeconds(lastActivity: at(-200), pausedAt: nil, now: now), 200 * 60, accuracy: 0.001)
        XCTAssertEqual(FinishTime.idleSeconds(lastActivity: at(-200), pausedAt: at(-10), now: now), 10 * 60, accuracy: 0.001)
        XCTAssertEqual(FinishTime.idleSeconds(lastActivity: nil, pausedAt: nil, now: now), 0)
        XCTAssertGreaterThan(FinishTime.idleSeconds(lastActivity: at(-200), pausedAt: nil, now: now), FinishTime.stillTrainingAfter)
    }

    func testActiveSecondsUpToAnEarlierEnd() {
        // Running since 30 min ago with 20 min before that.
        let running = LiveClock(startedAt: at(-90), accumulatedSeconds: 1200, resumedAt: at(-30))
        XCTAssertEqual(running.activeSeconds(until: now), 1200 + 1800, accuracy: 0.001)
        XCTAssertEqual(running.activeSeconds(until: at(-10)), 1200 + 1200, accuracy: 0.001)
        XCTAssertEqual(running.activeSeconds(until: at(-40)), 600, accuracy: 0.001, "an end before the resume takes that time off")
        // Paused 20 min ago with 50 min done.
        let paused = LiveClock(startedAt: at(-90), accumulatedSeconds: 3000, resumedAt: nil, pausedAt: at(-20))
        XCTAssertEqual(paused.activeSeconds(until: now), 3000, accuracy: 0.001)
        XCTAssertEqual(paused.activeSeconds(until: at(-30)), 2400, accuracy: 0.001)
        // Never more than the time since the start, never negative.
        let odd = LiveClock(startedAt: at(-10), accumulatedSeconds: 5000, resumedAt: nil)
        XCTAssertEqual(odd.activeSeconds(until: now), 600, accuracy: 0.001)
        XCTAssertEqual(LiveClock(startedAt: nil, accumulatedSeconds: 10, resumedAt: now).activeSeconds(until: at(-5)), 0)
    }

    func testOnlyStrengthKindsHaveALimit() {
        XCTAssertEqual(FinishTime.plausibleActiveSeconds(for: .gym), 4 * 3600)
        XCTAssertEqual(FinishTime.plausibleActiveSeconds(for: .band), 4 * 3600)
        XCTAssertEqual(FinishTime.plausibleActiveSeconds(for: .bodyweight), 4 * 3600)
        XCTAssertNil(FinishTime.plausibleActiveSeconds(for: .sport))
        XCTAssertNil(FinishTime.plausibleActiveSeconds(for: .yoga))
        XCTAssertNil(FinishTime.plausibleActiveSeconds(for: WorkoutKind("hiking")))
    }

    // MARK: What Apple Health gets

    func testAWholeWorkoutGoesToHealthWithItsPauses() throws {
        let pauses = [PauseSpan(start: at(-40), end: at(-30))]
        let span = try XCTUnwrap(FinishTime.healthSpan(start: at(-60), end: now, activeSeconds: 3000, continuedAt: nil,
                                                       activeBeforeContinuing: 0, watchStoppedAt: nil, pauses: pauses))
        XCTAssertEqual(span.start, at(-60))
        XCTAssertEqual(span.end, now)
        XCTAssertEqual(span.activeSeconds, 3000)
        XCTAssertEqual(span.pauses, pauses)
    }

    func testAContinuedWorkoutAddsOnlyTheNewPart() throws {
        // Stopped early two days ago after 40 min, continued 30 min ago.
        let firstStart = at(-2 * 24 * 60)
        let span = try XCTUnwrap(FinishTime.healthSpan(start: firstStart, end: now, activeSeconds: 2400 + 1800, continuedAt: at(-30),
                                                       activeBeforeContinuing: 2400, watchStoppedAt: nil,
                                                       pauses: [PauseSpan(start: at(-20), end: at(-15))]))
        XCTAssertEqual(span.start, at(-30))
        XCTAssertEqual(span.activeSeconds, 1800, accuracy: 0.001)
        XCTAssertEqual(span.pauses.count, 1)
        // Ended (by a chosen time) before it was continued: nothing new for Health.
        XCTAssertNil(FinishTime.healthSpan(start: firstStart, end: at(-40), activeSeconds: 2400, continuedAt: at(-30),
                                           activeBeforeContinuing: 2400, watchStoppedAt: nil, pauses: []))
    }

    func testAfterTheWatchStoppedOnlyTheRestIsSaved() throws {
        let span = try XCTUnwrap(FinishTime.healthSpan(start: at(-60), end: now, activeSeconds: 3600, continuedAt: nil,
                                                       activeBeforeContinuing: 0, watchStoppedAt: at(-20),
                                                       pauses: [PauseSpan(start: at(-10), end: at(-5))]))
        XCTAssertEqual(span.start, at(-20))
        XCTAssertEqual(span.activeSeconds, 15 * 60, accuracy: 0.001, "20 min minus the 5 min pause")
        // The watch stopped as the workout was finished on it: nothing left for the iPhone.
        XCTAssertNil(FinishTime.healthSpan(start: at(-60), end: now, activeSeconds: 3600, continuedAt: nil,
                                           activeBeforeContinuing: 0, watchStoppedAt: now.addingTimeInterval(-30), pauses: []))
        XCTAssertNil(FinishTime.healthSpan(start: at(-60), end: now, activeSeconds: 3600, continuedAt: nil,
                                           activeBeforeContinuing: 0, watchStoppedAt: now.addingTimeInterval(5), pauses: []))
    }

    // MARK: Pauses

    func testThePauseLog() {
        var log: [PauseSpan] = []
        log = PauseLog.pausing(log, at: at(-30))
        log = PauseLog.pausing(log, at: at(-29))
        XCTAssertEqual(log, [PauseSpan(start: at(-30))], "a second pause while paused changes nothing")
        log = PauseLog.resuming(log, at: at(-20))
        log = PauseLog.resuming(log, at: at(-19))
        XCTAssertEqual(log, [PauseSpan(start: at(-30), end: at(-20))])
        log = PauseLog.pausing(log, at: at(-5))
        XCTAssertEqual(PauseLog.pausedSeconds(log, from: at(-60), to: now), 15 * 60, accuracy: 0.001)

        // Cut to a window: a pause across its start begins there, one past its end stays open.
        let clipped = PauseLog.clipped(log, from: at(-25), to: at(-10))
        XCTAssertEqual(clipped, [PauseSpan(start: at(-25), end: at(-20))])
        XCTAssertEqual(PauseLog.clipped(log, from: at(-25), to: now), [PauseSpan(start: at(-25), end: at(-20)), PauseSpan(start: at(-5), end: nil)])
        XCTAssertEqual(PauseLog.clipped([PauseSpan(start: at(-30), end: at(-28))], from: at(-25), to: now), [])
        XCTAssertEqual(PauseLog.clipped([PauseSpan(start: at(-30), end: at(-5))], from: at(-60), to: at(-10)), [PauseSpan(start: at(-30), end: nil)])

        var long: [PauseSpan] = []
        for minute in 0..<(PauseLog.limit + 5) {
            long = PauseLog.pausing(long, at: at(Double(minute)))
            long = PauseLog.resuming(long, at: at(Double(minute) + 0.5))
        }
        XCTAssertEqual(long.count, PauseLog.limit)
    }

    func testPausesSurviveARelaunch() throws {
        let log = [PauseSpan(start: at(-30), end: at(-20)), PauseSpan(start: at(-5))]
        let back = try JSONDecoder().decode([PauseSpan].self, from: JSONEncoder().encode(log))
        XCTAssertEqual(back, log)
    }

    // MARK: The watch's Health workout

    func testWatchFinishAndDiscardCountHoweverLate() {
        let session = UUID()
        let lateFinish = WatchCommandEnvelope(command: .finish(effort: 7), sentAt: now.addingTimeInterval(-3 * 3600), sessionID: session)
        XCTAssertTrue(lateFinish.endsWorkout)
        XCTAssertTrue(lateFinish.isFresh(activeSessionID: session, now: now), "a Finish queued out of range still ends the workout")
        XCTAssertFalse(lateFinish.isFresh(activeSessionID: UUID(), now: now), "never another workout")
        XCTAssertFalse(lateFinish.isFresh(activeSessionID: nil, now: now))
        let lateDiscard = WatchCommandEnvelope(command: .discard, sentAt: now.addingTimeInterval(-40 * 60), sessionID: session)
        XCTAssertTrue(lateDiscard.isFresh(activeSessionID: session, now: now))
        // Without a workout id (older watch) the 15-minute limit still applies.
        let anonymous = WatchCommandEnvelope(command: .finish(effort: nil), sentAt: now.addingTimeInterval(-40 * 60), sessionID: nil)
        XCTAssertFalse(anonymous.isFresh(activeSessionID: session, now: now))
        XCTAssertFalse(WatchCommandEnvelope(command: .pause, sentAt: now, sessionID: session).endsWorkout)
    }

    func testWatchMetricsCarryTheWorkoutAndOldOnesStillDecode() throws {
        let session = UUID()
        let workout = UUID()
        let metrics = WatchMetrics(averageHeartRate: 120, activeEnergy: 300, healthWorkoutID: workout, endedAt: now, sessionID: session)
        let back = try WatchWire.decoder.decode(WatchMetrics.self, from: WatchWire.encoder.encode(metrics))
        XCTAssertEqual(back, metrics)
        XCTAssertEqual(back.sessionID, session)
        XCTAssertTrue(back.isFinal)
        XCTAssertFalse(WatchMetrics(heartRate: 100, sessionID: session).isFinal)
        XCTAssertTrue(WatchMetrics(endedAt: now).isFinal)

        // An older watch's packet (no session id).
        let old = Data(#"{"heartRate":101,"averageHeartRate":99}"#.utf8)
        let decoded = try WatchWire.decoder.decode(WatchMetrics.self, from: old)
        XCTAssertEqual(decoded.heartRate, 101)
        XCTAssertNil(decoded.sessionID)
        XCTAssertFalse(decoded.isFinal)
    }

    func testWhetherTheWatchSavesAndWhenFinishWaits() {
        XCTAssertTrue(HealthLink.watchSaves(watchHeard: true, watchWorkoutID: nil, watchStoppedAt: nil))
        XCTAssertTrue(HealthLink.watchSaves(watchHeard: false, watchWorkoutID: UUID(), watchStoppedAt: nil))
        XCTAssertFalse(HealthLink.watchSaves(watchHeard: false, watchWorkoutID: nil, watchStoppedAt: nil))
        XCTAssertFalse(HealthLink.watchSaves(watchHeard: false, watchWorkoutID: UUID(), watchStoppedAt: now), "stopped on the way: the iPhone saves the rest")

        XCTAssertTrue(HealthLink.waitsForWatch(expected: true, watchHeard: false, watchWorkoutID: nil, watchStoppedAt: nil, reachable: true))
        XCTAssertFalse(HealthLink.waitsForWatch(expected: true, watchHeard: true, watchWorkoutID: nil, watchStoppedAt: nil, reachable: true))
        XCTAssertFalse(HealthLink.waitsForWatch(expected: true, watchHeard: false, watchWorkoutID: nil, watchStoppedAt: nil, reachable: false))
        XCTAssertFalse(HealthLink.waitsForWatch(expected: false, watchHeard: false, watchWorkoutID: nil, watchStoppedAt: nil, reachable: true))
        XCTAssertFalse(HealthLink.waitsForWatch(expected: true, watchHeard: false, watchWorkoutID: nil, watchStoppedAt: now, reachable: true))
    }

    func testLinkingTheWatchWorkout() {
        let watch = UUID()
        let phone = UUID()
        let earlier = UUID()
        // Nothing linked yet: the watch's workout is the link.
        XCTAssertEqual(HealthLink.plan(watchWorkoutID: watch, linkedID: nil, phoneSavedID: nil), HealthLink.Plan(linkID: watch, deleteID: nil))
        // The iPhone saved its own without hearing from the watch: replaced, and the iPhone's goes.
        XCTAssertEqual(HealthLink.plan(watchWorkoutID: watch, linkedID: phone, phoneSavedID: phone), HealthLink.Plan(linkID: watch, deleteID: phone))
        // A continued workout keeps the link of its first part; the iPhone's copy of this part goes.
        XCTAssertEqual(HealthLink.plan(watchWorkoutID: watch, linkedID: earlier, phoneSavedID: phone), HealthLink.Plan(linkID: nil, deleteID: phone))
        XCTAssertEqual(HealthLink.plan(watchWorkoutID: watch, linkedID: earlier, phoneSavedID: nil), HealthLink.Plan(linkID: nil, deleteID: nil))
        // The same message twice changes nothing.
        XCTAssertEqual(HealthLink.plan(watchWorkoutID: watch, linkedID: watch, phoneSavedID: nil), HealthLink.Plan(linkID: nil, deleteID: nil))
    }

    func testPendingLinksAreKeptForAFewDays() throws {
        let a = PendingHealthLink(sessionID: UUID(), effort: 7, finishedAt: at(-10), phoneWorkoutID: UUID())
        let b = PendingHealthLink(sessionID: UUID(), effort: 5, finishedAt: at(-4 * 24 * 60))
        var links = PendingHealthLink.adding(a, to: [b], now: now)
        XCTAssertEqual(links, [a], "expired ones go")
        let newer = PendingHealthLink(sessionID: a.sessionID, effort: 8, finishedAt: at(-1))
        links = PendingHealthLink.adding(newer, to: links, now: now)
        XCTAssertEqual(links, [newer], "one per workout")
        XCTAssertEqual(PendingHealthLink.removing(a.sessionID, from: links), [])

        var many: [PendingHealthLink] = []
        for minute in 0..<30 {
            many = PendingHealthLink.adding(PendingHealthLink(sessionID: UUID(), effort: 6, finishedAt: at(-Double(minute))), to: many, now: now)
        }
        XCTAssertEqual(many.count, PendingHealthLink.limit)
        XCTAssertEqual(many.first?.finishedAt, now, "the newest are kept")

        let back = try JSONDecoder().decode([PendingHealthLink].self, from: JSONEncoder().encode([a]))
        XCTAssertEqual(back, [a])
    }
}
