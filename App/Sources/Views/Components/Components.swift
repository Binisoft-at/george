import SwiftUI
import BinisoftKit
import GeorgeCore

// MARK: - Color

extension Color {
    /// "#RRGGBB" or "RRGGBB"; falls back to gray.
    init(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        var value: UInt64 = 0
        guard text.count == 6, Scanner(string: text).scanHexInt64(&value) else {
            self = .gray
            return
        }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    static let georgeBlue = Color(hex: "#2E7BFF")
}

extension WorkoutKind {
    var color: Color { Color(hex: colorHex) }
}

extension Priority {
    var color: Color {
        switch self {
        case .none: return .secondary
        case .low: return .blue
        case .medium: return .orange
        case .high: return .red
        }
    }
}

let colorChoices: [String] = [
    "#FF453A", "#FF9F0A", "#FFD60A", "#30D158", "#63E6E2", "#30B0C7",
    "#0A84FF", "#5E5CE6", "#BF5AF2", "#FF375F", "#AC8E68", "#8E8E93",
]

let programSymbols: [String] = [
    "folder.fill", "dumbbell.fill", "figure.strengthtraining.functional", "figure.strengthtraining.traditional",
    "figure.tennis", "figure.yoga", "figure.flexibility", "figure.run", "figure.core.training",
    "figure.highintensity.intervaltraining", "figure.cooldown", "figure.mind.and.body", "flame.fill",
    "bolt.heart.fill", "heart.fill", "star.fill", "house.fill", "building.2.fill", "suitcase.fill", "mountain.2.fill",
]

// MARK: - Badges

struct KindBadge: View {
    let kind: WorkoutKind
    var compact = false

    var body: some View {
        Label(compact ? kind.shortName : kind.displayName, systemImage: kind.symbol)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(kind.color)
            .background(kind.color.opacity(0.14), in: Capsule())
    }
}

struct KindIcon: View {
    let kind: WorkoutKind
    var colorHex: String? = nil
    var size: CGFloat = 30

    var body: some View {
        let tint = Color(hex: colorHex ?? kind.colorHex)
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

struct Chip: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(tint)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Small circular progress indicator used in rows.
struct ProgressRing: View {
    let progress: Double
    var tint: Color = .accentColor
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Cross-platform helpers

extension View {
    @ViewBuilder
    func inlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder
    func largeTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.large)
        #else
        self
        #endif
    }

    @ViewBuilder
    func groupedList() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self.listStyle(.inset)
        #endif
    }

    @ViewBuilder
    func numberKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad)
        #else
        self
        #endif
    }

    @ViewBuilder
    func urlKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self
        #endif
    }

    @ViewBuilder
    func capitalizeCharacters() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.characters)
        #else
        self
        #endif
    }
}

extension ToolbarItemPlacement {
    static var georgeTrailing: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarTrailing
        #else
        return .primaryAction
        #endif
    }

    static var georgeLeading: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarLeading
        #else
        return .navigation
        #endif
    }
}

// MARK: - Empty states

/// An informational empty state (not found, nothing selected). List screens use BinisoftKit
/// `EmptyStateView`, which also offers "Import my data".
struct MessageView: View {
    let title: String
    let systemImage: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glassProminent)
            }
        }
    }
}

// MARK: - Date labels

enum DateLabel {
    /// Notes-style: "08:54" today, weekday within a week, otherwise "27.10.26".
    static func short(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if abs(days) < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits))
    }

    static func weekdayNames(_ days: [Int]) -> String {
        let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return days.filter { (1...7).contains($0) }.map { names[$0] }.joined(separator: " · ")
    }
}

// MARK: - Flow layout for chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
