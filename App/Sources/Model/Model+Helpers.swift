import Foundation
import SwiftData
import BinisoftKit
import GeorgeCore

extension Program {
    var kind: WorkoutKind {
        get { WorkoutKind(kindRaw) }
        set { kindRaw = newValue.rawValue }
    }

    var orderedTemplates: [WorkoutTemplate] {
        (templates ?? []).sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.createdAt < rhs.createdAt
        }
    }

    var allSessions: [WorkoutSession] { sessions ?? [] }

    var performedSessions: [WorkoutSession] {
        allSessions.filter { $0.status.isPerformed }.sorted { $0.date > $1.date }
    }

    var lastActivity: Date? { allSessions.map(\.date).max() }

    func touch() { updatedAt = Date() }
}

extension WorkoutTemplate {
    var kind: WorkoutKind {
        get { WorkoutKind(kindRaw) }
        set { kindRaw = newValue.rawValue; touch() }
    }

    /// Reading never fails (empty when the data can't be read); writing never empties or strips the
    /// stored workout – see `storeContent(_:force:)`.
    var content: WorkoutContent {
        get { WorkoutContent.decode(contentData) }
        set { storeContent(newValue) }
    }

    /// Whether this template's workout can be edited here (`StoredContent.ReadState`).
    var contentReadState: StoredContent.ReadState { StoredContent.readState(of: contentData) }

    /// Writes the workout unless that would lose data: stored data this build can't read, or that a
    /// newer George wrote, stays as it is (logged; the screens show it read-only). `force`: an explicit
    /// replace (import with "Replace templates", restore). Returns false when the stored data was kept.
    @discardableResult
    func storeContent(_ newValue: WorkoutContent, force: Bool = false) -> Bool {
        switch StoredContent.write(newValue, over: contentData, force: force) {
        case .write(let data):
            contentData = data
        case .repaired(let data, let removed):
            AppLog.error("Template saved without \(removed) number(s) that can't be stored (NaN/infinity)", category: "store")
            contentData = data
        case .keep(let reason):
            AppLog.error("Template not saved: \(reason.logText)", category: "store")
            return false
        }
        exerciseNames = newValue.allItems.map(\.name).joined(separator: " · ")
        exerciseCount = newValue.exerciseCount
        setCount = newValue.totalSets
        estimatedMinutes = Int((Double(newValue.estimatedSeconds()) / 60).rounded())
        touch()
        return true
    }

    /// Puts stored data back exactly as it was (an import's Undo, a restore): bytes, not a re-encoding,
    /// so fields of a newer George and data this build can't read survive.
    func restoreContentData(_ data: Data?) {
        contentData = data
        if let content = try? WorkoutContent.decodeStrict(data) {
            exerciseNames = content.allItems.map(\.name).joined(separator: " · ")
            exerciseCount = content.exerciseCount
            setCount = content.totalSets
            estimatedMinutes = Int((Double(content.estimatedSeconds()) / 60).rounded())
        }
        touch()
    }

    var tags: [String] {
        get { tagsRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        set { tagsRaw = newValue.joined(separator: ","); touch() }
    }

    var priority: Priority {
        get { Priority(rawValue: priorityRaw) ?? .none }
        set { priorityRaw = newValue.rawValue; touch() }
    }

    /// Calendar weekdays (1 = Sunday … 7 = Saturday) this template is usually done on.
    var scheduleDays: [Int] {
        get { scheduleRaw.split(separator: ",").compactMap { Int($0) }.sorted() }
        set { scheduleRaw = newValue.sorted().map(String.init).joined(separator: ","); touch() }
    }

    var displayColorHex: String { colorHex ?? kind.colorHex }

    func touch() { updatedAt = Date() }

    var summaryLine: String {
        var parts: [String] = []
        if exerciseCount > 0 { parts.append("\(exerciseCount) exercises") }
        if setCount > 0 { parts.append("\(setCount) sets") }
        if estimatedMinutes > 0 { parts.append("~\(estimatedMinutes) min") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }
}

extension WorkoutSession {
    var kind: WorkoutKind {
        get { WorkoutKind(kindRaw) }
        set { kindRaw = newValue.rawValue; touch() }
    }

    var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .planned }
        set { statusRaw = newValue.rawValue; touch() }
    }

    /// Reading never fails (empty when the data can't be read); writing never empties or strips the
    /// stored workout – see `storeContent(_:force:)`.
    var content: WorkoutContent {
        get { WorkoutContent.decode(contentData) }
        set { storeContent(newValue) }
    }

    /// Whether this workout can be edited and started here (`StoredContent.ReadState`).
    var contentReadState: StoredContent.ReadState { StoredContent.readState(of: contentData) }

    /// Writes the workout unless that would lose data: stored data this build can't read, or that a
    /// newer George wrote, stays as it is (logged; the screens show it read-only and Start refuses).
    /// `force`: an explicit replace (a restore). Returns false when the stored data was kept.
    @discardableResult
    func storeContent(_ newValue: WorkoutContent, force: Bool = false) -> Bool {
        switch StoredContent.write(newValue, over: contentData, force: force) {
        case .write(let data):
            contentData = data
        case .repaired(let data, let removed):
            AppLog.error("Workout saved without \(removed) number(s) that can't be stored (NaN/infinity)", category: "store")
            contentData = data
        case .keep(let reason):
            AppLog.error("Workout not saved: \(reason.logText)", category: "store")
            return false
        }
        exerciseNames = newValue.allItems.map(\.name).joined(separator: " · ")
        exerciseCount = newValue.exerciseCount
        setCount = newValue.totalSets
        doneSetCount = newValue.completedSets
        volumeKg = newValue.volumeKg
        touch()
        return true
    }

