import SwiftUI
import BinisoftKit
import GeorgeCore

/// George's colours for the finish screen, the share picture and the routine PDF – one family of
/// blues with a cool highlight and gold for records, so everything looks like it belongs together.
enum BrandPalette {
    static let midnight = Color(hex: "#060A1C")
    static let navy = Color(hex: "#0B1B3F")
    static let royal = Color(hex: "#1B3FA0")
    static let blue = Color(hex: "#2E7BFF")
    static let sky = Color(hex: "#6CC4FF")
    static let ice = Color(hex: "#DCEBFF")
    static let violet = Color(hex: "#6A5CFF")
    static let gold = Color(hex: "#FFD15C")
    static let ink = Color(hex: "#0E1630")

    /// Muscles on a dark background: dim navy → George blue → bright sky.
    static func muscleOnDark(_ t: Double) -> Color {
        guard t > 0 else { return Color.white.opacity(0.10) }
        return mix(Color.RGB(r: 46, g: 123, b: 255), Color.RGB(r: 170, g: 224, b: 255), min(1, max(0, t)), floor: 0.55)
    }

    /// Muscles on a light background: pale blue → George blue → deep royal.
    static func muscleOnLight(_ t: Double) -> Color {
        guard t > 0 else { return Color(hex: "#E3EAF6") }
        return mix(Color.RGB(r: 141, g: 183, b: 255), Color.RGB(r: 27, g: 63, b: 160), min(1, max(0, t)), floor: 1)
    }

    private static func mix(_ a: Color.RGB, _ b: Color.RGB, _ t: Double, floor: Double) -> Color {
        Color(red: (a.r + (b.r - a.r) * t) / 255, green: (a.g + (b.g - a.g) * t) / 255, blue: (a.b + (b.b - a.b) * t) / 255)
            .opacity(floor + (1 - floor) * min(1, t * 1.6))
    }
}

extension Color {
    struct RGB {
        let r: Double
        let g: Double
        let b: Double
    }
}

/// Slowly moving brand mesh behind the finish screen (static when motivation is off).
struct CelebrationBackground: View {
    var animated = true

    var body: some View {
        if animated {
            TimelineView(.animation) { context in
                mesh(t: context.date.timeIntervalSinceReferenceDate)
            }
            .ignoresSafeArea()
        } else {
            mesh(t: 0).ignoresSafeArea()
        }
    }

    private func mesh(t: Double) -> some View {
        let w = Float(sin(t * 0.35) * 0.18)
        let v = Float(cos(t * 0.27) * 0.16)
        return MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.5 + w, 0.45 + v], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1],
        ], colors: [
            BrandPalette.midnight, BrandPalette.navy, BrandPalette.royal,
            BrandPalette.navy, BrandPalette.blue, BrandPalette.violet,
            BrandPalette.midnight, BrandPalette.royal, BrandPalette.navy,
        ])
    }
}

/// A number that counts up from zero when `value` animates.
struct CountingText: View, Animatable {
    var value: Double
    let format: (Double) -> String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(format(value))
    }
}

/// The finish: full screen, the ring filling up, a burst of confetti, numbers counting up, records
/// in gold, the muscles lighting up, a line that fits the workout – then share, details, done.
struct FinishCelebrationView: View {
    let summary: LiveWorkoutController.FinishSummary
    @Environment(GeorgeStore.self) private var store
    @Environment(MuscleAnalytics.self) private var muscles
    @Environment(HealthKitManager.self) private var health
    @Environment(Router.self) private var router
    @Environment(LiveWorkoutController.self) private var live
    @Environment(ExerciseLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Prefs.motivation) private var motivationRaw = MotivationStyle.full.rawValue
    @State private var stage = 0
    @State private var ring = 0.0
    @State private var counted = 0.0
    @State private var confetti = 0
    @State private var templateUpdated = false
    @State private var templateSaved = false
    /// What "Update Template" would change: heavier loads only, and everything (sets, exercises).
    @State private var loadLines: [String] = []
    @State private var allLines: [String] = []
    @State private var confirmAllChanges = false
    @State private var templateUndo: (() -> Void)?
    @State private var recap: WorkoutRecap?
    @State private var skipped = false

