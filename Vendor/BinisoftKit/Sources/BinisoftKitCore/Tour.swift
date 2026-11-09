import Foundation

// The interactive tour engine (from Theo): the real screen runs on a throwaway demo store, a coach
// card explains one step at a time, and each step ticks itself off once the practice page shows
// that the person did it. Steps carry the tour version that introduced them, so people who already
// took the tour get only the new steps as "What's new".
//
// `Snapshot` is a small Equatable value the app builds from its demo store after every change
// (counts, flags, the order of rows …). Goals compare the snapshot with the one taken when the
// step started.

/// Scratch memory a goal can use between two snapshots (e.g. "saw the delete, waiting for Undo").
public struct TourMemory: Equatable, Sendable {
    public var sawChange = false
    public var marks: Set<String> = []

    public init() {}
}

/// What the practice page has to show before a step counts as done.
public struct TourGoal<Snapshot> {
    /// Read-only step: nothing to do, the button says Continue.
    public let isManual: Bool
    private let check: (_ baseline: Snapshot, _ now: Snapshot, _ memory: inout TourMemory) -> Bool

    /// A custom goal. `baseline` is the page when the step started, `now` the page after a change.
    public init(_ check: @escaping (_ baseline: Snapshot, _ now: Snapshot, _ memory: inout TourMemory) -> Bool) {
        self.isManual = false
        self.check = check
    }

    private init(manual: Bool) {
        self.isManual = manual
        self.check = { _, _, _ in false }
    }

    /// Nothing to do: read, then continue.
    public static var none: TourGoal { TourGoal(manual: true) }

    /// The value grew (an item was added, one more is done …).
    public static func increased<Value: Comparable>(_ path: KeyPath<Snapshot, Value>) -> TourGoal {
        TourGoal { base, now, _ in now[keyPath: path] > base[keyPath: path] }
    }

    /// The value shrank.
    public static func decreased<Value: Comparable>(_ path: KeyPath<Snapshot, Value>) -> TourGoal {
        TourGoal { base, now, _ in now[keyPath: path] < base[keyPath: path] }
    }

    /// The value is different from the start of the step (reordered, renamed …).
    public static func changed<Value: Equatable>(_ path: KeyPath<Snapshot, Value>) -> TourGoal {
        TourGoal { base, now, _ in now[keyPath: path] != base[keyPath: path] }
    }

    /// A flag became true (a sheet is open, a timer runs …).
    public static func isTrue(_ path: KeyPath<Snapshot, Bool>) -> TourGoal {
        TourGoal { _, now, _ in now[keyPath: path] }
    }

    /// The value went up and came back down: delete something, then Undo.
    public static func undone<Value: Comparable>(_ path: KeyPath<Snapshot, Value>) -> TourGoal {
        TourGoal { base, now, memory in
            if now[keyPath: path] > base[keyPath: path] { memory.sawChange = true }
            return memory.sawChange && now[keyPath: path] <= base[keyPath: path]
        }
    }

    /// Every goal is met at the same time.
    public static func all(_ goals: [TourGoal]) -> TourGoal {
        TourGoal { base, now, memory in
            var met = true
            for goal in goals where !goal.evaluate(baseline: base, now: now, memory: &memory) {
                met = false
            }
            return met
        }
    }

    func evaluate(baseline: Snapshot, now: Snapshot, memory: inout TourMemory) -> Bool {
        isManual ? false : check(baseline, now, &memory)
    }
}

/// One step of the tour.
public struct TourStep<Snapshot>: Identifiable {
    public let id: String
    /// Tour version that introduced the step. Steps newer than what someone has seen make up
    /// their "What's new" tour.
    public let since: Int
    public let symbol: String
    public let title: String
    /// Instructions for iPhone and iPad (touch).
    public let body: String
    /// Instructions for the Mac (pointer, menus and keyboard shortcuts).
    public let macBody: String
    public let goal: TourGoal<Snapshot>

    public init(id: String, since: Int = 1, symbol: String, title: String, body: String,
                macBody: String? = nil, goal: TourGoal<Snapshot> = .none) {
        self.id = id
        self.since = since
        self.symbol = symbol
        self.title = title
        self.body = body
        self.macBody = macBody ?? body
        self.goal = goal
    }

    /// The text for the platform this runs on.
    public var instructions: String {
        #if os(macOS)
        macBody
        #else
        body
        #endif
    }
}

/// All steps of an app's tour. Add new steps at the end of their topic with `since` set to a new
/// `version` and bump `version`; people who already took the tour then see just those steps.
public struct TourCatalog<Snapshot> {
    public let version: Int
    public let welcome: TourStep<Snapshot>
    public let whatsNew: TourStep<Snapshot>
    public let finish: TourStep<Snapshot>
    /// The steps between welcome and finish, in tour order.
    public let steps: [TourStep<Snapshot>]

    public init(version: Int, welcome: TourStep<Snapshot>, whatsNew: TourStep<Snapshot>,
                finish: TourStep<Snapshot>, steps: [TourStep<Snapshot>]) {
        self.version = version
        self.welcome = welcome
        self.whatsNew = whatsNew
        self.finish = finish
        self.steps = steps
    }

    /// The usual welcome / What's new / finish texts around the app's own steps.
    /// - Parameter replayHint: where the tour can be replayed, e.g. "Settings or the Help menu".
    public static func standard(appName: String, version: Int, practiceNoun: String = "items",
                                replayHint: String = "Settings (Help menu on the Mac)",
                                steps: [TourStep<Snapshot>]) -> TourCatalog {
        TourCatalog(
            version: version,
            welcome: TourStep(
                id: "welcome", symbol: "hand.wave", title: "Welcome to \(appName)",
                body: "Two minutes, hands on. This is a practice page, so nothing you do here touches your real \(practiceNoun). Each step ticks itself off when you've tried it."
            ),
            whatsNew: TourStep(
                id: "whats-new", symbol: "sparkles", title: "What's new in \(appName)",
                body: "A few new things to try, on a practice page. Nothing here touches your real \(practiceNoun)."
            ),
            finish: TourStep(
                id: "finish", symbol: "checkmark.seal", title: "You're all set",
                body: "Replay this tour any time from \(replayHint). New features show up here as a short \u{201C}What's new\u{201D} tour."
            ),
            steps: steps
        )
    }

