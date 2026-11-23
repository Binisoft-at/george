import Foundation

/// The device that runs a workout live, synced on the session (`liveDeviceID`, `liveClaimedAt`).
/// Stored as "<install id>|<kind>": an id each install makes once and keeps to itself, and the kind
/// of device – never the device's name, which often holds a person's name.
public struct LiveOwner: Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case phone = "iPhone"
        case pad = "iPad"
        case mac = "Mac"
    }

    /// The install (a UUID string kept on that device).
    public var id: String
    /// Nil for a kind this build doesn't know (a newer George on another kind of device).
    public var kind: Kind?

    public init(id: String, kind: Kind?) {
        self.id = id
        self.kind = kind
    }

    /// Reads the stored value. Nil – nobody claims the workout – for nothing, an empty value or one
    /// that can't be read (older builds don't write the field).
    public init?(raw: String?) {
        guard let raw else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let id = parts[0].trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        self.id = id
        self.kind = Kind(rawValue: parts[1].trimmingCharacters(in: .whitespaces))
    }

    /// The stored form.
    public var raw: String { id + "|" + (kind?.rawValue ?? "") }
}

/// Which device runs a workout that is in progress, and what the others do about it. "Continue
/// Here" on one device claims the workout (owner and time, saved right away); the device that ran it
/// before sees the newer claim once it syncs and lets go instead of saving its stale copy over the
/// sets logged on the new one.
public enum LiveOwnership {
    /// What the device running a workout does with the claim stored on it.
    public enum Verdict: Equatable, Sendable {
        /// This device runs it (or nobody claims it – older builds): carry on.
        case keep
        /// Another device's claim is older than this device's own (it arrived late, both claimed at
        /// about the same time): this device's claim is written again, so every device ends up
        /// agreeing on the newer one.
        case reclaim
        /// Another device claimed it after this one: it continues there, this device lets go.
        case letGo
    }

    /// - Parameters:
    ///   - stored: the owner stored on the synced session.
    ///   - storedClaimedAt: when that owner claimed it.
    ///   - localID: this install's id.
    ///   - localClaimedAt: when this device claimed it itself (nil: it never did – an older build
    ///     started it here).
    public static func verdict(stored: LiveOwner?, storedClaimedAt: Date?, localID: String, localClaimedAt: Date?) -> Verdict {
        guard let stored, stored.id != localID else { return .keep }
        guard let localClaimedAt else { return .letGo }
        let difference = (storedClaimedAt ?? .distantPast).timeIntervalSince(localClaimedAt)
        if difference > sameMoment { return .letGo }
        if difference < -sameMoment { return .reclaim }
        // The same moment on two devices: the same answer on both (the larger id keeps it).
        return stored.id > localID ? .letGo : .reclaim
    }

    /// Claims closer together than this count as made at the same moment (dates may lose a little
    /// precision on their way through iCloud; both devices must still come to the same answer).
    public static let sameMoment: TimeInterval = 0.01

    /// The time a new claim carries: now, but always clearly after the claim it takes over (another
    /// device's clock may be a little ahead – the device that took over last must win on both).
    public static func claimTime(now: Date, previous: Date?) -> Date {
        guard let previous else { return now }
        return max(now, previous.addingTimeInterval(2 * sameMoment))
    }

    /// Whether a workout in progress runs on another device, as this one sees it: another install
    /// claims it, or – without a claim (older builds) – it isn't the workout this device started.
    /// - Parameters:
    ///   - ownedID: the workout this device started or continued last (kept on the device).
    public static func runsElsewhere(sessionID: UUID, ownedID: UUID?, owner: LiveOwner?, localID: String) -> Bool {
        if let owner, owner.id != localID { return true }
        return sessionID != ownedID
    }

    /// "your Mac", "your other iPhone" (the same kind as this device), "another device" (no claim,
    /// or a kind this build doesn't know).
    public static func deviceName(of owner: LiveOwner?, localID: String, localKind: LiveOwner.Kind?) -> String {
        guard let owner, owner.id != localID, let kind = owner.kind else { return "another device" }
        return kind == localKind ? "your other \(kind.rawValue)" : "your \(kind.rawValue)"
    }

    /// "Running on your Mac" – a workout in progress elsewhere.
    public static func runningTitle(owner: LiveOwner?, localID: String, localKind: LiveOwner.Kind?) -> String {
        "Running on " + deviceName(of: owner, localID: localID, localKind: localKind)
    }

    /// "Continued on your Mac" – said once when this device let go of the workout.
    public static func continuedMessage(owner: LiveOwner?, localID: String, localKind: LiveOwner.Kind?) -> String {
        "Continued on " + deviceName(of: owner, localID: localID, localKind: localKind)
    }
}

// MARK: - Merging two live copies

