import Foundation

/// Small, locale-light formatting helpers shared by the iOS, macOS and watchOS apps.
public enum Format {
    public static func weight(_ kg: Double, unit: WeightUnit) -> String {
        let value = unit.fromKilograms(kg)
        return "\(number(value)) \(unit.rawValue)"
    }

    /// 12 -> "12", 12.5 -> "12.5", 12.25 -> "12.25"
    public static func number(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        let rounded = (value * 100).rounded() / 100
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// 45 -> "45s", 90 -> "1:30", 600 -> "10 min", 3700 -> "1h 1m"
    public static func shortDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds >= 3600 {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Clock style: 65 -> "1:05", 3725 -> "1:02:05"
    public static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "42 min", "1h 5m"
    public static func minutes(_ seconds: Double) -> String {
        let total = Int((seconds / 60).rounded())
        if total < 60 { return "\(total) min" }
        let h = total / 60
        let m = total % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    public static func distance(_ meters: Double) -> String {
        if meters >= 1000 { return "\(number((meters / 10).rounded() / 100)) km" }
        return "\(number(meters.rounded())) m"
    }

    public static func volume(_ kg: Double, unit: WeightUnit) -> String {
        let value = unit.fromKilograms(kg)
        if value >= 10_000 { return "\(number((value / 100).rounded() / 10))k \(unit.rawValue)" }
        return "\(Int(value.rounded())) \(unit.rawValue)"
    }
}

/// Parsing of loosely written durations/distances/numbers as they appear in CSVs and quick inputs.
public enum LooseParse {
    /// "30", "30s", "45 sec", "1:30", "2m", "2 min", "1h", "1h30m", "90''" -> seconds
    public static func seconds(_ raw: String) -> Int? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "''", with: "s").replacingOccurrences(of: "\"", with: "s")
        if text.contains(":") {
            let parts = text.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.allSatisfy({ $0 != nil }) else { return nil }
            let values = parts.compactMap { $0 }
            if values.count == 2 { return values[0] * 60 + values[1] }
            if values.count == 3 { return values[0] * 3600 + values[1] * 60 + values[2] }
            return nil
        }
        // Tokenize into number+unit pairs: "1h30m", "2 min", "45sec"
        var total = 0.0
        var number = ""
        var unit = ""
        var matchedAny = false
        func flush() -> Bool {
            guard !number.isEmpty else { return unit.isEmpty }
            guard let value = Double(number.replacingOccurrences(of: ",", with: ".")) else { return false }
            switch unit {
            case "", "s", "sec", "secs", "second", "seconds": total += value
            case "m", "min", "mins", "minute", "minutes", "'": total += value * 60
            case "h", "hr", "hrs", "hour", "hours": total += value * 3600
            default: return false
            }
            matchedAny = true
            number = ""
            unit = ""
            return true
        }
        for ch in text {
            if ch.isNumber || ch == "." || ch == "," {
                if !unit.isEmpty { guard flush() else { return nil } }
                number.append(ch)
            } else if ch.isLetter || ch == "'" {
                unit.append(ch)
            } else if ch == " " {
                continue
            } else {
                return nil
            }
        }
        guard flush(), matchedAny else { return nil }
        return Int(total.rounded())
    }

    /// "400", "400m", "1.5km", "1 mi", "800 yd" -> meters
    public static func meters(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "")
        guard !text.isEmpty else { return nil }
        let numberPart = String(text.prefix { $0.isNumber || $0 == "." || $0 == "," }).replacingOccurrences(of: ",", with: ".")
        let unitPart = String(text.dropFirst(numberPart.count))
        guard let value = Double(numberPart) else { return nil }
        switch unitPart {
        case "", "m", "meter", "meters", "metre", "metres": return value
        case "km", "k": return value * 1000
        case "mi", "mile", "miles": return value * 1609.344
        case "yd", "yard", "yards": return value * 0.9144
        case "ft", "feet": return value * 0.3048
        default: return nil
        }
    }

    public static func double(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
            .lowercased()
            .replacingOccurrences(of: "kg", with: "")
            .replacingOccurrences(of: "lbs", with: "")
            .replacingOccurrences(of: "lb", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return Double(text)
    }

    public static func bool(_ raw: String) -> Bool {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "y", "yes", "true", "x", "each", "both", "each side", "per side", "✓", "✔", "ja": return true
        default: return false
        }
    }

    /// Splits "12,10,8", "12/10/8", "12;10;8" or "12 | 10 | 8" into parts. Ranges like "8-12" stay intact.
    public static func list(_ raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",/;|")
        return raw.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
