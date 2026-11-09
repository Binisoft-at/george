import SwiftUI
import BinisoftKit
import GeorgeCore

/// A path from the body-map SVG data, scaled into the available rect (aspect-fit, centred).
struct BodyPathShape: Shape {
    let elements: [SVGPath.Element]

    init(path: String, mirrored: Bool = false) {
        let parsed = SVGPath.parse(path)
        elements = mirrored ? SVGPath.mirrored(parsed) : parsed
    }

    func path(in rect: CGRect) -> Path {
        let vw = BodyMap.viewBox.width
        let vh = BodyMap.viewBox.height
        let scale = min(rect.width / vw, rect.height / vh)
        let dx = rect.minX + (rect.width - vw * scale) / 2
        let dy = rect.minY + (rect.height - vh * scale) / 2
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: dx + x * scale, y: dy + y * scale) }
        var path = Path()
        for element in elements {
            switch element {
            case .move(let x, let y): path.move(to: p(x, y))
            case .line(let x, let y): path.addLine(to: p(x, y))
            case .cubic(let x, let y, let c1x, let c1y, let c2x, let c2y): path.addCurve(to: p(x, y), control1: p(c1x, c1y), control2: p(c2x, c2y))
            case .quad(let x, let y, let cx, let cy): path.addQuadCurve(to: p(x, y), control: p(cx, cy))
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

/// One side (front or back) of the body with muscles coloured by `fill`.
struct BodyFigure: View {
    let side: BodyMap.Side
    let fill: (MuscleGroup) -> Color
    var selected: MuscleGroup? = nil
    var onTap: ((MuscleGroup) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var baseColor: Color {
        colorScheme == .dark ? Color(white: 0.2) : Color(white: 0.82)
    }

    private var outlineColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.55) : Color.white.opacity(0.9)
    }

    var body: some View {
        ZStack {
            ForEach(Array(BodyMap.silhouette.enumerated()), id: \.offset) { _, shape in
                BodyPathShape(path: shape.path).fill(baseColor)
                if shape.mirrored {
                    BodyPathShape(path: shape.path, mirrored: true).fill(baseColor)
                }
            }
            ForEach(Array(BodyMap.regions(side).enumerated()), id: \.offset) { _, region in
                regionView(region, mirrored: false)
                if region.mirrored {
                    regionView(region, mirrored: true)
                }
            }
            ForEach(Array(BodyMap.details(side).enumerated()), id: \.offset) { _, detail in
                BodyPathShape(path: detail)
                    .stroke(outlineColor, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(BodyMap.viewBox.width / BodyMap.viewBox.height, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(side == .front ? "Body front" : "Body back")
    }

    @ViewBuilder
    private func regionView(_ region: BodyRegion, mirrored: Bool) -> some View {
        let shape = BodyPathShape(path: region.path, mirrored: mirrored)
        let isSelected = selected == region.group
        let filled = shape
            .fill(fill(region.group))
            .overlay {
                shape.stroke(isSelected ? Color.primary : outlineColor, lineWidth: isSelected ? 2 : 0.8)
            }
            .animation(.easeInOut(duration: 0.25), value: isSelected)
        if let onTap {
            filled
                .contentShape(shape)
                .onTapGesture { onTap(region.group) }
        } else {
            // No gesture, so taps reach an enclosing link or button.
            filled.allowsHitTesting(false)
        }
    }
}

/// Front and back next to each other.
struct BodyMapPair: View {
    let fill: (MuscleGroup) -> Color
    var selected: MuscleGroup? = nil
    var onTap: ((MuscleGroup) -> Void)? = nil
    var spacing: CGFloat = 12

    var body: some View {
        HStack(spacing: spacing) {
            BodyFigure(side: .front, fill: fill, selected: selected, onTap: onTap)
            BodyFigure(side: .back, fill: fill, selected: selected, onTap: onTap)
        }
    }
}

/// Compact map of the muscles a workout trains (sets per muscle) with the top muscles listed.
struct WorkoutMuscleMap: View {
    let sets: [MuscleGroup: Double]
    var title = "Muscles"

    var body: some View {
        let maxSets = max(1, sets.values.max() ?? 1)
        let top: [MuscleGroup] = sets.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(6).map { $0.key }
        HStack(alignment: .center, spacing: 16) {
            BodyMapPair(fill: { MusclePalette.heat((sets[$0] ?? 0) / maxSets) }, spacing: 4)
                .frame(height: 150)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                if top.isEmpty {
                    Text("No muscle data").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(top) { group in
                    let value = sets[group] ?? 0
                    HStack(spacing: 6) {
                        Circle().fill(MusclePalette.heat(value / maxSets)).frame(width: 8, height: 8)
                        Text(group.displayName).font(.caption)
                        Spacer(minLength: 4)
                        Text(Format.number((value * 10).rounded() / 10) + " sets")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

/// Five-segment level indicator used in muscle lists.
struct LevelBars: View {
    /// 0…1
    let level: Double
    let color: Color

    var body: some View {
        let filled = level <= 0 ? 0 : max(1, Int((level * 5).rounded(.up)))
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(index < filled ? color.opacity(index == filled - 1 ? 1 : 0.45) : Color.secondary.opacity(0.18))
                    .frame(width: 8, height: 26)
            }
        }
        .accessibilityHidden(true)
    }
}
