import Foundation
import GeorgeCore
import WidgetKit

/// What the watch-face complication and the Smart Stack show: the rest countdown while a workout
/// runs, otherwise the next workout and the week's streak.
///
/// The watch app writes it (`ComplicationBridge.write`) to the shared App Group,
/// `<group>/George/complication.json`; the GeorgeWatchWidgets extension reads it. This file is
/// compiled into both targets.
struct ComplicationData: Codable, Hashable, Sendable {
    struct Next: Codable, Hashable, Sendable {
        var title: String
        /// "Planned today", "6 exercises · 45 min".
        var detail: String
        var symbol: String
        /// A session planned for today (not just the program's suggestion).
        var isToday: Bool
    }

    struct Live: Codable, Hashable, Sendable {
        var title: String
        /// The exercise that's due (empty once every set is done).
        var exercise: String
        var symbol: String
        var completedSets: Int
        var totalSets: Int
        var restStartedAt: Date?
        var restEndsAt: Date?
        var isPaused: Bool

        /// The running rest as a countdown range (nil without one).
        var restInterval: ClosedRange<Date>? {
            guard let restEndsAt else { return nil }
            return min(restStartedAt ?? restEndsAt, restEndsAt)...restEndsAt
        }
    }

    var next: Next?
    var live: Live?
    var streakWeeks: Int
    var doneDays: Int
    var goal: Int
    var updatedAt: Date

    func hasSameContent(as other: ComplicationData?) -> Bool {
        guard var other else { return false }
        other.updatedAt = updatedAt
        return self == other
    }

    static let placeholder = ComplicationData(
        next: Next(title: "Upper Body", detail: "6 exercises · 45 min", symbol: "dumbbell.fill", isToday: false),
        live: nil, streakWeeks: 4, doneDays: 2, goal: 3, updatedAt: Date()
    )
}

extension ComplicationData {
    /// Built from what the phone sent: the running workout first, then today's planned session or
    /// the program's suggested template.
    init(snapshot: WatchSnapshot?, live: WatchLiveState?, now: Date = Date()) {
        var liveData: Live?
        if let live {
            var restStart: Date?
            var restEnd: Date?
            if !live.isPaused, let end = live.restEndsAt {
                restEnd = end
                restStart = end.addingTimeInterval(-Double(max(1, live.restTotalSeconds ?? 0)))
            }
            liveData = Live(
                title: live.title, exercise: live.current?.exercise.name ?? "", symbol: live.kind.symbol,
                completedSets: live.completedSets, totalSets: live.totalSets,
                restStartedAt: restStart, restEndsAt: restEnd, isPaused: live.isPaused
            )
        }

        var next: Next?
        if let today = snapshot?.upcoming.first(where: { Calendar.current.isDate($0.date, inSameDayAs: now) }) {
            next = Next(title: today.title, detail: "Planned today", symbol: today.kind.symbol, isToday: true)
        } else if let template = snapshot?.templates.first(where: \.isSuggested) ?? snapshot?.templates.first {
            var parts: [String] = []
            if template.exerciseCount > 0 { parts.append("\(template.exerciseCount) exercise\(template.exerciseCount == 1 ? "" : "s")") }
            if template.estimatedMinutes > 0 { parts.append("\(template.estimatedMinutes) min") }
            next = Next(title: template.name, detail: parts.joined(separator: " · "), symbol: template.kind.symbol, isToday: false)
        }

        self.init(
            next: next, live: liveData,
            streakWeeks: snapshot?.streak?.weeks ?? 0,
            doneDays: snapshot?.streak?.doneDays ?? 0,
            goal: snapshot?.streak?.goal ?? 0,
            updatedAt: now
        )
    }
}

enum ComplicationBridge {
    /// The complication's widget kind (for targeted reloads).
    static let kind = "GeorgeComplication"
    private static let folderName = "George"
    private static let fileName = "complication.json"
    private static let groupKey = "SharedAppGroup"

    @MainActor private static var lastWritten: ComplicationData?

    /// Call whenever the phone's snapshot or the live workout changed. Writes only when what the
    /// complication shows changed, then reloads it (the budget for reloads is small).
    @MainActor
    static func write(snapshot: WatchSnapshot?, live: WatchLiveState?) {
        let data = ComplicationData(snapshot: snapshot, live: live)
        guard !data.hasSameContent(as: lastWritten), let url = fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(data).write(to: url, options: .atomic)
            lastWritten = data
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        } catch {
            // No App Group in unsigned builds: the complication shows its placeholder.
        }
    }

    static func read() -> ComplicationData? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ComplicationData.self, from: data)
    }

    /// `<group>/George/complication.json`; nil without an App Group (unsigned builds).
    static var fileURL: URL? {
        guard let group = appGroup,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return root.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(fileName)
    }

    /// From Info.plist (`SharedAppGroup` = $(SHARED_APP_GROUP)). The watch app falls back to its
    /// embedded widget extension's Info.plist, which always carries the key.
    private static let appGroup: String? = {
        if let group = clean(Bundle.main.object(forInfoDictionaryKey: groupKey)) { return group }
        guard let plugIns = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil) else { return nil }
        for item in items where item.pathExtension == "appex" {
            if let group = clean(Bundle(url: item)?.object(forInfoDictionaryKey: groupKey)) { return group }
        }
        return nil
    }()

    private static func clean(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, !text.contains("$(") else { return nil }
        return text
    }
}
