import Foundation

/// The type of a workout or exercise. A small set of presets is built in, but any
/// other value is allowed ("tennis", "pilates", "climbing", ...) so imports never fail.
public struct WorkoutKind: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible, Comparable {
    public let rawValue: String

    public var id: String { rawValue }
    public var description: String { rawValue }

    public init(_ raw: String) {
        self.rawValue = WorkoutKind.normalize(raw)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: WorkoutKind, rhs: WorkoutKind) -> Bool {
        let li = presets.firstIndex(of: lhs) ?? Int.max
        let ri = presets.firstIndex(of: rhs) ?? Int.max
        if li != ri { return li < ri }
        return lhs.rawValue < rhs.rawValue
    }

    public static let gym = WorkoutKind(raw: "gym")
    public static let band = WorkoutKind(raw: "band")
    public static let bodyweight = WorkoutKind(raw: "bodyweight")
    public static let core = WorkoutKind(raw: "core")
    public static let hiit = WorkoutKind(raw: "hiit")
    public static let cardio = WorkoutKind(raw: "cardio")
    public static let stretch = WorkoutKind(raw: "stretch")
    public static let yoga = WorkoutKind(raw: "yoga")
    public static let mobility = WorkoutKind(raw: "mobility")
    public static let sport = WorkoutKind(raw: "sport")
    public static let other = WorkoutKind(raw: "other")

    public static let presets: [WorkoutKind] = [
        .gym, .band, .bodyweight, .core, .hiit, .cardio, .stretch, .yoga, .mobility, .sport, .other,
    ]

    private init(raw: String) { self.rawValue = raw }

    public var isPreset: Bool { WorkoutKind.presets.contains(self) }

    public var displayName: String {
        switch rawValue {
        case "gym": return "Gym"
        case "band": return "Elastic Band"
        case "bodyweight": return "Bodyweight"
        case "core": return "Core"
        case "hiit": return "HIIT"
        case "cardio": return "Cardio"
        case "stretch": return "Stretching"
        case "yoga": return "Yoga"
        case "mobility": return "Mobility & Prehab"
        case "sport": return "Sport"
        case "other": return "Other"
        default:
            return rawValue
                .split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    public var shortName: String {
        switch rawValue {
        case "band": return "Bands"
        case "stretch": return "Stretch"
        case "mobility": return "Mobility"
        default: return displayName
        }
    }

    /// SF Symbol used across the apps.
    public var symbol: String {
        switch rawValue {
        case "gym": return "dumbbell.fill"
        case "band": return "figure.strengthtraining.functional"
        case "bodyweight": return "figure.cross.training"
        case "core": return "figure.core.training"
        case "hiit": return "figure.highintensity.intervaltraining"
        case "cardio": return "figure.run"
        case "stretch": return "figure.flexibility"
        case "yoga": return "figure.yoga"
        case "mobility": return "figure.cooldown"
        case "sport", "tennis": return "figure.tennis"
        case "pilates": return "figure.pilates"
        case "climbing": return "figure.climbing"
        case "swimming", "swim": return "figure.pool.swim"
        case "cycling", "bike": return "figure.outdoor.cycle"
        case "walking", "walk": return "figure.walk"
        default: return "figure.mixed.cardio"
        }
    }

    /// Accent color as hex, used as the default tint for workouts of this kind.
    public var colorHex: String {
        switch rawValue {
        case "gym": return "#FF6B35"
        case "band": return "#30B0C7"
        case "bodyweight": return "#5E5CE6"
        case "core": return "#FF9F0A"
        case "hiit": return "#FF375F"
        case "cardio": return "#FF453A"
        case "stretch": return "#34C759"
        case "yoga": return "#AF52DE"
        case "mobility": return "#64D2FF"
        case "sport", "tennis": return "#C7D600"
        default: return "#8E8E93"
        }
    }

    /// Default way exercises of this kind are measured.
    public var defaultMode: ExerciseMode {
        switch rawValue {
        case "stretch", "yoga", "mobility": return .time
        case "cardio": return .time
        default: return .reps
        }
    }

    /// Metabolic equivalent used for energy estimates when no heart-rate data exists.
    public var met: Double {
        switch rawValue {
        case "gym": return 5.0
        case "band": return 3.8
        case "bodyweight": return 4.3
        case "core": return 3.8
        case "hiit": return 8.0
        case "cardio": return 7.0
        case "stretch": return 2.3
        case "yoga": return 2.8
        case "mobility": return 2.5
        case "sport", "tennis": return 7.3
        default: return 4.0
        }
    }

    private static let aliases: [String: String] = [
        "gym": "gym", "weights": "gym", "weight training": "gym", "strength": "gym",
        "strength training": "gym", "lifting": "gym", "weightlifting": "gym", "barbell": "gym",
        "dumbbell": "gym", "machine": "gym",
        "band": "band", "bands": "band", "elastic": "band", "elastic band": "band",
        "elastic bands": "band", "resistance band": "band", "resistance bands": "band",
        "eb": "band", "tube": "band", "tubes": "band",
        "bodyweight": "bodyweight", "body weight": "bodyweight", "body only": "bodyweight",
        "calisthenics": "bodyweight", "bw": "bodyweight", "home": "bodyweight",
        "core": "core", "abs": "core",
        "hiit": "hiit", "interval": "hiit", "intervals": "hiit", "tabata": "hiit", "circuit": "hiit",
        "cardio": "cardio", "conditioning": "cardio", "run": "cardio", "running": "cardio",
        "stretch": "stretch", "stretches": "stretch", "stretching": "stretch", "flexibility": "stretch",
        "yoga": "yoga",
        "mobility": "mobility", "prehab": "mobility", "rehab": "mobility", "pre&mob": "mobility",
        "prehab & mobility": "mobility", "prehab + mobility": "mobility", "warm-up": "mobility",
        "warmup": "mobility", "recovery": "mobility",
        "sport": "sport", "sports": "sport",
        "other": "other", "": "other",
    ]

    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let mapped = aliases[trimmed] { return mapped }
        let collapsed = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        if let mapped = aliases[collapsed] { return mapped }
        // Slugify custom kinds: "Tennis Drills" -> "tennis-drills"
        let allowed = CharacterSet.alphanumerics
        var slug = ""
        var lastWasDash = false
        for scalar in collapsed.unicodeScalars {
            if allowed.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "other" : slug
    }
}

/// How an exercise is measured.
public enum ExerciseMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case reps, time, distance
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .reps: return "Reps"
        case .time: return "Time"
        case .distance: return "Distance"
        }
    }
}

public enum WeightUnit: String, Codable, CaseIterable, Sendable, Identifiable {
    case kg, lb
    public var id: String { rawValue }
    public static let poundsPerKilogram = 2.2046226218

    public func fromKilograms(_ kg: Double) -> Double {
        self == .kg ? kg : kg * WeightUnit.poundsPerKilogram
    }

    public func toKilograms(_ value: Double) -> Double {
        self == .kg ? value : value / WeightUnit.poundsPerKilogram
    }

    public var increment: Double { self == .kg ? 2.5 : 5 }
}

public enum Priority: Int, Codable, CaseIterable, Sendable, Identifiable, Comparable {
    case none = 0, low = 1, medium = 2, high = 3
    public var id: Int { rawValue }
    public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    public var displayName: String {
        switch self {
        case .none: return "None"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
    public var symbol: String {
        switch self {
        case .none: return "minus"
        case .low: return "exclamationmark"
        case .medium: return "exclamationmark.2"
        case .high: return "exclamationmark.3"
        }
    }
}
