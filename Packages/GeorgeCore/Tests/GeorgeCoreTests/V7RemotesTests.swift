import XCTest
@testable import GeorgeCore

/// v7 lane "remotes": the watch protocol for set commands and per-side holds.
final class V7RemotesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func state(sessionID: UUID = UUID(), setStartedAt: Date? = nil, timedSetSeconds: Int? = nil, timedSides: Int? = nil,
                       isPaused: Bool = false, restEndsAt: Date? = nil) -> WatchLiveState {
        WatchLiveState(sessionID: sessionID, title: "T", kind: .stretch, startedAt: now, accumulatedSeconds: 0, resumedAt: isPaused ? nil : now,
                       isPaused: isPaused, restEndsAt: restEndsAt, restTotalSeconds: restEndsAt == nil ? nil : 60, currentSetID: nil,
                       exercises: [], completedSets: 0, totalSets: 0, setStartedAt: setStartedAt, timedSetSeconds: timedSetSeconds,
                       timedSides: timedSides)
    }

    // MARK: Set commands

    func testSetCommandsCountHoweverLateForTheSameWorkout() {
        let session = UUID()
        let lateTick = WatchCommandEnvelope(command: .completeSet(id: UUID(), reps: nil, weightKg: nil), sentAt: now.addingTimeInterval(-40 * 60), sessionID: session)
        XCTAssertTrue(lateTick.isFresh(activeSessionID: session, now: now), "a tick made out of range still counts")
        XCTAssertFalse(lateTick.isFresh(activeSessionID: UUID(), now: now), "never for another workout")
        XCTAssertFalse(lateTick.isFresh(activeSessionID: nil, now: now))

        let lateUndo = WatchCommandEnvelope(command: .undoSet(UUID()), sentAt: now.addingTimeInterval(-40 * 60), sessionID: session)
        XCTAssertTrue(lateUndo.isFresh(activeSessionID: session, now: now))

        // Without a workout id (older watch) the 15-minute limit still applies.
        let anonymous = WatchCommandEnvelope(command: .completeSet(id: UUID(), reps: nil, weightKg: nil), sentAt: now.addingTimeInterval(-40 * 60), sessionID: nil)
        XCTAssertFalse(anonymous.isFresh(activeSessionID: session, now: now))

        // Commands that act on whatever is current keep the limit.
        let lateCurrent = WatchCommandEnvelope(command: .completeCurrentSet, sentAt: now.addingTimeInterval(-40 * 60), sessionID: session)
        XCTAssertFalse(lateCurrent.isFresh(activeSessionID: session, now: now))
        let lateDrop = WatchCommandEnvelope(command: .dropWeight(setID: UUID(), repsDone: 5, newWeightKg: 50), sentAt: now.addingTimeInterval(-40 * 60), sessionID: session)
        XCTAssertFalse(lateDrop.isFresh(activeSessionID: session, now: now))
        let recentToggle = WatchCommandEnvelope(command: .toggleSet(UUID()), sentAt: now.addingTimeInterval(-60), sessionID: session)
        XCTAssertTrue(recentToggle.isFresh(activeSessionID: session, now: now))

        XCTAssertTrue(lateTick.targetsOneSet)
        XCTAssertTrue(lateUndo.targetsOneSet)
        XCTAssertFalse(lateCurrent.targetsOneSet)
        XCTAssertFalse(recentToggle.targetsOneSet)
    }

    func testUndoSetRoundTripsAndOlderCommandsStillDecode() throws {
        let id = UUID()
        let envelope = WatchCommandEnvelope(command: .undoSet(id), sentAt: now, sessionID: UUID())
        let back = try WatchWire.decoder.decode(WatchCommandEnvelope.self, from: WatchWire.encoder.encode(envelope))
        XCTAssertEqual(back, envelope)
        XCTAssertEqual(back.command, .undoSet(id))

        // Through the dictionary the watch sends.
        let packed = WatchWire.pack(envelope, as: .command)
        XCTAssertEqual(WatchWire.unpack(packed, as: WatchCommandEnvelope.self)?.command, .undoSet(id))

        for command: WatchCommand in [.toggleSet(id), .completeCurrentSet, .completeSet(id: id, reps: 8, weightKg: 60), .recordEnergy(4)] {
            let data = try WatchWire.encoder.encode(command)
            XCTAssertEqual(try WatchWire.decoder.decode(WatchCommand.self, from: data), command)
        }
    }

    // MARK: Per-side holds

    func testPerSideHoldSides() throws {
        let start = now
        // "30 s each side": 60 s in all.
        let live = state(setStartedAt: start, timedSetSeconds: 60, timedSides: 2)
        XCTAssertEqual(live.holdSideCount, 2)

        let first = try XCTUnwrap(live.holdSide(at: start.addingTimeInterval(10)))
        XCTAssertEqual(first.number, 1)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.start, start)
        XCTAssertEqual(first.end, start.addingTimeInterval(30))
        XCTAssertEqual(first.seconds, 30, accuracy: 0.001)
        XCTAssertEqual(first.remaining(at: start.addingTimeInterval(10)), 20, accuracy: 0.001)

        let second = try XCTUnwrap(live.holdSide(at: start.addingTimeInterval(30)))
        XCTAssertEqual(second.number, 2)
        XCTAssertEqual(second.start, start.addingTimeInterval(30))
        XCTAssertEqual(second.end, start.addingTimeInterval(60))
        XCTAssertEqual(second.remaining(at: start.addingTimeInterval(45)), 15, accuracy: 0.001)

        // Over, until the phone logs it: still side 2, nothing left.
        let over = try XCTUnwrap(live.holdSide(at: start.addingTimeInterval(90)))
        XCTAssertEqual(over.number, 2)
        XCTAssertEqual(over.remaining(at: start.addingTimeInterval(90)), 0)

        XCTAssertEqual(live.holdSwitchAt, start.addingTimeInterval(30))
    }

    func testOneSidedPausedOrRestingHoldsHaveNoSides() {
        let start = now
        let oneSided = state(setStartedAt: start, timedSetSeconds: 60)
        XCTAssertEqual(oneSided.holdSideCount, 1)
        XCTAssertNil(oneSided.holdSide(at: start.addingTimeInterval(10)))
        XCTAssertNil(oneSided.holdSwitchAt)

        XCTAssertNil(state(setStartedAt: start, timedSetSeconds: 60, timedSides: 2, isPaused: true).holdSide(at: start))
        XCTAssertNil(state(setStartedAt: start, timedSetSeconds: 60, timedSides: 2, restEndsAt: start.addingTimeInterval(30)).holdSide(at: start))
        XCTAssertNil(state(setStartedAt: nil, timedSetSeconds: 60, timedSides: 2).holdSide(at: start))
        XCTAssertNil(state(setStartedAt: start, timedSetSeconds: nil, timedSides: 2).holdSwitchAt)
        // Nonsense from the wire stays within two sides.
        XCTAssertEqual(state(setStartedAt: start, timedSetSeconds: 60, timedSides: 5).holdSideCount, 2)
    }

    func testLiveStateWithSidesRoundTripsAndOlderPayloadsDecode() throws {
        let session = UUID()
        let live = state(sessionID: session, setStartedAt: now, timedSetSeconds: 60, timedSides: 2)
        let back = try WatchWire.decoder.decode(WatchLiveState.self, from: WatchWire.encoder.encode(live))
        XCTAssertEqual(back, live)
        XCTAssertEqual(back.timedSides, 2)

        // A phone without the field: one-sided, as before.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: WatchWire.encoder.encode(live)) as? [String: Any])
        json.removeValue(forKey: "timedSides")
        let older = try WatchWire.decoder.decode(WatchLiveState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(older.timedSides)
        XCTAssertEqual(older.holdSideCount, 1)
        XCTAssertNil(older.holdSide(at: now.addingTimeInterval(10)))
        XCTAssertEqual(older.timedSetSeconds, 60)
    }
}
