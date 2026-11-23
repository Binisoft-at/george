import XCTest
@testable import GeorgeCore

/// v7 review: backups, sync fingerprint and merging copies from two devices.
final class V7ReviewDataTests: XCTestCase {
    private var utc: TimeZone { TimeZone(identifier: "UTC")! }
    private let start = Date(timeIntervalSince1970: 1_763_800_000)

    private func names(_ count: Int, reason: BackupReason, from first: Date, step: TimeInterval) -> [String] {
        (0..<count).map { BackupSchedule.fileName(at: first.addingTimeInterval(Double($0) * step), reason: reason, timeZone: utc) }
    }

    // MARK: Backups

    func testReasonFromFileName() {
        for reason in BackupReason.allCases {
            XCTAssertEqual(BackupSchedule.reason(fromFileName: BackupSchedule.fileName(at: start, reason: reason, timeZone: utc)), reason)
        }
        XCTAssertNil(BackupSchedule.reason(fromFileName: "My notes (weekly).json"))
        XCTAssertNil(BackupSchedule.reason(fromFileName: "George Backup 2025-11-22 082640 (other).json"))
    }

    func testImportBurstDoesNotPushOutWeeklyBackups() {
        // Six weeks of weekly backups, then ten imports on one day.
        let weekly = names(6, reason: .weekly, from: start, step: 7 * 86_400)
        let imports = names(10, reason: .beforeImport, from: start.addingTimeInterval(50 * 86_400), step: 600)
        let doomed = Set(BackupSchedule.filesToDelete((weekly + imports).shuffled(), keep: 8, keepWeekly: 4, timeZone: utc))
        XCTAssertEqual(doomed, Set(weekly.prefix(2) + imports.prefix(6)), "the 4 newest weekly ones and the 4 newest imports stay")
        XCTAssertEqual(weekly.count + imports.count - doomed.count, 8)
    }

    func testFewWeeklyBackupsLeaveTheRestToOthers() {
        let weekly = names(2, reason: .weekly, from: start, step: 7 * 86_400)
        let restores = names(10, reason: .beforeRestore, from: start.addingTimeInterval(20 * 86_400), step: 600)
        let doomed = Set(BackupSchedule.filesToDelete(weekly + restores, keep: 8, keepWeekly: 4, timeZone: utc))
        XCTAssertEqual(doomed, Set(restores.prefix(4)), "both weekly ones and the 6 newest restores stay")
    }

    func testOnlyWeeklyBackupsKeepTheNewest() {
        let weekly = names(10, reason: .weekly, from: start, step: 7 * 86_400)
        let doomed = Set(BackupSchedule.filesToDelete(weekly, keep: 8, keepWeekly: 4, timeZone: utc))
        XCTAssertEqual(doomed, Set(weekly.prefix(2)))
    }

    // MARK: Sync fingerprint

    private struct PlanRow: Hashable {
        var id: UUID
        var planned: Date?
        var title: String
        var updatedAt: Date
    }

    func testRowStampSeesEditsWithoutNewDate() {
        let stamp = Date(timeIntervalSince1970: 1_000)
        let a = PlanRow(id: UUID(), planned: Date(timeIntervalSince1970: 5_000), title: "UPPER · Mon", updatedAt: stamp)
        let b = PlanRow(id: UUID(), planned: Date(timeIntervalSince1970: 9_000), title: "LOWER · Wed", updatedAt: stamp)
        let before = TableStamp(rows: [a, b], newest: stamp)
        XCTAssertEqual(before, TableStamp(rows: [b, a], newest: stamp), "the order rows are read in doesn't matter")

        // Moved to today on another device: same count, same newest date.
        var moved = a
        moved.planned = Date(timeIntervalSince1970: 7_000)
        moved.title = "UPPER · Tue"
        let after = TableStamp(rows: [moved, b], newest: stamp)
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(after.newest, before.newest)
        XCTAssertNotEqual(after, before)

        let old = SyncFingerprint(performed: [:], tables: ["plans": before], running: [:])
        let new = SyncFingerprint(performed: [:], tables: ["plans": after], running: [:])
        XCTAssertEqual(new.changes(since: old), .data)
        XCTAssertEqual(old.changes(since: old), [])
    }

    // MARK: Merging two devices' copies

    func testMergedExtrasKeepBothSidesKeys() {
        var older = SettingsExtras()
        older.set(true, for: SettingsExtras.Key.thaliaDeliver)
        older.set("kept", for: "future.only.on.older")
        var newer = SettingsExtras()
        newer.set(false, for: SettingsExtras.Key.thaliaDeliver)
        newer.set(3, for: "future.only.on.newer")

        let merged = DuplicateMerge.mergedExtras(newer, over: older)
        XCTAssertEqual(merged.bool(SettingsExtras.Key.thaliaDeliver), false, "the copy changed last wins")
        XCTAssertEqual(merged.string("future.only.on.older"), "kept")
        XCTAssertEqual(merged.number("future.only.on.newer"), 3)
        XCTAssertEqual(DuplicateMerge.mergedExtras(SettingsExtras(), over: older), older)
    }

    func testEditedRoutineCopyWins() {
        let made = Date(timeIntervalSince1970: 10_000)
        let fresh = DuplicateMerge.Stamp(createdAt: made, updatedAt: made)
        let freshLater = DuplicateMerge.Stamp(createdAt: made.addingTimeInterval(3_600), updatedAt: made.addingTimeInterval(3_600))
        let edited = DuplicateMerge.Stamp(createdAt: made.addingTimeInterval(60), updatedAt: made.addingTimeInterval(600))
        let editedLater = DuplicateMerge.Stamp(createdAt: made, updatedAt: made.addingTimeInterval(900))

        XCTAssertTrue(DuplicateMerge.prefersOther(edited, over: fresh), "an edit on the other device survives")
        XCTAssertFalse(DuplicateMerge.prefersOther(freshLater, over: edited), "a fresh copy made later never replaces an edit")
        XCTAssertFalse(DuplicateMerge.prefersOther(freshLater, over: fresh), "two fresh copies: the kept one stays as it is")
        XCTAssertTrue(DuplicateMerge.prefersOther(editedLater, over: edited), "both edited: the later edit")
        XCTAssertFalse(DuplicateMerge.prefersOther(edited, over: editedLater))
    }
}
