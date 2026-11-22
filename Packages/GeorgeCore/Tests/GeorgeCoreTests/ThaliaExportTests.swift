import XCTest
@testable import GeorgeCore

/// Binisoft exchange v1 (docs/THALIA.md): the format, George's facts and the writer, in a temporary folder.
final class ThaliaExportTests: XCTestCase {
    let vienna = TimeZone(identifier: "Europe/Vienna")!
    let push = UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000001")!
    let pull = UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000002")!
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("thalia-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("George", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    /// A moment in Vienna.
    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = vienna
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func workout(_ n: Int, title: String = "Push", template: UUID?, templateTitle: String? = "Push",
                 end: Date, finished: Bool = true, source: ThaliaWorkout.Source = .george) -> ThaliaWorkout {
        ThaliaWorkout(id: UUID(uuidString: String(format: "5A100000-0000-4000-8000-%012d", n))!, title: title,
                      templateID: template, templateTitle: templateTitle, endedAt: end, isFinished: finished, source: source)
    }

    func fixture(_ path: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/exchange").appendingPathComponent(path)
        return try Data(contentsOf: url)
    }

    func dayFile(_ day: String) -> URL { BinisoftExchange.dayFileURL(appFolder: folder, day: day) }

    func readDay(_ day: String) throws -> ExchangeDayFile {
        let data = try Data(contentsOf: dayFile(day))
        guard case .success(let read) = ExchangeReader.dayFile(data, folder: "George", fileName: "\(day).json") else {
            XCTFail("unreadable day file")
            throw CocoaError(.fileReadCorruptFile)
        }
        XCTAssertEqual(read.skipped, [])
        return read.file
    }

    // MARK: 1. Facts

    func testFactsHaveKindStableIdsRefsOriginAndDate() throws {
        let done = workout(1, template: push, end: date(2026, 11, 22, 18, 4))
        let fact = try XCTUnwrap(ThaliaExport.fact(for: done, timeZone: vienna))
        XCTAssertEqual(fact.kind, .workoutDone)
        XCTAssertEqual(fact.id, "wo-5A100000-0000-4000-8000-000000000001")
        XCTAssertEqual(ThaliaExport.fact(for: done, timeZone: vienna), fact, "built twice = the same")
        XCTAssertEqual(fact.ref, push.uuidString)
        XCTAssertEqual(fact.refTitle, "Push")
        XCTAssertEqual(fact.title, "Push")
        XCTAssertEqual(fact.origin, .app)
        XCTAssertEqual(fact.at, "2026-11-22T18:04:00+01:00")
        XCTAssertNil(fact.value)
        XCTAssertNil(fact.metric)
        XCTAssertNil(fact.thalia)

        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$"#
        let fractional = Date(timeIntervalSince1970: 1_795_000_000.789)
        for zone in [vienna, TimeZone(identifier: "UTC")!, TimeZone(identifier: "America/New_York")!] {
            let text = ExchangeDate.string(fractional, timeZone: zone)
            XCTAssertNotNil(text.range(of: pattern, options: .regularExpression), text)
            XCTAssertEqual(ExchangeDate.parse(text), Date(timeIntervalSince1970: 1_795_000_000))
        }
        XCTAssertTrue(ExchangeDate.string(fractional, timeZone: TimeZone(identifier: "UTC")!).hasSuffix("Z"))
    }

    func testFreeWorkoutsAndUnfinishedOnes() throws {
        let free = try XCTUnwrap(ThaliaExport.fact(for: workout(2, title: "Morning", template: nil, end: date(2026, 11, 22, 9)), timeZone: vienna))
        XCTAssertEqual(free.ref, "frei")
        XCTAssertEqual(free.refTitle, "Freies Workout")
        XCTAssertEqual(free.title, "Morning")
        XCTAssertNil(ThaliaExport.fact(for: workout(3, template: push, end: date(2026, 11, 22, 9), finished: false)))
        // A template without a name, a workout without a title.
        let unnamed = try XCTUnwrap(ThaliaExport.fact(for: workout(4, title: " ", template: pull, templateTitle: "", end: date(2026, 11, 22, 9))))
        XCTAssertEqual(unnamed.refTitle, "Ohne Namen")
        XCTAssertEqual(unnamed.title, "Ohne Namen")
    }

    // MARK: 2. Day by time zone

    func testDayFollowsTheDeviceTimeZone() throws {
        let late = ISO8601DateFormatter().date(from: "2026-11-22T23:30:00Z")!
        XCTAssertEqual(ExchangeDate.day(late, timeZone: vienna), "2026-11-23")
        XCTAssertEqual(ExchangeDate.day(late, timeZone: TimeZone(identifier: "UTC")!), "2026-11-22")
        let byDay = ThaliaExport.factsByDay([workout(1, template: push, end: late)], today: "2026-11-23", timeZone: vienna)
        XCTAssertEqual(Array(byDay.keys), ["2026-11-23"])
        XCTAssertEqual(byDay["2026-11-23"]?.first?.at, "2026-11-23T00:30:00+01:00")
    }

    func testFactsByDayKeepsTheWindowAndCountsDuplicatesOnce() {
        let today = "2026-11-22"
        let workouts = [
            workout(1, template: push, end: date(2026, 11, 22, 18)),
            workout(1, template: push, end: date(2026, 11, 22, 18)), // the same workout twice (sync duplicate)
            workout(2, template: pull, templateTitle: "Pull", end: date(2026, 11, 22, 7)),
            workout(3, template: push, end: date(2026, 11, 23, 8)), // tomorrow: not yet
            workout(4, template: push, end: date(2026, 9, 21, 8)), // 62 days ago: still in
            workout(5, template: push, end: date(2026, 9, 20, 8)), // 63 days ago: out
        ]
        let byDay = ThaliaExport.factsByDay(workouts, today: today, timeZone: vienna)
        XCTAssertEqual(Set(byDay.keys), ["2026-11-22", "2026-09-21"])
        XCTAssertEqual(byDay["2026-11-22"]?.map(\.ref), [pull.uuidString, push.uuidString], "sorted by time")
    }

    // MARK: 3. Write and read back

    func testWrittenFilesReadBackWithoutSkips() throws {
        let facts = ThaliaExport.factsByDay([
            workout(1, template: push, end: date(2026, 11, 22, 7, 40)),
            workout(2, template: nil, end: date(2026, 11, 22, 17, 10)),
        ], today: "2026-11-22", timeZone: vienna)
        XCTAssertTrue(try ThaliaExchangeWriter.sync(facts, source: "george", appFolder: folder, today: "2026-11-22",
                                                    now: date(2026, 11, 22, 19, 30), timeZone: vienna))
        let file = try readDay("2026-11-22")
        XCTAssertEqual(file.v, 1)
        XCTAssertEqual(file.source, "george")
        XCTAssertEqual(file.generatedAt, "2026-11-22T19:30:00+01:00")
        XCTAssertEqual(file.facts.map(\.ref), [push.uuidString, "frei"])

        let text = try String(contentsOf: dayFile("2026-11-22"), encoding: .utf8)
        XCTAssertFalse(text.contains("\n"), "compact")
        XCTAssertFalse(text.contains("\\/"), "slashes not escaped")
        XCTAssertTrue(text.hasPrefix(#"{"day":"2026-11-22","facts":[{"at":"#), "keys sorted")

        let refs = ThaliaExport.refs([ThaliaTemplate(id: push, title: "Push"), ThaliaTemplate(id: pull, title: "Pull")])
        XCTAssertTrue(try ThaliaExchangeWriter.syncSource(refs: refs, source: "george", app: "George", appVersion: "1.1.0",
                                                          appFolder: folder, today: "2026-11-22", now: date(2026, 11, 22, 19, 30),
                                                          timeZone: vienna))
        let data = try Data(contentsOf: BinisoftExchange.sourceFileURL(appFolder: folder))
        guard case .success(let read) = ExchangeReader.source(data, folder: "George") else { return XCTFail("unreadable source.json") }
        XCTAssertEqual(read.skipped, [])
        XCTAssertEqual(read.info.app, "George")
        XCTAssertEqual(read.info.appVersion, "1.1.0")
        XCTAssertEqual(read.info.refs.map(\.title), ["Pull", "Push", "Freies Workout"])
        XCTAssertEqual(Set(read.info.refs.map(\.kind)), [.workout])
    }

    // MARK: 4. Sync in a folder

    func testSyncOnlyWritesWhatChanged() throws {
        let today = "2026-11-22"
        let a = workout(1, template: push, end: date(2026, 11, 22, 8))
        let b = workout(2, template: pull, templateTitle: "Pull", end: date(2026, 11, 22, 18))
        let yesterday = workout(3, template: push, end: date(2026, 11, 21, 8))
        func sync(_ workouts: [ThaliaWorkout], at hour: Int) throws -> Bool {
            try ThaliaExchangeWriter.sync(ThaliaExport.factsByDay(workouts, today: today, timeZone: vienna), source: "george",
                                          appFolder: folder, today: today, now: date(2026, 11, 22, hour), timeZone: vienna)
        }

        XCTAssertTrue(try sync([a, b, yesterday], at: 19))
        let first = try Data(contentsOf: dayFile(today))
        // Unchanged: same bytes, same generatedAt.
        XCTAssertFalse(try sync([b, a, yesterday], at: 20))
        XCTAssertEqual(try Data(contentsOf: dayFile(today)), first)
        XCTAssertEqual(try readDay(today).generatedAt, "2026-11-22T19:00:00+01:00")
        // A removed fact: the file without it.
        XCTAssertTrue(try sync([a, yesterday], at: 21))
        XCTAssertEqual(try readDay(today).facts.map(\.id), ["wo-" + a.id.uuidString])
        XCTAssertEqual(try readDay(today).generatedAt, "2026-11-22T21:00:00+01:00")
        // Days that never had anything: no file.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dayFile("2026-11-20").path))
        // A day that had a file and now has nothing: "facts":[].
        XCTAssertTrue(try sync([a], at: 22))
        XCTAssertEqual(try readDay("2026-11-21").facts, [])
        XCTAssertTrue(try String(contentsOf: dayFile("2026-11-21"), encoding: .utf8).contains(#""facts":[]"#))
        XCTAssertFalse(try sync([a], at: 23), "an empty file stays as it is")
    }

    func testOldDayFilesAreDeleted() throws {
        let names = ["2026-09-20.json", "2026-09-21.json", "2026-11-22.json", ".x.json"]
        XCTAssertEqual(BinisoftExchange.expiredDayFiles(names, today: "2026-11-22"), ["2026-09-20.json"])
        XCTAssertEqual(BinisoftExchange.expiredDayFiles(["notes.txt", "2026-02-30.json", ".2026-01-01.json.tmp"], today: "2026-11-22"), [])

        let days = BinisoftExchange.daysFolder(appFolder: folder)
        try FileManager.default.createDirectory(at: days, withIntermediateDirectories: true)
        for name in names {
            let day = name.replacingOccurrences(of: ".json", with: "")
            let data = ExchangeDate.isDay(day)
                ? try ExchangeDayFile(source: "george", day: day, generatedAt: "2026-09-20T10:00:00+02:00", facts: []).encoded()
                : Data("{}".utf8)
            try data.write(to: days.appendingPathComponent(name))
        }
        XCTAssertTrue(try ThaliaExchangeWriter.sync([:], source: "george", appFolder: folder, today: "2026-11-22",
                                                    now: date(2026, 11, 22, 12), timeZone: vienna))
        let left = try FileManager.default.contentsOfDirectory(atPath: days.path).sorted()
        XCTAssertEqual(left, [".x.json", "2026-09-21.json", "2026-11-22.json"])
    }

    func testSourceIsAHeartbeatAtMostOnceADay() throws {
        let refs = ThaliaExport.refs([ThaliaTemplate(id: push, title: "Push")])
        func sync(_ refs: [ExchangeRef], version: String = "1.1.0", day: Int, hour: Int) throws -> Bool {
            try ThaliaExchangeWriter.syncSource(refs: refs, source: "george", app: "George", appVersion: version, appFolder: folder,
                                                today: "2026-11-\(day)", now: date(2026, 11, day, hour), timeZone: vienna)
        }
        XCTAssertTrue(try sync(refs, day: 22, hour: 8))
        XCTAssertFalse(try sync(refs, day: 22, hour: 20), "same day, same content")
        XCTAssertTrue(try sync(ThaliaExport.refs([ThaliaTemplate(id: push, title: "Push A")]), day: 22, hour: 21), "renamed template")
        XCTAssertTrue(try sync(ThaliaExport.refs([ThaliaTemplate(id: push, title: "Push A")]), version: "1.2.0", day: 22, hour: 22), "new version")
        XCTAssertTrue(try sync(ThaliaExport.refs([ThaliaTemplate(id: push, title: "Push A")]), version: "1.2.0", day: 23, hour: 7), "next day")
        XCTAssertEqual(refs.last, ExchangeRef(id: "frei", title: "Freies Workout", kind: .workout))
    }

    // MARK: 5. Thalia's test files

    func testThaliasTestFilesParseAndOurOutputHasTheSameForm() throws {
        let dayData = try fixture("George/exchange/days/2026-11-22.json")
        guard case .success(let day) = ExchangeReader.dayFile(dayData, folder: "George", fileName: "2026-11-22.json") else {
            return XCTFail("day file")
        }
        XCTAssertEqual(day.skipped, [])
        XCTAssertEqual(day.file.facts.map(\.id), ["wo-5A10", "wo-5A11", "wo-HK01"])
        XCTAssertEqual(day.file.facts.map(\.origin), [.app, .app, .health])
        // George never writes facts like wo-HK01; the same day as George writes it:
        let own = ExchangeDayFile(source: "george", day: "2026-11-22", generatedAt: "2026-11-22T19:30:00+01:00",
                                  facts: ExchangeFact.sorted(day.file.facts.filter { $0.origin == .app }))
        var expected = try XCTUnwrap(JSONValue.parse(dayData))
        if case .object(var root) = expected, case .array(let facts)? = root["facts"] {
            root["facts"] = .array(facts.filter { if case .object(let o) = $0 { return o["origin"] != .string("health") }; return true })
            expected = .object(root)
        }
        XCTAssertEqual(JSONValue.parse(try own.encoded()), expected)

        let sourceData = try fixture("George/exchange/source.json")
        guard case .success(let source) = ExchangeReader.source(sourceData, folder: "George") else { return XCTFail("source.json") }
        XCTAssertEqual(source.skipped, [])
        XCTAssertEqual(source.info.refs.map(\.id), ["tpl-1", "tpl-2"])
        XCTAssertEqual(JSONValue.parse(try source.info.encoded()), JSONValue.parse(sourceData))

        guard case .success(let catalog) = ExchangeReader.catalog(try fixture("Thalia/exchange/catalog.json")) else {
            return XCTFail("catalog")
        }
        XCTAssertEqual(catalog.week, "2026-W47")
        XCTAssertEqual(catalog.segment, .init(id: "seg-2", title: "Abschnitt 2"))
        XCTAssertEqual(catalog.goals.map(\.key), ["1", "3", "5"])
        XCTAssertEqual(catalog.categories.map(\.key), ["1.2", "3.2", "5"])
        XCTAssertEqual(catalog.results.map(\.kind), ["count", "check"])
        XCTAssertEqual(catalog.measures(linkedTo: "app:george:workout=tpl-1").map(\.title), ["Workouts"])
        XCTAssertEqual(ThaliaExport.workoutLink(templateID: push), "app:george:workout=\(push.uuidString)")
        XCTAssertEqual(ThaliaExport.workoutLink(templateID: nil), "app:george:workout")
    }

    func testReaderRejectsAndSkipsWithReasons() {
        func day(_ json: String, file: String = "2026-11-22.json") -> Result<ExchangeDayRead, ExchangeReadError> {
            ExchangeReader.dayFile(Data(json.utf8), folder: "George", fileName: file)
        }
        let head = #""source":"george","day":"2026-11-22","generatedAt":"2026-11-22T10:00:00+01:00""#
        if case .success = day("{\"v\":0,\(head),\"facts\":[]}") { XCTFail("version 0") }
        if case .success = day("{\"v\":1,\(head),\"facts\":[]}", file: "2026-11-21.json") { XCTFail("file name") }
        if case .success = ExchangeReader.dayFile(Data("{\"v\":1,\(head),\"facts\":[]}".utf8), folder: "Theo") { XCTFail("folder") }
        if case .success = day("[]") { XCTFail("not an object") }
        if case .failure(let error) = day("{\"v\":1,\(head),\"facts\":[]}", file: "2026-11-21.json") {
            XCTAssertTrue(error.reason.contains("Dateinamen"), error.reason)
        }
        let facts = #"[{"id":"a","kind":"workout.done","origin":"app","extra":1},{"id":"b","kind":"workout.done"},"#
            + #"{"id":"c","kind":"workout.done","origin":"cloud"},{"kind":"x","origin":"app"},"#
            + #"{"id":"a","kind":"task.done","origin":"app"},{"id":"d","kind":"later.kind","origin":"app","value":"1.5"}]"#
        guard case .success(let read) = day("{\"v\":2,\(head),\"unknown\":true,\"facts\":\(facts)}") else { return XCTFail("tolerant") }
        XCTAssertEqual(read.file.facts.map(\.id), ["a", "d"])
        XCTAssertFalse(read.file.facts[1].kind.isKnown)
        XCTAssertNil(read.file.facts[1].value, "a value as text is ignored")
        XCTAssertEqual(read.skipped.map(\.index), [1, 2, 3, 4])
        XCTAssertTrue(read.skipped[1].reason.contains("cloud"))
    }

    func testDatesAndNames() {
        let reference = ExchangeDate.parse("2026-11-22T18:04:00+01:00")
        XCTAssertNotNil(reference)
        for text in ["2026-11-22T17:04:00Z", "2026-11-22T18:04:00+0100", "2026-11-22T18:04:00.000+01:00", "2026-11-22T12:04:00-05:00"] {
            XCTAssertEqual(ExchangeDate.parse(text), reference, text)
        }
        for text in ["2026-11-22T18:04:00", "2026-02-30T10:00:00Z", "2026-11-22", "nonsense"] {
            XCTAssertNil(ExchangeDate.parse(text), text)
        }
        XCTAssertEqual(BinisoftExchange.sourceID("George"), "george")
        XCTAssertEqual(BinisoftExchange.day("2026-03-01", adding: -1), "2026-02-28")
        XCTAssertEqual(BinisoftExchange.day("2028-03-01", adding: -1), "2028-02-29")
        XCTAssertEqual(BinisoftExchange.days(from: "2026-09-20", to: "2026-11-22"), 63)
        XCTAssertEqual(BinisoftExchange.dayFileURL(appFolder: folder, day: "2026-11-22").path,
                       folder.path + "/exchange/days/2026-11-22.json")
        XCTAssertEqual(ExchangeMetric.table.count, 8)
        XCTAssertEqual(ExchangeMetric.named("body_weight_kg")?.aggregation, .last)
    }

    // MARK: 6–8. No Health values; the Watch

    func testHealthOnlyWorkoutsAreNeverWrittenAndWatchWorkoutsAre() throws {
        let fromWatch = workout(1, template: push, end: date(2026, 11, 22, 7), source: .watch)
        let free = workout(2, title: "Tennis", template: nil, end: date(2026, 11, 22, 12))
        let fromHealth = workout(3, title: "Run", template: nil, end: date(2026, 11, 22, 17), source: .appleHealth)
        XCTAssertNil(ThaliaExport.fact(for: fromHealth))

        let facts = ThaliaExport.factsByDay([fromWatch, free, fromHealth], today: "2026-11-22", timeZone: vienna)
        try ThaliaExchangeWriter.sync(facts, source: "george", appFolder: folder, today: "2026-11-22",
                                      now: date(2026, 11, 22, 19), timeZone: vienna)
        let file = try readDay("2026-11-22")
        XCTAssertEqual(file.facts.map(\.id), ["wo-" + fromWatch.id.uuidString, "wo-" + free.id.uuidString])
        XCTAssertEqual(file.facts.map(\.ref), [push.uuidString, "frei"])
        XCTAssertTrue(file.facts.allSatisfy { $0.origin == .app && $0.value == nil && $0.metric == nil && $0.unit == nil })
        let text = try String(contentsOf: dayFile("2026-11-22"), encoding: .utf8)
        XCTAssertFalse(text.contains("health"))
        XCTAssertFalse(text.contains("\"value\""))
    }

    // MARK: 7. FNV-1a

    func testFNV1a() {
        XCTAssertEqual(ExchangeHash.hex(""), "cbf29ce484222325")
        XCTAssertEqual(ExchangeHash.hex("a"), "af63dc4c8601ec8c")
        XCTAssertEqual(ExchangeHash.hex("foobar"), "85944171f73967e8")
    }
}
