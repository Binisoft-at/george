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
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.motivation) private var motivationRaw = MotivationStyle.full.rawValue
    @State private var stage = 0
    @State private var ring = 0.0
    @State private var counted = 0.0
    @State private var confetti = 0
    @State private var templateUpdated = false
    @State private var recap: WorkoutRecap?

    private var motivation: MotivationStyle { MotivationStyle(rawValue: motivationRaw) ?? .full }

    var body: some View {
        ZStack {
            CelebrationBackground(animated: motivation != .off)
            ScrollView {
                VStack(spacing: 26) {
                    if let recap {
                        hero(recap)
                        if stage >= 2 { stats(recap).transition(.move(edge: .bottom).combined(with: .opacity)) }
                        if stage >= 3, !recap.records.isEmpty { records(recap).transition(.scale(scale: 0.9).combined(with: .opacity)) }
                        if stage >= 3, !recap.muscleSets.isEmpty { musclesCard(recap).transition(.opacity) }
                        if stage >= 4 {
                            quote(recap).transition(.opacity)
                            actions(recap).transition(.move(edge: .bottom).combined(with: .opacity))
                            details.transition(.opacity)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 36)
                .padding(.bottom, 40)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            if motivation == .full {
                ConfettiView(trigger: confetti, pieces: 70)
                    .ignoresSafeArea()
            }
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
                Text(recap.headline)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
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

    private func stats(_ recap: WorkoutRecap) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            statTile("Time", "clock") { Format.minutes(recap.duration * $0) }
            statTile("Sets", "checklist") { "\(Int((Double(recap.completedSets) * $0).rounded())) / \(recap.totalSets)" }
            if recap.volumeKg > 0 {
                statTile("Lifted", "scalemass.fill") { Format.volume(recap.volumeKg * $0, unit: recap.unit) }
            }
            if recap.energyKcal > 0 {
                statTile("Energy", "flame.fill") { "\(Int(recap.energyKcal * $0)) kcal" }
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
                .font(.system(size: 26, weight: .bold, design: .rounded))
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
        VStack(spacing: 12) {
            ShareRecapButton(recap: recap)
                .tint(BrandPalette.blue)
            HStack(spacing: 12) {
                Button {
                    router.open(.session(summary.sessionID))
                    dismiss()
                } label: {
                    Text("View Workout")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glass)
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glass)
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        VStack(spacing: 12) {
            if summary.canUpdateTemplate && !templateUpdated {
                VStack(alignment: .leading, spacing: 8) {
                    Label("You changed this workout", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.bold))
                    Text("Save the exercises, sets and loads you used back into “\(summary.templateName)” so next time starts from here?")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Button {
                        if let session = store.session(id: summary.sessionID) {
                            store.updateTemplate(from: session)
                            templateUpdated = true
                            Haptics.success()
                        }
                    } label: {
                        Label("Update Template", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                .padding(16)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else if templateUpdated {
                Label("Template updated", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(BrandPalette.sky)
            }
            if summary.savedToHealth {
                Label("Saved to Apple Health", systemImage: "heart.text.square.fill")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    // MARK: Sequence

    private func play() async {
        if let session = store.session(id: summary.sessionID) {
            recap = WorkoutRecap.make(session: session, store: store, muscles: muscles, health: health,
                                      records: summary.records, energyKcal: summary.energyKcal, averageHeartRate: summary.averageHeartRate)
        }
        let target = recap?.completion ?? 1
        guard motivation != .off else {
            ring = target
            counted = 1
            stage = 4
            return
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        withAnimation(.easeInOut(duration: 1.1)) { ring = target }
        try? await Task.sleep(nanoseconds: 800_000_000)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { stage = 1 }
        Haptics.success()
        if motivation == .full { confetti += 1 }
        try? await Task.sleep(nanoseconds: 600_000_000)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { stage = 2 }
        withAnimation(.easeOut(duration: 1.4)) { counted = 1 }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { stage = 3 }
        if !(recap?.records.isEmpty ?? true) { Haptics.heavy() }
        try? await Task.sleep(nanoseconds: 700_000_000)
        withAnimation(.easeOut(duration: 0.6)) { stage = 4 }
    }
}
