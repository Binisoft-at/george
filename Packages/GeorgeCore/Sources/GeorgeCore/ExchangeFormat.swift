import Foundation

// Binisoft exchange, format v1: small JSON files in the shared App Group that Binisoft apps write
// and Thalia reads on the same device. Written to Thalia's specification (paths, day files,
// source.json, catalog); only Foundation, so it is tested on Linux.

// MARK: - Paths, names, clean-up, writing

public enum BinisoftExchange {
    /// Format version written; readers accept 1 and higher.
    public static let version = 1
    public static let appGroup = "group.at.binisoft.shared"
    /// Darwin notification posted once after each write (only a hint: Thalia also reads on its own).
    public static let changedNotification = "at.binisoft.exchange.changed"
    /// Day files older than this many days (today − day > keepDays) are deleted by the writer.
    public static let keepDays = 62

    public static let exchangeFolderName = "exchange"
    public static let daysFolderName = "days"
    public static let sourceFileName = "source.json"
    public static let catalogFileName = "catalog.json"

    /// The source id for an app folder: "George" → "george" (lower case; only a–z, 0–9 and "-").
    public static func sourceID(_ appName: String) -> String {
        var id = ""
        for scalar in appName.lowercased().unicodeScalars {
            switch scalar {
            case "a"..."z", "0"..."9", "-": id.unicodeScalars.append(scalar)
            case " ", "_": id.append("-")
            default: continue
            }
        }
        return id
    }

    /// `<appFolder>/exchange`
    public static func exchangeFolder(appFolder: URL) -> URL {
        appFolder.appendingPathComponent(exchangeFolderName, isDirectory: true)
    }

    /// `<appFolder>/exchange/days`
    public static func daysFolder(appFolder: URL) -> URL {
        exchangeFolder(appFolder: appFolder).appendingPathComponent(daysFolderName, isDirectory: true)
    }

    /// `<appFolder>/exchange/days/<day>.json`
    public static func dayFileURL(appFolder: URL, day: String) -> URL {
        daysFolder(appFolder: appFolder).appendingPathComponent(dayFileName(day), isDirectory: false)
    }

    /// `<appFolder>/exchange/source.json`
    public static func sourceFileURL(appFolder: URL) -> URL {
        exchangeFolder(appFolder: appFolder).appendingPathComponent(sourceFileName, isDirectory: false)
    }

    /// "2026-11-22" → "2026-11-22.json"
    public static func dayFileName(_ day: String) -> String { day + ".json" }

    /// "2026-11-22.json" → "2026-11-22"; nil for dotfiles, temporary files and other names.
    public static func day(fromFileName name: String) -> String? {
        guard !name.hasPrefix("."), name.hasSuffix(".json") else { return nil }
        let day = String(name.dropLast(5))
        return ExchangeDate.isDay(day) ? day : nil
    }

    /// The day `days` days after `day` ("2026-11-22", -1 → "2026-11-21").
    public static func day(_ day: String, adding days: Int) -> String? {
        guard let date = ExchangeDate.dayStart(day),
              let moved = ExchangeDate.utcCalendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return ExchangeDate.day(moved, timeZone: ExchangeDate.utc)
    }

    /// Whole days from `from` to `to` (both "YYYY-MM-DD").
    public static func days(from: String, to: String) -> Int? {
        guard let start = ExchangeDate.dayStart(from), let end = ExchangeDate.dayStart(to) else { return nil }
        return ExchangeDate.utcCalendar.dateComponents([.day], from: start, to: end).day
    }

    /// The day files among `names` that are older than `keepDays` (today − day > keepDays).
    /// Dotfiles, temporary files and other names are never listed.
    public static func expiredDayFiles(_ names: [String], today: String) -> [String] {
        names.filter { name in
            guard let day = day(fromFileName: name), let age = days(from: day, to: today) else { return false }
            return age > keepDays
        }
        .sorted()
    }

    /// UTF-8, compact, keys sorted, slashes not escaped.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }

