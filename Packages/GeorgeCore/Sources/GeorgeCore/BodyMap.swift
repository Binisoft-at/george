import Foundation

/// A drawable muscle region of the body map (see scripts/body_map.py).
public struct BodyRegion: Hashable, Sendable {
    public var group: MuscleGroup
    /// SVG path data in a 200 × 440 view box (left side for mirrored regions).
    public var path: String
    /// Also draw the region mirrored around x = 100 (right side of the body).
    public var mirrored: Bool
}

/// Neutral silhouette pieces (head, hands, knees, feet…).
public struct BodyShape: Hashable, Sendable {
    public var name: String
    public var path: String
    public var mirrored: Bool
}

public enum BodyMap {
    public static let viewBox = (width: 200.0, height: 440.0)

    public enum Side: String, Sendable, CaseIterable { case front, back }

    public static func regions(_ side: Side) -> [BodyRegion] { side == .front ? front : back }
    public static func details(_ side: Side) -> [String] { side == .front ? frontDetails : backDetails }
}

/// Minimal SVG path parser (M, L, H, V, C, S, Q, T, Z — absolute and relative). Arcs are not supported.
public enum SVGPath {
    public enum Element: Hashable, Sendable {
        case move(x: Double, y: Double)
        case line(x: Double, y: Double)
        case cubic(x: Double, y: Double, c1x: Double, c1y: Double, c2x: Double, c2y: Double)
        case quad(x: Double, y: Double, cx: Double, cy: Double)
        case close
    }

    public static func parse(_ data: String) -> [Element] {
        var tokens: [String] = []
        var number = ""
        func flush() {
            if !number.isEmpty { tokens.append(number); number = "" }
        }
        for ch in data {
            if ch.isLetter && ch != "e" && ch != "E" {
                flush()
                tokens.append(String(ch))
            } else if ch == "-" {
                // A minus starts a new number unless it follows an exponent.
                if let last = number.last, last == "e" || last == "E" {
                    number.append(ch)
                } else {
                    flush()
                    number.append(ch)
                }
            } else if ch == "," || ch == " " || ch == "\n" || ch == "\t" {
                flush()
            } else if ch == "." && number.contains(".") && !number.contains("e") {
                flush()
                number.append(ch)
            } else {
                number.append(ch)
            }
        }
        flush()

        var elements: [Element] = []
        var index = 0
        var command: Character = "M"
        var current = (x: 0.0, y: 0.0)
        var start = (x: 0.0, y: 0.0)
        var lastControl: (x: Double, y: Double)? = nil
        var lastQuadControl: (x: Double, y: Double)? = nil

        func next() -> Double? {
            guard index < tokens.count, let value = Double(tokens[index]) else { return nil }
            index += 1
            return value
        }

        while index < tokens.count {
            if let first = tokens[index].first, first.isLetter {
                command = first
                index += 1
                if command == "Z" || command == "z" {
                    elements.append(.close)
                    current = start
                    lastControl = nil
                    lastQuadControl = nil
                    continue
                }
            }
            let relative = command.isLowercase
            let base = relative ? current : (x: 0.0, y: 0.0)
            switch command.uppercased().first! {
            case "M":
                guard let x = next(), let y = next() else { return elements }
                current = (base.x + x, base.y + y)
                start = current
                elements.append(.move(x: current.x, y: current.y))
                command = relative ? "l" : "L" // implicit lineto after moveto
                lastControl = nil
                lastQuadControl = nil
            case "L":
                guard let x = next(), let y = next() else { return elements }
                current = (base.x + x, base.y + y)
                elements.append(.line(x: current.x, y: current.y))
                lastControl = nil
                lastQuadControl = nil
            case "H":
                guard let x = next() else { return elements }
                current = (relative ? current.x + x : x, current.y)
                elements.append(.line(x: current.x, y: current.y))
                lastControl = nil
                lastQuadControl = nil
            case "V":
                guard let y = next() else { return elements }
                current = (current.x, relative ? current.y + y : y)
                elements.append(.line(x: current.x, y: current.y))
                lastControl = nil
                lastQuadControl = nil
            case "C":
                guard let x1 = next(), let y1 = next(), let x2 = next(), let y2 = next(), let x = next(), let y = next() else { return elements }
                let c1 = (base.x + x1, base.y + y1)
                let c2 = (base.x + x2, base.y + y2)
                current = (base.x + x, base.y + y)
                elements.append(.cubic(x: current.x, y: current.y, c1x: c1.0, c1y: c1.1, c2x: c2.0, c2y: c2.1))
                lastControl = (c2.0, c2.1)
                lastQuadControl = nil
            case "S":
                guard let x2 = next(), let y2 = next(), let x = next(), let y = next() else { return elements }
                let reflected = lastControl.map { (2 * current.x - $0.x, 2 * current.y - $0.y) } ?? (current.x, current.y)
                let c2 = (base.x + x2, base.y + y2)
                current = (base.x + x, base.y + y)
                elements.append(.cubic(x: current.x, y: current.y, c1x: reflected.0, c1y: reflected.1, c2x: c2.0, c2y: c2.1))
                lastControl = (c2.0, c2.1)
                lastQuadControl = nil
            case "Q":
                guard let x1 = next(), let y1 = next(), let x = next(), let y = next() else { return elements }
                let c = (base.x + x1, base.y + y1)
                current = (base.x + x, base.y + y)
                elements.append(.quad(x: current.x, y: current.y, cx: c.0, cy: c.1))
                lastQuadControl = (c.0, c.1)
                lastControl = nil
            case "T":
                guard let x = next(), let y = next() else { return elements }
                let c = lastQuadControl.map { (2 * current.x - $0.x, 2 * current.y - $0.y) } ?? (current.x, current.y)
                current = (base.x + x, base.y + y)
                elements.append(.quad(x: current.x, y: current.y, cx: c.0, cy: c.1))
                lastQuadControl = (c.0, c.1)
                lastControl = nil
            default:
                // Unsupported command (e.g. arcs): skip its token to avoid an endless loop.
                index += 1
            }
        }
        return elements
    }

    /// Mirror around a vertical axis (x' = axis * 2 - x).
    public static func mirrored(_ elements: [Element], axis: Double = 100) -> [Element] {
        func m(_ x: Double) -> Double { axis * 2 - x }
        return elements.map { element in
            switch element {
            case .move(let x, let y): return .move(x: m(x), y: y)
            case .line(let x, let y): return .line(x: m(x), y: y)
            case .cubic(let x, let y, let c1x, let c1y, let c2x, let c2y): return .cubic(x: m(x), y: y, c1x: m(c1x), c1y: c1y, c2x: m(c2x), c2y: c2y)
            case .quad(let x, let y, let cx, let cy): return .quad(x: m(x), y: y, cx: m(cx), cy: cy)
            case .close: return .close
            }
        }
    }
}
