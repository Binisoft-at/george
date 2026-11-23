import XCTest
@testable import GeorgeCore

/// v7 wave 2, lane "perfcore": which counters a save or an iCloud import moves, the history index
/// that decodes only what changed, and decoding many workouts at once.
final class V7W2PerfcoreTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func day(_ n: Double) -> Date { base.addingTimeInterval(n * 86_400) }

    private func stamp(_ updated: Double, status: String = "completed", effort: Int = 0, title: String = "UPPER") -> HistoryStamp {
        HistoryStamp(updatedAt: day(updated), status: status, title: title, kind: "gym", startedAt: day(updated),
                     accumulatedSeconds: 3600, effort: effort)
    }

    private func entry(_ id: UUID, date: Date, stamp: HistoryStamp, sets: Int = 3) -> HistoryIndex.Entry {
        let item = WorkoutItem(name: "Bench", sets: (0..<sets).map { _ in WorkoutSet(reps: 8, weight: 60, isDone: true) })
        let record = SessionRecord(id: id, date: date, title: stamp.title, kind: .gym, durationSeconds: 3600,
                                   isCompleted: true, content: WorkoutContent(blocks: [WorkoutBlock(items: [item])]))
        return HistoryIndex.Entry(stamp: stamp, record: record, effort: stamp.effort)
    }

    // MARK: What a save moves

    func testOnlyPerformedWorkoutsMoveTheHistory() {
        XCTAssertEqual(StoreChange.session(isPerformed: false, wasPerformed: false), .data,
                       "a planned or running workout (a set ticked, Start) is no history change")
        XCTAssertEqual(StoreChange.session(isPerformed: true, wasPerformed: false), [.data, .history], "finished or logged")
        XCTAssertEqual(StoreChange.session(isPerformed: false, wasPerformed: true), [.data, .history], "marked as not done")
        XCTAssertEqual(StoreChange.session(isPerformed: true, wasPerformed: true), [.data, .history], "a past workout edited")
        XCTAssertTrue(StoreChange.all.contains([.data, .history, .live]))
    }

    // MARK: History index

    func testTheHistoryIndexDecodesOnlyWhatChanged() {
        let a = UUID(), b = UUID(), c = UUID()
        var index = HistoryIndex()
        var decoded: [[UUID]] = []
        let first: [UUID: HistoryStamp] = [a: stamp(1), b: stamp(2), c: stamp(3)]
        let built = index.update(to: first) { ids in
            decoded.append(ids)
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, self.entry($0, date: first[$0]!.updatedAt, stamp: first[$0]!)) })
        }
        XCTAssertTrue(built)
        XCTAssertEqual(Set(decoded.first ?? []), [a, b, c])
        XCTAssertEqual(index.records.map(\.id), [a, b, c], "oldest first")
        XCTAssertEqual(index.version, 1)

        // Nothing changed (a template edit, a running workout's set): no decode, no new version.
        decoded = []
        XCTAssertFalse(index.update(to: first) { ids in
            decoded.append(ids)
            return [:]
        })
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertEqual(index.version, 1)

        // One workout edited (its effort), one deleted, one new: only the edited and the new are decoded.
        let d = UUID()
        var next = first
        next[b] = stamp(2, effort: 8)
        next[c] = nil
        next[d] = stamp(4)
        XCTAssertTrue(index.update(to: next) { ids in
            decoded.append(ids)
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, self.entry($0, date: next[$0]!.startedAt!, stamp: next[$0]!)) })
        })
        XCTAssertEqual(Set(decoded.first ?? []), [b, d])
        XCTAssertEqual(index.records.map(\.id), [a, b, d])
        XCTAssertEqual(index.effort(of: b), 8)
        XCTAssertFalse(index.contains(c))
        XCTAssertEqual(index.version, 2)
    }

    func testAWorkoutThatCantBeReadAnyMoreIsLeftOut() {
        let a = UUID(), b = UUID()
        var index = HistoryIndex()
        let stamps: [UUID: HistoryStamp] = [a: stamp(1), b: stamp(2)]
        index.update(to: stamps) { _ in [a: self.entry(a, date: self.day(1), stamp: stamps[a]!)] }
        XCTAssertEqual(index.records.map(\.id), [a])
        XCTAssertFalse(index.contains(b))
        // Asked again next time (it is still in the stamps).
        var asked: [UUID] = []
        index.update(to: stamps) { ids in
            asked = ids
            return [:]
        }
        XCTAssertEqual(asked, [b])
    }

    func testWorkoutsAtTheSameMomentKeepOneOrder() {
        let ids = (0..<6).map { _ in UUID() }
        let stamps = Dictionary(uniqueKeysWithValues: ids.map { ($0, stamp(1)) })
        var first = HistoryIndex()
        first.update(to: stamps) { requested in
            Dictionary(uniqueKeysWithValues: requested.map { ($0, self.entry($0, date: self.day(1), stamp: stamps[$0]!)) })
        }
        var second = HistoryIndex()
        second.update(to: stamps) { requested in
            Dictionary(uniqueKeysWithValues: requested.reversed().map { ($0, self.entry($0, date: self.day(1), stamp: stamps[$0]!)) })
        }
        XCTAssertEqual(first.records.map(\.id), second.records.map(\.id))
        XCTAssertEqual(first.records.map(\.id), ids.sorted { $0.uuidString < $1.uuidString })
    }

    func testEveryStampFieldCounts() {
        let base = stamp(1)
        var variants: [HistoryStamp] = []
        var s = base; s.updatedAt = day(2); variants.append(s)
        s = base; s.status = "partial"; variants.append(s)
        s = base; s.title = "LOWER"; variants.append(s)
        s = base; s.kind = "sport"; variants.append(s)
        s = base; s.startedAt = day(3); variants.append(s)
        s = base; s.plannedDate = day(3); variants.append(s)
        s = base; s.endedAt = day(3); variants.append(s)
        s = base; s.accumulatedSeconds = 60; variants.append(s)
        s = base; s.resumedAt = day(3); variants.append(s)
        s = base; s.energyKcal = 300; variants.append(s)
        s = base; s.effort = 7; variants.append(s)
        let id = UUID()
        var index = HistoryIndex()
        index.update(to: [id: base]) { _ in [id: self.entry(id, date: self.day(1), stamp: base)] }
        for variant in variants {
            XCTAssertEqual(index.changes(to: [id: variant]).changed, [id])
        }
        XCTAssertTrue(index.changes(to: [id: base]).changed.isEmpty)
    }

    // MARK: After an iCloud import

    private func fingerprint(performed: [UUID: HistoryStamp] = [:], templates: Int = 3, templatesNewest: Double = 1,
                             running: [UUID: RunningStamp] = [:]) -> SyncFingerprint {
        SyncFingerprint(performed: performed,
                        tables: ["templates": TableStamp(count: templates, newest: day(templatesNewest)),
                                 "settings": TableStamp(count: 1, newest: day(0))],
                        running: running)
    }

    private func running(done: Int, paused: Bool = false, owner: String? = "iphone:A", updated: Double = 5) -> RunningStamp {
        RunningStamp(state: RunningStamp.State(owner: owner, claimedAt: day(5), isPaused: paused),
                     progress: RunningStamp.Progress(updatedAt: day(updated), doneSets: done, totalSets: 12))
    }

    func testAnImportMovesOnlyWhatItChanged() {
        let workout = UUID(), live = UUID()
        let before = fingerprint(performed: [workout: stamp(1)], running: [live: running(done: 3)])
        XCTAssertEqual(before.changes(since: nil), .all, "the first import refreshes everything")
        XCTAssertEqual(before.changes(since: before), [], "an import that changed nothing moves nothing")

        // A set ticked on the iPhone while the Mac sits idle: only the running bars.
        let ticked = fingerprint(performed: [workout: stamp(1)], running: [live: running(done: 4, updated: 5.01)])
        XCTAssertEqual(ticked.changes(since: before), .live)

        // Paused there, or continued on another device: lists and Today show that.
        XCTAssertEqual(fingerprint(performed: [workout: stamp(1)], running: [live: running(done: 3, paused: true)]).changes(since: before), [.data, .live])
        XCTAssertEqual(fingerprint(performed: [workout: stamp(1)], running: [live: running(done: 3, owner: "mac:B")]).changes(since: before), [.data, .live])

        // A template edited elsewhere: the data, not the history.
        XCTAssertEqual(fingerprint(performed: [workout: stamp(1)], templatesNewest: 6, running: [live: running(done: 3)]).changes(since: before), .data)
        XCTAssertEqual(fingerprint(performed: [workout: stamp(1)], templates: 4, running: [live: running(done: 3)]).changes(since: before), .data)

        // Finished there: the running one is gone and a performed one is new.
        let finished = fingerprint(performed: [workout: stamp(1), live: stamp(5)])
        XCTAssertEqual(finished.changes(since: before), [.history, .data, .live])

        // A past workout edited or deleted elsewhere.
        XCTAssertEqual(fingerprint(performed: [workout: stamp(1, effort: 9)], running: [live: running(done: 3)]).changes(since: before), [.history, .data])
        XCTAssertEqual(fingerprint(performed: [:], running: [live: running(done: 3)]).changes(since: before), [.history, .data])
    }

    // MARK: Decoding many workouts

    func testDecodingManyAtOnceGivesTheSameAsOneByOne() throws {
        var blobs: [Data?] = []
        for n in 0..<40 {
            let item = WorkoutItem(name: "Row \(n)", sets: (0...(n % 5)).map { WorkoutSet(reps: $0 + 5, weight: Double(n), isDone: n % 2 == 0, doneAt: n % 2 == 0 ? base : nil) })
            blobs.append(try WorkoutContent(blocks: [WorkoutBlock(items: [item])]).encodedData())
        }
        // Nothing, empty data and data that can't be read are empty workouts, as with `decode`.
        blobs[3] = nil
        blobs[7] = Data()
        blobs[11] = Data("not a workout".utf8)
        let all = WorkoutContent.decodeAll(blobs)
        XCTAssertEqual(all.count, blobs.count)
        for (blob, content) in zip(blobs, all) {
            XCTAssertEqual(content, WorkoutContent.decode(blob))
        }
        XCTAssertEqual(all[0].allItems.first?.name, "Row 0")
        XCTAssertEqual(all[39].allItems.first?.name, "Row 39")
        XCTAssertTrue(all[11].isEmpty)
        // A few: one by one.
        XCTAssertEqual(WorkoutContent.decodeAll(Array(blobs.prefix(2))), blobs.prefix(2).map { WorkoutContent.decode($0) })
        XCTAssertEqual(WorkoutContent.decodeAll([]), [])
    }
}