    /// Atomic write (temporary file in the same folder, then rename); creates the folder if needed.
    public static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Origin, kinds, metrics

/// Where a fact comes from. Facts without an origin (or with another value) are not used by Thalia;
/// `health` facts are dropped by Thalia before they are stored (guideline 5.1.3(ii)).
public enum ExchangeOrigin: String, Codable, Hashable, Sendable, CaseIterable {
    /// Recorded in the app itself.
    case app
    /// From Apple Health.
    case health
}

/// The kind of a fact. Unknown kinds are kept as they are (Thalia shows them as "not used").
public struct ExchangeKind: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// A finished task; `ref` = its group.
    public static let taskDone: ExchangeKind = "task.done"
    /// A finished workout; `ref` = its template.
    public static let workoutDone: ExchangeKind = "workout.done"
    /// A habit done; `ref` = the habit.
    public static let habitDone: ExchangeKind = "habit.done"
    /// Power hours (`value` in PH with unit "PH", or minutes with unit "min"); `ref` = group.
    public static let ph: ExchangeKind = "ph"
    /// A day's number for a metric of `ExchangeMetric.table`.
    public static let value: ExchangeKind = "value"
    /// A group's spending on the day (`value` positive, `currency`).
    public static let spending: ExchangeKind = "spending"

    public static let known: [ExchangeKind] = [.taskDone, .workoutDone, .habitDone, .ph, .value, .spending]

    public var isKnown: Bool { Self.known.contains(self) }
    /// Counted kinds (`*.done`): each fact counts as 1, `value` is not read.
    public var isCounted: Bool { rawValue.hasSuffix(".done") }
}

/// The fixed metric table of format v1 (for facts of kind `value`).
public struct ExchangeMetric: Hashable, Sendable {
    public enum Aggregation: String, Hashable, Sendable {
        /// The day's facts are added up.
        case sum
        /// The last fact by `at` wins (without `at`, earlier, in file order).
        case last
    }

    public var id: String
    public var aggregation: Aggregation
    public var unit: String
    public var name: String

    public init(id: String, aggregation: Aggregation, unit: String, name: String) {
        self.id = id
        self.aggregation = aggregation
        self.unit = unit
        self.name = name
    }

    public static let table: [ExchangeMetric] = [
        ExchangeMetric(id: "kcal", aggregation: .sum, unit: "kcal", name: "Kalorien"),
        ExchangeMetric(id: "protein_g", aggregation: .sum, unit: "g", name: "Protein"),
        ExchangeMetric(id: "carbs_g", aggregation: .sum, unit: "g", name: "Kohlenhydrate"),
        ExchangeMetric(id: "fat_g", aggregation: .sum, unit: "g", name: "Fett"),
        ExchangeMetric(id: "water_ml", aggregation: .sum, unit: "ml", name: "Wasser"),
        ExchangeMetric(id: "net_worth", aggregation: .last, unit: "€", name: "Vermögen"),
        ExchangeMetric(id: "savings_rate", aggregation: .last, unit: "%", name: "Sparquote"),
        ExchangeMetric(id: "body_weight_kg", aggregation: .last, unit: "kg", name: "Gewicht"),
    ]

    public static func named(_ id: String) -> ExchangeMetric? { table.first { $0.id == id } }
}

// MARK: - Facts and files

/// What was chosen from Thalia's catalog in the source app (`measure` and `result` are reserved).
public struct ExchangeThalia: Codable, Hashable, Sendable {
    public var category: String?
    public var categoryTitle: String?

    public init(category: String? = nil, categoryTitle: String? = nil) {
        self.category = category
        self.categoryTitle = categoryTitle
    }
}

/// One fact of a day file. Optional fields are left out of the JSON when nil.
public struct ExchangeFact: Codable, Hashable, Sendable {
    /// Stable on every device and unique in the file, from the record's synced id ("wo-…").
    public var id: String
    public var kind: ExchangeKind
    public var origin: ExchangeOrigin
    /// Stable id in the source the fact belongs to (group, workout template, metric).
    public var ref: String?
    /// Display name of `ref`.
    public var refTitle: String?
    public var title: String?
    public var value: Double?
    public var unit: String?
    public var metric: String?
    public var currency: String?
    /// When it happened (`ExchangeDate.string`).
    public var at: String?
    public var thalia: ExchangeThalia?

