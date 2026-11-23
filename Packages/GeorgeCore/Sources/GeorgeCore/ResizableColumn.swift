import Foundation

/// A column whose edge is dragged to resize it (the Mac's list next to its detail). The width stays
/// in its range – also a stored width from an older range – and a drag counts from where it started,
/// so the edge follows the pointer instead of drifting while the column grows.
public struct ResizableColumn: Equatable, Sendable {
    public let range: ClosedRange<Double>
    /// Used when there is no usable width (nothing stored yet, or not a number).
    public let ideal: Double

    public init(range: ClosedRange<Double>, ideal: Double) {
        self.range = range
        self.ideal = min(max(ideal, range.lowerBound), range.upperBound)
    }

    /// `width` within the range.
    public func clamped(_ width: Double) -> Double {
        guard width.isFinite else { return ideal }
        return min(max(width, range.lowerBound), range.upperBound)
    }

    /// The width while dragging: the width the drag started at plus how far the edge moved.
    public func width(draggedFrom start: Double, by translation: Double) -> Double {
        guard translation.isFinite else { return clamped(start) }
        return clamped(clamped(start) + translation)
    }
}
