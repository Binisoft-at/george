import XCTest
import BinisoftKitCore
@testable import GeorgeCore

/// v7 wave 3, lane "lists": one Delete rule for a workout running on another device, and when a
/// restore asks first because this device may be behind iCloud.
final class V7W3ListsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Delete

    func testDeleteRouteFollowsWhereTheWorkoutRuns() {
        XCTAssertEqual(SessionDelete.route(isActive: false, isLiveHere: false), .delete)
        XCTAssertEqual(SessionDelete.route(isActive: true, isLiveHere: false), .confirmRunningElsewhere)
        XCTAssertEqual(SessionDelete.route(isActive: true, isLiveHere: true), .discardInLive)
        // Live mode here wins even before the synced status says "in progress".
        XCTAssertEqual(SessionDelete.route(isActive: false, isLiveHere: true), .discardInLive)
    }

    func testRunningElsewhereTitleAndMessage() {
        let phone = LiveOwner(id: "other", kind: .phone)
        XCTAssertEqual(LiveOwnership.runningTitle(owner: phone, localID: "me", localKind: .mac), "Running on your iPhone")
        XCTAssertEqual(LiveOwnership.runningTitle(owner: nil, localID: "me", localKind: .mac), "Running on another device")
        XCTAssertEqual(SessionDelete.stopsThereToo, "It stops there too.")
    }

    func testBulkWithoutRunningWorkoutsDeletesAllWithThePlainQuestion() {
        let bulk = SessionDelete.bulk([
            .init(isActive: false, isLiveHere: false),
            .init(isActive: false, isLiveHere: false),
        ])
        XCTAssertEqual(bulk.deleted, [0, 1])
        XCTAssertFalse(bulk.keptRunningHere)
        XCTAssertNil(bulk.message)
    }

    func testBulkAsksOnceWhenOneRunsElsewhere() {
        let bulk = SessionDelete.bulk([
            .init(isActive: false, isLiveHere: false),
            .init(isActive: true, isLiveHere: false, deviceName: "your iPhone"),
            .init(isActive: false, isLiveHere: false),
        ])
        XCTAssertEqual(bulk.deleted, [0, 1, 2])
        XCTAssertEqual(bulk.message, "Running on your iPhone. It stops there too.")
    }

    func testBulkKeepsTheWorkoutRunningHere() {
        let bulk = SessionDelete.bulk([
            .init(isActive: true, isLiveHere: true, deviceName: "your Mac"),
            .init(isActive: false, isLiveHere: false),
        ])
        XCTAssertEqual(bulk.deleted, [1])
        XCTAssertTrue(bulk.keptRunningHere)
        XCTAssertNil(bulk.message, "the one running here isn't deleted, so nothing stops elsewhere")
    }

    func testBulkMessageForSeveralRunningElsewhere() {
        XCTAssertEqual(SessionDelete.elsewhereMessage(["your iPhone", "your iPhone"]),
                       "2 are running on your iPhone. They stop there too.")
        XCTAssertEqual(SessionDelete.elsewhereMessage(["your iPhone", "your iPad"]),
                       "2 are running on other devices. They stop there too.")
        XCTAssertNil(SessionDelete.elsewhereMessage([]))
    }

    // MARK: Restore

    func testRestoreDoesNotAskWithoutICloud() {
        XCTAssertNil(RestoreCaution.evaluate(syncs: false, importSeen: false, lastImport: nil, syncProblem: true, now: now))
    }

    func testRestoreAsksWhileTheFirstImportIsPending() {
        XCTAssertEqual(RestoreCaution.evaluate(syncs: true, importSeen: false, lastImport: nil, syncProblem: false, now: now),
                       .firstImportPending)
        // A sync problem on a new device still reads as "not loaded yet".
        XCTAssertEqual(RestoreCaution.evaluate(syncs: true, importSeen: false, lastImport: nil, syncProblem: true, now: now),
                       .firstImportPending)
    }

    func testRestoreAsksWhenTheLastImportIsOld() {
        let fresh = now.addingTimeInterval(-10 * 60)
        let edge = now.addingTimeInterval(-RestoreCaution.staleAfter)
        let old = now.addingTimeInterval(-RestoreCaution.staleAfter - 60)
        XCTAssertNil(RestoreCaution.evaluate(syncs: true, importSeen: true, lastImport: fresh, syncProblem: false, now: now))
        XCTAssertNil(RestoreCaution.evaluate(syncs: true, importSeen: true, lastImport: edge, syncProblem: false, now: now))
        XCTAssertEqual(RestoreCaution.evaluate(syncs: true, importSeen: true, lastImport: old, syncProblem: false, now: now), .mayBeBehind)
        // Seen before, but no time kept (an older build): asks.
        XCTAssertEqual(RestoreCaution.evaluate(syncs: true, importSeen: true, lastImport: nil, syncProblem: false, now: now), .mayBeBehind)
    }

    func testRestoreAsksWhileSyncHasAProblem() {
        let fresh = now.addingTimeInterval(-60)
        XCTAssertEqual(RestoreCaution.evaluate(syncs: true, importSeen: true, lastImport: fresh, syncProblem: true, now: now), .mayBeBehind)
    }

    func testSyncProblemFromSyncState() {
        let ok = SyncState(mode: .iCloud(container: "iCloud.test"), account: .available)
        XCTAssertFalse(RestoreCaution.hasSyncProblem(ok))
        XCTAssertFalse(RestoreCaution.hasSyncProblem(SyncState(mode: .iCloud(container: "iCloud.test"), account: .unknown)))
        XCTAssertTrue(RestoreCaution.hasSyncProblem(SyncState(mode: .iCloud(container: "iCloud.test"), account: .available, lastError: "No network")))
        XCTAssertTrue(RestoreCaution.hasSyncProblem(SyncState(mode: .iCloud(container: "iCloud.test"), account: .noAccount)))
        XCTAssertTrue(RestoreCaution.hasSyncProblem(SyncState(mode: .iCloud(container: "iCloud.test"), account: .temporarilyUnavailable)))

        let fresh = now.addingTimeInterval(-60)
        XCTAssertNil(RestoreCaution.evaluate(ok, importSeen: true, lastImport: fresh, now: now))
        XCTAssertEqual(RestoreCaution.evaluate(ok, importSeen: false, lastImport: nil, now: now), .firstImportPending)
        XCTAssertNil(RestoreCaution.evaluate(SyncState(mode: .local(reason: nil)), importSeen: false, lastImport: nil, now: now))
    }

    func testRestoreTexts() {
        XCTAssertEqual(RestoreCaution.firstImportPending.alertTitle, "Restore Before iCloud Is Done?")
        XCTAssertTrue(RestoreCaution.mayBeBehind.note.hasPrefix("This device may not have the newest data from iCloud yet."))
        XCTAssertTrue(RestoreCaution.mayBeBehind.alertMessage.contains("bring back copies of workouts"))
    }
}
