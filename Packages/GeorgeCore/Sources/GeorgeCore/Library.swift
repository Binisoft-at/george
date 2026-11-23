import Foundation

/// An exercise from the bundled library (free-exercise-db + George's curated additions).
public struct LibraryExercise: Codable, Identifiable, Hashable, Sendable {
    public struct Defaults: Codable, Hashable, Sendable {
        public var sets: Int?
        public var reps: String?
        public var holdSec: Int?
        public var restSec: Int?
    }

    /// A page that shows how it's done, with photos or video (Yoga Journal, ACE, NHS …).
    public struct Reference: Codable, Hashable, Sendable {
        public var site: String
        public var title: String
        public var url: String

        public init(site: String, title: String, url: String) {
            self.site = site
            self.title = title
            self.url = url
        }
    }

    /// Who made the preview picture and under which licence (Wikimedia Commons).
    public struct ImageCredit: Codable, Hashable, Sendable {
        public var author: String
        public var license: String
        public var licenseUrl: String?
        public var filePage: String?

        public init(author: String, license: String, licenseUrl: String? = nil, filePage: String? = nil) {
            self.author = author
            self.license = license
            self.licenseUrl = licenseUrl
            self.filePage = filePage
        }

        /// "Photo: Jane Doe · CC BY-SA 4.0"
        public var line: String { "Picture: \(author) · \(license)" }
    }

    public var id: String
    public var name: String
    public var kind: WorkoutKind
    public var category: String
    public var equipment: String?
    public var level: String?
    public var force: String?
    public var mechanic: String?
    public var primary: [String]
    public var secondary: [String]
    public var steps: [String]
    public var aliases: [String]
    public var tags: [String]
    public var mode: ExerciseMode
    public var defaults: Defaults?
    public var perSide: Bool
    public var images: [String]
    public var symbol: String?
    /// How-to pages with photos or video (checked sources).
    public var references: [Reference]
    /// Licence information for a preview picture from Wikimedia Commons.
    public var credit: ImageCredit?
    /// When to be careful or skip it ("Avoid with neck problems; never turn the head").
    public var caution: String?

    enum CodingKeys: String, CodingKey {
        case id, name, kind, category, equipment, level, force, mechanic, primary, secondary, steps, aliases, tags, mode, defaults, perSide, images, symbol, references, credit, caution
    }

    public init(
        id: String, name: String, kind: WorkoutKind, category: String = "strength", equipment: String? = nil,
        level: String? = nil, force: String? = nil, mechanic: String? = nil, primary: [String] = [],
        secondary: [String] = [], steps: [String] = [], aliases: [String] = [], tags: [String] = [],
        mode: ExerciseMode = .reps, defaults: Defaults? = nil, perSide: Bool = false, images: [String] = [], symbol: String? = nil,
        references: [Reference] = [], credit: ImageCredit? = nil, caution: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.category = category
        self.equipment = equipment
        self.level = level
        self.force = force
        self.mechanic = mechanic
        self.primary = primary
        self.secondary = secondary
        self.steps = steps
        self.aliases = aliases
        self.tags = tags
        self.mode = mode
        self.defaults = defaults
        self.perSide = perSide
        self.images = images
        self.symbol = symbol
        self.references = references
        self.credit = credit
        self.caution = caution
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(WorkoutKind.self, forKey: .kind) ?? .gym
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "strength"
        equipment = try c.decodeIfPresent(String.self, forKey: .equipment)
        level = try c.decodeIfPresent(String.self, forKey: .level)
        force = try c.decodeIfPresent(String.self, forKey: .force)
        mechanic = try c.decodeIfPresent(String.self, forKey: .mechanic)
        primary = try c.decodeIfPresent([String].self, forKey: .primary) ?? []
        secondary = try c.decodeIfPresent([String].self, forKey: .secondary) ?? []
        steps = try c.decodeIfPresent([String].self, forKey: .steps) ?? []
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        mode = (try? c.decodeIfPresent(ExerciseMode.self, forKey: .mode)) ?? .reps
        defaults = try? c.decodeIfPresent(Defaults.self, forKey: .defaults)
        perSide = try c.decodeIfPresent(Bool.self, forKey: .perSide) ?? false
        images = try c.decodeIfPresent([String].self, forKey: .images) ?? []
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        references = (try? c.decodeIfPresent([Reference].self, forKey: .references)) ?? []
        credit = try? c.decodeIfPresent(ImageCredit.self, forKey: .credit)
        caution = try c.decodeIfPresent(String.self, forKey: .caution)
    }

