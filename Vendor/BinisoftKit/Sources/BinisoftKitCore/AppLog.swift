import Foundation

// The in-app log. Every app writes what matters (launch, store mode, sync events, imports,
// errors) to AppLog; Settings → Diagnostics shows it with a "Copy log" button, so a problem on a
// device can be pasted straight into a chat. Kept on the device (Application Support), capped,
// never synced and never sent anywhere.

public enum LogLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case debug, info, notice, warning, error

    private var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .notice: 2
        case .warning: 3
        case .error: 4
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }

    public var symbol: String {
        switch self {
        case .debug: "ladybug"
        case .info: "info.circle"
        case .notice: "bell"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }
}

public struct LogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var level: LogLevel
    public var category: String
    public var message: String

    public init(id: UUID = UUID(), date: Date = Date(), level: LogLevel, category: String, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }

    /// `2026-11-01 12:03:04.123 [warning] sync: message`
    public var line: String {
        "\(LogEntry.timestamp(date)) [\(level.rawValue)] \(category): \(message)"
    }

    static func timestamp(_ date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let millis = (parts.nanosecond ?? 0) / 1_000_000
        return String(format: "%04ld-%02ld-%02ld %02ld:%02ld:%02ld.%03ldZ",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, millis)
    }
}

/// Thread-safe ring buffer of log entries, optionally persisted as JSON lines.
public final class LogBuffer: @unchecked Sendable {
    /// Posted (on any thread) after an entry was added or the log was cleared.
    public static let didChange = Notification.Name("BinisoftKit.LogBuffer.didChange")

    public let capacity: Int
    public let fileURL: URL?
    private let lock = NSLock()
    private var storage: [LogEntry] = []
    private var linesInFile = 0
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Called for every new entry (BinisoftKit mirrors it to the unified system log).
    public var mirror: ((LogEntry) -> Void)?

    public init(capacity: Int = 2000, fileURL: URL? = nil) {
        self.capacity = max(10, capacity)
        self.fileURL = fileURL
        load()
    }

    public var entries: [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func append(_ entry: LogEntry) {
        lock.lock()
        storage.append(entry)
        if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
        persist(entry)
        lock.unlock()
        mirror?(entry)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    public func log(_ level: LogLevel, _ message: String, category: String = "app") {
        append(LogEntry(level: level, category: category, message: message))
    }

    public func clear() {
        lock.lock()
        storage.removeAll()
        if let fileURL { try? Data().write(to: fileURL, options: .atomic) }
        linesInFile = 0
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// The text behind "Copy log": a header (app, version, device, storage) and every entry.
    public func export(header: [(String, String)] = [], minimum: LogLevel = .debug) -> String {
        var lines: [String] = []
        for (key, value) in header { lines.append("\(key): \(value)") }
        if !header.isEmpty { lines.append("") }
        let selected = entries.filter { $0.level >= minimum }
        lines.append("\(selected.count) entries, oldest first, times in UTC")
        lines.append(contentsOf: selected.map(\.line))
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: File

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = data.split(separator: UInt8(ascii: "\n"))
        let decoded = lines.compactMap { try? decoder.decode(LogEntry.self, from: Data($0)) }
        storage = Array(decoded.suffix(capacity))
        linesInFile = lines.count
        if linesInFile > capacity { rewrite() }
    }

    /// Appends one JSON line; rewrites the file from memory once it holds twice the capacity.
    private func persist(_ entry: LogEntry) {
        guard let fileURL, var line = try? encoder.encode(entry) else { return }
        line.append(UInt8(ascii: "\n"))
        if linesInFile + 1 > capacity * 2 {
            rewrite()
            return
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: fileURL, options: .atomic)
        }
        linesInFile += 1
    }

    private func rewrite() {
        guard let fileURL else { return }
        var data = Data()
        for entry in storage {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        linesInFile = storage.count
    }
}

/// The app-wide log. `AppLog.bootstrap(appName:)` (BinisoftKit) points it at a file once at launch;
/// until then entries stay in memory.
public enum AppLog {
    nonisolated(unsafe) public static var shared = LogBuffer()

    public static func debug(_ message: String, category: String = "app") { shared.log(.debug, message, category: category) }
    public static func info(_ message: String, category: String = "app") { shared.log(.info, message, category: category) }
    public static func notice(_ message: String, category: String = "app") { shared.log(.notice, message, category: category) }
    public static func warning(_ message: String, category: String = "app") { shared.log(.warning, message, category: category) }
    public static func error(_ message: String, category: String = "app") { shared.log(.error, message, category: category) }
}
