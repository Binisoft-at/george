import Foundation
import Observation
import SwiftUI
import CoreData
import BinisoftKit
import GeorgeCore

/// Builds muscle-level analytics (freshness, muscular load, sets/volume per muscle) from the
/// workout log, resolving muscles through the exercise library. Cached per store revision, profile
/// (recovery scale and load band) and – with "Count other sports" on – the Apple Health workouts.
@MainActor
@Observable
final class MuscleAnalytics {
    private let store: GeorgeStore
    private let library: ExerciseLibrary
    /// Apple Health workouts (tennis, runs …) – nil in the tour's practice store.
    private let health: HealthKitManager?

    /// Everything the engine is built from; views use it as their `.task(id:)` so they recompute
    /// exactly when the analytics change.
    struct EngineKey: Hashable {
        var revision: Int
        var libraryCount: Int
        var recoveryScale: Double
        var bandLow: Double
        var bandHigh: Double
        var countsOtherSports: Bool
        var healthVersion: Int
    }

    @ObservationIgnored private var cachedEngine: MuscleEngine?
    @ObservationIgnored private var cachedKey: EngineKey?
    /// Settings → "Count other sports", mirrored so views refresh when it's switched.
    private(set) var countsOtherSports = CoachPrefs.countOtherSports
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?

