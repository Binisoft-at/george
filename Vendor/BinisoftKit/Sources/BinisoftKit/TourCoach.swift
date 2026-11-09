#if os(iOS) || os(macOS)
import SwiftUI
import BinisoftKitCore

// The coach card of the interactive tour (Theo). Put `.tourCoach(...)` on the practice page
// *inside* its NavigationStack: the card then sits below the navigation bar, so toolbar buttons
// a step points to stay reachable.

/// The floating card that explains the current step.
public struct TourCoachCard: View {
    let symbol: String
    let title: String
    let instructions: String
    let index: Int
    let count: Int
    let isMet: Bool
    let primaryTitle: String
    let primaryIsProminent: Bool
    let onBack: (() -> Void)?
    let onNext: () -> Void
    let onClose: () -> Void

    @State private var isFolded = false

    public init(symbol: String, title: String, instructions: String, index: Int, count: Int, isMet: Bool,
                primaryTitle: String, primaryIsProminent: Bool, onBack: (() -> Void)?,
                onNext: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.instructions = instructions
        self.index = index
        self.count = count
        self.isMet = isMet
        self.primaryTitle = primaryTitle
        self.primaryIsProminent = primaryIsProminent
        self.onBack = onBack
        self.onNext = onNext
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: isMet ? "checkmark.circle.fill" : symbol)
                    .font(.title2)
                    .foregroundStyle(isMet ? Color.green : Brand.accent)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isMet ? "Nice, that's it!" : title)
                        .font(.headline)
                    Text("Step \(index + 1) of \(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button {
                    withAnimation(.snappy) { isFolded.toggle() }
                } label: {
                    Image(systemName: isFolded ? "chevron.down" : "chevron.up")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isFolded ? "Show Instructions" : "Hide Instructions")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close Tour")
            }
            if !isFolded {
                Text(instructions)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                HStack(spacing: 12) {
                    ProgressView(value: Double(index + 1), total: Double(max(count, 1)))
                    if let onBack {
                        Button("Back", action: onBack)
                            .buttonStyle(.borderless)
                    }
                    if primaryIsProminent {
                        Button(action: onNext) {
                            Text(primaryTitle).frame(minWidth: 64)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Brand.accent)
                    } else {
                        // Skipping is fine, but doing the step is the main path.
                        Button(action: onNext) {
                            Text(primaryTitle).frame(minWidth: 52)
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .floatingGlass(cornerRadius: 22)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .sensoryFeedback(.success, trigger: isMet) { _, new in new }
        .animation(.snappy, value: index)
    }
}

private struct TourCoachModifier<Snapshot: Equatable>: ViewModifier {
    let steps: [TourStep<Snapshot>]
    let snapshot: Snapshot
    let startAt: String?
    let onClose: () -> Void

    @State private var progress: TourProgress<Snapshot>?
    @State private var latest: Snapshot?

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let progress, let step = progress.step {
                    TourCoachCard(
                        symbol: step.symbol,
                        title: step.title,
                        instructions: step.instructions,
                        index: progress.index,
                        count: progress.steps.count,
                        isMet: progress.isMet,
                        primaryTitle: progress.primaryTitle,
                        primaryIsProminent: progress.primaryIsProminent,
                        onBack: progress.isFirst ? nil : { goBack() },
                        onNext: { advance() },
                        onClose: onClose
                    )
                }
            }
            .onAppear {
                if progress == nil {
                    progress = TourProgress(steps: steps, start: snapshot, startAt: startAt)
                }
                latest = snapshot
            }
            .onChange(of: snapshot) { _, newValue in
                observe(newValue)
            }
    }

    private func observe(_ newValue: Snapshot) {
        latest = newValue
        guard var current = progress else { return }
        let ticked = current.observe(newValue)
        guard ticked else { return }
        withAnimation(.snappy) { progress = current }
        let index = current.index
        // Give the "Nice, that's it!" a moment, then move on by itself.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            if progress?.index == index, progress?.isMet == true { advance() }
        }
    }

    private func advance() {
        guard var current = progress else { return }
        if current.next(at: latest ?? snapshot) {
            withAnimation(.snappy) { progress = current }
        } else {
            onClose()
        }
    }

    private func goBack() {
        guard var current = progress else { return }
        current.back(at: latest ?? snapshot)
        withAnimation(.snappy) { progress = current }
    }
}

public extension View {
    /// Runs the tour on this practice page. `snapshot` is rebuilt from the demo store on every
    /// change; each step ticks itself off once its goal is met, then moves on.
    /// - Parameter startAt: step id to open first (`-TourStep <id>` for screenshots).
    func tourCoach<Snapshot: Equatable>(steps: [TourStep<Snapshot>], snapshot: Snapshot,
                                        startAt: String? = nil, onClose: @escaping () -> Void) -> some View {
        modifier(TourCoachModifier(steps: steps, snapshot: snapshot, startAt: startAt, onClose: onClose))
    }
}
#endif