    /// Welcome, every step, finish.
    public var allSteps: [TourStep<Snapshot>] { [welcome] + steps + [finish] }

    /// The tour for someone who last finished `seenVersion`: everything on first run (0),
    /// otherwise only the steps added since, framed by What's new and finish (empty when nothing is new).
    public func steps(newerThan seenVersion: Int) -> [TourStep<Snapshot>] {
        guard seenVersion > 0 else { return allSteps }
        let new = steps.filter { $0.since > seenVersion }
        guard !new.isEmpty else { return [] }
        return [whatsNew] + new + [finish]
    }

    /// Mistakes the app's Core tests should catch (empty when the catalog is fine).
    public func problems() -> [String] {
        var problems: [String] = []
        if version < 1 { problems.append("version must be 1 or higher") }
        var seen = Set<String>()
        for step in [welcome, whatsNew, finish] + steps {
            if !seen.insert(step.id).inserted { problems.append("duplicate step id \(step.id)") }
            if step.title.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("\(step.id): empty title") }
            if step.body.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("\(step.id): empty text") }
        }
        for step in steps where step.since < 1 || step.since > version {
            problems.append("\(step.id): since \(step.since) is outside 1...\(version)")
        }
        if version > 1, !steps.contains(where: { $0.since == version }) {
            problems.append("version \(version) has no step with since: \(version)")
        }
        return problems
    }
}

/// Follows the current step by comparing the page with how it looked when the step started.
public struct TourTracker<Snapshot> {
    public private(set) var baseline: Snapshot
    private var memory = TourMemory()

    public init(baseline: Snapshot) {
        self.baseline = baseline
    }

    /// Starts the next step from the page as it is now.
    public mutating func restart(at snapshot: Snapshot) {
        baseline = snapshot
        memory = TourMemory()
    }

    /// Whether `goal` is reached, given the page as it is now. Call it after every change.
    public mutating func isMet(_ goal: TourGoal<Snapshot>, now: Snapshot) -> Bool {
        goal.evaluate(baseline: baseline, now: now, memory: &memory)
    }
}

/// Where a running tour is: current step, whether it ticked off, what the buttons say.
/// The SwiftUI coach (BinisoftKit `tourCoach`) is a thin view over this.
public struct TourProgress<Snapshot> {
    public let steps: [TourStep<Snapshot>]
    public private(set) var index: Int
    public private(set) var isMet = false
    private var tracker: TourTracker<Snapshot>

    /// - Parameter startAt: step id to open first (screenshots: `-TourStep <id>`).
    public init(steps: [TourStep<Snapshot>], start snapshot: Snapshot, startAt: String? = nil) {
        self.steps = steps
        self.index = startAt.flatMap { id in steps.firstIndex { $0.id == id } } ?? 0
        self.tracker = TourTracker(baseline: snapshot)
    }

    public var step: TourStep<Snapshot>? { steps.indices.contains(index) ? steps[index] : nil }
    public var isFirst: Bool { index == 0 }
    public var isLast: Bool { index >= steps.count - 1 }

    /// Title of the main button.
    public var primaryTitle: String {
        if isLast { return "Done" }
        guard let step, !step.goal.isManual else { return isFirst ? "Let's Go" : "Continue" }
        return isMet ? "Next" : "Skip"
    }

    /// Doing the step is the main path; Skip is shown as the secondary style until it ticked off.
    public var primaryIsProminent: Bool {
        guard let step else { return true }
        return step.goal.isManual || isMet || isLast
    }

    /// Feed every change of the practice page. Returns true when the current step just ticked off.
    public mutating func observe(_ snapshot: Snapshot) -> Bool {
        guard !isMet, let step, !step.goal.isManual else { return false }
        guard tracker.isMet(step.goal, now: snapshot) else { return false }
        isMet = true
        return true
    }

    /// Moves on. Returns false when the tour is finished.
    public mutating func next(at snapshot: Snapshot) -> Bool {
        guard !isLast else { return false }
        index += 1
        isMet = false
        tracker.restart(at: snapshot)
        return true
    }

    public mutating func back(at snapshot: Snapshot) {
        guard index > 0 else { return }
        index -= 1
        isMet = false
        tracker.restart(at: snapshot)
    }
}

/// Decides when the tour opens by itself: the full tour after install, the What's new steps after
/// an update that added steps, otherwise never (replay from Settings / the Mac Help menu).
public struct TourSchedule {
    public static let seenVersionKey = "binisoft.tour.seenVersion"

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var seenVersion: Int { defaults.integer(forKey: Self.seenVersionKey) }

    /// Steps to open at launch (empty: nothing to show).
    public func stepsToOffer<Snapshot>(_ catalog: TourCatalog<Snapshot>) -> [TourStep<Snapshot>] {
        guard seenVersion < catalog.version else { return [] }
        return catalog.steps(newerThan: seenVersion)
    }

    /// Call when the tour closes (finished or skipped): it won't open by itself again until a new version.
    public func markSeen<Snapshot>(_ catalog: TourCatalog<Snapshot>) {
        defaults.set(catalog.version, forKey: Self.seenVersionKey)
    }

    public func reset() {
        defaults.removeObject(forKey: Self.seenVersionKey)
    }
}
