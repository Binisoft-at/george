import Foundation

/// Safe reading and writing of a workout's stored content (`contentData` of templates and sessions).
///
/// The rules that keep a workout from being emptied or stripped:
/// - Data that can't be read is never replaced by what was derived from it (the empty workout the
///   lenient `WorkoutContent.decode` returns).
/// - Data written by a newer George (a higher `version`) is never overwritten here: this build
///   would drop the fields it doesn't know, and sync would carry the stripped copy to every device.
/// - A number JSON can't carry (NaN, infinity) never turns the whole workout into empty data: the
///   number is left empty, the rest is written.
public enum StoredContent {
    /// Whether stored content can be shown and edited on this device.
    public enum ReadState: Equatable, Sendable {
        case readable
        /// Written by a newer George (format `version`): shown read-only until George is updated here.
        case newer(version: Int)
        /// Data that can't be read at all. It stays as it is.
        case unreadable

        public var isEditable: Bool { self == .readable }

        /// Banner title on the workout and template screens.
        public var title: String {
            switch self {
            case .readable: return ""
            case .newer: return "Update George on this device to edit"
            case .unreadable: return "Can't read this workout"
            }
        }

        /// Banner text under the title.
        public var message: String {
            switch self {
            case .readable: return ""
            case .newer:
                return "A newer version of George changed it. To keep what it added, it's read-only here until you update."
            case .unreadable:
                return "Its exercises are kept as they are, so nothing is lost. Update George, or restore it from a backup in Settings."
            }
        }
    }

    public static func readState(of data: Data?) -> ReadState {
        guard let data, !data.isEmpty else { return .readable }
        // One decode in the usual case (every save of a live set comes through here).
        if let content = try? WorkoutContent.decodeStrict(data) {
            return content.version > WorkoutContent.currentVersion ? .newer(version: content.version) : .readable
        }
        // A newer format this build can't even decode is still "newer", not broken.
        if let version = storedVersion(of: data), version > WorkoutContent.currentVersion {
            return .newer(version: version)
        }
        return .unreadable
    }

    /// The `version` written in stored content (nil without one, or when it isn't JSON).
    public static func storedVersion(of data: Data) -> Int? {
        struct Header: Decodable { var version: Int? }
        return (try? JSONDecoder().decode(Header.self, from: data))?.version
    }

    /// Why a write was refused (the stored data stays).
    public enum KeepReason: Equatable, Sendable {
        case newerVersion(Int)
        case unreadable
        case encodingFailed(String)

        /// For the App Log.
        public var logText: String {
            switch self {
            case .newerVersion(let version): return "written by a newer George (format \(version)); update this device to edit"
            case .unreadable: return "the stored workout can't be read, so it isn't replaced"
            case .encodingFailed(let error): return "couldn't encode the workout (\(error))"
            }
        }
    }

    public enum WriteDecision: Equatable, Sendable {
        /// Store this data.
        case write(Data)
        /// Store this data; `removed` numbers JSON can't carry (NaN, infinity) were left empty.
        case repaired(Data, removed: Int)
        /// Keep the stored data as it is.
        case keep(KeepReason)
    }

    /// What to store for `content` over the stored `old` data. `force` (an explicit replace: an import
    /// with "Replace templates", a restore) skips the checks on the old data – the new content is
    /// complete by itself – but never writes data that can't be encoded.
    public static func write(
        _ content: WorkoutContent, over old: Data?, force: Bool = false,
        encode: (WorkoutContent) throws -> Data = { try $0.encodedData() }
    ) -> WriteDecision {
        if !force {
            switch readState(of: old) {
            case .readable: break
            case .newer(let version): return .keep(.newerVersion(version))
            case .unreadable: return .keep(.unreadable)
            }
            // Read from a newer format (fields this build doesn't know were dropped on reading).
            if content.version > WorkoutContent.currentVersion { return .keep(.newerVersion(content.version)) }
        }
        do {
            return .write(try encode(content))
        } catch {
            let (cleaned, removed) = content.removingNonFiniteNumbers()
            guard removed > 0, let data = try? encode(cleaned) else {
                return .keep(.encodingFailed(String(describing: error)))
            }
            return .repaired(data, removed: removed)
        }
    }
}

public extension WorkoutContent {
    /// A copy without numbers JSON can't carry (NaN, ±infinity): they become empty. Returns how many
    /// were removed.
    func removingNonFiniteNumbers() -> (content: WorkoutContent, removed: Int) {
        var copy = self
        var removed = 0
        func clean(_ value: inout Double?) {
            if let v = value, !v.isFinite {
                value = nil
                removed += 1
            }
        }
        func clean(_ date: inout Date?) {
            if let d = date, !d.timeIntervalSince1970.isFinite {
                date = nil
                removed += 1
            }
        }
        for b in copy.blocks.indices {
            for i in copy.blocks[b].items.indices {
                clean(&copy.blocks[b].items[i].fatigue)
                for s in copy.blocks[b].items[i].sets.indices {
                    clean(&copy.blocks[b].items[i].sets[s].targetWeight)
                    clean(&copy.blocks[b].items[i].sets[s].targetMeters)
                    clean(&copy.blocks[b].items[i].sets[s].targetRPE)
                    clean(&copy.blocks[b].items[i].sets[s].weight)
                    clean(&copy.blocks[b].items[i].sets[s].meters)
                    clean(&copy.blocks[b].items[i].sets[s].rpe)
                    clean(&copy.blocks[b].items[i].sets[s].doneAt)
                    clean(&copy.blocks[b].items[i].sets[s].startedAt)
                }
            }
        }
        return (copy, removed)
    }
}