    public init(id: String, kind: ExchangeKind, origin: ExchangeOrigin, ref: String? = nil, refTitle: String? = nil,
                title: String? = nil, value: Double? = nil, unit: String? = nil, metric: String? = nil,
                currency: String? = nil, at: String? = nil, thalia: ExchangeThalia? = nil) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.ref = ref
        self.refTitle = refTitle
        self.title = title
        self.value = value
        self.unit = unit
        self.metric = metric
        self.currency = currency
        self.at = at
        self.thalia = thalia
    }

    /// The fixed order of a day file: by `at` (facts without `at` first), then by `id`.
    public static func sorted(_ facts: [ExchangeFact]) -> [ExchangeFact] {
        facts.sorted { lhs, rhs in
            let l = lhs.at.flatMap(ExchangeDate.parse) ?? .distantPast
            let r = rhs.at.flatMap(ExchangeDate.parse) ?? .distantPast
            if l != r { return l < r }
            if lhs.at != rhs.at { return (lhs.at ?? "") < (rhs.at ?? "") }
            return lhs.id < rhs.id
        }
    }
}

/// `days/YYYY-MM-DD.json`
public struct ExchangeDayFile: Codable, Hashable, Sendable {
    public var v: Int
    public var source: String
    public var day: String
    public var generatedAt: String
    public var facts: [ExchangeFact]

    public init(v: Int = BinisoftExchange.version, source: String, day: String, generatedAt: String, facts: [ExchangeFact]) {
        self.v = v
        self.source = source
        self.day = day
        self.generatedAt = generatedAt
        self.facts = facts
    }

    public func encoded() throws -> Data { try BinisoftExchange.encode(self) }
}

/// A stable id the person can pick in Thalia (`source.json` → `refs`).
public struct ExchangeRef: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// A group of tasks, power hours or spending.
        case group
        /// A workout template.
        case workout
        case habit
        case metric
    }

    public var id: String
    public var title: String
    /// Without a kind the ref fits everything.
    public var kind: Kind?

    public init(id: String, title: String, kind: Kind? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
    }
}

/// `source.json`: heartbeat and the directory of stable ids.
public struct ExchangeSourceInfo: Codable, Hashable, Sendable {
    public var v: Int
    public var source: String
    /// Display name ("George").
    public var app: String
    public var appVersion: String
    public var generatedAt: String
    public var refs: [ExchangeRef]

    public init(v: Int = BinisoftExchange.version, source: String, app: String, appVersion: String, generatedAt: String,
                refs: [ExchangeRef]) {
        self.v = v
        self.source = source
        self.app = app
        self.appVersion = appVersion
        self.generatedAt = generatedAt
        self.refs = refs
    }

    public func encoded() throws -> Data { try BinisoftExchange.encode(self) }

    /// Equal apart from `generatedAt` (nothing new to tell).
    public func sameContent(as other: ExchangeSourceInfo) -> Bool {
        v == other.v && source == other.source && app == other.app && appVersion == other.appVersion && refs == other.refs
    }
}

/// Thalia's `catalog.json`: structure only (no values, no progress). Read tolerantly.
public struct ExchangeCatalog: Codable, Hashable, Sendable {
    public struct Segment: Codable, Hashable, Sendable {
        public var id: String
        public var title: String
        public init(id: String, title: String) { self.id = id; self.title = title }
    }

    public struct Goal: Codable, Hashable, Sendable {
        public var key: String
        public var title: String
        public init(key: String, title: String) { self.key = key; self.title = title }
    }

    public struct Category: Codable, Hashable, Sendable {
        public var key: String
        public var goal: String?
        public var title: String
        public var segment: String?
        public init(key: String, goal: String? = nil, title: String, segment: String? = nil) {
            self.key = key; self.goal = goal; self.title = title; self.segment = segment
        }
    }

    public struct Measure: Codable, Hashable, Sendable {
        public var code: String
        public var title: String
        public var unit: String?
        /// The measure's source, e.g. "app:george:workout=<template id>".
        public var link: String?
        public var category: String?
        public init(code: String, title: String, unit: String? = nil, link: String? = nil, category: String? = nil) {
            self.code = code; self.title = title; self.unit = unit; self.link = link; self.category = category
        }
    }

