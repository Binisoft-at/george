import Foundation
import Testing
@testable import BinisoftKitCore

@Suite("Log")
struct LogTests {
    @Test func ringBufferKeepsTheNewest() {
        let log = LogBuffer(capacity: 10)
        for index in 0..<25 { log.log(.info, "entry \(index)") }
        #expect(log.entries.count == 10)
        #expect(log.entries.first?.message == "entry 15")
        #expect(log.entries.last?.message == "entry 24")
    }

    @Test func exportHasHeaderAndLines() {
        let log = LogBuffer(capacity: 10)
        log.log(.warning, "iCloud not signed in", category: "sync")
        log.log(.debug, "noise")
        let text = log.export(header: [("App", "Probe 1.0 (3)")], minimum: .info)
        #expect(text.hasPrefix("App: Probe 1.0 (3)\n"))
        #expect(text.contains("[warning] sync: iCloud not signed in"))
        #expect(!text.contains("noise"))
        #expect(text.contains("1 entries"))
    }

    @Test func persistsAcrossLaunches() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("app-log.jsonl")
        let first = LogBuffer(capacity: 10, fileURL: file)
        for index in 0..<30 { first.log(.info, "entry \(index)") }
        let second = LogBuffer(capacity: 10, fileURL: file)
        #expect(second.entries.count == 10)
        #expect(second.entries.last?.message == "entry 29")
        second.clear()
        let third = LogBuffer(capacity: 10, fileURL: file)
        #expect(third.entries.isEmpty)
    }

    @Test func timestampIsUTC() {
        let line = LogEntry(date: Date(timeIntervalSince1970: 0), level: .error, category: "app", message: "x").line
        #expect(line == "1970-01-01 00:00:00.000Z [error] app: x")
    }

    @Test func levelsAreOrdered() {
        #expect(LogLevel.debug < .info)
        #expect(LogLevel.warning < .error)
    }
}

@Suite("Sync status")
struct SyncStatusTests {
    let relative: (Date) -> String = { _ in "just now" }

    @Test func summaries() {
        #expect(SyncState(mode: .local(reason: nil)).summary(relative: relative) == "Off – this device only")
        #expect(SyncState(mode: .demo).summary(relative: relative) == "Off – demo data")
        var state = SyncState(mode: .iCloud(container: "iCloud.at.binisoft.probe"), account: .available)
        #expect(state.summary(relative: relative) == "On")
        #expect(state.isHealthy)
        state.lastSync = Date()
        #expect(state.summary(relative: relative) == "On · synced just now")
        state.isSyncing = true
        #expect(state.summary(relative: relative) == "Syncing…")
        state.lastError = "boom"
        #expect(state.summary(relative: relative) == "Not syncing")
        #expect(!state.isHealthy)
        state.account = .noAccount
        #expect(state.summary(relative: relative) == "Off – sign in to iCloud")
    }

    @Test func schemaErrorGetsTheFix() {
        let text = SyncErrorText.describe("Cannot create or modify field 'CD_title' in record type 'CD_Item'", appName: "Probe")
        #expect(text.contains("CloudKit schema"))
        #expect(SyncErrorText.describe("Something odd", appName: "Probe") == "Something odd")
    }

    @Test func storageModes() {
        #expect(StorageMode.iCloud(container: "x").containerID == "x")
        #expect(StorageMode.local(reason: nil).containerID == nil)
        #expect(!StorageMode.demo.isSynced)
    }
}

@Suite("Records")
struct RecordTests {
    final class Note: SoftDeletable {
        var deletedAt: Date?
        var modifiedAt = Date(timeIntervalSince1970: 0)
    }

    @Test func softDeleteAndRestore() {
        let note = Note()
        let now = Date(timeIntervalSince1970: 100)
        note.moveToTrash(now: now)
        #expect(note.isInTrash)
        #expect(note.modifiedAt == now)
        note.restoreFromTrash(now: Date(timeIntervalSince1970: 200))
        #expect(!note.isInTrash)
        #expect(note.modifiedAt == Date(timeIntervalSince1970: 200))
    }

    @Test func trashExpires() {
        let policy = TrashPolicy(keepDays: 30)
        let deleted = Date(timeIntervalSince1970: 0)
        #expect(!policy.isExpired(deletedAt: deleted, now: deleted.addingTimeInterval(29 * 86_400)))
        #expect(policy.isExpired(deletedAt: deleted, now: deleted.addingTimeInterval(30 * 86_400)))
        #expect(!policy.isExpired(deletedAt: nil))
        #expect(policy.daysLeft(deletedAt: deleted, now: deleted.addingTimeInterval(10 * 86_400 + 5)) == 19)
    }

    @Test func sortOrderBetween() {
        #expect(ListOrder.between(1, 2) == 1.5)
        #expect(ListOrder.between(nil, 2) == 1)
        #expect(ListOrder.between(3, nil) == 4)
        #expect(ListOrder.between(nil, nil) == 0)
        #expect(ListOrder.after([0, 5, 2]) == 6)
        #expect(ListOrder.before([0, 5, 2]) == -1)
        #expect(ListOrder.after([]) == 0)
    }

