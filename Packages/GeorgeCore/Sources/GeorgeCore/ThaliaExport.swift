import Foundation

// What George tells Thalia (Binisoft exchange v1, see docs/THALIA.md): one `workout.done` fact per
// finished workout, and the templates as refs. Only George's own synced records – nothing from
// Apple Health.

/// A workout as the Thalia export sees it (plain values, built from the synced store).
public struct ThaliaWorkout: Hashable, Sendable {
    /// How the workout got into George's synced store.
    public enum Source: String, Hashable, Sendable {
        /// Recorded or logged in George on iPhone, iPad or Mac.
        case george
        /// Recorded with George on the Apple Watch; arrived through George's own sync.
        case watch
        /// Only read back from Apple Health (another app, or a Health copy) – never exported.
        case appleHealth
    }

    /// The synced id of the workout (`WorkoutSession.id`).
    public var id: UUID
    public var title: String
    /// The template it was started from (synced id), nil for a free workout.
    public var templateID: UUID?
    /// The template's current name (or the name stored with the workout if the template is gone).
    public var templateTitle: String?
    /// When it ended.
    public var endedAt: Date
    /// Completed or stopped early (planned, running and skipped workouts are not exported).
    public var isFinished: Bool
    public var source: Source

    public init(id: UUID, title: String, templateID: UUID?, templateTitle: String?, endedAt: Date, isFinished: Bool,
                source: Source = .george) {
        self.id = id
        self.title = title
        self.templateID = templateID
        self.templateTitle = templateTitle
        self.endedAt = endedAt
        self.isFinished = isFinished
        self.source = source
    }
}

/// A template as a ref in `source.json`.
public struct ThaliaTemplate: Hashable, Sendable {
    public var id: UUID
    public var title: String

    public init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }
}

public enum ThaliaExport {
    /// The app folder's name in the App Group and the display name in `source.json`.
    public static let appName = "George"
    /// "george"
    public static let source = BinisoftExchange.sourceID(appName)
    /// The ref of workouts without a template.
    public static let freeRef = "frei"
    public static let freeTitle = "Freies Workout"
    /// Shown when a template has no name.
    public static let untitled = "Ohne Namen"

    /// The fact for one workout; nil when it is not finished or only came from Apple Health.
    public static func fact(for workout: ThaliaWorkout, timeZone: TimeZone = .current) -> ExchangeFact? {
        guard workout.isFinished, workout.source != .appleHealth else { return nil }
        let ref: String
        let refTitle: String
        if let templateID = workout.templateID {
            ref = templateID.uuidString
            refTitle = clean(workout.templateTitle) ?? untitled
        } else {
            ref = freeRef
            refTitle = freeTitle
        }
        return ExchangeFact(
            id: "wo-" + workout.id.uuidString,
            kind: .workoutDone,
            origin: .app,
            ref: ref,
            refTitle: refTitle,
            title: clean(workout.title) ?? refTitle,
            at: ExchangeDate.string(workout.endedAt, timeZone: timeZone)
        )
    }

    /// The facts of the last `BinisoftExchange.keepDays` days up to `today`, by day ("2026-11-22"),
    /// each day in file order. Days in the future are left out; a workout that sync duplicated
    /// (same id twice) counts once.
    public static func factsByDay(_ workouts: [ThaliaWorkout], today: String, timeZone: TimeZone = .current) -> [String: [ExchangeFact]] {
        guard let oldest = BinisoftExchange.day(today, adding: -BinisoftExchange.keepDays) else { return [:] }
        // Deterministic on every device: for duplicates the latest end wins.
        let ordered = workouts.sorted { ($0.id.uuidString, $1.endedAt) < ($1.id.uuidString, $0.endedAt) }
        var seen = Set<UUID>()
        var result: [String: [ExchangeFact]] = [:]
        for workout in ordered {
            guard let fact = fact(for: workout, timeZone: timeZone) else { continue }
            let day = ExchangeDate.day(workout.endedAt, timeZone: timeZone)
            guard day >= oldest, day <= today, seen.insert(workout.id).inserted else { continue }
            result[day, default: []].append(fact)
        }
        return result.mapValues(ExchangeFact.sorted)
    }

