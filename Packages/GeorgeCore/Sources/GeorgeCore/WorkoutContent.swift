import Foundation

// MARK: - Sets

public enum SetKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case warmup, working, drop, failure
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .warmup: return "Warm-up"
        case .working: return "Working"
        case .drop: return "Drop set"
        case .failure: return "To failure"
        }
    }
    /// Short badge shown on set chips ("W", "D", "F"). Working sets show their number instead.
    public var badge: String? {
        switch self {
        case .warmup: return "W"
        case .working: return nil
        case .drop: return "D"
        case .failure: return "F"
        }
    }

    init(loose raw: String) {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "w", "warmup", "warm-up", "warm up", "wu": self = .warmup
        case "d", "drop", "dropset", "drop set", "drop-set": self = .drop
        case "f", "failure", "to failure", "amrap": self = .failure
        default: self = .working
        }
    }
}

/// One set of an exercise: a target (what the template prescribes) plus the actual result.
/// Weights are always stored in kilograms.
public struct WorkoutSet: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: SetKind
    public var targetReps: String?
    public var targetWeight: Double?
    public var targetLoad: String?
    public var targetSeconds: Int?
    public var targetMeters: Double?
    public var targetRPE: Double?
    public var reps: Int?
    public var weight: Double?
    public var seconds: Int?
    public var meters: Double?
    public var rpe: Double?
    public var isDone: Bool
    public var doneAt: Date?
    public var note: String?

    public init(
        id: UUID = UUID(), kind: SetKind = .working, targetReps: String? = nil, targetWeight: Double? = nil,
        targetLoad: String? = nil, targetSeconds: Int? = nil, targetMeters: Double? = nil, targetRPE: Double? = nil,
        reps: Int? = nil, weight: Double? = nil, seconds: Int? = nil, meters: Double? = nil, rpe: Double? = nil,
        isDone: Bool = false, doneAt: Date? = nil, note: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.targetReps = targetReps
        self.targetWeight = targetWeight
        self.targetLoad = targetLoad
        self.targetSeconds = targetSeconds
        self.targetMeters = targetMeters
        self.targetRPE = targetRPE
        self.reps = reps
        self.weight = weight
        self.seconds = seconds
        self.meters = meters
        self.rpe = rpe
        self.isDone = isDone
        self.doneAt = doneAt
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, targetReps, targetWeight, targetLoad, targetSeconds, targetMeters, targetRPE
        case reps, weight, seconds, meters, rpe, isDone, doneAt, note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = (try? c.decodeIfPresent(SetKind.self, forKey: .kind)) ?? .working
        targetReps = try c.decodeIfPresent(String.self, forKey: .targetReps)
        targetWeight = try c.decodeIfPresent(Double.self, forKey: .targetWeight)
        targetLoad = try c.decodeIfPresent(String.self, forKey: .targetLoad)
        targetSeconds = try c.decodeIfPresent(Int.self, forKey: .targetSeconds)
        targetMeters = try c.decodeIfPresent(Double.self, forKey: .targetMeters)
        targetRPE = try c.decodeIfPresent(Double.self, forKey: .targetRPE)
        reps = try c.decodeIfPresent(Int.self, forKey: .reps)
        weight = try c.decodeIfPresent(Double.self, forKey: .weight)
        seconds = try c.decodeIfPresent(Int.self, forKey: .seconds)
        meters = try c.decodeIfPresent(Double.self, forKey: .meters)
        rpe = try c.decodeIfPresent(Double.self, forKey: .rpe)
        isDone = try c.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    /// Lower bound of the target reps ("8-12" -> 8, "AMRAP" -> nil).
    public var targetRepsValue: Int? {
        guard let raw = targetReps?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let digits = raw.prefix { $0.isNumber }
        return Int(digits)
    }

    /// Reps that count for this set: actual if logged, otherwise the target.
    public var effectiveReps: Int? { reps ?? targetRepsValue }
    public var effectiveWeight: Double? { weight ?? targetWeight }
    public var effectiveSeconds: Int? { seconds ?? targetSeconds }
    public var effectiveMeters: Double? { meters ?? targetMeters }

    public var hasActuals: Bool { reps != nil || weight != nil || seconds != nil || meters != nil || rpe != nil }

    /// A copy that keeps the prescription but clears what was performed.
    public func clearedCopy(newID: Bool = true) -> WorkoutSet {
        var copy = self
        if newID { copy.id = UUID() }
        copy.reps = nil
        copy.weight = nil
        copy.seconds = nil
        copy.meters = nil
        copy.rpe = nil
        copy.isDone = false
        copy.doneAt = nil
        return copy
    }

    /// Promote performed values to targets (used when saving a session back into a template).
    public func promotedToTarget() -> WorkoutSet {
        var copy = clearedCopy()
        if let r = reps { copy.targetReps = String(r) }
        if let w = weight { copy.targetWeight = w }
        if let s = seconds { copy.targetSeconds = s }
        if let m = meters { copy.targetMeters = m }
        return copy
    }

    /// Label like "12 × 20 kg", "30s", "400 m", "AMRAP · red band".
    public func label(mode: ExerciseMode, unit: WeightUnit, preferActual: Bool = true) -> String {
        var parts: [String] = []
        switch mode {
        case .reps:
            let repsText: String? = {
                if preferActual, let r = reps { return String(r) }
                return targetReps
            }()
            let weightKg = preferActual ? (weight ?? targetWeight) : targetWeight
            if let repsText, !repsText.isEmpty {
                if let weightKg, weightKg > 0 {
                    parts.append("\(repsText) × \(Format.weight(weightKg, unit: unit))")
                } else {
                    parts.append(repsText)
                }
            } else if let weightKg, weightKg > 0 {
                parts.append(Format.weight(weightKg, unit: unit))
            }
        case .time:
            if let s = preferActual ? (seconds ?? targetSeconds) : targetSeconds {
                parts.append(Format.shortDuration(s))
            }
            if let weightKg = preferActual ? (weight ?? targetWeight) : targetWeight, weightKg > 0 {
                parts.append(Format.weight(weightKg, unit: unit))
            }
        case .distance:
            if let m = preferActual ? (meters ?? targetMeters) : targetMeters {
                parts.append(Format.distance(m))
            }
            if let s = preferActual ? (seconds ?? targetSeconds) : targetSeconds {
                parts.append(Format.shortDuration(s))
            }
        }
        if let load = targetLoad, !load.isEmpty { parts.append(load) }
        if parts.isEmpty { return "—" }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Items (one exercise inside a block)

public struct WorkoutItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Library id ("fedb:Band_Pull_Apart", "george:band-face-pull") or "custom:<uuid>".
    public var exerciseID: String?
    public var name: String
    public var kind: WorkoutKind?
    public var mode: ExerciseMode
    public var sets: [WorkoutSet]
    public var perSide: Bool
    public var restSeconds: Int?
    public var tempo: String?
    public var notes: String?
    public var links: [String]
    public var equipment: String?
    public var muscles: [String]
    public var imageURL: String?

    public init(
        id: UUID = UUID(), exerciseID: String? = nil, name: String, kind: WorkoutKind? = nil,
        mode: ExerciseMode = .reps, sets: [WorkoutSet] = [], perSide: Bool = false, restSeconds: Int? = nil,
        tempo: String? = nil, notes: String? = nil, links: [String] = [], equipment: String? = nil,
        muscles: [String] = [], imageURL: String? = nil
    ) {
        self.id = id
        self.exerciseID = exerciseID
        self.name = name
        self.kind = kind
        self.mode = mode
        self.sets = sets
        self.perSide = perSide
        self.restSeconds = restSeconds
        self.tempo = tempo
        self.notes = notes
        self.links = links
        self.equipment = equipment
        self.muscles = muscles
        self.imageURL = imageURL
    }

    enum CodingKeys: String, CodingKey {
        case id, exerciseID, name, kind, mode, sets, perSide, restSeconds, tempo, notes, links, equipment, muscles, imageURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        exerciseID = try c.decodeIfPresent(String.self, forKey: .exerciseID)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Exercise"
        kind = try c.decodeIfPresent(WorkoutKind.self, forKey: .kind)
        mode = (try? c.decodeIfPresent(ExerciseMode.self, forKey: .mode)) ?? .reps
        sets = try c.decodeIfPresent([WorkoutSet].self, forKey: .sets) ?? []
        perSide = try c.decodeIfPresent(Bool.self, forKey: .perSide) ?? false
        restSeconds = try c.decodeIfPresent(Int.self, forKey: .restSeconds)
        tempo = try c.decodeIfPresent(String.self, forKey: .tempo)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        links = try c.decodeIfPresent([String].self, forKey: .links) ?? []
        equipment = try c.decodeIfPresent(String.self, forKey: .equipment)
        muscles = try c.decodeIfPresent([String].self, forKey: .muscles) ?? []
        imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL)
    }

    /// Stable key used to match the same exercise across sessions.
    public var exerciseKey: String {
        if let exerciseID, !exerciseID.isEmpty { return exerciseID }
        return "name:" + name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var completedSets: Int { sets.filter(\.isDone).count }
    public var isComplete: Bool { !sets.isEmpty && sets.allSatisfy(\.isDone) }

    /// "3 × 12 · 20 kg · rest 60s · each side"
    public func prescription(unit: WeightUnit) -> String {
        var parts: [String] = []
        let working = sets.filter { $0.kind != .warmup }
        let warmups = sets.count - working.count
        let reference = working.first ?? sets.first
        let count = working.isEmpty ? sets.count : working.count
        if let reference {
            let labels = Set(working.map { $0.label(mode: mode, unit: unit, preferActual: false) })
            if labels.count == 1 {
                let label = reference.label(mode: mode, unit: unit, preferActual: false)
                parts.append(label == "—" ? "\(count) sets" : "\(count) × \(label)")
            } else {
                let joined = working.map { $0.label(mode: mode, unit: unit, preferActual: false) }.joined(separator: ", ")
                parts.append(joined)
            }
        } else {
            parts.append("No sets")
        }
        if warmups > 0 { parts.append("+\(warmups) warm-up") }
        if perSide { parts.append("each side") }
        if let tempo, !tempo.isEmpty { parts.append("tempo \(tempo)") }
        if let restSeconds, restSeconds > 0 { parts.append("rest \(Format.shortDuration(restSeconds))") }
        return parts.joined(separator: " · ")
    }

    /// Number shown on a working set chip (warm-ups don't count).
    public func displayIndex(of set: WorkoutSet) -> String {
        if let badge = set.kind.badge { return badge }
        var n = 0
        for s in sets where s.kind != .warmup {
            n += 1
            if s.id == set.id { return String(n) }
        }
        return "•"
    }

    /// A new set copied from the last set (targets only).
    public func makeNextSet() -> WorkoutSet {
        if let last = sets.last { return last.clearedCopy() }
        switch mode {
        case .reps: return WorkoutSet(targetReps: "10")
        case .time: return WorkoutSet(targetSeconds: 30)
        case .distance: return WorkoutSet(targetMeters: 400)
        }
    }
}

// MARK: - Blocks (single exercise, superset, circuit, ...)

public enum BlockStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case single, superset, circuit, emom, amrap, interval
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .single: return "Straight sets"
        case .superset: return "Superset"
        case .circuit: return "Circuit"
        case .emom: return "EMOM"
        case .amrap: return "AMRAP"
        case .interval: return "Intervals"
        }
    }
    public var symbol: String {
        switch self {
        case .single: return "square.stack"
        case .superset: return "link"
        case .circuit: return "arrow.triangle.2.circlepath"
        case .emom: return "timer"
        case .amrap: return "infinity"
        case .interval: return "metronome"
        }
    }
    /// Whether exercises alternate round by round.
    public var isGrouped: Bool { self != .single }

    init(loose raw: String, itemCount: Int) {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "superset", "ss", "pair", "super set": self = .superset
        case "circuit", "giant", "giant set", "giantset", "triset", "tri-set": self = .circuit
        case "emom": self = .emom
        case "amrap": self = .amrap
        case "interval", "intervals", "tabata", "hiit": self = .interval
        case "single", "straight", "straight sets", "none": self = itemCount > 1 ? .superset : .single
        default:
            if itemCount <= 1 { self = .single } else if itemCount == 2 { self = .superset } else { self = .circuit }
        }
    }
}