    public struct Result: Codable, Hashable, Sendable {
        public var id: String
        public var title: String
        /// "check", "count" or "value".
        public var kind: String?
        public var goal: String?
        public init(id: String, title: String, kind: String? = nil, goal: String? = nil) {
            self.id = id; self.title = title; self.kind = kind; self.goal = goal
        }
    }

    public var v: Int
    public var source: String
    public var generatedAt: String?
    /// The week the measures come from ("2026-W47").
    public var week: String?
    public var segment: Segment?
    public var goals: [Goal]
    public var categories: [Category]
    public var measures: [Measure]
    public var results: [Result]

    public init(v: Int = BinisoftExchange.version, source: String = "thalia", generatedAt: String? = nil, week: String? = nil,
                segment: Segment? = nil, goals: [Goal] = [], categories: [Category] = [], measures: [Measure] = [],
                results: [Result] = []) {
        self.v = v
        self.source = source
        self.generatedAt = generatedAt
        self.week = week
        self.segment = segment
        self.goals = goals
        self.categories = categories
        self.measures = measures
        self.results = results
    }

    /// Measures whose source is exactly `link` ("app:george:workout=<id>").
    public func measures(linkedTo link: String) -> [Measure] {
        measures.filter { $0.link == link }
    }

    public func category(key: String) -> Category? { categories.first { $0.key == key } }
}

// MARK: - Reading (tolerant)

/// Why a file was rejected, in plain German (shown in Thalia's diagnostics).
public struct ExchangeReadError: Error, Hashable, Sendable {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
}

/// A fact (or ref) that was left out while reading, and why.
public struct ExchangeSkipped: Hashable, Sendable {
    public var index: Int
    public var id: String?
    public var reason: String
    public init(index: Int, id: String?, reason: String) {
        self.index = index
        self.id = id
        self.reason = reason
    }
}

public struct ExchangeDayRead: Hashable, Sendable {
    public var file: ExchangeDayFile
    public var skipped: [ExchangeSkipped]
}

public struct ExchangeSourceRead: Hashable, Sendable {
    public var info: ExchangeSourceInfo
    public var skipped: [ExchangeSkipped]
}

/// Tolerant reading: unknown fields are ignored, a broken fact is skipped (with a reason) instead of
/// rejecting the whole file. Wrongly typed optional fields are ignored.
public enum ExchangeReader {
    /// A day file. With `folder` the source must match the folder's name; with `fileName` the day must
    /// match the file name.
    public static func dayFile(_ data: Data, folder: String? = nil, fileName: String? = nil) -> Swift.Result<ExchangeDayRead, ExchangeReadError> {
        guard case .object(let root)? = JSONValue.parse(data) else { return .failure(.init("Kein gültiges JSON-Objekt.")) }
        if case .failure(let error) = checkVersion(root) { return .failure(error) }
        guard let source = root["source"]?.string, !source.isEmpty else { return .failure(.init("Die Quelle fehlt.")) }
        if let folder, source != BinisoftExchange.sourceID(folder) {
            return .failure(.init("Die Quelle „\(source)“ passt nicht zum Ordner „\(folder)“."))
        }
        guard let day = root["day"]?.string else { return .failure(.init("Der Tag fehlt.")) }
        guard ExchangeDate.isDay(day) else { return .failure(.init("„\(day)“ ist kein gültiger Tag.")) }
        if let fileName, fileName != BinisoftExchange.dayFileName(day) {
            return .failure(.init("Der Tag „\(day)“ passt nicht zum Dateinamen „\(fileName)“."))
        }
        guard let generatedAt = root["generatedAt"]?.string, ExchangeDate.parse(generatedAt) != nil else {
            return .failure(.init("Der Zeitpunkt „generatedAt“ fehlt oder ist kein Datum."))
        }
        guard case .array(let items)? = root["facts"] else { return .failure(.init("Die Liste „facts“ fehlt.")) }

        var facts: [ExchangeFact] = []
        var skipped: [ExchangeSkipped] = []
        var ids = Set<String>()
        for (index, item) in items.enumerated() {
            guard case .object(let object) = item else {
                skipped.append(.init(index: index, id: nil, reason: "Die Tatsache ist kein Objekt."))
                continue
            }
            let id = object["id"]?.string
            guard let id, !id.isEmpty else {
                skipped.append(.init(index: index, id: nil, reason: "Die Tatsache hat keine id."))
                continue
            }
            guard let kind = object["kind"]?.string, !kind.isEmpty else {
                skipped.append(.init(index: index, id: id, reason: "Die Tatsache hat keine Art (kind)."))
                continue
            }
            guard let originText = object["origin"]?.string else {
                skipped.append(.init(index: index, id: id, reason: "Die Tatsache hat keine Herkunft (origin)."))
                continue
            }
            guard let origin = ExchangeOrigin(rawValue: originText) else {
                skipped.append(.init(index: index, id: id, reason: "Unbekannte Herkunft „\(originText)“."))
                continue
            }
            guard ids.insert(id).inserted else {
                skipped.append(.init(index: index, id: id, reason: "Die id „\(id)“ kommt doppelt vor."))
                continue
            }
            var thalia: ExchangeThalia?
            if case .object(let tag)? = object["thalia"] {
                thalia = ExchangeThalia(category: tag["category"]?.string, categoryTitle: tag["categoryTitle"]?.string)
            }
            facts.append(ExchangeFact(
                id: id, kind: ExchangeKind(rawValue: kind), origin: origin,
                ref: object["ref"]?.string, refTitle: object["refTitle"]?.string, title: object["title"]?.string,
                value: object["value"]?.number, unit: object["unit"]?.string, metric: object["metric"]?.string,
                currency: object["currency"]?.string,
                at: object["at"]?.string.flatMap { ExchangeDate.parse($0) != nil ? $0 : nil },
                thalia: thalia
            ))
        }
        let version = root["v"]?.integer ?? BinisoftExchange.version
        let file = ExchangeDayFile(v: version, source: source, day: day, generatedAt: generatedAt, facts: facts)
        return .success(ExchangeDayRead(file: file, skipped: skipped))
    }

