import Foundation

/// Where a running workout stands, kept on this device so a relaunch (iOS ended the app, the phone
/// restarted) continues exactly there: the rest still running, the set already started, the plan's
/// place, a pause. Cleared when the workout ends.
struct LiveResume: Codable {
    var currentSetID: UUID?
    var focusedItemID: UUID?
    var restEndsAt: Date?
    var restTotal: Int
    var restBeforeNext: Double
    var nudgesGiven: Int
    var isPaused: Bool
    var pausedRestRemaining: Double?
    var pausedAt: Date?
    /// A hold paused mid-way: what was left of it, and its set.
    var pausedTimedRemaining: Double? = nil
    var pausedTimedSetID: UUID? = nil
    /// When the running hold of the current set ends (pauses already left out).
    var timedSetEndsAt: Date? = nil

    private static func key(_ id: UUID) -> String { "live.resume." + id.uuidString }

    static func load(for sessionID: UUID) -> LiveResume? {
        guard let data = UserDefaults.standard.data(forKey: key(sessionID)) else { return nil }
        return try? JSONDecoder().decode(LiveResume.self, from: data)
    }

    func save(for sessionID: UUID) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(sessionID))
    }

    static func clear(for sessionID: UUID) {
        UserDefaults.standard.removeObject(forKey: key(sessionID))
        UserDefaults.standard.removeObject(forKey: preStartKey(sessionID))
    }

    // MARK: Before Start

    /// How a session looked before Start made it the running workout (a workout continued after
    /// "stopped early", or a planned one). Discard puts it back, so the sets saved earlier, their
    /// effort and the Apple Health link stay. Written once at Start, kept apart from the state above
    /// (which is saved on every tick), and cleared with it.
    struct PreStart: Codable {
        var statusRaw: String
        var contentData: Data?
        var startedAt: Date?
        var plannedDate: Date?
        var endedAt: Date?
        var accumulatedSeconds: Double
        var title: String
        /// The automatic title Start gave it for today (put back only while it still has that title).
        var autoTitle: String? = nil

        func save(for sessionID: UUID) {
            guard let data = try? JSONEncoder().encode(self) else { return }
            UserDefaults.standard.set(data, forKey: LiveResume.preStartKey(sessionID))
        }
    }

    private static func preStartKey(_ id: UUID) -> String { "live.prestart." + id.uuidString }

    static func loadPreStart(for sessionID: UUID) -> PreStart? {
        guard let data = UserDefaults.standard.data(forKey: preStartKey(sessionID)) else { return nil }
        return try? JSONDecoder().decode(PreStart.self, from: data)
    }
}