    /// Stretching, yoga and mobility: positions people need to see described, not just named.
    public var needsGuidance: Bool { ["stretch", "yoga", "mobility"].contains(kind.rawValue) }

    public var source: String { id.split(separator: ":").first.map(String.init) ?? "custom" }

    public var displaySymbol: String { symbol ?? kind.symbol }

    /// Builds a workout item with the library's default prescription.
    public func makeItem(defaultRest: Int? = nil) -> WorkoutItem {
        let count = max(1, defaults?.sets ?? (mode == .time ? 2 : 3))
        var sets: [WorkoutSet] = []
        for _ in 0..<count {
            switch mode {
            case .reps: sets.append(WorkoutSet(targetReps: defaults?.reps ?? "10"))
            case .time: sets.append(WorkoutSet(targetSeconds: defaults?.holdSec ?? 30))
            case .distance: sets.append(WorkoutSet(targetMeters: defaults?.reps.flatMap { LooseParse.meters($0) } ?? 400))
            }
        }
        return WorkoutItem(
            exerciseID: id, name: name, kind: kind, mode: mode, sets: sets, perSide: perSide,
            restSeconds: defaults?.restSec ?? defaultRest, links: [], equipment: equipment,
            muscles: primary, imageURL: nil
        )
    }
}

public struct LibraryFile: Codable, Sendable {
    public struct Source: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var url: String?
        public var license: String?
    }
    public var version: Int
    public var imageBase: String?
    public var sources: [Source]
    public var exercises: [LibraryExercise]

    enum CodingKeys: String, CodingKey { case version, imageBase, sources, exercises }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        imageBase = try c.decodeIfPresent(String.self, forKey: .imageBase)
        sources = try c.decodeIfPresent([Source].self, forKey: .sources) ?? []
        exercises = try c.decodeIfPresent([LibraryExercise].self, forKey: .exercises) ?? []
    }

    public init(version: Int = 1, imageBase: String? = nil, sources: [Source] = [], exercises: [LibraryExercise] = []) {
        self.version = version
        self.imageBase = imageBase
        self.sources = sources
        self.exercises = exercises
    }
}

/// In-memory searchable catalog.
public final class ExerciseCatalog: @unchecked Sendable {
    public let exercises: [LibraryExercise]
    public let sources: [LibraryFile.Source]
    private let imageBase: String
    private let byID: [String: LibraryExercise]
    private let byName: [String: LibraryExercise]
    /// Per exercise, in `exercises` order: everything a search looks in (folded) …
    private let searchTexts: [String]
    /// … its folded name …
    private let foldedNames: [String]
    /// … and its place in the alphabetical order of names (ties keep the file's order). Built once,
    /// so a search sorts by two integers instead of comparing localized names.
    private let alphabeticalRanks: [Int]
    /// Name and alias words per exercise, for fuzzy matching.
    private let nameTokens: [(exercise: LibraryExercise, tokens: Set<String>)]
    private let lock = NSLock()
    private var fuzzyCache: [String: String] = [:]
    /// Muscles any exercise trains first, sorted (the muscle filter).
    public let allMuscles: [String]
    /// Equipment of the exercises, sorted.
    public let allEquipment: [String]
    /// Kinds that have exercises, in display order (the kind filter).
    public let kinds: [WorkoutKind]