    /// `source.json`. With `folder` the source must match the folder's name.
    public static func source(_ data: Data, folder: String? = nil) -> Swift.Result<ExchangeSourceRead, ExchangeReadError> {
        guard case .object(let root)? = JSONValue.parse(data) else { return .failure(.init("Kein gültiges JSON-Objekt.")) }
        if case .failure(let error) = checkVersion(root) { return .failure(error) }
        guard let source = root["source"]?.string, !source.isEmpty else { return .failure(.init("Die Quelle fehlt.")) }
        if let folder, source != BinisoftExchange.sourceID(folder) {
            return .failure(.init("Die Quelle „\(source)“ passt nicht zum Ordner „\(folder)“."))
        }
        guard let generatedAt = root["generatedAt"]?.string, ExchangeDate.parse(generatedAt) != nil else {
            return .failure(.init("Der Zeitpunkt „generatedAt“ fehlt oder ist kein Datum."))
        }
        var refs: [ExchangeRef] = []
        var skipped: [ExchangeSkipped] = []
        if case .array(let items)? = root["refs"] {
            var ids = Set<String>()
            for (index, item) in items.enumerated() {
                guard case .object(let object) = item, let id = object["id"]?.string, !id.isEmpty else {
                    skipped.append(.init(index: index, id: nil, reason: "Der Eintrag hat keine id."))
                    continue
                }
                guard ids.insert(id).inserted else {
                    skipped.append(.init(index: index, id: id, reason: "Die id „\(id)“ kommt doppelt vor."))
                    continue
                }
                let kind = object["kind"]?.string.flatMap(ExchangeRef.Kind.init(rawValue:))
                refs.append(ExchangeRef(id: id, title: object["title"]?.string ?? id, kind: kind))
            }
        }
        let version = root["v"]?.integer ?? BinisoftExchange.version
        let info = ExchangeSourceInfo(v: version, source: source, app: root["app"]?.string ?? source,
                                      appVersion: root["appVersion"]?.string ?? "", generatedAt: generatedAt, refs: refs)
        return .success(ExchangeSourceRead(info: info, skipped: skipped))
    }

