#if canImport(TipKit)
import Foundation
import TipKit
import BinisoftKitCore

/// TipKit setup shared by every app: hints show right away (each once), demo/screenshot launches
/// hide them, and "Show hints again" in Settings resets them on the next launch.
public enum BinisoftTips {
    static let resetKey = "binisoft.tips.resetRequested"

    /// Call once at launch, before any tip is shown.
    public static func configure(launch: LaunchOptions = .current) {
        if launch.isDemo {
            Tips.hideAllTipsForTesting()
        }
        // The datastore can only be reset before `Tips.configure`.
        if UserDefaults.standard.bool(forKey: resetKey) {
            UserDefaults.standard.removeObject(forKey: resetKey)
            do {
                try Tips.resetDatastore()
                AppLog.info("Hints reset", category: "tips")
            } catch {
                AppLog.warning("Hints couldn't be reset: \(error.localizedDescription)", category: "tips")
            }
        }
        do {
            try Tips.configure([
                .displayFrequency(.immediate),
                .datastoreLocation(.applicationDefault),
            ])
        } catch {
            AppLog.warning("TipKit not configured: \(error.localizedDescription)", category: "tips")
        }
    }

    /// "Show hints again": takes effect at the next launch.
    public static func requestReset() {
        UserDefaults.standard.set(true, forKey: resetKey)
    }
}
#endif
