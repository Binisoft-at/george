import Foundation
import GeorgeCore

extension SyncedSettings {
    /// Synced settings without their own CloudKit field (JSON in `extrasData`; unknown keys are kept).
    var extras: SettingsExtras {
        get { SettingsExtras(data: extrasData) }
        set {
            let data = newValue.encoded()
            guard data != extrasData else { return }
            extrasData = data
            updatedAt = Date()
        }
    }
}
