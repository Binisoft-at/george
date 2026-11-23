import Foundation

/// Rules for records that two devices created before they synced (settings, an exercise's personal
/// notes, a break week, the "Stretch & Yoga" program). iCloud can't keep records unique, so the app
/// merges the copies afterwards; these are the pure parts of that merge.
public enum DuplicateMerge {
    /// When a copy was created and last changed.
    public struct Stamp: Equatable, Sendable {
        public var createdAt: Date
        public var updatedAt: Date
        public init(createdAt: Date, updatedAt: Date) {
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        /// Changed after it was made – not just fresh defaults (a new device makes those before its
        /// first sync).
        public var wasEdited: Bool { updatedAt.timeIntervalSince(createdAt) > DuplicateMerge.editSlack }
    }

    /// How much later than its creation a change must be to count as an edit.
    public static let editSlack: TimeInterval = 2

    /// Which copy to keep (the oldest, so every device keeps the same one) and whose values it takes:
    /// the copy edited last. A copy nobody edited never wins over an edited one; with no edited copy
    /// the oldest keeps its own values.
    public static func plan(_ stamps: [Stamp]) -> (keep: Int, source: Int)? {
        guard !stamps.isEmpty else { return nil }
        let indices = Array(stamps.indices)
        let keep = indices.min { lhs, rhs in
            stamps[lhs].createdAt != stamps[rhs].createdAt ? stamps[lhs].createdAt < stamps[rhs].createdAt : lhs < rhs
        } ?? 0
        let edited = indices.filter { stamps[$0].wasEdited }
        let source = edited.max { lhs, rhs in
            stamps[lhs].updatedAt != stamps[rhs].updatedAt ? stamps[lhs].updatedAt < stamps[rhs].updatedAt : lhs > rhs
        } ?? keep
        return (keep, source)
    }

    /// One setting while merging: the value of the copy changed last – unless that copy still has
    /// the default there and the other one chose something (the newer copy may be a new device that
    /// only changed one thing before its first sync).
    public static func pick<T: Equatable>(_ newest: T, over older: T, default value: T) -> T {
        newest != value ? newest : older
    }

    /// Notes from several copies: each different text once (compared without surrounding spaces),
    /// in the order given, joined by a blank line.
    public static func joinedNotes(_ notes: [String]) -> String {
        var seen = Set<String>()
        var parts: [String] = []
        for note in notes {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            parts.append(trimmed)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Links from several copies, each once, in the order given.
    public static func unionLinks(_ lists: [[String]]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for link in lists.joined() {
            let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// Indices of the records that share a key, for every key that appears more than once (first
    /// appearance order).
    public static func groups<Key: Hashable>(_ keys: [Key]) -> [[Int]] {
        var order: [Key] = []
        var byKey: [Key: [Int]] = [:]
        for (index, key) in keys.enumerated() {
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(index)
        }
        return order.compactMap { key in
            guard let indices = byKey[key], indices.count > 1 else { return nil }
            return indices
        }
    }
}
