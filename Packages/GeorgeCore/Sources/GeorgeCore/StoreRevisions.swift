import Foundation

// MARK: - What changed

/// What a save or an iCloud import changed, for the store's counters: `data` (anything lists, Today
/// and the sidebar show), `history` (performed workouts: the history index, "last time", muscles,
/// Progress) and `live` (a workout in progress: the "running on another device" bars).
public struct StoreChange: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let data = StoreChange(rawValue: 1)
    public static let history = StoreChange(rawValue: 2)
    public static let live = StoreChange(rawValue: 4)
    public static let all: StoreChange = [.data, .history, .live]

    /// A saved workout: one that is or was performed changes the history (and so the data); a
    /// planned or running one only the data.
    public static func session(isPerformed: Bool, wasPerformed: Bool) -> StoreChange {
        isPerformed || wasPerformed ? [.data, .history] : .data
    }
}

// MARK: - History index

/// The fields of a performed workout the history reads besides its content: whether a stored workout
/// changed since the history index decoded it. Every write of the content stamps `updatedAt`.
public struct HistoryStamp: Hashable, Sendable {
    public var updatedAt: Date
    public var status: String
    public var title: String
    public var kind: String
    public var startedAt: Date?
    public var plannedDate: Date?
    public var endedAt: Date?
    public var accumulatedSeconds: Double
    public var resumedAt: Date?
    public var energyKcal: Double
    public var effort: Int

    public init(updatedAt: Date, status: String, title: String = "", kind: String = "", startedAt: Date? = nil,
                plannedDate: Date? = nil, endedAt: Date? = nil, accumulatedSeconds: Double = 0, resumedAt: Date? = nil,
                energyKcal: Double = 0, effort: Int = 0) {
        self.updatedAt = updatedAt
        self.status = status
        self.title = title
        self.kind = kind
        self.startedAt = startedAt
        self.plannedDate = plannedDate
        self.endedAt = endedAt
        self.accumulatedSeconds = accumulatedSeconds
        self.resumedAt = resumedAt
        self.energyKcal = energyKcal
        self.effort = effort
    }
}

/// The performed workouts as plain records, oldest first, kept up to date by decoding only what
/// changed: the app reads every performed workout's stamp (cheap, without the content) and hands the
/// new and changed ones to `decode`.
public struct HistoryIndex: Sendable {
    public struct Entry: Sendable {
        public var stamp: HistoryStamp
        public var record: SessionRecord
        /// The effort rating (1–10, 0 = none).
        public var effort: Int

        public init(stamp: HistoryStamp, record: SessionRecord, effort: Int) {
            self.stamp = stamp
            self.record = record
            self.effort = effort
        }
    }

    public private(set) var entries: [UUID: Entry] = [:]
    /// Oldest first; workouts at the same moment by id, so the order never depends on the fetch.
    public private(set) var records: [SessionRecord] = []
    /// Moves whenever `records` changes – caches built from the records key on it.
    public private(set) var version = 0

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    public func contains(_ id: UUID) -> Bool { entries[id] != nil }
    public func effort(of id: UUID) -> Int { entries[id]?.effort ?? 0 }

    /// New or changed workouts (to decode) and the ones that are gone (deleted, or not performed any more).
    public func changes(to stamps: [UUID: HistoryStamp]) -> (changed: [UUID], removed: [UUID]) {
        let changed = stamps.compactMap { id, stamp in entries[id]?.stamp == stamp ? nil : id }
        let removed = entries.keys.filter { stamps[$0] == nil }
        return (changed, removed)
    }

    /// Brings the index to `stamps`. `decode` gets the ids of new and changed workouts and returns
    /// their entries; one it can't return any more (deleted in between) is left out. Returns whether
    /// the records changed.
    @discardableResult
    public mutating func update(to stamps: [UUID: HistoryStamp], decode: ([UUID]) -> [UUID: Entry]) -> Bool {
        let (changed, removed) = changes(to: stamps)
        guard !changed.isEmpty || !removed.isEmpty else { return false }
        for id in removed { entries[id] = nil }
        if !changed.isEmpty {
            let decoded = decode(changed)
            for id in changed { entries[id] = decoded[id] }
        }
        records = entries.values.map(\.record).sorted(by: HistoryIndex.isOrderedBefore)
        version &+= 1
        return true
    }