    @Test func sortOrderNormalizing() {
        #expect(!ListOrder.needsNormalizing([0, 1, 2]))
        #expect(ListOrder.needsNormalizing([0, 0.0000001, 2]))
        #expect(ListOrder.normalized(count: 3) == [0, 1, 2])
    }

    @Test func moveKeepsOthersAndOrdersMovedRows() {
        let orders: [Double] = [0, 1, 2, 3]
        // Move the last row to the top.
        let top = ListOrder.move(orders, from: IndexSet(integer: 3), to: 0)
        #expect(top.count == 1)
        #expect(top[3]! < 0)
        // Move the first row between the third and fourth.
        let middle = ListOrder.move(orders, from: IndexSet(integer: 0), to: 3)
        #expect(middle[0]! > 2 && middle[0]! < 3)
        // Move two rows to the end.
        let end = ListOrder.move(orders, from: IndexSet([0, 1]), to: 4)
        #expect(end[0]! > 3 && end[1]! > end[0]!)
    }
}

@Suite("Environment")
struct EnvironmentTests {
    @Test func identifiersIgnoreUnresolvedSettings() {
        let ids = AppIdentifiers(info: [
            "AppCloudKitContainer": "iCloud.at.binisoft.probe",
            "SharedCloudKitContainer": "$(SHARED_CLOUDKIT_CONTAINER)",
            "SharedAppGroup": "",
        ])
        #expect(ids.appCloudKitContainer == "iCloud.at.binisoft.probe")
        #expect(ids.sharedCloudKitContainer == nil)
        #expect(ids.sharedAppGroup == nil)
    }

    @Test func version() {
        let version = AppVersion(info: ["CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "57"])
        #expect(version.display == "1.2.0 (57)")
    }

    @Test func launchOptions() {
        let options = LaunchOptions(arguments: ["app", "-Demo", "-DemoScreen", "settings", "-TourStep", "undo"])
        #expect(options.isDemo)
        #expect(options.screen == "settings")
        #expect(options.tourStep == "undo")
        #expect(options.startTour)
        #expect(!options.resetTour)
        let plain = LaunchOptions(arguments: ["app", "-DemoScreen", "-Tour"])
        #expect(!plain.isDemo)
        #expect(plain.screen == nil)
        #expect(plain.startTour)
    }

    @Test func snapshotFileRoundTrip() throws {
        struct Summary: Codable, Equatable {
            var open: Int
            var updated: Date
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = SnapshotFile<Summary>(folder: folder, name: "snapshot.json")
        #expect(file.read() == nil)
        let value = Summary(open: 3, updated: Date(timeIntervalSince1970: 1_700_000_000))
        try file.write(value)
        #expect(file.read() == value)
    }
}

@Suite("Import")
struct ImportTests {
    @Test func csvHandlesQuotesAndDelimiters() {
        let rows = CSV.parse("title;notes\n\"Milk; oat\";\"say \"\"hi\"\"\"\nBread;\n")
        #expect(rows == [["title", "notes"], ["Milk; oat", "say \"hi\""], ["Bread", ""]])
    }

    @Test func csvRoundTrip() {
        let table = [["id", "title"], ["1", "a, b"], ["2", "line\nbreak"]]
        #expect(CSV.parse(CSV.write(table)) == table)
    }

    @Test func csvRecordsAndBOM() {
        let (header, rows) = CSV.records("\u{FEFF}ID,Title\n7,Hello\n")
        #expect(header == ["id", "title"])
        #expect(rows == [["id": "7", "title": "Hello"]])
    }

    @Test func importPlanIsSafeToRepeat() {
        let existing = ["1": "Milk", "2": "Bread"]
        let plan = ImportPlan(incoming: [("1", "Milk"), ("2", "Brot"), ("3", "Eggs"), ("3", "Eggs (6)")],
                              existing: existing, skipped: ["Row 5: no title"])
        #expect(plan.creates == 1)
        #expect(plan.updates == 1)
        #expect(plan.unchanged == 1)
        #expect(plan.entries.first { $0.key == "3" }?.record == "Eggs (6)")
        #expect(plan.summary == "1 new · 1 updated · 1 unchanged · 1 skipped")
        let again = ImportPlan(incoming: [("1", "Milk")], existing: existing)
        #expect(!again.hasChanges)
    }

    @Test func contentKeyIgnoresCaseAndSpaces() {
        #expect(ImportPlan<String>.contentKey(["  Buy  Milk ", "Home"]) == ImportPlan<String>.contentKey(["buy milk", "home"]))
    }

    @Test func promptListsColumnsAndNames() {
        let prompt = AIImportPrompt(
            appName: "Probe", task: "Turn my notes into items.",
            columns: [.init("id", "stable id"), .init("title", "what it is", required: true)],
            rules: ["Dates are YYYY-MM-DD."],
            existingNames: [("Folders", ["Work", "Home"]), ("Tags", [])],
            exampleRows: [["1", "Call, then email"]]
        )
        let text = prompt.text
        #expect(text.contains("\nid,title\n"))
        #expect(text.contains("| title | what it is | yes |"))
        #expect(text.contains("- Folders: Work, Home"))
        #expect(!text.contains("- Tags:"))
        #expect(text.contains("1,\"Call, then email\""))
    }
}