extension WorkoutContent {
    /// One running workout written by two devices (a late save from the device that ran it before,
    /// or an older build that doesn't know about claims) as one copy, so nothing logged on either
    /// side is lost:
    /// - a set is done when it is done on either side; its numbers and `doneAt` come from the side
    ///   that did it last (`mine` when neither side did it, or both at the same time);
    /// - sets, exercises and blocks only one side has are kept – `theirs` go in after what comes
    ///   before them there (at the front when nothing does);
    /// - everything else (names, order, notes) is `mine`, the copy of the device that saves now.
    public static func mergedLive(mine: WorkoutContent, theirs: WorkoutContent) -> WorkoutContent {
        var theirItems: [UUID: WorkoutItem] = [:]
        var theirSets: [UUID: WorkoutSet] = [:]
        for item in theirs.allItems {
            if theirItems[item.id] == nil { theirItems[item.id] = item }
            for set in item.sets where theirSets[set.id] == nil { theirSets[set.id] = set }
        }
        let myBlockIDs = Set(mine.blocks.map(\.id))
        let myItemIDs = Set(mine.allItems.map(\.id))
        let mySetIDs = Set(mine.allItems.flatMap { $0.sets.map(\.id) })

        // Something only `theirs` has, without what `mine` holds elsewhere (moved there).
        func onlyTheirs(_ item: WorkoutItem) -> WorkoutItem {
            var copy = item
            copy.sets.removeAll { mySetIDs.contains($0.id) }
            return copy
        }

        func merged(_ item: WorkoutItem) -> WorkoutItem {
            var result = item
            result.sets = item.sets.map { set in theirSets[set.id].map { mergedLiveSet(mine: set, theirs: $0) } ?? set }
            if let other = theirItems[item.id] {
                result.sets = insertingMissing(other.sets, into: result.sets) { mySetIDs.contains($0) }
                if result.fatigue == nil { result.fatigue = other.fatigue }
            }
            return result
        }

        var blocks = mine.blocks.map { block -> WorkoutBlock in
            var result = block
            result.items = block.items.map(merged)
            if let other = theirs.blocks.first(where: { $0.id == block.id }) {
                let added = other.items.filter { !myItemIDs.contains($0.id) }.map(onlyTheirs)
                result.items = insertingMissing(added, into: result.items, order: other.items) { _ in false }
            }
            return result
        }
        let addedBlocks = theirs.blocks.filter { !myBlockIDs.contains($0.id) }.compactMap { block -> WorkoutBlock? in
            var copy = block
            copy.items = block.items.filter { !myItemIDs.contains($0.id) }.map(onlyTheirs)
            return copy.items.isEmpty ? nil : copy
        }
        blocks = insertingMissing(addedBlocks, into: blocks, order: theirs.blocks) { _ in false }
        var result = mine
        result.blocks = blocks
        return result
    }

    /// The stored copy of the running workout when someone else wrote it since this device last
    /// wrote or read it (`lastSeen`) – to be merged in before saving. Nil when nothing changed, and
    /// when it can't be merged safely (unreadable, or from a newer George: the save keeps that copy).
    public static func writtenElsewhere(stored: Data?, lastSeen: Data?) -> WorkoutContent? {
        guard let stored, !stored.isEmpty, stored != lastSeen,
              let theirs = try? decodeStrict(stored), theirs.version <= currentVersion else { return nil }
        return theirs
    }

    /// One set as both devices had it (see `mergedLive`).
    public static func mergedLiveSet(mine: WorkoutSet, theirs: WorkoutSet) -> WorkoutSet {
        // Done on one side only: that side's numbers. Done (or not) on both: the later tick's.
        let useTheirs = mine.isDone != theirs.isDone
            ? theirs.isDone
            : (theirs.doneAt ?? .distantPast) > (mine.doneAt ?? .distantPast)
        var result = useTheirs ? theirs : mine
        result.isDone = mine.isDone || theirs.isDone
        if result.isDone && result.doneAt == nil {
            result.doneAt = useTheirs ? mine.doneAt : theirs.doneAt
        }
        return result
    }

    /// `result` with every element of `added` that it doesn't hold yet (and `skip` doesn't exclude),
    /// each after the element that comes before it in `order` (at the front when none does).
    private static func insertingMissing<T: Identifiable>(
        _ added: [T], into result: [T], order: [T]? = nil, skip: (T.ID) -> Bool
    ) -> [T] {
        let order = order ?? added
        var result = result
        var present = Set(result.map(\.id))
        for element in added where !present.contains(element.id) && !skip(element.id) {
            var position = 0
            if let index = order.firstIndex(where: { $0.id == element.id }) {
                for previous in order[..<index].reversed() {
                    if let found = result.firstIndex(where: { $0.id == previous.id }) {
                        position = found + 1
                        break
                    }
                }
            }
            result.insert(element, at: position)
            present.insert(element.id)
        }
        return result
    }
}
