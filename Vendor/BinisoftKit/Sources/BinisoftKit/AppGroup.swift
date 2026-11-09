import Foundation
import BinisoftKitCore

/// The app's own folder inside the shared App Group (`group.at.binisoft.shared`).
///
/// The group is shared by every Binisoft app, so only small summaries live here (widget
/// snapshots, cross-app events) – never the app's data.
public enum AppGroupFolder {
    /// `<App Group>/<appName>/`, created on demand. Nil when the build has no App Group
    /// entitlement (unsigned CI builds).
    public static func url(appName: String, identifiers: AppIdentifiers = .main) -> URL? {
        guard let group = identifiers.sharedAppGroup,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        let folder = root.appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
