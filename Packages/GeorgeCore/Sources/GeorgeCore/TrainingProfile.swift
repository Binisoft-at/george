import Foundation

public enum TrainingGoal: String, CaseIterable, Sendable, Identifiable {
    case muscle, strength, fitness, endurance
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .muscle: return "Build muscle"
        case .strength: return "Get stronger"
        case .fitness: return "Stay fit & healthy"
        case .endurance: return "Muscular endurance"
        }
    }
}

public enum TrainingExperience: String, CaseIterable, Sendable, Identifiable {
    case beginner, intermediate, advanced
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .beginner: return "Beginner (< 1 year)"
        case .intermediate: return "Intermediate (1–3 years)"
        case .advanced: return "Advanced (3+ years)"
        }
    }
}

/// Who trains, for advice that fits: age, experience and goal. Every number is a guideline from the
/// training literature (sources in `sources`), never a rule.
public struct TrainingProfile: Equatable, Sendable {
    public var age: Int?
    public var experience: TrainingExperience
    public var goal: TrainingGoal

    public init(age: Int? = nil, experience: TrainingExperience = .intermediate, goal: TrainingGoal = .muscle) {
        self.age = age.flatMap { (10...100).contains($0) ? $0 : nil }
        self.experience = experience
        self.goal = goal
    }

    public init(birthYear: Int, experienceRaw: String, goalRaw: String, now: Date = Date(), calendar: Calendar = .training()) {
        let year = calendar.component(.year, from: now)
        self.init(age: birthYear > 1900 ? year - birthYear : nil,
                  experience: TrainingExperience(rawValue: experienceRaw) ?? .intermediate,
                  goal: TrainingGoal(rawValue: goalRaw) ?? .muscle)
    }

    var isOlder: Bool { (age ?? 0) >= 60 }

    /// Recovery takes a little longer with age: ×1 up to 30, then about +0.8 % a year, at most ×1.35.
    /// An estimate for the freshness model, not a measurement.
    public var recoveryScale: Double {
        guard let age, age > 30 else { return 1 }
        return min(1.35, 1 + Double(age - 30) * 0.008)
    }

    /// Hard sets per muscle and week.
    public var weeklySets: ClosedRange<Int> {
        switch goal {
        case .muscle:
            switch experience {
            case .beginner: return 6...10
            case .intermediate: return 10...16
            case .advanced: return 12...20
            }
        case .strength: return experience == .beginner ? 4...8 : 6...12
        case .fitness: return 4...10
        case .endurance: return 6...12
        }
    }

    /// Workouts per week that train each muscle.
    public var sessionsPerMuscle: ClosedRange<Int> {
        switch goal {
        case .muscle, .strength: return 2...3
        case .fitness, .endurance: return 2...3
        }
    }

    public var repRange: ClosedRange<Int> {
        switch goal {
        case .muscle: return isOlder ? 8...15 : 6...15
        case .strength: return isOlder ? 6...10 : 3...6
        case .fitness: return isOlder ? 10...15 : 8...12
        case .endurance: return 12...20
        }
    }

    /// Rest between sets, in seconds.
    public var restSeconds: ClosedRange<Int> {
        switch goal {
        case .muscle: return 90...180
        case .strength: return 120...300
        case .fitness: return 60...120
        case .endurance: return 30...60
        }
    }

    /// Hours before hammering the same muscle again.
    public var recoveryHours: ClosedRange<Int> {
        let base = 48.0 * recoveryScale
        return Int(base.rounded())...Int((72 * recoveryScale).rounded())
    }

    /// Reps left in the tank on working sets.
    public var repsInReserve: ClosedRange<Int> {
        switch experience {
        case .beginner: return 2...4
        case .intermediate: return 1...3
        case .advanced: return 0...2
        }
    }

    /// The optimal muscular-load band as a share of the usual weekly load (the 0.8–1.3 window,
    /// a bit narrower for beginners and older lifters).
    public var loadRatioBand: ClosedRange<Double> {
        (experience == .beginner || isOlder) ? 0.8...1.2 : 0.8...1.3
    }

    public var headline: String {
        var who = experience.title.components(separatedBy: " (").first ?? ""
        if let age { who += ", \(age)" }
        return "\(who) · \(goal.title)"
    }

    /// Short, plain explanations for the "optimal for you" sections.
    public var notes: [String] {
        var notes = [
            "\(weeklySets.lowerBound)–\(weeklySets.upperBound) hard sets per muscle and week, spread over \(sessionsPerMuscle.lowerBound)–\(sessionsPerMuscle.upperBound) workouts. More isn't always better: gains flatten out above ~20 sets.",
            "\(repRange.lowerBound)–\(repRange.upperBound) reps per set, stopping \(repsInReserve.lowerBound)–\(repsInReserve.upperBound) reps before failure.",
            "Rest \(Format.shortDuration(restSeconds.lowerBound))–\(Format.shortDuration(restSeconds.upperBound)) between sets; \(recoveryHours.lowerBound)–\(recoveryHours.upperBound) h before the same muscle works hard again.",
        ]
        if isOlder {
            notes.append("From 60 on, strength training matters even more (bone, balance, independence). Recovery takes a little longer, so George stretches its recovery estimates.")
        } else if let age, age > 30 {
            notes.append("George stretches recovery estimates a little with age (×\(Format.number((recoveryScale * 100).rounded() / 100)) for you).")
        }
        if experience == .beginner {
            notes.append("As a beginner, almost any consistent plan works – a few hard sets per muscle already drive progress.")
        }
        return notes
    }

    public static let sources: [TrainingSource] = [
        TrainingSource("Schoenfeld et al. 2017 – weekly sets and muscle growth", "https://pubmed.ncbi.nlm.nih.gov/27433992/"),
        TrainingSource("Pelland et al. 2024 – dose–response of volume and frequency", "https://sportrxiv.org/index.php/server/preprint/view/460"),
        TrainingSource("Schoenfeld et al. 2016 – training frequency", "https://pubmed.ncbi.nlm.nih.gov/27102172/"),
        TrainingSource("ACSM 2009 – progression models in resistance training", "https://pubmed.ncbi.nlm.nih.gov/19204579/"),
        TrainingSource("ACSM 2009 – exercise and physical activity for older adults", "https://pubmed.ncbi.nlm.nih.gov/19516148/"),
    ]
}

/// A study or guideline behind a recommendation.
public struct TrainingSource: Hashable, Sendable, Identifiable {
    public var id: String { url }
    public let title: String
    public let url: String

    public init(_ title: String, _ url: String) {
        self.title = title
        self.url = url
    }
}