    /// Puts stored data back exactly as it was (a restore): bytes, not a re-encoding.
    func restoreContentData(_ data: Data?) {
        contentData = data
        if let content = try? WorkoutContent.decodeStrict(data) {
            exerciseNames = content.allItems.map(\.name).joined(separator: " · ")
            exerciseCount = content.exerciseCount
            setCount = content.totalSets
            doneSetCount = content.completedSets
            volumeKg = content.volumeKg
        }
        touch()
    }

    var tags: [String] {
        get { tagsRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        set { tagsRaw = newValue.joined(separator: ","); touch() }
    }

    var priority: Priority {
        get { Priority(rawValue: priorityRaw) ?? .none }
        set { priorityRaw = newValue.rawValue; touch() }
    }

    /// The date a session belongs to: when it started, else when it's planned, else when it was created.
    var date: Date { startedAt ?? plannedDate ?? createdAt }

    var isRunning: Bool { status == .active && resumedAt != nil }
    var isPaused: Bool { status == .active && resumedAt == nil }

    func elapsedSeconds(at now: Date = Date()) -> Double {
        guard let resumedAt else { return accumulatedSeconds }
        return accumulatedSeconds + max(0, now.timeIntervalSince(resumedAt))
    }

    /// Duration of a finished session (active time, pauses excluded).
    var durationSeconds: Double {
        let elapsed = elapsedSeconds()
        if elapsed > 0 { return elapsed }
        if let startedAt, let endedAt { return max(0, endedAt.timeIntervalSince(startedAt)) }
        return 0
    }

    var progress: Double { setCount == 0 ? 0 : Double(doneSetCount) / Double(setCount) }

    var displayColorHex: String { colorHex ?? kind.colorHex }

    func touch() { updatedAt = Date() }

    /// With George's estimate for the calories ("≈"); views with the store pass
    /// `store.displayEnergy(for:)` to `summaryLine(energy:)` (measured when this device has it).
    var summaryLine: String {
        summaryLine(energy: EnergyDisplay.choose(measured: nil, estimated: energyKcal))
    }

    func summaryLine(energy: EnergyDisplay?) -> String {
        switch status {
        case .planned:
            return exerciseCount > 0 ? "\(exerciseCount) exercises · \(setCount) sets" : "Empty workout"
        case .active:
            return "\(doneSetCount)/\(setCount) sets · \(Format.minutes(elapsedSeconds()))"
        case .completed, .partial:
            var parts = ["\(doneSetCount)/\(setCount) sets"]
            if durationSeconds > 0 { parts.append(Format.minutes(durationSeconds)) }
            if let energy { parts.append(energy.text) }
            return parts.joined(separator: " · ")
        case .skipped:
            return "Skipped"
        }
    }

    func record() -> SessionRecord {
        SessionRecord(
            id: id, date: date, title: title, kind: kind, durationSeconds: durationSeconds,
            energyKcal: energyKcal, isCompleted: status == .completed, content: content
        )
    }
}

extension UserExercise {
    var kind: WorkoutKind {
        get { WorkoutKind(kindRaw) }
        set { kindRaw = newValue.rawValue }
    }

    var mode: ExerciseMode {
        get { ExerciseMode(rawValue: modeRaw) ?? .reps }
        set { modeRaw = newValue.rawValue }
    }

    var links: [String] {
        get { linksRaw.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
        set { linksRaw = newValue.joined(separator: "\n"); updatedAt = Date() }
    }

    var muscles: [String] {
        get { musclesRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        set { musclesRaw = newValue.joined(separator: ",") }
    }

    /// A library-shaped value so custom exercises appear alongside the bundled ones.
    var asLibraryExercise: LibraryExercise {
        LibraryExercise(
            id: key, name: name, kind: kind, category: "custom", equipment: equipment.isEmpty ? nil : equipment,
            primary: muscles, steps: instructions.split(separator: "\n").map(String.init),
            mode: mode, perSide: perSide, images: imageURL.isEmpty ? [] : [imageURL], symbol: nil
        )
    }
}

extension SyncedSettings {
    var unit: WeightUnit {
        get { WeightUnit(rawValue: unitRaw) ?? .kg }
        set { unitRaw = newValue.rawValue; updatedAt = Date() }
    }

    var goalHistory: [GoalChange] {
        get {
            guard let goalHistoryData else { return [] }
            return (try? JSONDecoder().decode([GoalChange].self, from: goalHistoryData)) ?? []
        }
        set {
            goalHistoryData = try? JSONEncoder().encode(newValue)
            updatedAt = Date()
        }
    }

    /// Change the weekly goal from this week on, keeping history so past weeks are judged fairly.
    func setWeeklyGoal(_ days: Int, calendar: Calendar) {
        let clamped = max(1, min(7, days))
        var history = goalHistory
        let thisWeek = calendar.weekStart(for: Date())
        if history.isEmpty {
            // Everything before today was judged by the previous goal.
            history.append(GoalChange(effectiveFrom: .distantPast, daysPerWeek: weeklyGoal))
        }
        history.removeAll { calendar.weekStart(for: $0.effectiveFrom) == thisWeek }
        history.append(GoalChange(effectiveFrom: thisWeek, daysPerWeek: clamped))
        goalHistory = history
        weeklyGoal = clamped
    }

    var streakConfig: StreakConfig {
        StreakConfig(
            goals: goalHistory, defaultGoal: weeklyGoal, weeksPerCredit: 2, maxCredits: 3,
            autoUseCredits: autoUseSaves, rescueCountsDouble: rescueCountsDouble
        )
    }
}
