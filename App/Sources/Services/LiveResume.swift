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
    }
}
