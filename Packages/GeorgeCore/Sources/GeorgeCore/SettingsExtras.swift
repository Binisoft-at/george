import Foundation

/// Settings that sync without a CloudKit schema change: a small JSON object stored in one field of the
/// synced settings record (`SyncedSettings.extrasData`). Keys are namespaced ("thalia.deliver").
/// Unknown keys – written by a newer app version – are kept when saving.
public struct SettingsExtras: Codable, Hashable, Sendable {
    /// A JSON value (unknown keys are kept as they are).
    public enum Value: Codable, Hashable, Sendable {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([Value])
        case object([String: Value])

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([Value].self) { self = .array(value) }
            else { self = .object(try container.decode([String: Value].self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }
    }

    public private(set) var values: [String: Value]

    public init(_ values: [String: Value] = [:]) {
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: Value].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    /// Reads the stored data; broken or missing data gives empty extras (never throws).
    public init(data: Data?) {
        guard let data, let decoded = try? JSONDecoder().decode(SettingsExtras.self, from: data) else {
            self.init()
            return
        }
        self = decoded
    }

    /// Compact JSON with sorted keys (the same content gives the same bytes on every device).
    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(self)
    }

    public func bool(_ key: String) -> Bool? {
        if case .bool(let value)? = values[key] { return value }
        return nil
    }

    public func string(_ key: String) -> String? {
        if case .string(let value)? = values[key] { return value }
        return nil
    }

    public func number(_ key: String) -> Double? {
        if case .number(let value)? = values[key] { return value }
        return nil
    }

    public subscript(key: String) -> Value? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public mutating func set(_ value: Bool, for key: String) { values[key] = .bool(value) }
    public mutating func set(_ value: String, for key: String) { values[key] = .string(value) }
    public mutating func set(_ value: Double, for key: String) { values[key] = .number(value) }
    public mutating func remove(_ key: String) { values[key] = nil }

    /// Keys used by George.
    public enum Key {
        /// Settings → Thalia → "Send to Thalia" (default on).
        public static let thaliaDeliver = "thalia.deliver"
    }
}