public struct WorkoutBlock: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Section header shown above this block ("WARM-UP", "MAIN", "FINISHER").
    public var section: String?
    public var style: BlockStyle
    public var rounds: Int?
    public var restAfterRoundSeconds: Int?
    public var timeCapSeconds: Int?
    public var notes: String?
    public var items: [WorkoutItem]

    public init(
        id: UUID = UUID(), section: String? = nil, style: BlockStyle = .single, rounds: Int? = nil,
        restAfterRoundSeconds: Int? = nil, timeCapSeconds: Int? = nil, notes: String? = nil, items: [WorkoutItem] = []
    ) {
        self.id = id
        self.section = section
        self.style = style
        self.rounds = rounds
        self.restAfterRoundSeconds = restAfterRoundSeconds
        self.timeCapSeconds = timeCapSeconds
        self.notes = notes
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case id, section, style, rounds, restAfterRoundSeconds, timeCapSeconds, notes, items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        section = try c.decodeIfPresent(String.self, forKey: .section)
        style = (try? c.decodeIfPresent(BlockStyle.self, forKey: .style)) ?? .single
        rounds = try c.decodeIfPresent(Int.self, forKey: .rounds)
        restAfterRoundSeconds = try c.decodeIfPresent(Int.self, forKey: .restAfterRoundSeconds)
        timeCapSeconds = try c.decodeIfPresent(Int.self, forKey: .timeCapSeconds)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        items = try c.decodeIfPresent([WorkoutItem].self, forKey: .items) ?? []
    }

    public var roundCount: Int { rounds ?? (items.map(\.sets.count).max() ?? 0) }

    public var title: String {
        if items.count == 1 { return items[0].name }
        return "\(style.displayName) · \(items.count) exercises"
    }
}

