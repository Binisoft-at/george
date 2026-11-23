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
        /// The history index's version: moves only when performed workouts really changed (not with
        /// template edits, plans, settings or a running workout's sets).
        var revision: Int
        var libraryCount: Int
        var firstWeekday: Int
        var setCeiling: Double
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
            revision: SessionHistory.shared.version(store),
            libraryCount: library.catalog.exercises.count,
            firstWeekday: store.settings.weekStartsOn,
            setCeiling: Double(profile.weeklySets.upperBound),
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
                                  setCeiling: key.setCeiling)
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

    // MARK: Muscular load

    private struct LoadSummaryKey: Hashable {
        var group: MuscleGroup?
        var days: Int
        var day: Date
    }

    /// Load summaries of the current engine (`loadSummary(group:days:now:)`).
    @ObservationIgnored private var loadSummaries: (key: EngineKey, values: [LoadSummaryKey: LoadSummary])?

    /// The engine's muscular load (whole body or one muscle), kept per muscle, days and day while the
    /// engine stays the same: the load card, the muscle detail and every exercise's progression chip in
    /// live mode ask for the same ones on each redraw. It only depends on the day of `now`.
    func loadSummary(group: MuscleGroup? = nil, days: Int = 30, now: Date = Date()) -> LoadSummary {
        let engine = self.engine
        guard let engineKey = cachedKey else { return engine.loadSummary(group: group, days: days, now: now) }
        let key = LoadSummaryKey(group: group, days: days, day: engine.calendar.startOfDay(for: now))
        var values = loadSummaries?.key == engineKey ? (loadSummaries?.values ?? [:]) : [:]
        if let hit = values[key] { return hit }
        let summary = engine.loadSummary(group: group, days: days, now: now)
        if values.count >= 64 { values.removeAll() }
        values[key] = summary
        loadSummaries = (key: engineKey, values: values)
        return summary
    }
}

// MARK: - History index

/// The performed sessions as plain records, shared by the muscle engine, the Progress tab, exercise
/// history and "last time" lookups. Checked when `historyRevision` moves – only the workouts that are
/// new or changed since are decoded (`HistoryIndex`); the first build decodes on all cores.
@MainActor
final class SessionHistory {
    static let shared = SessionHistory()

    private var index = HistoryIndex()
    private var cachedRevision = -1
    private var cachedStore: ObjectIdentifier?
    /// Moves whenever the records change (also when the index changes stores: never repeats).
    private var currentVersion = 0

    /// Performed sessions, oldest first.
    func records(_ store: GeorgeStore) -> [SessionRecord] {
        refresh(store)
        return index.records
    }

    /// Moves only when the records really changed – caches built from them key on it (a history
    /// bump that changed nothing costs one look at the stamps, no rebuild).
    func version(_ store: GeorgeStore) -> Int {
        refresh(store)
        return currentVersion
    }

    /// The effort rating (1–10, 0 = none) of a session in the last `records` result.
    func effort(of sessionID: UUID) -> Int { index.effort(of: sessionID) }

    /// Whether the session was performed when the index last looked (a save that makes it planned
    /// again still changes the history). False while the index belongs to another store.
    func contains(_ sessionID: UUID, in store: GeorgeStore) -> Bool {
        cachedStore == ObjectIdentifier(store) && index.contains(sessionID)
    }

