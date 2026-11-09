import Foundation

/// Identifiers from Config/Base.xcconfig, exposed to code through Info.plist keys. Nothing is
/// hard-coded in Swift: the app's own container, the shared container and the shared App Group
/// all come from here.
public struct AppIdentifiers: Equatable, Sendable {
    public static let appCloudKitContainerKey = "AppCloudKitContainer"
    public static let sharedCloudKitContainerKey = "SharedCloudKitContainer"
    public static let sharedAppGroupKey = "SharedAppGroup"

    /// The app's own iCloud container (its synced data).
    public let appCloudKitContainer: String?
    /// Cross-app container for small events and summaries only – never an app's data.
    public let sharedCloudKitContainer: String?
    /// Shared App Group (widgets, complications, small cross-app files).
    public let sharedAppGroup: String?

    public init(info: [String: Any]) {
        appCloudKitContainer = Self.clean(info[Self.appCloudKitContainerKey])
        sharedCloudKitContainer = Self.clean(info[Self.sharedCloudKitContainerKey])
        sharedAppGroup = Self.clean(info[Self.sharedAppGroupKey])
    }

    public static var main: AppIdentifiers { AppIdentifiers(info: Bundle.main.infoDictionary ?? [:]) }

    /// Empty values and unresolved build settings ("$(APP_CLOUDKIT_CONTAINER)") count as missing.
    static func clean(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, !text.contains("$(") else { return nil }
        return text
    }
}

/// Marketing version and build number from Info.plist.
public struct AppVersion: Equatable, Sendable {
    public let marketing: String
    public let build: String

    public init(info: [String: Any]) {
        marketing = info["CFBundleShortVersionString"] as? String ?? "0"
        build = info["CFBundleVersion"] as? String ?? "0"
    }

    public static var main: AppVersion { AppVersion(info: Bundle.main.infoDictionary ?? [:]) }

    /// "1.2.0 (57)"
    public var display: String { "\(marketing) (\(build))" }
}

/// Launch arguments every app understands (screenshots in CI, UI checks, support).
///
///     -Demo                 sample data in a separate in-memory store; no sync, no tips, no automatic tour
///     -DemoScreen <name>    open this screen (the app maps names to screens)
///     -Tour                 open the tour at launch
///     -TourStep <id>        open the tour at this step
///     -ResetTour            forget which tour version was seen
public struct LaunchOptions: Equatable, Sendable {
    public var isDemo: Bool
    public var screen: String?
    public var startTour: Bool
    public var tourStep: String?
    public var resetTour: Bool

    public init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            let value = arguments[index + 1]
            return value.hasPrefix("-") ? nil : value
        }
        isDemo = arguments.contains("-Demo")
        screen = value(after: "-DemoScreen")
        tourStep = value(after: "-TourStep")
        startTour = arguments.contains("-Tour") || tourStep != nil
        resetTour = arguments.contains("-ResetTour")
    }

    public static let current = LaunchOptions()
}

/// A small Codable file (widget snapshot, cross-app summary) written atomically.
public struct SnapshotFile<Value: Codable> {
    public let url: URL

    public init(folder: URL, name: String) {
        url = folder.appendingPathComponent(name)
    }

    public func write(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    public func read() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }
}