// MARK: - Content

/// Everything inside a workout: ordered blocks of exercises with their sets.
/// Stored as JSON in templates and sessions so the whole structure syncs as one value.
public struct WorkoutContent: Codable, Hashable, Sendable {
    public var version: Int
    public var blocks: [WorkoutBlock]

    public init(blocks: [WorkoutBlock] = []) {
        self.version = 1
        self.blocks = blocks
    }

    enum CodingKeys: String, CodingKey { case version, blocks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        blocks = try c.decodeIfPresent([WorkoutBlock].self, forKey: .blocks) ?? []
    }

    public static let empty = WorkoutContent()

    // MARK: Encoding

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public static func decode(_ data: Data?) -> WorkoutContent {
        guard let data, !data.isEmpty else { return WorkoutContent() }
        return (try? decoder.decode(WorkoutContent.self, from: data)) ?? WorkoutContent()
    }

    public func encoded() -> Data {
        (try? WorkoutContent.encoder.encode(self)) ?? Data()
    }

    // MARK: Queries

    public var isEmpty: Bool { blocks.allSatisfy { $0.items.isEmpty } }
    public var allItems: [WorkoutItem] { blocks.flatMap(\.items) }
    public var exerciseCount: Int { blocks.reduce(0) { $0 + $1.items.count } }
    public var totalSets: Int { allItems.reduce(0) { $0 + $1.sets.count } }
    public var completedSets: Int { allItems.reduce(0) { $0 + $1.completedSets } }
    public var progress: Double { totalSets == 0 ? 0 : Double(completedSets) / Double(totalSets) }
    public var isComplete: Bool { totalSets > 0 && completedSets == totalSets }
    public var hasAnyActuals: Bool { allItems.contains { $0.sets.contains { $0.isDone || $0.hasActuals } } }

