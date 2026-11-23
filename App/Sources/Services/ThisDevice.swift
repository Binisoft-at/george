import Foundation
import SwiftData
import GeorgeCore
#if os(iOS)
import UIKit
#endif

/// This install as the owner of a running workout (`WorkoutSession.liveDeviceID`, GeorgeCore
/// `LiveOwner`): an id made once and kept on this device, plus the kind of device – never the
/// device's name, which often holds a person's name.
enum ThisDevice {
    /// Made on first use and kept in UserDefaults (device-local).
    static let installID: String = {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: Prefs.installID), !stored.isEmpty { return stored }
        let made = UUID().uuidString
        defaults.set(made, forKey: Prefs.installID)
        return made
    }()

    @MainActor
    static var kind: LiveOwner.Kind {
        #if os(macOS)
        return .mac
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
        #endif
    }

    @MainActor
    static var owner: LiveOwner { LiveOwner(id: installID, kind: kind) }

    /// "Running on your Mac" for a workout in progress elsewhere ("Running on another device" when
    /// nobody claims it – older builds).
    @MainActor
    static func runningTitle(for session: WorkoutSession) -> String {
        LiveOwnership.runningTitle(owner: LiveOwner(raw: session.liveDeviceID), localID: installID, localKind: kind)
    }

    /// "your Mac", "your other iPhone", "another device" – where a workout in progress runs.
    @MainActor
    static func ownerName(of session: WorkoutSession) -> String {
        LiveOwnership.deviceName(of: LiveOwner(raw: session.liveDeviceID), localID: installID, localKind: kind)
    }
}