    public init(file: LibraryFile) {
        exercises = file.exercises
        sources = file.sources
        imageBase = file.imageBase ?? "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/"
        var ids: [String: LibraryExercise] = [:]
        var names: [String: LibraryExercise] = [:]
        var texts: [String: String] = [:]
        for exercise in file.exercises {
            ids[exercise.id] = exercise
            names[ExerciseCatalog.fold(exercise.name)] = names[ExerciseCatalog.fold(exercise.name)] ?? exercise
            for alias in exercise.aliases { names[ExerciseCatalog.fold(alias)] = names[ExerciseCatalog.fold(alias)] ?? exercise }
            texts[exercise.id] = ExerciseCatalog.fold(([exercise.name] + exercise.aliases + exercise.primary + exercise.tags + [exercise.equipment ?? "", exercise.kind.displayName]).joined(separator: " "))
        }
        byID = ids
        byName = names
        let all = file.exercises
        searchTexts = all.map { texts[$0.id] ?? "" }
        foldedNames = all.map { ExerciseCatalog.fold($0.name) }
        let alphabetical = all.indices.sorted { a, b in
            let order = all[a].name.localizedCaseInsensitiveCompare(all[b].name)
            return order == .orderedSame ? a < b : order == .orderedAscending
        }
        var ranks = [Int](repeating: 0, count: all.count)
        for (rank, index) in alphabetical.enumerated() { ranks[index] = rank }
        alphabeticalRanks = ranks
        nameTokens = file.exercises.flatMap { exercise in
            ([exercise.name] + exercise.aliases).map { (exercise: exercise, tokens: ExerciseCatalog.tokens($0)) }
        }
        allMuscles = Array(Set(all.flatMap(\.primary))).sorted()
        allEquipment = Array(Set(all.compactMap(\.equipment))).sorted()
        kinds = Array(Set(all.map(\.kind))).sorted()
    }

    public convenience init(data: Data) throws {
        let file = try JSONDecoder().decode(LibraryFile.self, from: data)
        self.init(file: file)
    }

    public static let empty = ExerciseCatalog(file: LibraryFile())

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    public func exercise(id: String?) -> LibraryExercise? {
        guard let id else { return nil }
        return byID[id]
    }

    public func exercise(named name: String) -> LibraryExercise? {
        byName[ExerciseCatalog.fold(name)]
    }

    /// Best library match for a workout item: by id, then exact name/alias, then the closest name
    /// that contains all its words ("Barbell Bench Press" → "Barbell Bench Press - Medium Grip").
    public func match(for item: WorkoutItem) -> LibraryExercise? {
        exercise(id: item.exerciseID) ?? exercise(named: item.name) ?? fuzzyMatch(item.name)
    }

    /// The exercise whose name (or alias) shares the most words with `name`, when one contains all
    /// the words of the other and they overlap at least half. Exercises with pictures win ties.
    public func fuzzyMatch(_ name: String) -> LibraryExercise? {
        let key = ExerciseCatalog.fold(name).lowercased()
        lock.lock()
        let cached = fuzzyCache[key]
        lock.unlock()
        if let cached { return cached.isEmpty ? nil : byID[cached] }
        let query = ExerciseCatalog.tokens(name)
        var best: (score: Double, exercise: LibraryExercise)?
        if !query.isEmpty {
            for entry in nameTokens {
                let common = query.intersection(entry.tokens).count
                guard common > 0, common == query.count || common == entry.tokens.count else { continue }
                var score = Double(common) / Double(query.union(entry.tokens).count)
                if !entry.exercise.images.isEmpty { score += 0.05 }
                if score > (best?.score ?? 0) { best = (score, entry.exercise) }
            }
        }
        let result = (best?.score ?? 0) >= 0.5 ? best?.exercise : nil
        lock.lock()
        fuzzyCache[key] = result?.id ?? ""
        lock.unlock()
        return result
    }

    private static let synonyms: [String: String] = [
        "db": "dumbbell", "dbs": "dumbbell", "bb": "barbell", "kb": "kettlebell", "ez": "ez",
        "pullup": "pull", "pullups": "pull", "pushup": "push", "pushups": "push", "chinup": "chin", "chinups": "chin",
        "situp": "sit", "situps": "sit", "lat": "lat", "lats": "lat", "tricep": "triceps", "bicep": "biceps",
    ]
    private static let stopwords: Set<String> = ["the", "a", "an", "with", "and", "on", "of", "to", "for", "in"]

