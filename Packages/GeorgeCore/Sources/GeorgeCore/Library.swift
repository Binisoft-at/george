import Foundation

/// An exercise from the bundled library (free-exercise-db + George's curated additions).
public struct LibraryExercise: Codable, Identifiable, Hashable, Sendable {
    public struct Defaults: Codable, Hashable, Sendable {
        public var sets: Int?
        public var reps: String?
        public var holdSec: Int?
        public var restSec: Int?
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

    enum CodingKeys: String, CodingKey {
        case id, name, kind, category, equipment, level, force, mechanic, primary, secondary, steps, aliases, tags, mode, defaults, perSide, images, symbol
    }

    public init(
        id: String, name: String, kind: WorkoutKind, category: String = "strength", equipment: String? = nil,
        level: String? = nil, force: String? = nil, mechanic: String? = nil, primary: [String] = [],
        secondary: [String] = [], steps: [String] = [], aliases: [String] = [], tags: [String] = [],
        mode: ExerciseMode = .reps, defaults: Defaults? = nil, perSide: Bool = false, images: [String] = [], symbol: String? = nil
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
    }

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
    private let searchText: [String: String]

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
        searchText = texts
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

    /// Best library match for a workout item (by id, then exact name/alias).
    public func match(for item: WorkoutItem) -> LibraryExercise? {
        exercise(id: item.exerciseID) ?? exercise(named: item.name)
    }

    public func imageURLs(for exercise: LibraryExercise) -> [URL] {
        exercise.images.compactMap { path in
            if path.hasPrefix("http") { return URL(string: path) }
            return URL(string: imageBase + path)
        }
    }

    public var allMuscles: [String] {
        Array(Set(exercises.flatMap(\.primary))).sorted()
    }

    public var allEquipment: [String] {
        Array(Set(exercises.compactMap(\.equipment))).sorted()
    }

    public var kinds: [WorkoutKind] {
        Array(Set(exercises.map(\.kind))).sorted()
    }

    /// Simple ranked search: every word must match; name prefix matches rank first.
    public func search(_ query: String, kind: WorkoutKind? = nil, muscle: String? = nil, equipment: String? = nil, limit: Int = 400) -> [LibraryExercise] {
        let words = ExerciseCatalog.fold(query).split(separator: " ").map(String.init)
        var scored: [(Int, LibraryExercise)] = []
        for exercise in exercises {
            if let kind, exercise.kind != kind { continue }
            if let muscle, !exercise.primary.contains(muscle) && !exercise.secondary.contains(muscle) { continue }
            if let equipment, exercise.equipment != equipment { continue }
            if words.isEmpty {
                scored.append((0, exercise))
                continue
            }
            let haystack = searchText[exercise.id] ?? ""
            guard words.allSatisfy({ haystack.contains($0) }) else { continue }
            let name = ExerciseCatalog.fold(exercise.name)
            var score = 3
            if name == words.joined(separator: " ") { score = 0 }
            else if name.hasPrefix(words[0]) { score = 1 }
            else if name.contains(words.joined(separator: " ")) { score = 2 }
            scored.append((score, exercise))
        }
        scored.sort { a, b in a.0 != b.0 ? a.0 < b.0 : a.1.name.localizedCaseInsensitiveCompare(b.1.name) == .orderedAscending }
        return Array(scored.prefix(limit).map(\.1))
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
