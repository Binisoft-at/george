import Foundation

// Helpers for the "all mutations go through one store type" rule: soft delete with a trash that
// empties itself, timestamps, and fractional sort orders (from Theo's TaskStore).

/// A record that is moved to "Recently Deleted" instead of being deleted right away.
///
/// Don't name your own property `isDeleted`: SwiftData's `PersistentModel` already has one.
public protocol SoftDeletable: AnyObject {
    var deletedAt: Date? { get set }
    var modifiedAt: Date { get set }
}

public extension SoftDeletable {
    var isInTrash: Bool { deletedAt != nil }

    func moveToTrash(now: Date = Date()) {
        deletedAt = now
        modifiedAt = now
    }

    func restoreFromTrash(now: Date = Date()) {
        deletedAt = nil
        modifiedAt = now
    }

    func touch(now: Date = Date()) {
        modifiedAt = now
    }
}

/// How long "Recently Deleted" keeps things.
public struct TrashPolicy: Equatable, Sendable {
    public var keepDays: Int

    public init(keepDays: Int = 30) {
        self.keepDays = keepDays
    }

    public func isExpired(deletedAt: Date?, now: Date = Date()) -> Bool {
        guard let deletedAt else { return false }
        return now.timeIntervalSince(deletedAt) >= Double(keepDays) * 86_400
    }

    /// Whole days left before it is gone for good (0 = today).
    public func daysLeft(deletedAt: Date, now: Date = Date()) -> Int {
        let left = Double(keepDays) * 86_400 - now.timeIntervalSince(deletedAt)
        return max(0, Int(left / 86_400))
    }
}

/// Fractional sort orders: inserting between two rows never renumbers the others.
public enum ListOrder {
    /// A value between `before` and `after` (either may be nil: start or end of the list).
    public static func between(_ before: Double?, _ after: Double?) -> Double {
        switch (before, after) {
        case let (b?, a?): return (b + a) / 2
        case let (b?, nil): return b + 1
        case let (nil, a?): return a - 1
        case (nil, nil): return 0
        }
    }

    /// The order for a new row at the end.
    public static func after(_ values: [Double]) -> Double {
        (values.max() ?? -1) + 1
    }

    /// The order for a new row at the top.
    public static func before(_ values: [Double]) -> Double {
        (values.min() ?? 1) - 1
    }

    /// True when repeated midpoint inserts made gaps too small; then renumber with `normalized`.
    public static func needsNormalizing(_ sorted: [Double], minimumGap: Double = 0.000_001) -> Bool {
        guard sorted.count > 1 else { return false }
        for index in 1..<sorted.count where sorted[index] - sorted[index - 1] < minimumGap {
            return true
        }
        return false
    }

    public static func normalized(count: Int) -> [Double] {
        (0..<max(0, count)).map(Double.init)
    }

    /// New order values for moving rows (List `onMove`): returns the moved rows' new values,
    /// by index in the original array. Only the moved rows change.
    public static func move(_ orders: [Double], from source: IndexSet, to destination: Int) -> [Int: Double] {
        var indices = Array(orders.indices)
        let moving = source.sorted()
        let movingSet = Set(moving)
        let insertAt = destination - moving.filter { $0 < destination }.count
        indices.removeAll { movingSet.contains($0) }
        let before = insertAt > 0 ? orders[indices[insertAt - 1]] : nil
        let after = insertAt < indices.count ? orders[indices[insertAt]] : nil
        var result: [Int: Double] = [:]
        let count = Double(moving.count)
        for (offset, index) in moving.enumerated() {
            let position = Double(offset + 1) / (count + 1)
            switch (before, after) {
            case let (b?, a?): result[index] = b + (a - b) * position
            case let (b?, nil): result[index] = b + Double(offset + 1)
            case let (nil, a?): result[index] = a - count + Double(offset)
            case (nil, nil): result[index] = Double(offset)
            }
        }
        return result
    }
}