    /// Thalia's `catalog.json`. Entries without their key fields are left out.
    public static func catalog(_ data: Data) -> Swift.Result<ExchangeCatalog, ExchangeReadError> {
        guard case .object(let root)? = JSONValue.parse(data) else { return .failure(.init("Kein gültiges JSON-Objekt.")) }
        if case .failure(let error) = checkVersion(root) { return .failure(error) }
        guard let source = root["source"]?.string, source == "thalia" else {
            return .failure(.init("Der Katalog stammt nicht von Thalia."))
        }
        func objects(_ key: String) -> [[String: JSONValue]] {
            guard case .array(let items)? = root[key] else { return [] }
            return items.compactMap { if case .object(let o) = $0 { return o } else { return nil } }
        }
        var segment: ExchangeCatalog.Segment?
        if case .object(let o)? = root["segment"], let id = o["id"]?.string {
            segment = .init(id: id, title: o["title"]?.string ?? id)
        }
        let goals = objects("goals").compactMap { o -> ExchangeCatalog.Goal? in
            guard let key = o["key"]?.text else { return nil }
            return .init(key: key, title: o["title"]?.string ?? key)
        }
        let categories = objects("categories").compactMap { o -> ExchangeCatalog.Category? in
            guard let key = o["key"]?.text else { return nil }
            return .init(key: key, goal: o["goal"]?.text, title: o["title"]?.string ?? key, segment: o["segment"]?.string)
        }
        let measures = objects("measures").compactMap { o -> ExchangeCatalog.Measure? in
            guard let code = o["code"]?.string else { return nil }
            return .init(code: code, title: o["title"]?.string ?? code, unit: o["unit"]?.string, link: o["link"]?.string,
                         category: o["category"]?.text)
        }
        let results = objects("results").compactMap { o -> ExchangeCatalog.Result? in
            guard let id = o["id"]?.string else { return nil }
            return .init(id: id, title: o["title"]?.string ?? id, kind: o["kind"]?.string, goal: o["goal"]?.text)
        }
        let version = root["v"]?.integer ?? BinisoftExchange.version
        return .success(ExchangeCatalog(v: version, source: source, generatedAt: root["generatedAt"]?.string,
                                        week: root["week"]?.string, segment: segment, goals: goals,
                                        categories: categories, measures: measures, results: results))
    }

    private static func checkVersion(_ root: [String: JSONValue]) -> Swift.Result<Void, ExchangeReadError> {
        guard let number = root["v"]?.number else { return .failure(.init("Die Version „v“ fehlt.")) }
        guard number >= 1 else { return .failure(.init("Version \(JSONValue.number(number).text ?? "?") wird nicht unterstützt (mindestens 1).")) }
        return .success(())
    }
}

/// A parsed JSON value (for tolerant reading on every platform).
enum JSONValue: Decodable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    static func parse(_ data: Data) -> JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: data) }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// A key that may be written as text ("3.2") or as a number (5).
    var text: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 { return String(Int(value)) }
            return String(value)
        default: return nil
        }
    }

    /// A whole number that fits an Int (versions).
    var integer: Int? {
        guard case .number(let value) = self, value.rounded() == value, abs(value) < 1e15 else { return nil }
        return Int(value)
    }
}

// MARK: - Dates

