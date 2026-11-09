import Foundation
import Observation
import SwiftUI
import BinisoftKit
import GeorgeCore

/// Builds muscle-level analytics (freshness, muscular load, sets/volume per muscle) from the
/// workout log, resolving muscles through the exercise library. Cached per store revision.
@MainActor
@Observable
final class MuscleAnalytics {
    private let store: GeorgeStore
    private let library: ExerciseLibrary

    @ObservationIgnored private var cachedEngine: MuscleEngine?
    @ObservationIgnored private var cachedRevision = -1
    @ObservationIgnored private var cachedLibraryCount = -1
    @ObservationIgnored private var cachedRecoveryScale = 0.0

    init(store: GeorgeStore, library: ExerciseLibrary) {
        self.store = store
        self.library = library
    }

    /// Which muscles an exercise trains: library primary (1) + secondary (0.5), the item's own
    /// muscle list overriding the library's primary muscles.
    func contributions(for item: WorkoutItem) -> [MuscleContribution] {
        let match = library.exercise(for: item)
        let primary = item.muscles.isEmpty ? (match?.primary ?? []) : item.muscles
        let secondary = (match?.secondary ?? []).filter { !primary.contains($0) }
        return MuscleResolver.contributions(primary: primary, secondary: secondary, exerciseName: item.name)
    }

    var engine: MuscleEngine {
        let revision = store.revision
        let libraryCount = library.catalog.exercises.count
        // Recovery takes a little longer with age (Settings → Your Profile).
        let recoveryScale = store.profile.recoveryScale
        if let cachedEngine, cachedRevision == revision, cachedLibraryCount == libraryCount, cachedRecoveryScale == recoveryScale {
            return cachedEngine
        }
        let sessions = store.fetchSessions().filter { $0.status.isPerformed }
        let efforts = Dictionary(sessions.map { ($0.id, $0.effort) }, uniquingKeysWith: { a, _ in a })
        let events = MuscleEngine.events(
            from: sessions.map { $0.record() },
            effort: { efforts[$0] ?? 0 },
            contributions: { [unowned self] item in self.contributions(for: item) }
        )
        let engine = MuscleEngine(events: events, calendar: store.calendar, recoveryScale: recoveryScale)
        cachedEngine = engine
        cachedRecoveryScale = recoveryScale
        cachedRevision = revision
        cachedLibraryCount = libraryCount
        return engine
    }

    func plannedLoad(_ content: WorkoutContent, kind: WorkoutKind) -> [MuscleGroup: Double] {
        MusclePlan.load(of: content, kind: kind, contributions: { [unowned self] in self.contributions(for: $0) })
    }

    func plannedSets(_ content: WorkoutContent, completedOnly: Bool) -> [MuscleGroup: Double] {
        MusclePlan.sets(of: content, completedOnly: completedOnly, contributions: { [unowned self] in self.contributions(for: $0) })
    }

    /// 0…1 — how fresh the muscles a workout targets are right now.
    func readiness(of content: WorkoutContent, kind: WorkoutKind) -> Double {
        engine.readiness(for: plannedLoad(content, kind: kind))
    }

    /// Muscles a workout loads that aren't recovered yet, most fatigued first.
    func fatiguedTargets(of content: WorkoutContent, kind: WorkoutKind, minimumShare: Double = 0.1) -> [MuscleFreshness] {
        let load = plannedLoad(content, kind: kind)
        let total = load.values.reduce(0, +)
        guard total > 0 else { return [] }
        return load
            .filter { $0.value / total >= minimumShare }
            .map { engine.freshness(of: $0.key) }
            .filter { $0.status != .recovered }
            .sorted { $0.freshness < $1.freshness }
    }
}

// MARK: - Colours

enum MusclePalette {
    /// Neutral fill for muscles without data.
    static let empty = Color.secondary.opacity(0.22)

    /// Single warm ramp for magnitudes (sets, volume, load): light amber → red-orange.
    static func heat(_ value: Double) -> Color {
        guard value > 0 else { return empty }
        let t = max(0.08, min(1, value))
        let lo = (r: 247.0, g: 201.0, b: 107.0)
        let hi = (r: 232.0, g: 70.0, b: 30.0)
        return Color(
            red: (lo.r + (hi.r - lo.r) * t) / 255,
            green: (lo.g + (hi.g - lo.g) * t) / 255,
            blue: (lo.b + (hi.b - lo.b) * t) / 255
        )
    }

    static func freshness(_ status: FreshnessStatus) -> Color {
        switch status {
        case .recovered: return Color(hex: "#30D158")
        case .fatigued: return Color(hex: "#FF9F0A")
        case .depleted: return Color(hex: "#FF453A")
        }
    }

    static func load(_ status: LoadStatus) -> Color {
        switch status {
        case .calibrating: return .gray
        case .detraining: return Color(hex: "#F2A93B")
        case .peaking: return Color(hex: "#64D2FF")
        case .maintaining: return Color(hex: "#B4A9F5")
        case .productive: return Color(hex: "#30D158")
        case .fatigued: return Color(hex: "#FF7A45")
        case .overtraining: return Color(hex: "#FF3B30")
        }
    }
}

extension FreshnessStatus {
    var color: Color { MusclePalette.freshness(self) }
}

extension LoadStatus {
    var color: Color { MusclePalette.load(self) }
}

extension MuscleFreshness {
    /// "Ready now", "Ready in ~14 h", "Ready in ~2 days"
    var readyText: String {
        if hoursUntilRecovered <= 0.5 { return "Ready now" }
        if hoursUntilRecovered < 36 { return "Ready in ~\(Int(hoursUntilRecovered.rounded())) h" }
        return "Ready in ~\(Int((hoursUntilRecovered / 24).rounded())) days"
    }
}
