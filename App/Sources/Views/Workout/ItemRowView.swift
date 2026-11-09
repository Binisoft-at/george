import SwiftUI
import BinisoftKit
import GeorgeCore

/// One exercise in the document: thumbnail, name, prescription and set chips.
struct ItemRowView: View {
    let item: WorkoutItem
    let mode: EditorMode
    let isGrouped: Bool
    /// "A1", "A2" … for exercises in a superset/circuit.
    var groupLabel: String? = nil
    let tint: Color
    let previous: [WorkoutSet]?
    let onToggleSet: (UUID) -> Void
    let onEditSet: (UUID) -> Void
    let onAddSet: () -> Void
    let onOpen: () -> Void

    @Environment(GeorgeStore.self) private var store
    @Environment(ExerciseLibrary.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    ExerciseThumb(urls: library.imageURLs(for: item), symbol: (item.kind ?? .gym).symbol, tint: tint, size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if let groupLabel {
                                Text(groupLabel)
                                    .font(.caption2.weight(.heavy))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .foregroundStyle(.white)
                                    .background(Color.accentColor, in: Capsule())
                            }
                            Text(item.name)
                                .font(.headline)
                                .foregroundStyle(item.isComplete && mode.isSession ? Color.secondary : Color.primary)
                                .strikethrough(item.isComplete && mode.isSession, color: .secondary)
                                .lineLimit(2)
                            if !item.links.isEmpty {
                                Image(systemName: "play.rectangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        Text(item.prescription(unit: store.unit))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if let previousText {
                            Label(previousText, systemImage: "clock.arrow.circlepath")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        if let notes = item.notes, !notes.isEmpty {
                            Text(notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .italic()
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            FlowLayout(spacing: 6) {
                ForEach(item.sets) { set in
                    SetChip(
                        index: item.displayIndex(of: set),
                        label: set.label(mode: item.mode, unit: store.unit, preferActual: mode.isSession),
                        isDone: set.isDone,
                        checkable: mode.isSession,
                        tint: tint
                    )
                    .onTapGesture {
                        if mode.isSession { onToggleSet(set.id) } else { onEditSet(set.id) }
                    }
                    .onLongPressGesture(minimumDuration: 0.35) {
                        Haptics.tap()
                        onEditSet(set.id)
                    }
                    .sensoryFeedback(.success, trigger: set.isDone) { _, new in new }
                }
                Button(action: onAddSet) {
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(.secondary)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add set")
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .leading) {
            if isGrouped {
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint)
                    .frame(width: 3)
                    .padding(.vertical, 2)
                    .offset(x: -12)
            }
        }
    }

    private var previousText: String? {
        guard let previous, !previous.isEmpty else { return nil }
        let done = previous.filter(\.isDone)
        guard !done.isEmpty else { return nil }
        let labels = done.prefix(4).map { $0.label(mode: item.mode, unit: store.unit) }
        return "Last: " + labels.joined(separator: ", ") + (done.count > 4 ? "…" : "")
    }
}

struct SetChip: View {
    let index: String
    let label: String
    let isDone: Bool
    let checkable: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(isDone ? tint : tint.opacity(0.15))
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                } else {
                    Text(index)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 18, height: 18)
            Text(label)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(isDone ? Color.primary : Color.primary.opacity(0.85))
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(isDone ? tint.opacity(0.18) : Color.secondary.opacity(0.08))
        )
        .overlay(
            Capsule().strokeBorder(isDone ? tint.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Capsule())
        .animation(.snappy, value: isDone)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Set \(index), \(label)\(isDone ? ", done" : "")")
        .accessibilityAddTraits(checkable ? .isButton : [])
    }
}

/// Exercise image with an SF Symbol fallback. Library exercises have start/end frames.
struct ExerciseThumb: View {
    let urls: [URL]
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 44

    @AppStorage(Prefs.showImages) private var showImages = true

    var body: some View {
        Group {
            if showImages, let url = urls.first {
                AsyncImage(url: url, transaction: Transaction(animation: .easeIn)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private var fallback: some View {
        ZStack {
            tint.opacity(0.14)
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}

/// Plays through the start/end frames of a library exercise like a GIF.
struct ExerciseAnimation: View {
    let urls: [URL]
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        if urls.isEmpty {
            ZStack {
                tint.opacity(0.12)
                Image(systemName: symbol)
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(tint)
            }
        } else {
            TimelineView(.periodic(from: .now, by: 1.1)) { context in
                let index = Int(context.date.timeIntervalSinceReferenceDate / 1.1) % urls.count
                ZStack {
                    ForEach(Array(urls.enumerated()), id: \.offset) { offset, url in
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFit()
                            } else {
                                Color.clear
                            }
                        }
                        .opacity(offset == index ? 1 : 0)
                    }
                }
                .animation(.easeInOut(duration: 0.35), value: index)
            }
            .background(Color.white)
        }
    }
}
