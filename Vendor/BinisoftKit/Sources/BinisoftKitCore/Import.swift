import Foundation

// Import building blocks (from Finn and George): a forgiving CSV reader, a plan that makes
// re-importing the same file safe (updates instead of duplicates), and the prompt people paste
// into another AI to turn their notes or spreadsheets into the app's CSV format.

/// Small RFC 4180 CSV reader/writer with delimiter detection and the usual encodings.
public enum CSV {
    public static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text.withoutBOM }
        if let text = String(data: data, encoding: .utf16) { return text.withoutBOM }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    /// Picks the delimiter (`,` `;` tab or `|`) that splits the first lines most consistently.
    public static func detectDelimiter(_ text: String) -> Character {
        let lines = text.split(whereSeparator: \.isNewline).prefix(5).map(String.init)
        guard !lines.isEmpty else { return "," }
        var best: (Character, Int) = (",", 0)
        for candidate in [",", ";", "\t", "|"] as [Character] {
            let counts = lines.map { countOutsideQuotes(candidate, in: $0) }
            guard let first = counts.first, first > 0 else { continue }
            let score = (counts.allSatisfy { $0 == first } ? 1000 : 0) + first
            if score > best.1 { best = (candidate, score) }
        }
        return best.0
    }

    private static func countOutsideQuotes(_ char: Character, in line: String) -> Int {
        var inQuotes = false
        var count = 0
        for c in line {
            if c == "\"" { inQuotes.toggle() } else if c == char && !inQuotes { count += 1 }
        }
        return count
    }

    public static func parse(_ text: String, delimiter: Character? = nil) -> [[String]] {
        let delimiter = delimiter ?? detectDelimiter(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = Array(text.withoutBOM).makeIterator()
        var pending: Character?

        func nextChar() -> Character? {
            if let p = pending {
                pending = nil
                return p
            }
            return iterator.next()
        }

        func endRow() {
            row.append(field)
            field = ""
            if !(row.count == 1 && row[0].trimmingCharacters(in: .whitespaces).isEmpty) {
                rows.append(row)
            }
            row = []
        }

        while let c = nextChar() {
            if inQuotes {
                if c == "\"" {
                    if let following = nextChar() {
                        if following == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = following
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.trimmingCharacters(in: .whitespaces).isEmpty {
                field = ""
                inQuotes = true
            } else if c == delimiter {
                row.append(field)
                field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                endRow()
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows.map { $0.map { $0.trimmingCharacters(in: .whitespaces) } }
    }

    public static func escape(_ value: String, delimiter: Character = ",") -> String {
        if value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    public static func write(_ rows: [[String]], delimiter: Character = ",") -> String {
        rows.map { $0.map { escape($0, delimiter: delimiter) }.joined(separator: String(delimiter)) }
            .joined(separator: "\n") + "\n"
    }

    /// Rows as dictionaries keyed by the lower-cased, trimmed header.
    public static func records(_ text: String, delimiter: Character? = nil) -> (header: [String], rows: [[String: String]]) {
        let table = parse(text, delimiter: delimiter)
        guard let header = table.first else { return ([], []) }
        let keys = header.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        let rows = table.dropFirst().map { values -> [String: String] in
            var record: [String: String] = [:]
            for (index, key) in keys.enumerated() where index < values.count {
                record[key] = values[index]
            }
            return record
        }
        return (keys, Array(rows))
    }
}

/// What an import will do, shown as a preview before anything changes. Records are matched by a
/// stable key (an `id` column, or a key derived from the content), so importing the same file
/// twice updates instead of duplicating.
public struct ImportPlan<Record: Equatable> {
    public enum Action: Equatable, Sendable {
        case create, update, unchanged
    }

    public struct Entry {
        public let key: String
        public let record: Record
        public let action: Action
    }

    public let entries: [Entry]
    /// Rows that couldn't be read, with the reason ("Row 4: no title").
    public let skipped: [String]

    /// - Parameters:
    ///   - incoming: parsed rows in file order; a key that appears twice keeps the last row.
    ///   - existing: what the app already has, by the same key.
    public init(incoming: [(key: String, record: Record)], existing: [String: Record], skipped: [String] = []) {
        var order: [String] = []
        var latest: [String: Record] = [:]
        for (key, record) in incoming {
            if latest[key] == nil { order.append(key) }
            latest[key] = record
        }
        entries = order.compactMap { key in
            guard let record = latest[key] else { return nil }
            let action: Action
            if let current = existing[key] {
                action = current == record ? .unchanged : .update
            } else {
                action = .create
            }
            return Entry(key: key, record: record, action: action)
        }
        self.skipped = skipped
    }

    public var creates: Int { entries.filter { $0.action == .create }.count }
    public var updates: Int { entries.filter { $0.action == .update }.count }
    public var unchanged: Int { entries.filter { $0.action == .unchanged }.count }
    public var hasChanges: Bool { creates + updates > 0 }

    /// "3 new · 1 updated · 5 unchanged · 1 skipped"
    public var summary: String {
        var parts = ["\(creates) new", "\(updates) updated", "\(unchanged) unchanged"]
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
        return parts.joined(separator: " · ")
    }

    /// A stable key from content, for files without an id column (lower-cased, trimmed, collapsed spaces).
    public static func contentKey(_ parts: [String]) -> String {
        parts.map { part in
            part.lowercased()
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        }
        .joined(separator: "|")
    }
}

/// The prompt behind "Copy prompt for another AI": the person pastes it with their notes,
/// screenshots or spreadsheet into any AI and gets back a CSV the app imports (preview first).
public struct AIImportPrompt: Sendable {
    public struct Column: Sendable {
        public let name: String
        public let meaning: String
        public let required: Bool

        public init(_ name: String, _ meaning: String, required: Bool = false) {
            self.name = name
            self.meaning = meaning
            self.required = required
        }
    }

    public var appName: String
    /// What the AI should do, in the person's words (e.g. "Turn my gym notes into workouts").
    public var task: String
    public var columns: [Column]
    public var rules: [String]
    /// Names that already exist in the app, so the AI reuses them ("Folders": ["Work", "Home"]).
    public var existingNames: [(String, [String])]
    public var exampleRows: [[String]]

    public init(appName: String, task: String, columns: [Column], rules: [String] = [],
                existingNames: [(String, [String])] = [], exampleRows: [[String]] = []) {
        self.appName = appName
        self.task = task
        self.columns = columns
        self.rules = rules
        self.existingNames = existingNames
        self.exampleRows = exampleRows
    }

    public var header: String { columns.map(\.name).joined(separator: ",") }

    public var text: String {
        var lines: [String] = []
        lines.append("You convert my data into the CSV import format of my app \"\(appName)\". \(task)")
        lines.append("")
        lines.append("## Output rules")
        lines.append("- Answer with ONE csv code block and nothing else. The first line is exactly this header:")
        lines.append(header)
        lines.append("- Comma separated, UTF-8. Put a value in \"double quotes\" if it contains a comma, a quote or a line break.")
        lines.append("- Leave a column empty when it doesn't apply. Never invent data; skip a row if it is unclear.")
        lines.append("- Keep my own words and names exactly as I wrote them.")
        for rule in rules { lines.append("- \(rule)") }
        lines.append("")
        lines.append("## Columns")
        lines.append("| column | meaning | required |")
        lines.append("|---|---|---|")
        for column in columns {
            lines.append("| \(column.name) | \(column.meaning) | \(column.required ? "yes" : "no") |")
        }
        let names = existingNames.filter { !$0.1.isEmpty }
        if !names.isEmpty {
            lines.append("")
            lines.append("## Names that already exist in \(appName) (reuse them exactly)")
            for (kind, values) in names { lines.append("- \(kind): \(values.joined(separator: ", "))") }
        }
        if !exampleRows.isEmpty {
            lines.append("")
            lines.append("## Example")
            lines.append("```csv")
            lines.append(header)
            for row in exampleRows { lines.append(row.map { CSV.escape($0) }.joined(separator: ",")) }
            lines.append("```")
        }
        lines.append("")
        lines.append("Here is my data:")
        return lines.joined(separator: "\n") + "\n"
    }
}

extension String {
    var withoutBOM: String {
        hasPrefix("\u{FEFF}") ? String(dropFirst()) : self
    }
}