    /// `source.json` refs: every template (by name), then "Freies Workout".
    public static func refs(_ templates: [ThaliaTemplate]) -> [ExchangeRef] {
        var seen = Set<UUID>()
        let sorted = templates.sorted { lhs, rhs in
            let l = lhs.title.lowercased(), r = rhs.title.lowercased()
            if l != r { return l < r }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        var refs: [ExchangeRef] = []
        for template in sorted where seen.insert(template.id).inserted {
            refs.append(ExchangeRef(id: template.id.uuidString, title: clean(template.title) ?? untitled, kind: .workout))
        }
        refs.append(ExchangeRef(id: freeRef, title: freeTitle, kind: .workout))
        return refs
    }

    /// Thalia's link for a measure that counts a template's workouts (all workouts without an id).
    public static func workoutLink(templateID: UUID?) -> String {
        let base = "app:\(source):workout"
        guard let templateID else { return base }
        return base + "=" + templateID.uuidString
    }

    private static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// Writes the exchange files (format v1) into `appFolder` = `<App Group>/George`.
public enum ThaliaExchangeWriter {
    /// `facts`: every fact of the last 62 days from the synced store, by day ("2026-11-22").
    /// Writes only days whose facts changed (unchanged files keep their bytes and `generatedAt`),
    /// gives a day that had a file and now has nothing `"facts":[]`, never creates a file for a day
    /// without anything, and deletes day files older than 62 days. Returns true if anything changed.
    @discardableResult
    public static func sync(_ facts: [String: [ExchangeFact]], source: String, appFolder: URL, today: String,
                            now: Date = Date(), timeZone: TimeZone = .current) throws -> Bool {
        let manager = FileManager.default
        var changed = false
        for offset in 0...BinisoftExchange.keepDays {
            guard let day = BinisoftExchange.day(today, adding: -offset) else { continue }
            let url = BinisoftExchange.dayFileURL(appFolder: appFolder, day: day)
            let sorted = ExchangeFact.sorted(facts[day] ?? [])
            let old = try? Data(contentsOf: url)
            if old == nil && sorted.isEmpty { continue }
            if let old, case .success(let read) = ExchangeReader.dayFile(old),
               let same = try? ExchangeDayFile(source: source, day: day, generatedAt: read.file.generatedAt, facts: sorted).encoded(),
               same == old { continue }
            let file = ExchangeDayFile(source: source, day: day, generatedAt: ExchangeDate.string(now, timeZone: timeZone), facts: sorted)
            try BinisoftExchange.write(file.encoded(), to: url)
            changed = true
        }
        let days = BinisoftExchange.daysFolder(appFolder: appFolder)
        let names = (try? manager.contentsOfDirectory(atPath: days.path)) ?? []
        for name in BinisoftExchange.expiredDayFiles(names, today: today) {
            try? manager.removeItem(at: days.appendingPathComponent(name))
            changed = true
        }
        return changed
    }

    /// `source.json`: written right away when the refs, the app or its version changed, otherwise at
    /// most once a day (heartbeat). Returns true if it was written.
    @discardableResult
    public static func syncSource(refs: [ExchangeRef], source: String, app: String, appVersion: String, appFolder: URL,
                                  today: String, now: Date = Date(), timeZone: TimeZone = .current) throws -> Bool {
        let url = BinisoftExchange.sourceFileURL(appFolder: appFolder)
        let info = ExchangeSourceInfo(source: source, app: app, appVersion: appVersion,
                                      generatedAt: ExchangeDate.string(now, timeZone: timeZone), refs: refs)
        if let old = try? Data(contentsOf: url), case .success(let read) = ExchangeReader.source(old),
           read.skipped.isEmpty, read.info.sameContent(as: info),
           let written = ExchangeDate.parse(read.info.generatedAt),
           ExchangeDate.day(written, timeZone: timeZone) == today {
            return false
        }
        try BinisoftExchange.write(info.encoded(), to: url)
        return true
    }
}
