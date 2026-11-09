import SwiftUI
import BinisoftKit
import GeorgeCore

enum SessionScope: Hashable {
    case all
    case planned
    case done
    case favorites
    case kind(WorkoutKind)
    case program(UUID)

    var title: String {
        switch self {
        case .all: return "All Workouts"
        case .planned: return "Planned"
        case .done: return "Done"
        case .favorites: return "Favorites"
        case .kind(let kind): return kind.displayName
        case .program: return "Workouts"
        }
    }
}

enum SessionGrouping: String, CaseIterable, Identifiable {
    case date, week, month, type, template, status, priority, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .date: return "Date (like Notes)"
        case .week: return "Week"
        case .month: return "Month"
        case .type: return "Type"
        case .template: return "Template"
        case .status: return "Status"
        case .priority: return "Priority"
        case .none: return "None"
        }
    }
}

enum SessionSort: String, CaseIterable, Identifiable {
    case date, planned, updated, title, priority, duration
    var id: String { rawValue }
    var title: String {
        switch self {
        case .date: return "Workout Date"
        case .planned: return "Planned Date"
        case .updated: return "Last Edited"
        case .title: return "Title"
        case .priority: return "Priority"
        case .duration: return "Duration"
        }
    }
}

enum TemplateSort: String, CaseIterable, Identifiable {
    case manual, name, lastUsed, updated, priority
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manual: return "Manual"
        case .name: return "Name"
        case .lastUsed: return "Last Used"
        case .updated: return "Last Edited"
        case .priority: return "Priority"
        }
    }
}

/// Search tokens shown as chips in the search field.
enum SearchToken: Identifiable, Hashable {
    case kind(WorkoutKind)
    case status(SessionStatus)
    case tag(String)
    case priority(Priority)

    var id: String {
        switch self {
        case .kind(let kind): return "k:" + kind.rawValue
        case .status(let status): return "s:" + status.rawValue
        case .tag(let tag): return "t:" + tag
        case .priority(let priority): return "p:\(priority.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .kind(let kind): return kind.shortName
        case .status(let status): return status.displayName
        case .tag(let tag): return "#" + tag
        case .priority(let priority): return priority.displayName + " priority"
        }
    }

    var symbol: String {
        switch self {
        case .kind(let kind): return kind.symbol
        case .status(let status): return status.symbol
        case .tag: return "number"
        case .priority(let priority): return priority.symbol
        }
    }

    func matches(_ session: WorkoutSession) -> Bool {
        switch self {
        case .kind(let kind): return session.kind == kind
        case .status(let status): return session.status == status
        case .tag(let tag): return session.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        case .priority(let priority): return session.priority == priority
        }
    }

    func matches(_ template: WorkoutTemplate) -> Bool {
        switch self {
        case .kind(let kind): return template.kind == kind
        case .status: return true
        case .tag(let tag): return template.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        case .priority(let priority): return template.priority == priority
        }
    }
}

struct SessionGroup: Identifiable {
    var id: String
    var title: String
    var sessions: [WorkoutSession]
}

enum SessionGrouper {
    static func group(_ sessions: [WorkoutSession], by grouping: SessionGrouping, calendar: Calendar) -> [SessionGroup] {
        let pinned = sessions.filter(\.isPinned)
        let rest = sessions.filter { !$0.isPinned }
        var groups: [SessionGroup] = []
        if !pinned.isEmpty { groups.append(SessionGroup(id: "pinned", title: "Pinned", sessions: pinned)) }

        func ordered<Key: Hashable>(_ keyFor: (WorkoutSession) -> Key, title: (Key) -> String, sortKeys: ([Key]) -> [Key]) {
            var buckets: [Key: [WorkoutSession]] = [:]
            var order: [Key] = []
            for session in rest {
                let key = keyFor(session)
                if buckets[key] == nil { order.append(key) }
                buckets[key, default: []].append(session)
            }
            for key in sortKeys(order) {
                groups.append(SessionGroup(id: "\(key)", title: title(key), sessions: buckets[key] ?? []))
            }
        }

        switch grouping {
        case .none:
            if !rest.isEmpty { groups.append(SessionGroup(id: "all", title: pinned.isEmpty ? "" : "Workouts", sessions: rest)) }
        case .date:
            ordered({ DateBucket.bucket(for: $0.date, calendar: calendar) }, title: { $0.title }, sortKeys: { $0.sorted() })
        case .week:
            let namer = SessionNamer(calendar: calendar)
            ordered({ calendar.weekStart(for: $0.date) }, title: { namer.weekTitle(for: $0) }, sortKeys: { $0.sorted(by: >) })
        case .month:
            ordered({ session -> Date in
                calendar.date(from: calendar.dateComponents([.year, .month], from: session.date)) ?? session.date
            }, title: { $0.formatted(.dateTime.month(.wide).year()) }, sortKeys: { $0.sorted(by: >) })
        case .type:
            ordered({ $0.kind }, title: { $0.displayName }, sortKeys: { $0.sorted() })
        case .template:
            ordered({ $0.templateName.isEmpty ? "—" : $0.templateName }, title: { $0 == "—" ? "No Template" : $0 }, sortKeys: { $0.sorted() })
        case .status:
            let order: [SessionStatus] = [.active, .planned, .partial, .completed, .skipped]
            ordered({ $0.status }, title: { $0.displayName }, sortKeys: { keys in order.filter { keys.contains($0) } })
        case .priority:
            ordered({ $0.priority }, title: { $0 == .none ? "No Priority" : "\($0.displayName) Priority" }, sortKeys: { $0.sorted(by: >) })
        }
        return groups
    }
}

extension SessionSort {
    func sort(_ sessions: [WorkoutSession]) -> [WorkoutSession] {
        switch self {
        case .date: return sessions.sorted { $0.date > $1.date }
        case .planned: return sessions.sorted { ($0.plannedDate ?? .distantFuture) < ($1.plannedDate ?? .distantFuture) }
        case .updated: return sessions.sorted { $0.updatedAt > $1.updatedAt }
        case .title: return sessions.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .priority: return sessions.sorted { $0.priorityRaw != $1.priorityRaw ? $0.priorityRaw > $1.priorityRaw : $0.date > $1.date }
        case .duration: return sessions.sorted { $0.durationSeconds > $1.durationSeconds }
        }
    }
}