/// Dates as the exchange writes them: ISO 8601 with the zone's offset and no fractional seconds
/// ("2026-11-22T18:04:00+01:00", UTC "…Z"); days as "YYYY-MM-DD" in the device's time zone.
public enum ExchangeDate {
    static let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }()

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// "2026-11-22T18:04:00+01:00" in `timeZone`; "…Z" when the offset is zero.
    public static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
        let whole = Date(timeIntervalSince1970: (date.timeIntervalSince1970).rounded(.down))
        let c = calendar(timeZone).dateComponents([.year, .month, .day, .hour, .minute, .second], from: whole)
        let offset = timeZone.secondsFromGMT(for: whole)
        var text = "\(pad(c.year ?? 0, 4))-\(pad(c.month ?? 0, 2))-\(pad(c.day ?? 0, 2))"
        text += "T\(pad(c.hour ?? 0, 2)):\(pad(c.minute ?? 0, 2)):\(pad(c.second ?? 0, 2))"
        if offset == 0 { return text + "Z" }
        let minutes = abs(offset) / 60
        return text + (offset < 0 ? "-" : "+") + "\(pad(minutes / 60, 2)):\(pad(minutes % 60, 2))"
    }

    /// The calendar day of `date` in `timeZone` ("2026-11-23").
    public static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        let c = calendar(timeZone).dateComponents([.year, .month, .day], from: date)
        return "\(pad(c.year ?? 0, 4))-\(pad(c.month ?? 0, 2))-\(pad(c.day ?? 0, 2))"
    }

    /// Reads ISO 8601 with a zone: fractional seconds, "+01:00", "+0100", "+01" and "Z" are accepted.
    public static func parse(_ text: String) -> Date? {
        let c = Array(text.utf8)
        func digits(_ start: Int, _ count: Int) -> Int? {
            guard start >= 0, start + count <= c.count else { return nil }
            var value = 0
            for i in start..<(start + count) {
                guard c[i] >= 48, c[i] <= 57 else { return nil }
                value = value * 10 + Int(c[i] - 48)
            }
            return value
        }
        func at(_ i: Int, _ ascii: Unicode.Scalar) -> Bool { i < c.count && c[i] == UInt8(ascii: ascii) }
        guard let year = digits(0, 4), at(4, "-"), let month = digits(5, 2), at(7, "-"), let day = digits(8, 2),
              at(10, "T") || at(10, "t") || at(10, " "),
              let hour = digits(11, 2), at(13, ":"), let minute = digits(14, 2), at(16, ":"), let second = digits(17, 2),
              isValid(year: year, month: month, day: day), hour < 24, minute < 60, second <= 60 else { return nil }
        var i = 19
        var fraction = 0.0
        if at(i, ".") || at(i, ",") {
            i += 1
            var scale = 0.1
            let start = i
            while i < c.count, c[i] >= 48, c[i] <= 57 {
                fraction += Double(c[i] - 48) * scale
                scale /= 10
                i += 1
            }
            guard i > start else { return nil }
        }
        var offset = 0
        if at(i, "Z") || at(i, "z") {
            i += 1
        } else if at(i, "+") || at(i, "-") {
            let sign = at(i, "-") ? -1 : 1
            i += 1
            guard let hours = digits(i, 2), hours < 24 else { return nil }
            i += 2
            var minutes = 0
            if i < c.count {
                if at(i, ":") { i += 1 }
                guard let value = digits(i, 2), value < 60 else { return nil }
                minutes = value
                i += 2
            }
            offset = sign * (hours * 3600 + minutes * 60)
        } else {
            return nil
        }
        guard i == c.count,
              let base = utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour,
                                                               minute: minute, second: min(second, 59))) else { return nil }
        return base.addingTimeInterval(Double(second == 60 ? 1 : 0) + fraction - Double(offset))
    }

    /// "YYYY-MM-DD" and a real calendar day.
    public static func isDay(_ text: String) -> Bool { dayStart(text) != nil }

    /// Midnight UTC of a "YYYY-MM-DD" day (for day arithmetic).
    static func dayStart(_ text: String) -> Date? {
        let c = Array(text.utf8)
        guard c.count == 10, c[4] == UInt8(ascii: "-"), c[7] == UInt8(ascii: "-") else { return nil }
        func digits(_ start: Int, _ count: Int) -> Int? {
            var value = 0
            for i in start..<(start + count) {
                guard c[i] >= 48, c[i] <= 57 else { return nil }
                value = value * 10 + Int(c[i] - 48)
            }
            return value
        }
        guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              isValid(year: year, month: month, day: day) else { return nil }
        return utcCalendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    static func isValid(year: Int, month: Int, day: Int) -> Bool {
        guard year >= 1, (1...12).contains(month), day >= 1 else { return false }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= lengths[month - 1]
    }

    static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }
}

// MARK: - Hash

/// FNV-1a, 64 bit: short stable ids from text (e.g. for records without a UUID).
public enum ExchangeHash {
    public static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// 16 lower-case hex digits: "" → "cbf29ce484222325".
    public static func hex(_ text: String) -> String {
        let digits = String(fnv1a64(text), radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}