    /// Lowercased words without punctuation, plurals and filler ("Dumbbell Curls" → dumbbell, curl).
    static func tokens(_ text: String) -> Set<String> {
        let words = fold(text).lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var result = Set<String>()
        for var word in words where !stopwords.contains(word) {
            if let synonym = synonyms[word] { word = synonym }
            if word.hasSuffix("sses") { word = String(word.dropLast(2)) }
            else if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us") { word = String(word.dropLast()) }
            result.insert(word)
        }
        return result
    }

    public func imageURLs(for exercise: LibraryExercise) -> [URL] {
        exercise.images.compactMap { path in
            if path.hasPrefix("http") { return URL(string: path) }
            return URL(string: imageBase + path)
        }
    }

    /// Simple ranked search: every word must match; name prefix matches rank first, then A–Z.
    public func search(_ query: String, kind: WorkoutKind? = nil, muscle: String? = nil, equipment: String? = nil, limit: Int = 400) -> [LibraryExercise] {
        let words = ExerciseCatalog.fold(query).split(separator: " ").map(String.init)
        let phrase = words.joined(separator: " ")
        // (score, alphabetical rank, index): integers only – the order of names was worked out once.
        var scored: [(score: Int, rank: Int, index: Int)] = []
        for (index, exercise) in exercises.enumerated() {
            if let kind, exercise.kind != kind { continue }
            if let muscle, !exercise.primary.contains(muscle) && !exercise.secondary.contains(muscle) { continue }
            if let equipment, exercise.equipment != equipment { continue }
            if words.isEmpty {
                scored.append((0, alphabeticalRanks[index], index))
                continue
            }
            let haystack = searchTexts[index]
            guard words.allSatisfy({ haystack.contains($0) }) else { continue }
            let name = foldedNames[index]
            var score = 3
            if name == phrase { score = 0 }
            else if name.hasPrefix(words[0]) { score = 1 }
            else if name.contains(phrase) { score = 2 }
            scored.append((score, alphabeticalRanks[index], index))
        }
        scored.sort { a, b in a.score != b.score ? a.score < b.score : a.rank < b.rank }
        return scored.prefix(limit).map { exercises[$0.index] }
    }
}

/// Tutorial links that always work, even without a stored video.
public enum TutorialLinks {
    public static func youtubeSearch(for name: String, kind: WorkoutKind?) -> URL? {
        let suffix: String
        switch kind?.rawValue {
        case "band": suffix = "resistance band exercise tutorial"
        case "stretch": suffix = "stretch how to"
        case "yoga": suffix = "yoga pose tutorial"
        case "mobility": suffix = "mobility drill tutorial"
        case "cardio": suffix = "technique tutorial"
        default: suffix = "exercise proper form"
        }
        var components = URLComponents(string: "https://www.youtube.com/results")
        components?.queryItems = [URLQueryItem(name: "search_query", value: "\(name) \(suffix)")]
        return components?.url
    }

    /// Extracts a YouTube video id from common URL shapes.
    public static func youtubeID(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        if host.contains("youtu.be") {
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }
        guard host.contains("youtube.com") else { return nil }
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = comps.queryItems?.first(where: { $0.name == "v" })?.value {
            return v
        }
        let parts = url.path.split(separator: "/").map(String.init)
        if let idx = parts.firstIndex(where: { $0 == "shorts" || $0 == "embed" || $0 == "live" }), idx + 1 < parts.count {
            return parts[idx + 1]
        }
        return nil
    }

    public static func youtubeThumbnail(for url: URL) -> URL? {
        guard let id = youtubeID(from: url) else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }

    public enum LinkKind: Sendable { case youtube, video, image, web }

    public static func kind(of url: URL) -> LinkKind {
        if youtubeID(from: url) != nil { return .youtube }
        let ext = url.pathExtension.lowercased()
        if ["mp4", "mov", "m4v", "m3u8"].contains(ext) { return .video }
        if ["gif", "jpg", "jpeg", "png", "webp", "heic"].contains(ext) { return .image }
        return .web
    }
}