    static func isOrderedBefore(_ lhs: SessionRecord, _ rhs: SessionRecord) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

// MARK: - After an iCloud import

/// One table's size and newest change (templates, programs, planned workouts, settings …).
public struct TableStamp: Hashable, Sendable {
    public var count: Int
    public var newest: Date?

    public init(count: Int, newest: Date?) {
        self.count = count
        self.newest = newest
    }
}

/// A workout in progress, as the store has it: who runs it and whether it's paused (lists and Today
/// show that), and how far it is (only the "running on another device" bars show that).
public struct RunningStamp: Hashable, Sendable {
    public struct State: Hashable, Sendable {
        public var owner: String?
        public var claimedAt: Date?
        public var isPaused: Bool

        public init(owner: String?, claimedAt: Date?, isPaused: Bool) {
            self.owner = owner
            self.claimedAt = claimedAt
            self.isPaused = isPaused
        }
    }

    public struct Progress: Hashable, Sendable {
        public var updatedAt: Date
        public var doneSets: Int
        public var totalSets: Int

        public init(updatedAt: Date, doneSets: Int, totalSets: Int) {
            self.updatedAt = updatedAt
            self.doneSets = doneSets
            self.totalSets = totalSets
        }
    }

    public var state: State
    public var progress: Progress

    public init(state: State, progress: Progress) {
        self.state = state
        self.progress = progress
    }
}

/// A cheap summary of what the store holds, taken after each iCloud import, to tell which counters the
/// import has to move. A set ticked on another device moves only `live`; a workout started, ended or
/// continued elsewhere moves the data; a performed workout added, edited or deleted moves the history.
public struct SyncFingerprint: Equatable, Sendable {
    /// Every performed workout's stamp.
    public var performed: [UUID: HistoryStamp]
    /// Everything else, as size and newest change per table.
    public var tables: [String: TableStamp]
    /// Workouts in progress.
    public var running: [UUID: RunningStamp]

    public init(performed: [UUID: HistoryStamp], tables: [String: TableStamp], running: [UUID: RunningStamp]) {
        self.performed = performed
        self.tables = tables
        self.running = running
    }

    /// What moved since `old` (everything when there was no fingerprint before).
    public func changes(since old: SyncFingerprint?) -> StoreChange {
        guard let old else { return .all }
        var change: StoreChange = []
        if performed != old.performed { change.formUnion([.history, .data]) }
        if tables != old.tables { change.insert(.data) }
        if running.mapValues(\.state) != old.running.mapValues(\.state) { change.formUnion([.data, .live]) }
        if running.mapValues(\.progress) != old.running.mapValues(\.progress) { change.insert(.live) }
        return change
    }
}

// MARK: - Decoding many workouts

extension WorkoutContent {
    /// Lenient reads of many stored workouts at once, spread over the processor's cores (the history
    /// index reads every performed workout once). The same results as `decode(_:)` one by one, in order.
    public static func decodeAll(_ blobs: [Data?]) -> [WorkoutContent] {
        guard blobs.count > 8 else { return blobs.map { decode($0) } }
        let lanes = max(1, min(blobs.count / 4, ProcessInfo.processInfo.activeProcessorCount * 2))
        var results = [WorkoutContent](repeating: WorkoutContent(), count: blobs.count)
        results.withUnsafeMutableBufferPointer { buffer in
            let output = buffer
            DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                // One decoder per lane, set up like `decodeStrict`'s.
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                var index = lane
                while index < blobs.count {
                    if let data = blobs[index], !data.isEmpty,
                       let content = try? decoder.decode(WorkoutContent.self, from: data) {
                        output[index] = content
                    }
                    index += lanes
                }
            }
        }
        return results
    }
}
