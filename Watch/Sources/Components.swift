import SwiftUI
import WatchKit
import GeorgeCore

// MARK: - Colors

extension Color {
    /// Creates a color from `#RRGGBB`, `RRGGBB` or `#RRGGBBAA`. Invalid input falls back to system gray.
    init(georgeHex hex: String) {
        let rgba = GeorgeHex.components(of: hex) ?? GeorgeHex.fallback
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

enum GeorgeHex {
    typealias RGBA = (red: Double, green: Double, blue: Double, alpha: Double)

    static let fallback: RGBA = (red: 142.0 / 255, green: 142.0 / 255, blue: 147.0 / 255, alpha: 1)

    static func components(of hex: String) -> RGBA? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        return (
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            alpha: hasAlpha ? Double(value & 0xFF) / 255 : 1
        )
    }

    /// Rough perceived brightness (0...1), good enough to pick black or white text on top of a color.
    static func brightness(of hex: String) -> Double {
        let c = components(of: hex) ?? fallback
        return 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue
    }
}

extension WorkoutKind {
    /// Accent color for workouts of this kind.
    var tint: Color { Color(georgeHex: colorHex) }

    /// Readable foreground on top of `tint`.
    var onTint: Color { GeorgeHex.brightness(of: colorHex) > 0.6 ? .black : .white }

    /// Background for the live workout pages.
    var pageBackground: LinearGradient {
        LinearGradient(colors: [tint.opacity(0.45), Color.black], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Views

/// The workout kind's SF Symbol in a filled circle.
struct KindIcon: View {
    let kind: WorkoutKind
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(kind.onTint)
            .frame(width: size, height: size)
            .background(Circle().fill(kind.tint))
            .accessibilityHidden(true)
    }
}

/// The rest ring: a countdown with the time left in the middle (rest in the workout's tint,
/// a running hold in green).
struct CountdownRing: View {
    let remaining: TimeInterval
    let total: Double
    let tint: Color
    let caption: String
    var lineWidth: CGFloat = 8
    var fontSize: CGFloat = 28

    var body: some View {
        let fraction = min(1, max(0, remaining / max(total, remaining, 1)))
        let clock = Format.clock(Int(remaining.rounded(.up)))
        ZStack {
            Circle()
                .stroke(tint.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(fraction))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(clock)
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !caption.isEmpty {
                    Text(caption)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(lineWidth)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(caption.isEmpty ? "\(clock) left" : "\(caption.capitalized), \(clock) left"))
    }
}

/// Small rounded chip for quick answers (energy, fatigue, reps left).
struct ChipButtonStyle: ButtonStyle {
    var fill: Color = Color.white.opacity(0.18)
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.horizontal, 2)
            .foregroundStyle(foreground)
            .background(Capsule().fill(fill.opacity(configuration.isPressed ? 0.6 : 1)))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .contentShape(Capsule())
    }
}

/// Compact, full-width capsule button used on the workout pages.
struct CapsuleButtonStyle: ButtonStyle {
    var fill: Color
    var foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .padding(.horizontal, 6)
            .foregroundStyle(foreground)
            .background(Capsule().fill(fill.opacity(configuration.isPressed ? 0.7 : 1)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Capsule())
    }
}

// MARK: - Haptics

@MainActor
enum Haptics {
    /// A set was completed.
    static func success() { play(.success) }
    /// Small confirmation (undo, rest adjustments, discard).
    static func click() { play(.click) }
    /// Rest is over.
    static func notify() { play(.notification) }
    static func start() { play(.start) }
    static func stop() { play(.stop) }
    /// Something didn't happen (e.g. the iPhone never started the workout).
    static func failure() { play(.failure) }

    private static func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }
}

// MARK: - Text helpers

enum EffortScale {
    static let range = 1...10

    static func label(for value: Int) -> String {
        switch value {
        case ...3: return "Easy"
        case 4...6: return "Moderate"
        case 7...8: return "Hard"
        default: return "All out"
        }
    }
}

enum DayLabel {
    /// "Today", "Tomorrow", "Yesterday" or e.g. "Fri 31 Oct".
    static func text(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}
