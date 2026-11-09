import Foundation

/// Muscle groups George tracks (shown on the body map and in muscle stats).
public enum MuscleGroup: String, CaseIterable, Codable, Sendable, Identifiable, Comparable {
    case chest, shoulders, biceps, triceps, forearms
    case abs, obliques
    case traps, upperBack, lats, lowerBack
    case glutes, hipFlexors, quads, hamstrings, adductors, abductors, calves
    case neck

    public var id: String { rawValue }

    public static func < (lhs: MuscleGroup, rhs: MuscleGroup) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    public var displayName: String {
        switch self {
        case .chest: return "Chest"
        case .shoulders: return "Shoulders"
        case .biceps: return "Biceps"
        case .triceps: return "Triceps"
        case .forearms: return "Forearms"
        case .abs: return "Abs"
        case .obliques: return "Obliques"
        case .traps: return "Traps"
        case .upperBack: return "Upper Back"
        case .lats: return "Lats"
        case .lowerBack: return "Lower Back"
        case .glutes: return "Glutes"
        case .hipFlexors: return "Hip Flexors"
        case .quads: return "Quads"
        case .hamstrings: return "Hamstrings"
        case .adductors: return "Adductors"
        case .abductors: return "Abductors"
        case .calves: return "Calves"
        case .neck: return "Neck"
        }
    }

    public enum Region: String, Sendable { case upper, core, lower }

    public var region: Region {
        switch self {
        case .chest, .shoulders, .biceps, .triceps, .forearms, .traps, .upperBack, .lats, .neck: return .upper
        case .abs, .obliques, .lowerBack: return .core
        case .glutes, .hipFlexors, .quads, .hamstrings, .adductors, .abductors, .calves: return .lower
        }
    }

    /// Recovery time constant in hours (fatigue decays as e^(-t/τ)).
    /// Large muscles ≈ 90% recovered after ~70 h, small ones after ~45 h.
    public var recoveryTimeConstant: Double {
        switch self {
        case .quads, .glutes, .hamstrings, .lats, .upperBack, .lowerBack, .chest: return 30
        case .shoulders, .traps, .adductors, .abductors, .hipFlexors, .obliques: return 24
        case .biceps, .triceps, .forearms, .calves, .abs, .neck: return 20
        }
    }

    /// Maps library muscle names ("quadriceps", "middle back", …) to groups.
    public static func from(libraryName raw: String) -> MuscleGroup? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "chest", "pecs", "pectorals": return .chest
        case "shoulders", "shoulder", "delts", "deltoids": return .shoulders
        case "biceps": return .biceps
        case "triceps": return .triceps
        case "forearms", "forearm", "wrist", "grip": return .forearms
        case "abdominals", "abs", "core": return .abs
        case "obliques", "oblique": return .obliques
        case "traps", "trapezius": return .traps
        case "middle back", "upper back", "rhomboids", "rear delts": return .upperBack
        case "lats", "latissimus dorsi": return .lats
        case "lower back", "erectors", "spinal erectors": return .lowerBack
        case "glutes", "gluteus": return .glutes
        case "hip flexors", "hip flexor", "iliopsoas": return .hipFlexors
        case "quadriceps", "quads": return .quads
        case "hamstrings": return .hamstrings
        case "adductors", "adductor", "groin": return .adductors
        case "abductors", "abductor": return .abductors
        case "calves", "calf", "tibialis": return .calves
        case "neck": return .neck
        default: return nil
        }
    }
}

/// How much one set of an exercise counts for a muscle (1 = primary mover, 0.5 = secondary).
public struct MuscleContribution: Hashable, Sendable {
    public var group: MuscleGroup
    public var weight: Double
    public init(group: MuscleGroup, weight: Double) {
        self.group = group
        self.weight = weight
    }
}

public enum MuscleResolver {
    /// Primary muscles count a full set, secondary muscles half a set ("fractional" counting,
    /// which best explains hypertrophy outcomes in dose–response meta-analyses).
    public static let secondaryWeight = 0.5

    public static func contributions(primary: [String], secondary: [String], exerciseName: String) -> [MuscleContribution] {
        var weights: [MuscleGroup: Double] = [:]
        for name in primary {
            if let group = MuscleGroup.from(libraryName: name) { weights[group] = max(weights[group] ?? 0, 1) }
        }
        for name in secondary {
            if let group = MuscleGroup.from(libraryName: name) { weights[group] = max(weights[group] ?? 0, secondaryWeight) }
        }
        // The library has no obliques / hip flexors; infer them from the movement name.
        let lower = exerciseName.lowercased()
        let rotational = ["twist", "woodchop", "wood chop", "rotation", "side plank", "side bridge", "pallof", "oblique", "windmill", "russian", "anti-rotation", "forehand", "backhand", "side bend", "landmine"]
        if rotational.contains(where: lower.contains) {
            weights[.obliques] = max(weights[.obliques] ?? 0, weights[.abs] != nil ? 1 : secondaryWeight)
        }
        let hipFlexion = ["leg raise", "knee raise", "knee tuck", "mountain climber", "v-up", "flutter kick", "hanging", "hip flexor", "toes to bar", "l-sit", "scissor"]
        if hipFlexion.contains(where: lower.contains) {
            weights[.hipFlexors] = max(weights[.hipFlexors] ?? 0, secondaryWeight)
        }
        return weights.map { MuscleContribution(group: $0.key, weight: $0.value) }.sorted { $0.group < $1.group }
    }
}

/// Time windows for muscle statistics (like 7D / 30D / 3M / 1Y / YTD).
public enum MuscleRange: String, CaseIterable, Identifiable, Sendable {
    case week, month, quarter, year, yearToDate
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .week: return "7D"
        case .month: return "30D"
        case .quarter: return "3M"
        case .year: return "1Y"
        case .yearToDate: return "YTD"
        }
    }

    /// The interval ending at the end of `reference`'s day, shifted back by `offset` periods.
    public func interval(endingAt reference: Date, offset: Int = 0, calendar: Calendar) -> DateInterval {
        let endOfDay = calendar.addingDays(1, to: calendar.startOfDay(for: reference))
        switch self {
        case .yearToDate:
            let year = calendar.component(.year, from: reference) - offset
            let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? endOfDay
            let end = offset == 0 ? endOfDay : (calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? endOfDay)
            return DateInterval(start: start, end: max(start, end))
        default:
            let days = self.days
            let end = calendar.addingDays(-days * offset, to: endOfDay)
            return DateInterval(start: calendar.addingDays(-days, to: end), end: end)
        }
    }

    public var days: Int {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 91
        case .year: return 365
        case .yearToDate: return 365
        }
    }
}