    init(store: GeorgeStore, library: ExerciseLibrary, health: HealthKitManager? = nil) {
        self.store = store
        self.library = library
        self.health = health
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let value = CoachPrefs.countOtherSports
                if value != self.countsOtherSports { self.countsOtherSports = value }
            }
        }
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    /// Which muscles an exercise trains: library primary (1) + secondary (0.5), the item's own
    /// muscle list overriding the library's primary muscles.
    func contributions(for item: WorkoutItem) -> [MuscleContribution] {
        library.contributions(for: item)
    }

    var engineKey: EngineKey {
        let profile = store.profile
        let band = profile.loadRatioBand
        let countsOtherSports = health != nil && self.countsOtherSports
        return EngineKey(
            revision: store.revision,
            libraryCount: library.catalog.exercises.count,
            // Recovery takes a little longer with age (Settings → Your Profile).
            recoveryScale: profile.recoveryScale,
            bandLow: band.lowerBound,
            bandHigh: band.upperBound,
            countsOtherSports: countsOtherSports,
            healthVersion: countsOtherSports ? (health?.workoutsVersion ?? 0) : 0
        )
    }

    var engine: MuscleEngine {
        let key = engineKey
        if let cachedEngine, cachedKey == key { return cachedEngine }
        let history = SessionHistory.shared
        let records = history.records(store)
        var events = MuscleEngine.events(
            from: records,
            effort: { history.effort(of: $0) },
            contributions: { [unowned self] item in self.contributions(for: item) }
        )
        if key.countsOtherSports, let health {
            // Other sports add load (recovery, muscular load) but never sets.
            events += SportLoad.events(from: health.healthWorkouts)
        }
        // A jump over the usual week only warns when a muscle got more than the profile's weekly target.
        let engine = MuscleEngine(events: events, calendar: store.calendar, recoveryScale: key.recoveryScale,
                                  loadBand: key.bandLow...key.bandHigh,
                                  setCeiling: Double(store.profile.weeklySets.upperBound))
        cachedEngine = engine
        cachedKey = key
        return engine
    }

    func plannedLoad(_ content: WorkoutContent, kind: WorkoutKind) -> [MuscleGroup: Double] {
        MusclePlan.load(of: content, kind: kind, contributions: { [unowned self] in self.contributions(for: $0) })
    }

    /// Hard sets per muscle. Pass the workout's kind so stretch, yoga, mobility and cardio don't count as sets.
    func plannedSets(_ content: WorkoutContent, completedOnly: Bool, kind: WorkoutKind? = nil) -> [MuscleGroup: Double] {
        MusclePlan.sets(of: content, completedOnly: completedOnly, kind: kind, contributions: { [unowned self] in self.contributions(for: $0) })
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

// MARK: - History index

/// The performed sessions as plain records, decoded once per store revision and shared by the
/// muscle engine, the Progress tab, exercise history and "last time" lookups.
@MainActor
final class SessionHistory {
    static let shared = SessionHistory()

    private var cached: [SessionRecord] = []
    private var efforts: [UUID: Int] = [:]
    private var cachedRevision = -1
    private var cachedStore: ObjectIdentifier?

    /// Performed sessions, oldest first.
    func records(_ store: GeorgeStore) -> [SessionRecord] {
        let id = ObjectIdentifier(store)
        if cachedRevision == store.revision, cachedStore == id { return cached }
        let sessions = store.fetchSessions().filter { $0.status.isPerformed }
        efforts = Dictionary(sessions.map { ($0.id, $0.effort) }, uniquingKeysWith: { a, _ in a })
        cached = sessions.map { $0.record() }.sorted { $0.date < $1.date }
        cachedRevision = store.revision
        cachedStore = id
        return cached
    }

    /// The effort rating (1–10, 0 = none) of a session in the last `records` result.
    func effort(of sessionID: UUID) -> Int { efforts[sessionID] ?? 0 }
}

// MARK: - Fresh after iCloud

/// Workouts that arrive through iCloud don't go through the store, so nothing bumps its revision:
/// this bumps it (debounced) after every finished import, and analytics, Progress and "last time"
/// refresh after a sync.
@MainActor
final class CloudImportRefresher {
    private let store: GeorgeStore
    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?

    init(store: GeorgeStore) {
        self.store = store
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event,
                  event.type == .import, event.endDate != nil, event.succeeded else { return }
            MainActor.assumeIsolated { self?.scheduleBump() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func scheduleBump() {
        pending?.cancel()
        pending = Task { [weak self] in
            // Imports come in bursts; the main context also needs a moment to merge them.
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            self.store.bump()
            AppLog.info("iCloud import – analytics refreshed", category: "sync")
        }
    }
}

// MARK: - Colours

enum MusclePalette {
    /// Neutral fill for muscles without data.
    static let empty = Color.secondary.opacity(0.22)

    /// Single warm ramp for magnitudes (volume, load): light amber → red-orange.
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

    /// Fills (body map, dots, bars): green → amber → red.
    static func freshness(_ status: FreshnessStatus) -> Color {
        switch status {
        case .recovered: return Color(hex: "#30D158")
        case .fatigued: return Color(hex: "#FFB21A")
        case .depleted: return Color(hex: "#FF453A")
        }
    }

    /// Words in a freshness colour, readable on the card background.
    static func freshnessText(_ status: FreshnessStatus) -> Color {
        switch status {
        case .recovered: return Tone.goodText
        case .fatigued: return Tone.cautionText
        case .depleted: return Tone.badText
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

    /// Words in a load colour, readable on the card background.
    static func loadText(_ status: LoadStatus) -> Color {
        switch status {
        case .calibrating: return .secondary
        case .detraining: return Tone.cautionText
        case .peaking: return Tone.infoText
        case .maintaining: return Tone.calmText
        case .productive: return Tone.goodText
        case .fatigued: return Tone.cautionText
        case .overtraining: return Tone.badText
        }
    }
}

extension FreshnessStatus {
    /// Fill colour (maps, dots, bars).
    var color: Color { MusclePalette.freshness(self) }
    /// Colour for the status word.
    var textColor: Color { MusclePalette.freshnessText(self) }
    /// A symbol, so the status never relies on colour alone.
    var symbol: String {
        switch self {
        case .recovered: return "checkmark.circle.fill"
        case .fatigued: return "hourglass"
        case .depleted: return "exclamationmark.triangle.fill"
        }
    }
}

extension LoadStatus {
    /// Fill colour (gauge, chart points, status strip).
    var color: Color { MusclePalette.load(self) }
    /// Colour for the status word.
    var textColor: Color { MusclePalette.loadText(self) }
}

extension MuscleFreshness {
    /// "Ready now", "Ready in ~14 h", "Ready in ~2 days"
    var readyText: String {
        if hoursUntilRecovered <= 0.5 { return "Ready now" }
        if hoursUntilRecovered < 36 { return "Ready in ~\(Int(hoursUntilRecovered.rounded())) h" }
        return "Ready in ~\(Int((hoursUntilRecovered / 24).rounded())) days"
    }
}

extension LoadPoint {
    /// There is a usual week to compare with (not calibrating).
    var showsRatio: Bool { status != .calibrating && chronic > 0.01 }

    /// "150 %" – or the sets while there is no usual week yet.
    var headline: String {
        showsRatio ? "\(percentOfUsual) %" : "\(Int(acuteSets.rounded()))"
    }

    /// What the headline number is.
    var headlineCaption: String {
        showsRatio ? "of your usual week" : "sets in 7 days"
    }

    /// "52 sets in 7 days · usual ≈ 24 a week" – real sets (the % compares effort-weighted load).
    var detailLine: String {
        let sets = "\(Int(acuteSets.rounded())) sets in 7 days"
        guard usualSets > 0.01 else { return sets }
        return sets + " · usual ≈ \(Int(usualSets.rounded())) a week"
    }

    /// "80–130 %"
    var bandText: String {
        "\(Int((lowRatio * 100).rounded()))–\(Int((highRatio * 100).rounded())) %"
    }

    /// For VoiceOver and chart tooltips: "150 % of your usual week, fatigued".
    var spokenSummary: String {
        showsRatio
            ? "\(percentOfUsual) % of your usual week, \(status.displayName.lowercased())"
            : "\(Int(acute.rounded())) hard sets in 7 days, \(status.displayName.lowercased())"
    }
}

extension TrainingProfile {
    /// "80–130 %" – the optimal load band of this profile.
    var loadBandText: String {
        "\(Int((loadRatioBand.lowerBound * 100).rounded()))–\(Int((loadRatioBand.upperBound * 100).rounded())) %"
    }
}