    private var motivation: MotivationStyle { MotivationStyle(rawValue: motivationRaw) ?? .full }
    /// No moving background, confetti or staged reveal with Reduce Motion (or celebrations off).
    private var animates: Bool { motivation != .off && !reduceMotion }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            CelebrationBackground(animated: animates)
            ScrollView {
                VStack(spacing: 26) {
                    if let recap {
                        hero(recap)
                        if stage >= 2 { stats(recap).transition(.move(edge: .bottom).combined(with: .opacity)) }
                        if stage >= 2, let comparison = summary.comparison { comparisonCard(comparison).transition(.opacity) }
                        if stage >= 2 { templateCard.transition(.opacity) }
                        if stage >= 3, !recap.records.isEmpty { records(recap).transition(.scale(scale: 0.9).combined(with: .opacity)) }
                        if stage >= 3, !recap.muscleSets.isEmpty { musclesCard(recap).transition(.opacity) }
                        if stage >= 4 {
                            if let routine = summary.coolDown { coolDownCard(routine).transition(.opacity) }
                            quote(recap).transition(.opacity)
                            actions(recap).transition(.move(edge: .bottom).combined(with: .opacity))
                            details.transition(.opacity)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 48)
                .padding(.bottom, 24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                // A tap anywhere shows everything at once.
                .onTapGesture { if stage < 4 { showAll() } }
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom) {
                if let recap, stage >= 1 {
                    HStack(spacing: 12) {
                        ShareRecapButton(recap: recap)
                            .tint(BrandPalette.blue)
                        Button {
                            dismiss()
                        } label: {
                            Text("Done")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.white.opacity(0.25))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    // A calm band behind the buttons, so the cards scrolling underneath don't show through.
                    .background(.ultraThinMaterial)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            if motivation == .full && !reduceMotion {
                ConfettiView(trigger: confetti, pieces: 70)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding(.trailing, 16)
            .padding(.top, 8)
            .accessibilityLabel("Close")
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .task { await play() }
    }

    // MARK: Parts

    private func hero(_ recap: WorkoutRecap) -> some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 16)
                Circle()
                    .trim(from: 0, to: max(0.001, ring))
                    .stroke(AngularGradient(colors: [BrandPalette.sky, BrandPalette.blue, BrandPalette.violet, BrandPalette.sky], center: .center),
                            style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: BrandPalette.sky.opacity(0.6), radius: 12)
                Circle()
                    .fill(RadialGradient(colors: [BrandPalette.blue.opacity(0.55), .clear], center: .center, startRadius: 4, endRadius: 90))
                    .scaleEffect(stage >= 1 ? 1 : 0.4)
                    .opacity(stage >= 1 ? 1 : 0)
                Image(systemName: recap.records.isEmpty ? "checkmark" : "trophy.fill")
                    .font(.system(size: 64, weight: .heavy))
                    .foregroundStyle(recap.records.isEmpty ? AnyShapeStyle(Color.white) : AnyShapeStyle(BrandPalette.gold.gradient))
                    .scaleEffect(stage >= 1 ? 1 : 0.2)
                    .opacity(stage >= 1 ? 1 : 0)
                    .symbolEffect(.bounce, value: stage >= 1)
            }
            .frame(width: 190, height: 190)

            VStack(spacing: 6) {
                Text(headline(recap))
                    .font(.system(.largeTitle, design: .rounded).weight(.heavy))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                Text(recap.title)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                if recap.streakWeeks > 0 {
                    Label("\(recap.streakWeeks)-week streak", systemImage: "flame.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(BrandPalette.gold)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(BrandPalette.gold.opacity(0.14), in: Capsule())
                        .padding(.top, 4)
                }
            }
            .opacity(stage >= 1 ? 1 : 0)
            .offset(y: stage >= 1 ? 0 : 16)
        }
    }

    /// "Beat last time on 3 of 4" before "Every set done!" – progress against yourself.
    private func headline(_ recap: WorkoutRecap) -> String {
        if let comparison = summary.comparison, comparison.up > 0, recap.records.isEmpty {
            return "Beat last time on \(comparison.up) of \(comparison.exercises.count)"
        }
        return recap.headline
    }

    private func comparisonCard(_ comparison: SessionComparison) -> some View {
        let rising = comparison.exercises.filter { $0.direction == .up }
        let lines = Array((rising.isEmpty ? comparison.exercises : rising).prefix(3))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("vs. last time · \(comparison.previousDate.formatted(.dateTime.day().month(.abbreviated)))", systemImage: "arrow.up.right")
                    .font(.headline)
                    .foregroundStyle(BrandPalette.sky)
                Spacer()
                Text(rising.isEmpty ? "Matched last time" : "\(comparison.up) up · \(comparison.same) same")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            ForEach(lines) { line in
                HStack {
                    Text(line.exerciseName).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(line.change(unit: store.unit))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(line.direction == .up ? BrandPalette.sky : .white.opacity(0.75))
                }
                .font(.subheadline)
            }
            if abs(comparison.volumeDelta) >= 1 {
                Text("\(comparison.volumeDelta > 0 ? "+" : "−")\(Format.volume(abs(comparison.volumeDelta), unit: store.unit)) lifted vs. last time")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(16)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// "You went heavier" saves only the heavier loads; "You changed this workout" saves sets and
    /// exercises too. Drop sets and warm-ups added during the workout never go into the template.
    private var offersLoads: Bool { !loadLines.isEmpty }

    /// Update the template (changes or heavier loads), or keep a template-less workout as one.
    @ViewBuilder
    private var templateCard: some View {
        if summary.canUpdateTemplate && !templateUpdated && (offersLoads || !allLines.isEmpty) {
            let lines = offersLoads ? loadLines : allLines
            VStack(alignment: .leading, spacing: 8) {
                Label(offersLoads ? "You went heavier" : "You changed this workout", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.bold))
                ForEach(lines.prefix(4), id: \.self) { line in
                    Text(line).font(.caption.weight(.semibold)).foregroundStyle(BrandPalette.sky)
                }
                if lines.count > 4 {
                    Text("and \(lines.count - 4) more").font(.caption).foregroundStyle(.white.opacity(0.75))
                }
                Text(offersLoads
                     ? "Save these loads into “\(summary.templateName)”? Sets and reps stay as planned."
                     : "Save these changes into “\(summary.templateName)” so next time starts from here?")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                Button {
                    updateTemplate(offersLoads ? .loads : .everything)
                } label: {
                    Label(offersLoads ? "Update Loads" : "Update Template", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glass)
                if offersLoads && !allLines.isEmpty {
                    Button("Save All Changes…") { confirmAllChanges = true }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .buttonStyle(.plain)
                }
            }
            .padding(16)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .confirmationDialog("Save all changes?", isPresented: $confirmAllChanges, titleVisibility: .visible) {
                Button("Save All Changes") { updateTemplate(.everything) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(allLines.prefix(6).joined(separator: "\n"))
            }
        } else if templateUpdated {
            HStack {
                Label("Template updated", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(BrandPalette.sky)
                Spacer()
                if let undo = templateUndo {
                    Button("Undo") {
                        undo()
                        templateUndo = nil
                        templateUpdated = false
                        Haptics.tap()
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.glass)
                }
            }
        } else if summary.canSaveAsTemplate && !templateSaved {
            VStack(alignment: .leading, spacing: 8) {
                Label("Keep this as a template?", systemImage: "square.on.square")
                    .font(.subheadline.weight(.bold))
                Text("Start it again with one tap next time.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                Button {
                    if let session = store.session(id: summary.sessionID) {
                        let template = store.saveAsTemplate(session, into: session.program)
                        template.name = suggestedTemplateName
                        session.templateID = template.id
                        session.templateName = template.name
                        store.save()
                        templateSaved = true
                        Haptics.success()
                    }
                } label: {
                    Label("Save as “\(suggestedTemplateName)”", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glass)
            }
            .padding(16)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else if templateUpdated || templateSaved {
            Label(templateSaved ? "Saved as a template" : "Template updated", systemImage: "checkmark.circle.fill")
                .foregroundStyle(BrandPalette.sky)
        }
    }

    /// "Upper body", "Legs" … from the muscles trained most, otherwise the kind of workout.
    private var suggestedTemplateName: String {
        if let top = recap?.muscleSets.max(by: { $0.value < $1.value })?.key {
            switch top.region {
            case .upper: return "Upper Body"
            case .lower: return "Lower Body"
            case .core: return "Core"
            }
        }
        return summary.kind.displayName
    }

    private func coolDownCard(_ routine: Routine) -> some View {
        Button {
            let template = store.templateForRoutine(routine, catalog: library.catalog).template
            dismiss()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                live.requestStart(.template(template))
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: routine.symbol)
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cool down · \(routine.name)")
                        .font(.subheadline.weight(.bold))
                    Text("\(routine.subtitle) · about \(Format.minutes(Double(routine.content(using: library.catalog).estimatedSeconds())))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill")
            }
            .padding(14)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func stats(_ recap: WorkoutRecap) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            statTile("Time", "clock") { Format.minutes(recap.duration * $0) }
            statTile("Sets", "checklist") { "\(Int((Double(recap.completedSets) * $0).rounded())) / \(recap.totalSets)" }
            if recap.volumeKg > 0 {
                statTile("Lifted", "scalemass.fill") { Format.volume(recap.volumeKg * $0, unit: recap.unit) }
            }
            if let energy = recap.energy {
                // "≈" marks George's estimate; Watch-measured energy shows as is.
                statTile(energy.isMeasured ? "Energy" : "Energy (est.)", "flame.fill") { energy.text(scaled: $0) }
            }
            if let hr = recap.averageHeartRate {
                statTile("Avg heart rate", "heart.fill") { "\(Int(hr * $0)) bpm" }
            }
            if recap.effort > 0 {
                statTile("Effort", "gauge.with.dots.needle.67percent") { _ in "\(recap.effort) / 10" }
            }
        }
    }

    private func statTile(_ title: String, _ symbol: String, format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(BrandPalette.sky)
            CountingText(value: counted, format: format)
                .font(.system(.title, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    private func records(_ recap: WorkoutRecap) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(recap.records.count == 1 ? "New personal record" : "\(recap.records.count) new personal records", systemImage: "trophy.fill")
                .font(.headline)
                .foregroundStyle(BrandPalette.gold)
            ForEach(recap.records) { record in
                HStack {
                    Text(record.exerciseName).lineLimit(1)
                    Spacer()
                    Text(recap.recordText(record))
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(BrandPalette.gold)
                }
                .font(.subheadline)
            }
        }
        .padding(16)
        .background(BrandPalette.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(BrandPalette.gold.opacity(0.35)))
    }

    private func musclesCard(_ recap: WorkoutRecap) -> some View {
        let maxSets = max(1, recap.muscleSets.values.max() ?? 1)
        let top: [MuscleGroup] = recap.muscleSets.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(5).map { $0.key }
        return HStack(spacing: 16) {
            BodyMapPair(fill: { BrandPalette.muscleOnDark((recap.muscleSets[$0] ?? 0) / maxSets) }, spacing: 4)
                .frame(height: 150)
            VStack(alignment: .leading, spacing: 6) {
                Text("Muscles worked")
                    .font(.subheadline.weight(.bold))
                ForEach(top) { group in
                    let sets = recap.muscleSets[group] ?? 0
                    HStack(spacing: 6) {
                        Circle().fill(BrandPalette.muscleOnDark(sets / maxSets)).frame(width: 8, height: 8)
                        Text(group.displayName).font(.caption)
                        Spacer(minLength: 4)
                        Text("\(Format.number((sets * 10).rounded() / 10)) sets").font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func quote(_ recap: WorkoutRecap) -> some View {
        let context = FinishQuote.Context(
            hasRecord: !recap.records.isEmpty, energyBefore: recap.energyBefore, streakWeeks: recap.streakWeeks,
            completion: recap.completion, minutes: Int(recap.duration / 60)
        )
        return VStack(spacing: 8) {
            Image(systemName: "quote.opening")
                .font(.title2)
                .foregroundStyle(BrandPalette.sky)
            Text(FinishQuote.pick(context, seed: summary.sessionID.hashValue))
                .font(.system(.title3, design: .serif).italic())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("— George")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }

    private func actions(_ recap: WorkoutRecap) -> some View {
        Button {
            router.open(.session(summary.sessionID))
            dismiss()
        } label: {
            Text("View Workout")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glass)
    }

    @ViewBuilder
    private var details: some View {
        VStack(spacing: 12) {
            if summary.savedToHealth {
                Label(summary.healthNote ?? "Saved to Apple Health", systemImage: "heart.text.square.fill")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    // MARK: Sequence

    /// Saves the workout into its template and keeps an Undo on the card.
    private func updateTemplate(_ mode: TemplateUpdateMode) {
        guard let session = store.session(id: summary.sessionID) else { return }
        templateUndo = store.updateTemplate(from: session, mode: mode)
        guard templateUndo != nil else { return }
        templateUpdated = true
        Haptics.success()
    }

    private func play() async {
        if let session = store.session(id: summary.sessionID) {
            recap = WorkoutRecap.make(session: session, store: store, muscles: muscles, health: health,
                                      records: summary.records, energyKcal: summary.energyKcal, averageHeartRate: summary.averageHeartRate)
            if summary.canUpdateTemplate {
                // The exact lines the update would write (heavier loads; all changes when the sets or
                // exercises changed) – the card shows them before anything is saved.
                loadLines = summary.loadChanges.isEmpty ? [] : store.templateChanges(from: session, mode: .loads)
                allLines = store.sessionDiffersFromTemplate(session) ? store.templateChanges(from: session, mode: .everything) : []
            }
        }
        let target = recap?.completion ?? 1
        guard animates else {
            showAll()
            return
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !skipped else { return }
        withAnimation(.easeInOut(duration: 1.1)) { ring = target }
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard !skipped else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { stage = 1 }
        Haptics.success()
        if motivation == .full { confetti += 1 }
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard !skipped else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { stage = 2 }
        withAnimation(.easeOut(duration: 1.4)) { counted = 1 }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !skipped else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { stage = 3 }
        if !(recap?.records.isEmpty ?? true) { Haptics.heavy() }
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard !skipped else { return }
        withAnimation(.easeOut(duration: 0.6)) { stage = 4 }
    }

    /// Everything at once (tap, Reduce Motion, celebrations off).
    private func showAll() {
        skipped = true
        let target = recap?.completion ?? 1
        withAnimation(reduceMotion ? nil : .snappy) {
            ring = target
            counted = 1
            stage = 4
        }
    }
}
