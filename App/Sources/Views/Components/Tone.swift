import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// One meaning per colour, everywhere in George.
///
/// * `accent` – the action, the current thing, done (brand blue).
/// * `warning` – needs attention (orange). Never decoration.
/// * `rest` – a calm teal for resting and recovering phases.
/// * `flame` / `flameGlow` – only the flame and the streak dots.
/// * `record` – personal records (gold).
///
/// Fills (bars, maps, dots) may use the bright system colours; words in a status colour use the
/// `…Text` variants, which keep at least 4.5 : 1 contrast on the card background in light and dark.
enum Tone {
    static let accent = Color.accentColor
    static let warning = Color.orange
    static let rest = Color.dynamic(light: "#16968D", dark: "#4FD1C5")
    static let flame = Color(hex: "#FF6A1A")
    static let flameGlow = Color(hex: "#FFC23D")
    static let record = Color.dynamic(light: "#C98A00", dark: "#FFD15C")

    // MARK: Status words (contrast-safe)

    /// "Recovered", "In target", "Productive".
    static let goodText = Color.dynamic(light: "#1E7A34", dark: "#5FD27A")
    /// "Recovering", "Fatigued", "Detraining" – take it a bit easier.
    static let cautionText = Color.dynamic(light: "#B85C00", dark: "#FFB35C")
    /// "Depleted", "Overtraining" – too much.
    static let badText = Color.dynamic(light: "#C4281C", dark: "#FF7B72")
    /// Neutral information in colour ("Peaking", "Below target").
    static let infoText = Color.dynamic(light: "#0B67A8", dark: "#7CCBFF")
    /// "Maintaining".
    static let calmText = Color.dynamic(light: "#5B4BC4", dark: "#BDB4FF")

    // MARK: Target status fills (sets per week against the profile's target)

    /// Below the target: a light blue, deeper the closer it gets to the target.
    static let below = Color(hex: "#5AA9F5")
    static let inTarget = Color(hex: "#34C759")
    static let above = Color(hex: "#F5A524")
}

extension Color {
    /// A colour that follows light and dark mode ("#RRGGBB" each).
    static func dynamic(light: String, dark: String) -> Color {
        #if os(iOS)
        let lightColor = UIColor(rgbHex: light)
        let darkColor = UIColor(rgbHex: dark)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor })
        #elseif os(macOS)
        let lightColor = NSColor(rgbHex: light)
        let darkColor = NSColor(rgbHex: dark)
        return Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        })
        #else
        return Color(hex: light)
        #endif
    }
}

private func rgbComponents(_ hex: String) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
    var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("#") { text.removeFirst() }
    var value: UInt64 = 0
    guard text.count == 6, Scanner(string: text).scanHexInt64(&value) else { return (0.5, 0.5, 0.5) }
    return (CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255)
}

#if os(iOS)
private extension UIColor {
    convenience init(rgbHex: String) {
        let c = rgbComponents(rgbHex)
        self.init(red: c.red, green: c.green, blue: c.blue, alpha: 1)
    }
}
#elseif os(macOS)
private extension NSColor {
    convenience init(rgbHex: String) {
        let c = rgbComponents(rgbHex)
        self.init(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }
}
#endif

/// Where a weekly value sits against a target range (sets per muscle and week).
enum TargetStatus: String, CaseIterable, Identifiable {
    case below, within, above
    var id: String { rawValue }

    init(_ value: Double, target: ClosedRange<Int>) {
        if value < Double(target.lowerBound) { self = .below }
        else if value <= Double(target.upperBound) { self = .within }
        else { self = .above }
    }

    var title: String {
        switch self {
        case .below: return "Below target"
        case .within: return "In target"
        case .above: return "Above target"
        }
    }

    /// A symbol, so the status never relies on colour alone.
    var symbol: String {
        switch self {
        case .below: return "arrow.down"
        case .within: return "checkmark"
        case .above: return "arrow.up"
        }
    }

    var color: Color {
        switch self {
        case .below: return Tone.below
        case .within: return Tone.inTarget
        case .above: return Tone.above
        }
    }

    var textColor: Color {
        switch self {
        case .below: return Tone.infoText
        case .within: return Tone.goodText
        case .above: return Tone.cautionText
        }
    }

    /// Fill for a value: below the target a light blue that deepens toward the lower bound.
    static func fill(_ value: Double, target: ClosedRange<Int>) -> Color {
        let status = TargetStatus(value, target: target)
        guard status == .below else { return status.color }
        guard value > 0 else { return MusclePalette.empty }
        let share = min(1, value / Double(max(1, target.lowerBound)))
        return Tone.below.opacity(0.3 + 0.6 * share)
    }
}