    private func refresh(_ store: GeorgeStore) {
        let id = ObjectIdentifier(store)
        let revision = store.historyRevision
        if cachedRevision == revision, cachedStore == id { return }
        if cachedStore != id {
            index = HistoryIndex()
            currentVersion &+= 1
        }
        cachedStore = id
        cachedRevision = revision
        if index.isEmpty {
            // First build: one fetch with the content, decoded on all cores.
            let sessions = store.fetchPerformedSessions()
            let contents = WorkoutContent.decodeAll(sessions.map(\.contentData))
            var entries: [UUID: HistoryIndex.Entry] = [:]
            var stamps: [UUID: HistoryStamp] = [:]
            for (session, content) in zip(sessions, contents) {
                let stamp = session.historyStamp
                stamps[session.id] = stamp
                entries[session.id] = HistoryIndex.Entry(stamp: stamp, record: session.record(content: content), effort: session.effort)
            }
            if index.update(to: stamps, decode: { _ in entries }) { currentVersion &+= 1 }
            return
        }
        // Later: the stamps without the content; only new and changed workouts are read and decoded.
        let sessions = store.fetchPerformedSessions(scalarsOnly: true)
        var byID: [UUID: WorkoutSession] = [:]
        var stamps: [UUID: HistoryStamp] = [:]
        for session in sessions {
            byID[session.id] = session
            stamps[session.id] = session.historyStamp
        }
        let didChange = index.update(to: stamps) { changed in
            if changed.count > 32 {
                // Many at once (a big import): one fetch with the content instead of one per workout.
                for session in store.fetchPerformedSessions() { byID[session.id] = session }
            }
            let contents = WorkoutContent.decodeAll(changed.map { byID[$0]?.contentData })
            var entries: [UUID: HistoryIndex.Entry] = [:]
            for (sessionID, content) in zip(changed, contents) {
                guard let session = byID[sessionID] else { continue }
                entries[sessionID] = HistoryIndex.Entry(stamp: session.historyStamp, record: session.record(content: content), effort: session.effort)
            }
            return entries
        }
        if didChange { currentVersion &+= 1 }
    }
}

// MARK: - Fresh after iCloud

/// Workouts that arrive through iCloud don't go through the store's saves: after every finished
/// import (debounced) this compares a cheap fingerprint of the store and moves only the counters the
/// import changed – the history for performed workouts, the data for plans, templates and settings,
/// `liveRevision` for a workout running on another device. A set ticked on the iPhone while the Mac
/// sits idle doesn't make the Mac rebuild its history, muscles or Today.
@MainActor
final class CloudImportRefresher {
    /// Posted after each import was looked at (the running workout checks whether it ended or moved
    /// to another device: `LiveWorkoutController.syncedStatusChanged`).
    static let didRefresh = Notification.Name("George.cloudImportRefreshed")

    private let store: GeorgeStore
    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    /// The store as the last import (or the launch) left it.
    private var fingerprint: SyncFingerprint?

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
            MainActor.assumeIsolated {
                // Welcome on a new device waits for the first import before it offers a sample program.
                self?.store.noteCloudImport()
                self?.scheduleBump()
            }
        }
        // Copies two devices made before they synced (settings, exercise notes, break weeks): merged
        // once at launch, then after every import. The fingerprint the first import is compared with.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.store.resolveDuplicates()
            if self.fingerprint == nil { self.fingerprint = self.store.syncFingerprint() }
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
            self.store.resolveDuplicates()
            let now = self.store.syncFingerprint()
            let change = now.changes(since: self.fingerprint)
            self.fingerprint = now
            self.store.bump(change)
            // Ended, deleted or continued elsewhere – also when no counter moved (sets merged in).
            NotificationCenter.default.post(name: Self.didRefresh, object: self.store)
            if !change.isEmpty {
                AppLog.info("iCloud import – refreshed \(Self.describe(change))", category: "sync")
            }
        }
    }

    private static func describe(_ change: StoreChange) -> String {
        var parts: [String] = []
        if change.contains(.history) { parts.append("history") }
        if change.contains(.data) { parts.append("data") }
        if change.contains(.live) { parts.append("running workout") }
        return parts.joined(separator: ", ")
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
            : "\(Int(acuteSets.rounded())) sets in 7 days, \(status.displayName.lowercased())"
    }
}

extension TrainingProfile {
    /// "80–130 %" – the optimal load band of this profile.
    var loadBandText: String {
        "\(Int((loadRatioBand.lowerBound * 100).rounded()))–\(Int((loadRatioBand.upperBound * 100).rounded())) %"
    }
}