    /// Ordered distinct section titles.
    public var sections: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for block in blocks {
            if let s = block.section, !s.isEmpty, !seen.contains(s) {
                seen.insert(s)
                result.append(s)
            }
        }
        return result
    }

    /// Total volume (reps × kg) of completed sets.
    public var volumeKg: Double {
        var total = 0.0
        for item in allItems {
            let sides: Double = item.perSide ? 2 : 1
            for set in item.sets where set.isDone {
                let reps = Double(set.effectiveReps ?? 0)
                let weight = set.effectiveWeight ?? 0
                total += reps * weight * sides
            }
        }
        return total
    }

    public var completedReps: Int {
        var total = 0
        for item in allItems {
            let sides = item.perSide ? 2 : 1
            for set in item.sets where set.isDone {
                total += (set.effectiveReps ?? 0) * sides
            }
        }
        return total
    }

    /// Distinct kinds of the exercises (falls back to the provided default).
    public func kinds(default fallback: WorkoutKind) -> [WorkoutKind] {
        let all = allItems.map { $0.kind ?? fallback }
        return Array(Set(all)).sorted()
    }

    /// Rough duration estimate: work time per set plus rest.
    public func estimatedSeconds() -> Int {
        var total = 0
        for block in blocks {
            for item in block.items {
                for set in item.sets {
                    let work: Int
                    switch item.mode {
                    case .reps: work = max(20, (set.targetRepsValue ?? 10) * 3)
                    case .time: work = set.targetSeconds ?? 30
                    case .distance: work = set.targetSeconds ?? Int((set.targetMeters ?? 400) / 3)
                    }
                    total += work * (item.perSide ? 2 : 1)
                    if block.style == .single {
                        total += item.restSeconds ?? 60
                    } else {
                        total += 10
                    }
                }
            }
            if block.style.isGrouped {
                total += (block.restAfterRoundSeconds ?? 60) * max(0, block.roundCount)
            }
        }
        return total
    }

    public func summary(unit: WeightUnit = .kg) -> String {
        let minutes = Int((Double(estimatedSeconds()) / 60).rounded())
        var parts = ["\(exerciseCount) exercise\(exerciseCount == 1 ? "" : "s")", "\(totalSets) sets"]
        if minutes > 0 { parts.append("~\(minutes) min") }
        return parts.joined(separator: " · ")
    }

    /// Sets per primary muscle (completed only if `completedOnly`).
    public func muscleSets(completedOnly: Bool, lookup: (WorkoutItem) -> [String] = { $0.muscles }) -> [String: Int] {
        var result: [String: Int] = [:]
        for item in allItems {
            let count = completedOnly ? item.completedSets : item.sets.count
            guard count > 0 else { continue }
            for muscle in lookup(item) {
                result[muscle, default: 0] += count
            }
        }
        return result
    }

    // MARK: Locating

    public struct SetRef: Hashable, Sendable {
        public var blockIndex: Int
        public var itemIndex: Int
        public var setIndex: Int
        public init(blockIndex: Int, itemIndex: Int, setIndex: Int) {
            self.blockIndex = blockIndex
            self.itemIndex = itemIndex
            self.setIndex = setIndex
        }
    }

    public func locate(setID: UUID) -> SetRef? {
        for (b, block) in blocks.enumerated() {
            for (i, item) in block.items.enumerated() {
                if let s = item.sets.firstIndex(where: { $0.id == setID }) {
                    return SetRef(blockIndex: b, itemIndex: i, setIndex: s)
                }
            }
        }
        return nil
    }

    public func locate(itemID: UUID) -> (block: Int, item: Int)? {
        for (b, block) in blocks.enumerated() {
            if let i = block.items.firstIndex(where: { $0.id == itemID }) { return (b, i) }
        }
        return nil
    }

    public func item(id: UUID) -> WorkoutItem? {
        guard let loc = locate(itemID: id) else { return nil }
        return blocks[loc.block].items[loc.item]
    }

    public func set(id: UUID) -> WorkoutSet? {
        guard let ref = locate(setID: id) else { return nil }
        return blocks[ref.blockIndex].items[ref.itemIndex].sets[ref.setIndex]
    }

    public func item(at ref: SetRef) -> WorkoutItem? {
        guard blocks.indices.contains(ref.blockIndex), blocks[ref.blockIndex].items.indices.contains(ref.itemIndex) else { return nil }
        return blocks[ref.blockIndex].items[ref.itemIndex]
    }

    public func set(at ref: SetRef) -> WorkoutSet? {
        guard let item = item(at: ref), item.sets.indices.contains(ref.setIndex) else { return nil }
        return item.sets[ref.setIndex]
    }

    // MARK: Execution order

    /// The order sets are performed in. Straight sets run item by item; grouped blocks
    /// alternate exercises round by round (A1, B1, A2, B2, ...).
    public func executionOrder() -> [SetRef] {
        var order: [SetRef] = []
        for (b, block) in blocks.enumerated() {
            if block.style.isGrouped && block.items.count > 1 {
                let rounds = block.items.map(\.sets.count).max() ?? 0
                for r in 0..<rounds {
                    for (i, item) in block.items.enumerated() where item.sets.indices.contains(r) {
                        order.append(SetRef(blockIndex: b, itemIndex: i, setIndex: r))
                    }
                }
            } else {
                for (i, item) in block.items.enumerated() {
                    for s in item.sets.indices {
                        order.append(SetRef(blockIndex: b, itemIndex: i, setIndex: s))
                    }
                }
            }
        }
        return order
    }

    /// The first set not yet done, in execution order.
    public func nextPendingSet(after current: SetRef? = nil) -> SetRef? {
        let order = executionOrder()
        var startIndex = 0
        if let current, let idx = order.firstIndex(of: current) { startIndex = idx + 1 }
        if startIndex < order.count {
            for ref in order[startIndex...] where set(at: ref)?.isDone == false { return ref }
        }
        // Wrap around to anything skipped earlier.
        for ref in order where set(at: ref)?.isDone == false { return ref }
        return nil
    }

    /// Rest to take after finishing the set at `ref`, or nil when no rest is needed.
    public func restAfter(_ ref: SetRef, defaultRest: Int) -> Int? {
        guard let item = item(at: ref) else { return nil }
        let block = blocks[ref.blockIndex]
        if block.style.isGrouped && block.items.count > 1 {
            // Rest only after the last exercise of a round.
            let lastInRound = block.items.indices.last { block.items[$0].sets.indices.contains(ref.setIndex) }
            if ref.itemIndex == lastInRound {
                return block.restAfterRoundSeconds ?? item.restSeconds ?? defaultRest
            }
            return nil
        }
        let rest = item.restSeconds ?? defaultRest
        return rest > 0 ? rest : nil
    }

    // MARK: Mutations

    public mutating func updateSet(id: UUID, _ body: (inout WorkoutSet) -> Void) {
        guard let ref = locate(setID: id) else { return }
        body(&blocks[ref.blockIndex].items[ref.itemIndex].sets[ref.setIndex])
    }

    public mutating func updateItem(id: UUID, _ body: (inout WorkoutItem) -> Void) {
        guard let loc = locate(itemID: id) else { return }
        body(&blocks[loc.block].items[loc.item])
    }

    public mutating func updateBlock(id: UUID, _ body: (inout WorkoutBlock) -> Void) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        body(&blocks[index])
    }

    /// Toggle a set. When completing, targets are copied into actuals if nothing was logged.
    @discardableResult
    public mutating func toggleSet(id: UUID, at date: Date = Date()) -> Bool {
        var nowDone = false
        updateSet(id: id) { set in
            set.isDone.toggle()
            nowDone = set.isDone
            if set.isDone {
                set.doneAt = date
                if set.reps == nil, let r = set.targetRepsValue { set.reps = r }
                if set.weight == nil, let w = set.targetWeight { set.weight = w }
                if set.seconds == nil, let s = set.targetSeconds { set.seconds = s }
                if set.meters == nil, let m = set.targetMeters { set.meters = m }
            } else {
                set.doneAt = nil
            }
        }
        return nowDone
    }

    public mutating func setAllSets(of itemID: UUID, done: Bool, at date: Date = Date()) {
        updateItem(id: itemID) { item in
            for i in item.sets.indices where item.sets[i].isDone != done {
                item.sets[i].isDone = done
                item.sets[i].doneAt = done ? date : nil
                if done {
                    if item.sets[i].reps == nil { item.sets[i].reps = item.sets[i].targetRepsValue }
                    if item.sets[i].weight == nil { item.sets[i].weight = item.sets[i].targetWeight }
                    if item.sets[i].seconds == nil { item.sets[i].seconds = item.sets[i].targetSeconds }
                }
            }
        }
    }

    public mutating func addSet(to itemID: UUID) {
        updateItem(id: itemID) { item in item.sets.append(item.makeNextSet()) }
    }

    public mutating func removeSet(id: UUID) {
        guard let ref = locate(setID: id) else { return }
        blocks[ref.blockIndex].items[ref.itemIndex].sets.remove(at: ref.setIndex)
    }

    public mutating func duplicateSet(id: UUID) {
        guard let ref = locate(setID: id) else { return }
        let copy = blocks[ref.blockIndex].items[ref.itemIndex].sets[ref.setIndex].clearedCopy()
        blocks[ref.blockIndex].items[ref.itemIndex].sets.insert(copy, at: ref.setIndex + 1)
    }

    /// Append exercises. With `asGroup` they form one superset/circuit block.
    public mutating func append(items newItems: [WorkoutItem], asGroup: Bool = false, section: String? = nil) {
        guard !newItems.isEmpty else { return }
        let resolvedSection = section ?? blocks.last?.section
        if asGroup && newItems.count > 1 {
            blocks.append(WorkoutBlock(section: resolvedSection, style: newItems.count == 2 ? .superset : .circuit, items: newItems))
        } else {
            for item in newItems {
                blocks.append(WorkoutBlock(section: resolvedSection, style: .single, items: [item]))
            }
        }
    }

    /// Insert exercises right after the given item (or at the end).
    public mutating func insert(items newItems: [WorkoutItem], afterItem itemID: UUID?) {
        guard let itemID, let loc = locate(itemID: itemID) else {
            append(items: newItems)
            return
        }
        let section = blocks[loc.block].section
        let newBlocks = newItems.map { WorkoutBlock(section: section, style: .single, items: [$0]) }
        blocks.insert(contentsOf: newBlocks, at: loc.block + 1)
    }

    public mutating func removeItem(id: UUID) {
        guard let loc = locate(itemID: id) else { return }
        blocks[loc.block].items.remove(at: loc.item)
        normalizeBlocks()
    }

    public mutating func duplicateItem(id: UUID) {
        guard let loc = locate(itemID: id) else { return }
        var copy = blocks[loc.block].items[loc.item]
        copy.id = UUID()
        copy.sets = copy.sets.map { $0.clearedCopy() }
        if blocks[loc.block].style.isGrouped {
            blocks[loc.block].items.insert(copy, at: loc.item + 1)
        } else {
            blocks.insert(WorkoutBlock(section: blocks[loc.block].section, style: .single, items: [copy]), at: loc.block + 1)
        }
    }

    public mutating func removeBlock(id: UUID) {
        blocks.removeAll { $0.id == id }
    }

    public mutating func moveBlocks(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { blocks[$0] }
        var remaining: [WorkoutBlock] = []
        var insertAt = destination
        for (index, block) in blocks.enumerated() {
            if source.contains(index) {
                if index < destination { insertAt -= 1 }
            } else {
                remaining.append(block)
            }
        }
        insertAt = max(0, min(insertAt, remaining.count))
        remaining.insert(contentsOf: moving, at: insertAt)
        blocks = remaining
    }

    public mutating func moveItems(inBlock blockID: UUID, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let b = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        var items = blocks[b].items
        let moving = source.sorted().map { items[$0] }
        var insertAt = destination
        for index in source.sorted(by: >) {
            items.remove(at: index)
            if index < destination { insertAt -= 1 }
        }
        insertAt = max(0, min(insertAt, items.count))
        items.insert(contentsOf: moving, at: insertAt)
        blocks[b].items = items
    }

    /// Move an exercise one position up or down in execution order (crossing block boundaries).
    public mutating func moveItem(id: UUID, by offset: Int) {
        guard let loc = locate(itemID: id) else { return }
        let block = blocks[loc.block]
        if block.items.count > 1 {
            let target = loc.item + offset
            if block.items.indices.contains(target) {
                blocks[loc.block].items.swapAt(loc.item, target)
                return
            }
            // Leave the group.
            let item = blocks[loc.block].items.remove(at: loc.item)
            let single = WorkoutBlock(section: block.section, style: .single, items: [item])
            blocks.insert(single, at: offset < 0 ? loc.block : loc.block + 1)
            normalizeBlocks()
            return
        }
        let target = loc.block + offset
        guard blocks.indices.contains(target) else { return }
        blocks.swapAt(loc.block, target)
    }

    /// Link the block containing `itemID` with the next block into a superset/circuit.
    public mutating func groupWithNext(itemID: UUID) {
        guard let loc = locate(itemID: itemID), blocks.indices.contains(loc.block + 1) else { return }
        let next = blocks.remove(at: loc.block + 1)
        blocks[loc.block].items.append(contentsOf: next.items)
        let count = blocks[loc.block].items.count
        if !blocks[loc.block].style.isGrouped || blocks[loc.block].style == .superset {
            blocks[loc.block].style = count == 2 ? .superset : .circuit
        }
    }

    /// Group a set of blocks (by id, in current order) into a single grouped block.
    public mutating func group(blockIDs: [UUID], style: BlockStyle? = nil) {
        let indices = blocks.indices.filter { blockIDs.contains(blocks[$0].id) }
        guard let first = indices.first, indices.count > 1 else { return }
        var merged = blocks[first]
        for index in indices.dropFirst() { merged.items.append(contentsOf: blocks[index].items) }
        merged.style = style ?? (merged.items.count == 2 ? .superset : .circuit)
        for index in indices.reversed() { blocks.remove(at: index) }
        blocks.insert(merged, at: first)
    }

    /// Split a grouped block back into straight-set blocks.
    public mutating func ungroup(blockID: UUID) {
        guard let b = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        let block = blocks[b]
        guard block.items.count > 1 || block.style.isGrouped else { return }
        let singles = block.items.map { WorkoutBlock(section: block.section, style: .single, items: [$0]) }
        blocks.replaceSubrange(b...b, with: singles)
    }

    /// Take an exercise out of its group into its own block right after the group.
    public mutating func detach(itemID: UUID) {
        guard let loc = locate(itemID: itemID), blocks[loc.block].items.count > 1 else { return }
        let item = blocks[loc.block].items.remove(at: loc.item)
        blocks.insert(WorkoutBlock(section: blocks[loc.block].section, style: .single, items: [item]), at: loc.block + 1)
        normalizeBlocks()
    }

    public mutating func renameSection(from old: String?, to new: String?) {
        let cleaned = new?.trimmingCharacters(in: .whitespacesAndNewlines)
        for i in blocks.indices where blocks[i].section == old {
            blocks[i].section = (cleaned?.isEmpty ?? true) ? nil : cleaned
        }
    }

    /// Replace an exercise but keep the set structure.
    public mutating func replaceExercise(itemID: UUID, exerciseID: String?, name: String, kind: WorkoutKind?, mode: ExerciseMode?, muscles: [String], equipment: String?, imageURL: String?) {
        updateItem(id: itemID) { item in
            item.exerciseID = exerciseID
            item.name = name
            item.kind = kind
            item.muscles = muscles
            item.equipment = equipment
            item.imageURL = imageURL
            if let mode, mode != item.mode {
                item.mode = mode
                item.sets = item.sets.map { set in
                    var s = set.clearedCopy(newID: false)
                    switch mode {
                    case .reps: if s.targetReps == nil { s.targetReps = "10" }
                    case .time: if s.targetSeconds == nil { s.targetSeconds = 30 }
                    case .distance: if s.targetMeters == nil { s.targetMeters = 400 }
                    }
                    return s
                }
            }
        }
    }

    /// Drop empty blocks and collapse one-item groups to straight sets.
    public mutating func normalizeBlocks() {
        blocks.removeAll { $0.items.isEmpty }
        for i in blocks.indices where blocks[i].items.count == 1 && blocks[i].style == .superset {
            blocks[i].style = .single
        }
    }

    // MARK: Derivations

    /// A fresh copy for a new session: new ids, actuals cleared, targets kept.
    public func freshCopy() -> WorkoutContent {
        var copy = self
        for b in copy.blocks.indices {
            copy.blocks[b].id = UUID()
            for i in copy.blocks[b].items.indices {
                copy.blocks[b].items[i].id = UUID()
                copy.blocks[b].items[i].sets = copy.blocks[b].items[i].sets.map { $0.clearedCopy() }
            }
        }
        return copy
    }

    /// Turn a performed session into a template: performed values become the new targets.
    /// Sets that were never done keep their original targets.
    public func asTemplate(promoteActuals: Bool = true) -> WorkoutContent {
        var copy = self
        for b in copy.blocks.indices {
            copy.blocks[b].id = UUID()
            for i in copy.blocks[b].items.indices {
                copy.blocks[b].items[i].id = UUID()
                copy.blocks[b].items[i].sets = copy.blocks[b].items[i].sets.map {
                    promoteActuals && $0.isDone ? $0.promotedToTarget() : $0.clearedCopy()
                }
            }
        }
        return copy
    }

    /// Clears all progress but keeps ids.
    public mutating func resetProgress() {
        for b in blocks.indices {
            for i in blocks[b].items.indices {
                blocks[b].items[i].sets = blocks[b].items[i].sets.map { $0.clearedCopy(newID: false) }
            }
        }
    }

    /// Structural signature (exercises + set counts) used to detect edits made during a session.
    public var structureSignature: [String] {
        blocks.map { block in
            block.style.rawValue + ":" + block.items.map { "\($0.exerciseKey)x\($0.sets.count)" }.joined(separator: ",")
        }
    }

    /// Whether the structure differs from another content (added/removed/reordered exercises or set counts).
    public func structureDiffers(from other: WorkoutContent) -> Bool {
        structureSignature != other.structureSignature
    }

    /// Prefill targets from the last time each exercise was performed (progressive overload helper).
    public mutating func applyPrevious(_ lookup: (WorkoutItem) -> [WorkoutSet]?) {
        for b in blocks.indices {
            for i in blocks[b].items.indices {
                guard let previous = lookup(blocks[b].items[i]), !previous.isEmpty else { continue }
                for s in blocks[b].items[i].sets.indices {
                    let prev = s < previous.count ? previous[s] : previous[previous.count - 1]
                    guard prev.isDone else { continue }
                    if blocks[b].items[i].sets[s].targetWeight == nil, let w = prev.weight, w > 0 {
                        blocks[b].items[i].sets[s].targetWeight = w
                    }
                }
            }
        }
    }
}
