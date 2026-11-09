import Foundation
import OSLog
import BinisoftKitCore

public extension AppLog {
    /// Call once at launch: keeps the log in Application Support/<appName>/app-log.jsonl (this
    /// device only) and mirrors every entry to the unified system log (Console.app, `log show`).
    static func bootstrap(appName: String) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(appName, isDirectory: true)
        let buffer = LogBuffer(capacity: 2000, fileURL: folder?.appendingPathComponent("app-log.jsonl"))
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "at.binisoft.\(appName.lowercased())", category: "app")
        buffer.mirror = { entry in
            let text = "\(entry.category): \(entry.message)"
            switch entry.level {
            case .debug: logger.debug("\(text, privacy: .public)")
            case .info: logger.info("\(text, privacy: .public)")
            case .notice: logger.notice("\(text, privacy: .public)")
            case .warning: logger.warning("\(text, privacy: .public)")
            case .error: logger.error("\(text, privacy: .public)")
            }
        }
        shared = buffer
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        info("Launch \(appName) \(AppVersion.main.display) · \(os) · \(PlatformInfo.model)", category: "launch")
    }

    /// The text behind "Copy log".
    @MainActor
    static func exportText(appName: String, mode: StorageMode?) -> String {
        shared.export(header: [
            ("App", "\(appName) \(AppVersion.main.display)"),
            ("Bundle", Bundle.main.bundleIdentifier ?? "?"),
            ("System", "\(PlatformInfo.name) \(ProcessInfo.processInfo.operatingSystemVersionString)"),
            ("Device", PlatformInfo.model),
            ("Storage", mode?.title ?? "?"),
            ("Exported", Date().formatted(.iso8601)),
        ])
    }
}
