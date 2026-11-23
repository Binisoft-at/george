import Foundation
import GeorgeCore

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
    /// Pauses since Start (Apple Health gets them as pause/resume events).
    var pauses: [PauseSpan]? = nil
    /// The Apple Watch was asked to record this workout (paired, George installed).
    var watchExpected: Bool? = nil
    /// The watch was heard recording it: the watch saves it to Apple Health, not the iPhone.
    var watchRecording: Bool? = nil
    /// The watch's recording ended while the workout went on: when, and the part it saved.
    var watchStoppedAt: Date? = nil
    var watchWorkoutID: UUID? = nil

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
        /// When this Start continued it: Apple Health gets only what was done since (the part saved
        /// before is in Health already). Nil from older versions.
        var segmentStartedAt: Date? = nil

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

    // MARK: Apple Health links after Finish

    private static let healthLinksKey = "live.healthLinks"

    /// Finished workouts whose Apple Health link may still change (`PendingHealthLink`): kept apart
    /// from the per-workout state above, which goes when the workout ends.
    static func pendingHealthLinks(now: Date = Date()) -> [PendingHealthLink] {
        guard let data = UserDefaults.standard.data(forKey: healthLinksKey),
              let links = try? JSONDecoder().decode([PendingHealthLink].self, from: data) else { return [] }
        return PendingHealthLink.pruned(links, now: now)
    }

    static func addPendingHealthLink(_ link: PendingHealthLink) {
        savePendingHealthLinks(PendingHealthLink.adding(link, to: pendingHealthLinks(), now: Date()))
    }

    static func removePendingHealthLink(for sessionID: UUID) {
        savePendingHealthLinks(PendingHealthLink.removing(sessionID, from: pendingHealthLinks()))
    }

    private static func savePendingHealthLinks(_ links: [PendingHealthLink]) {
        guard !links.isEmpty, let data = try? JSONEncoder().encode(links) else {
            UserDefaults.standard.removeObject(forKey: healthLinksKey)
            return
        }
        UserDefaults.standard.set(data, forKey: healthLinksKey)
    }

    // MARK: The first part of a continued workout after Finish

    private static let earlierPartsKey = "live.earlierParts"

    /// What was measured before a finished workout was continued (`EarlierPartNumbers`): kept apart
    /// from the per-workout state above (Finish clears it), for the watch's numbers that come late.
    static func earlierPart(for sessionID: UUID, now: Date = Date()) -> EarlierPartNumbers? {
        earlierParts(now: now).first { $0.sessionID == sessionID }
    }

    static func keepEarlierPart(_ part: EarlierPartNumbers) {
        let parts = EarlierPartNumbers.adding(part, to: earlierParts(now: Date()), now: Date())
        guard let data = try? JSONEncoder().encode(parts) else { return }
        UserDefaults.standard.set(data, forKey: earlierPartsKey)
    }

    private static func earlierParts(now: Date) -> [EarlierPartNumbers] {
        guard let data = UserDefaults.standard.data(forKey: earlierPartsKey),
              let parts = try? JSONDecoder().decode([EarlierPartNumbers].self, from: data) else { return [] }
        return EarlierPartNumbers.pruned(parts, now: now)
    }
}
