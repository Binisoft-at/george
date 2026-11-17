import Foundation

/// What the exercise progress chart plots.
public enum ProgressMetric: String, CaseIterable, Sendable, Identifiable {
    case oneRepMax, topSet, volume, reps, seconds
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .oneRepMax: return "e1RM"
        case .topSet: return "Top set"
        case .volume: return "Volume"
        case .reps: return "Reps"
        case .seconds: return "Longest hold"
        }
    }

    /// One line on what the number means.
    public var explanation: String {
        switch self {
        case .oneRepMax: return "Estimated one-rep max of your best set – fair across rep ranges."
        case .topSet: return "Your heaviest set, whatever the reps."
        case .volume: return "Reps × weight of the working sets."
        case .reps: return "Total reps of the sessions without added weight."
        case .seconds: return "Your longest hold."
        }
    }
}

/// One session on the exercise progress chart.
public struct ProgressSample: Hashable, Sendable, Identifiable {
    public var id: UUID { sessionID }
    public var sessionID: UUID
    public var date: Date
    /// kg for e1RM, top set and volume; reps; or seconds.
    public var value: Double
    /// Reps of the top set ("80 kg × 5").
    public var reps: Int?
    /// Better than every earlier session (never the first one).
    public var isRecord: Bool

    public init(sessionID: UUID, date: Date, value: Double, reps: Int? = nil, isRecord: Bool = false) {
        self.sessionID = sessionID
        self.date = date
        self.value = value
        self.reps = reps
        self.isRecord = isRecord
    }
}

/// Turns an exercise history into chart series that answer "am I getting stronger?": e1RM by default
/// (80 × 3 after 75 × 10 is not progress), sessions without weight as their own reps series.
public enum ExerciseProgress {
    static func isWeighted(_ set: WorkoutSet) -> Bool {
        (set.effectiveWeight ?? 0) > 0 && (set.effectiveReps ?? 0) > 0
    }

    /// The metrics a history can show, the default first: weighted lifts → e1RM, top set, volume
    /// (plus reps when some sessions were done without weight); bodyweight → reps; holds → seconds.
    public static func metrics(for points: [ExercisePoint], mode: ExerciseMode) -> [ProgressMetric] {
        if mode == .time {
            return points.contains { ($0.bestSeconds ?? 0) > 0 } ? [.seconds] : []
        }
        var result: [ProgressMetric] = []
        if points.contains(where: { $0.sets.contains(where: isWeighted) }) {
            result += [.oneRepMax, .topSet, .volume]
        }
        if points.contains(where: { bodyweightReps($0) != nil }) {
            result.append(.reps)
        }
        if result.isEmpty, points.contains(where: { ($0.bestSeconds ?? 0) > 0 }) {
            result.append(.seconds)
        }
        return result
    }

    /// Total reps of a session's working sets when none of them used weight; nil otherwise.
    public static func bodyweightReps(_ point: ExercisePoint) -> Int? {
        let working = point.sets.filter { $0.kind != .warmup }
        guard !working.contains(where: isWeighted) else { return nil }
        let reps = working.compactMap(\.effectiveReps).reduce(0, +)
        return reps > 0 ? reps : nil
    }

    /// One sample per session that has the metric, oldest first, with records marked.
    public static func samples(_ points: [ExercisePoint], metric: ProgressMetric) -> [ProgressSample] {
        var result: [ProgressSample] = []
        var best = -Double.infinity
        for point in points.sorted(by: { $0.date < $1.date }) {
            guard let measured = value(of: point, metric: metric), measured.value > 0 else { continue }
            let isRecord = !result.isEmpty && measured.value > best + 0.0001
            best = max(best, measured.value)
            result.append(ProgressSample(sessionID: point.sessionID, date: point.date, value: measured.value,
                                         reps: measured.reps, isRecord: isRecord))
        }
        return result
    }

    static func value(of point: ExercisePoint, metric: ProgressMetric) -> (value: Double, reps: Int?)? {
        let weighted = point.sets.filter(isWeighted)
        switch metric {
        case .oneRepMax:
            let best = weighted.map { StatsEngine.oneRepMax(weight: $0.effectiveWeight ?? 0, reps: $0.effectiveReps ?? 0) }.max()
            return best.map { (value: $0, reps: nil) }
        case .topSet:
            let top = weighted.max { lhs, rhs in
                ((lhs.effectiveWeight ?? 0), (lhs.effectiveReps ?? 0)) < ((rhs.effectiveWeight ?? 0), (rhs.effectiveReps ?? 0))
            }
            guard let top else { return nil }
            return (value: top.effectiveWeight ?? 0, reps: top.effectiveReps)
        case .volume:
            let working = weighted.filter { $0.kind != .warmup }
            guard !working.isEmpty else { return nil }
            return (value: working.reduce(0) { $0 + Double($1.effectiveReps ?? 0) * ($1.effectiveWeight ?? 0) }, reps: nil)
        case .reps:
            return bodyweightReps(point).map { (value: Double($0), reps: nil) }
        case .seconds:
            return point.bestSeconds.map { (value: Double($0), reps: nil) }
        }
    }
}
