import Foundation

// What is due now in a live workout when sets are ticked out of order, and when a superset or
// circuit rests. The planned order (`executionOrder`) stays the guide; these rules keep "now" on
// the set that is really still open, and rest a superset only once its round is done.
extension WorkoutContent {
    /// Whether the block alternates its exercises round by round (a superset or circuit).
    private func alternatesRounds(_ blockIndex: Int) -> Bool {
        guard blocks.indices.contains(blockIndex) else { return false }
        return blocks[blockIndex].style.isGrouped && blocks[blockIndex].items.count > 1
    }

    private func isDone(_ slot: RoundSlot, inBlock blockIndex: Int) -> Bool {
        set(at: SetRef(blockIndex: blockIndex, itemIndex: slot.itemIndex, setIndex: slot.setIndex))?.isDone == true
    }

    /// The round a superset/circuit set belongs to (nil for straight sets).
    public func roundIndex(of ref: SetRef) -> Int? {
        guard alternatesRounds(ref.blockIndex) else { return nil }
        return roundSlots(ofBlock: ref.blockIndex)
            .first { $0.itemIndex == ref.itemIndex && $0.setIndex == ref.setIndex }?
            .round
    }

    /// Whether every set of a superset/circuit round (drop sets included) is done.
    public func isRoundComplete(blockIndex: Int, round: Int) -> Bool {
        let slots = roundSlots(ofBlock: blockIndex).filter { $0.round == round }
        guard !slots.isEmpty else { return false }
        return slots.allSatisfy { isDone($0, inBlock: blockIndex) }
    }

    /// The next open set of the round `ref` belongs to: the first one after `ref` in the order the
    /// round is done, else (wrapping around) the first one before it. Nil for straight sets and for
    /// a round that is done.
    public func nextOpenSet(inRoundOf ref: SetRef) -> SetRef? {
        guard let round = roundIndex(of: ref) else { return nil }
        let slots = roundSlots(ofBlock: ref.blockIndex).filter { $0.round == round }
        let position = slots.firstIndex { $0.itemIndex == ref.itemIndex && $0.setIndex == ref.setIndex } ?? -1
        let after = slots.enumerated().first { $0.offset > position && !isDone($0.element, inBlock: ref.blockIndex) }?.element
        let slot = after ?? slots.first { !isDone($0, inBlock: ref.blockIndex) }
        return slot.map { SetRef(blockIndex: ref.blockIndex, itemIndex: $0.itemIndex, setIndex: $0.setIndex) }
    }

    /// The rest to start now that the set at `ref` was ticked (the content already has it done).
    /// Like `restAfter`, but a superset/circuit rests once its whole round is done – whichever set
    /// of the round came last – and not after a set while others of its round are still open.
    /// A set whose drop set is still open gets no rest (the drop set follows straight away).
    public func restAfterDone(_ ref: SetRef, defaultRest: Int) -> Int? {
        guard let item = item(at: ref) else { return nil }
        let next = ref.setIndex + 1
        if item.sets.indices.contains(next), item.sets[next].kind == .drop, !item.sets[next].isDone { return nil }
        if alternatesRounds(ref.blockIndex) {
            // Warm-ups (round -1) are a lead-in before the first round: no round rest after them.
            guard let round = roundIndex(of: ref), round >= 0, isRoundComplete(blockIndex: ref.blockIndex, round: round) else { return nil }
            // The round's rest, as planned after its last set.
            let block = blocks[ref.blockIndex]
            let last = roundSlots(ofBlock: ref.blockIndex).last { $0.round == round }
            let lastItem = last.flatMap { block.items.indices.contains($0.itemIndex) ? block.items[$0.itemIndex] : nil } ?? item
            return block.restAfterRoundSeconds ?? lastItem.restSeconds ?? defaultRest
        }
        let rest = item.restSeconds ?? defaultRest
        return rest > 0 ? rest : nil
    }

    /// What is due after the set at `ticked` was ticked (the content already has it done).
    /// - `current`: the set that was due before the tick.
    /// - `offPlan`: the tick was in another exercise than the planned one (the plan keeps its place).
    ///
    /// The set that was due stays due while it is open and the tick was off plan or elsewhere in the
    /// same exercise or superset (set 3 before set 2, B1 before A1). Otherwise a superset/circuit
    /// finishes its round first, then the next open set in the planned order.
    public func currentAfterTick(_ ticked: SetRef, previous current: SetRef?, offPlan: Bool) -> SetRef? {
        if let current, current != ticked, set(at: current)?.isDone == false,
           offPlan || current.blockIndex == ticked.blockIndex {
            return current
        }
        if let open = nextOpenSet(inRoundOf: ticked) { return open }
        return nextPendingSet(after: ticked)
    }

    /// True when `other` has the same blocks, exercises and sets (by id and in the same order) with
    /// the same ticks, set types and modes – only values such as numbers, names or notes differ.
    /// Live mode saves such edits after a pause in typing; anything else is a structural edit.
    public func hasSameSetsAndTicks(as other: WorkoutContent) -> Bool {
        guard blocks.count == other.blocks.count else { return false }
        for (a, b) in zip(blocks, other.blocks) {
            guard a.id == b.id, a.style == b.style, a.items.count == b.items.count else { return false }
            for (x, y) in zip(a.items, b.items) {
                guard x.id == y.id, x.mode == y.mode, x.sets.count == y.sets.count else { return false }
                for (s, t) in zip(x.sets, y.sets) where s.id != t.id || s.isDone != t.isDone || s.kind != t.kind {
                    return false
                }
            }
        }
        return true
    }
}
