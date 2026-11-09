import Foundation

/// RFC 4180 CSV reader with delimiter auto-detection (comma, semicolon, tab),
/// quoted fields (including embedded newlines and doubled quotes) and BOM handling.
public enum CSVReader {
    public static func detectDelimiter(in text: String) -> Character {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let candidates: [Character] = [",", ";", "\t"]
        var best: Character = ","
        var bestCount = 0
        for candidate in candidates {
            var count = 0
            var inQuotes = false
            for ch in firstLine {
                if ch == "\"" { inQuotes.toggle() } else if ch == candidate && !inQuotes { count += 1 }
            }
            if count > bestCount {
                best = candidate
                bestCount = count
            }
        }
        return best
    }

    /// Returns rows with their 1-based starting line number.
    public static func parse(_ input: String, delimiter: Character? = nil) -> [(line: Int, fields: [String])] {
        var text = input
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let sep = delimiter ?? detectDelimiter(in: text)
        var rows: [(Int, [String])] = []
        var field = ""
        var fields: [String] = []
        var inQuotes = false
        var line = 1
        var rowStartLine = 1
        var iterator = Array(text).makeIterator()
        var pending: Character? = nil

        func nextChar() -> Character? {
            if let p = pending {
                pending = nil
                return p
            }
            return iterator.next()
        }

        func endRow() {
            fields.append(field)
            field = ""
            // Skip completely empty lines.
            if !(fields.count == 1 && fields[0].trimmingCharacters(in: .whitespaces).isEmpty) {
                rows.append((rowStartLine, fields))
            }
            fields = []
        }

        while let ch = nextChar() {
            if inQuotes {
                if ch == "\"" {
                    if let next = nextChar() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    if ch == "\n" || ch == "\r\n" { line += 1 }
                    field.append(ch)
                }
                continue
            }
            switch ch {
            case "\"":
                if field.trimmingCharacters(in: .whitespaces).isEmpty {
                    field = ""
                    inQuotes = true
                } else {
                    field.append(ch)
                }
            case sep:
                fields.append(field)
                field = ""
            case "\n", "\r\n", "\r":
                endRow()
                line += 1
                rowStartLine = line
            default:
                field.append(ch)
            }
        }
        if !field.isEmpty || !fields.isEmpty { endRow() }
        return rows
    }

    /// Escape a value for writing.
    public static func escape(_ value: String, delimiter: Character = ",") -> String {
        let needsQuotes = value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r")
            || value.hasPrefix(" ") || value.hasSuffix(" ")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func write(rows: [[String]], delimiter: Character = ",") -> String {
        rows.map { row in row.map { escape($0, delimiter: delimiter) }.joined(separator: String(delimiter)) }
            .joined(separator: "\n") + "\n"
    }
}
