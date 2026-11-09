import Foundation
import SwiftData
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

    var content: WorkoutContent {
        get { WorkoutContent.decode(contentData) }
        set {
            contentData = newValue.encoded()
            exerciseNames = newValue.allItems.map(\.name).joined(separator: " · ")
            exerciseCount = newValue.exerciseCount
            setCount = newValue.totalSets
            estimatedMinutes = Int((Double(newValue.estimatedSeconds()) / 60).rounded())
            touch()
        }
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

    var content: WorkoutContent {
        get { WorkoutContent.decode(contentData) }
        set {
            contentData = newValue.encoded()
            exerciseNames = newValue.allItems.map(\.name).joined(separator: " · ")
            exerciseCount = newValue.exerciseCount
            setCount = newValue.totalSets
            doneSetCount = newValue.completedSets
            volumeKg = newValue.volumeKg
            touch()
        }
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

    var summaryLine: String {
        switch status {
        case .planned:
            return exerciseCount > 0 ? "\(exerciseCount) exercises · \(setCount) sets" : "Empty workout"
        case .active:
            return "\(doneSetCount)/\(setCount) sets · \(Format.minutes(elapsedSeconds()))"
        case .completed, .partial:
            var parts = ["\(doneSetCount)/\(setCount) sets"]
            if durationSeconds > 0 { parts.append(Format.minutes(durationSeconds)) }
            if energyKcal > 0 { parts.append("\(Int(energyKcal)) kcal") }
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
