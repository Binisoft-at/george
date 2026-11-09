import SwiftUI
import BinisoftKit
import GeorgeCore

/// Everything the finish screen, the workout overview and the share card show about one workout.
struct WorkoutRecap: Identifiable, Equatable {
    struct Highlight: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let detail: String
    }

    let id: UUID
    let title: String
    let date: Date
    let kind: WorkoutKind
    let duration: Double
    let completedSets: Int
    let totalSets: Int
    let volumeKg: Double
    let energyKcal: Double
    let averageHeartRate: Double?
    let effort: Int
    let energyBefore: Int
    let records: [PersonalRecord]
    let muscleSets: [MuscleGroup: Double]
    let highlights: [Highlight]
    let streakWeeks: Int
    let weekDays: Int
    let weekGoal: Int
    let unit: WeightUnit

    var completion: Double { Double(completedSets) / Double(max(1, totalSets)) }

    /// The best line for the top: a record beats a full workout beats "stopped early".
    var headline: String {
        if !records.isEmpty { return records.count == 1 ? "New personal record!" : "\(records.count) new personal records!" }
        if completedSets >= totalSets && totalSets > 0 { return "Every set done!" }
        if (1...2).contains(energyBefore) { return "Showed up on a low day" }
        return "Workout done"
    }

    var subline: String {
        if (1...2).contains(energyBefore) {
            return "You started at “\(EnergyEntry.label(for: energyBefore))” and still did \(completedSets) sets. That's how streaks are built."
        }
        if streakWeeks >= 2 { return "\(streakWeeks)-week streak and counting." }
        return "\(completedSets) sets in \(Format.minutes(duration))."
    }

    func recordText(_ record: PersonalRecord) -> String {
        switch record.metric {
        case .weight: return Format.weight(record.value, unit: unit)
        case .oneRepMax: return "e1RM " + Format.weight(record.value, unit: unit)
        case .reps: return "\(Int(record.value)) reps"
        case .duration: return Format.shortDuration(Int(record.value))
        case .volume: return Format.volume(record.value, unit: unit)
        }
    }

    @MainActor
    static func make(session: WorkoutSession, store: GeorgeStore, muscles: MuscleAnalytics, health: HealthKitManager,
                     records: [PersonalRecord]? = nil, energyKcal: Double? = nil, averageHeartRate: Double? = nil) -> WorkoutRecap {
        let content = session.content
        let record = session.record()
        let found = records ?? StatsEngine.newRecords(in: record, comparedTo: store.performedRecords())
        let metrics = store.healthMetrics(for: session.id)
        let streak = store.streakSummary(healthEntries: health.externalWorkouts)
        let highlights: [Highlight] = content.allItems
            .filter { $0.completedSets > 0 }
            .map { item -> (WorkoutItem, Double) in
                let volume = item.sets.filter(\.isDone).reduce(0.0) { $0 + Double($1.effectiveReps ?? 0) * ($1.effectiveWeight ?? 0) }
                return (item, volume)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(4)
            .map { item, _ in
                let top = item.sets.filter(\.isDone).max { ($0.effectiveWeight ?? 0, $0.effectiveReps ?? 0) < ($1.effectiveWeight ?? 0, $1.effectiveReps ?? 0) }
                let best = top.map { $0.label(mode: item.mode, unit: store.unit) } ?? ""
                return Highlight(name: item.name, detail: "\(item.completedSets) × · best \(best)")
            }
        let heartRate = averageHeartRate ?? metrics?.averageHeartRate
        let measuredEnergy = metrics?.activeEnergyKcal ?? 0
        return WorkoutRecap(
            id: session.id, title: session.title, date: session.startedAt ?? session.date, kind: session.kind,
            duration: session.durationSeconds, completedSets: content.completedSets, totalSets: content.totalSets,
            volumeKg: content.volumeKg,
            energyKcal: energyKcal ?? (measuredEnergy > 0 ? measuredEnergy : session.energyKcal),
            averageHeartRate: (heartRate ?? 0) > 0 ? heartRate : nil,
            effort: session.effort, energyBefore: session.energyBefore, records: found,
            muscleSets: muscles.plannedSets(content, completedOnly: true),
            highlights: Array(highlights), streakWeeks: streak.currentWeeks,
            weekDays: streak.thisWeek.workoutDays, weekGoal: streak.thisWeek.goal, unit: store.unit
        )
    }
}

// MARK: - Hero

/// The big top of a recap: ring of sets done, headline, counting numbers.
struct RecapHero: View {
    let recap: WorkoutRecap
    var animated = true
    @State private var shown = 0.0

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                ProgressRing(progress: recap.completion * shown, tint: recap.records.isEmpty ? .green : .yellow, lineWidth: 12)
                VStack(spacing: 0) {
                    Image(systemName: recap.records.isEmpty ? "checkmark.seal.fill" : "trophy.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle((recap.records.isEmpty ? Color.green : Color.yellow).gradient)
                        .symbolEffect(.bounce, value: shown >= 1)
                    Text("\(Int((Double(recap.completedSets) * shown).rounded()))/\(recap.totalSets)")
                        .font(.headline)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("sets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, height: 140)
            Text(recap.headline)
                .font(.title.weight(.heavy))
                .multilineTextAlignment(.center)
            Text(recap.subline)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            guard animated else { shown = 1; return }
            withAnimation(.easeOut(duration: 1.2).delay(0.2)) { shown = 1 }
        }
    }
}

/// Time, volume, energy, heart rate as tiles whose numbers count up.
struct RecapStatsGrid: View {
    let recap: WorkoutRecap
    var animated = true
    @State private var shown = 0.0

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
            tile("Time", Format.minutes(recap.duration * shown), "clock", .blue)
            if recap.volumeKg > 0 {
                tile("Volume", Format.volume(recap.volumeKg * shown, unit: recap.unit), "scalemass.fill", .accentColor)
            }
            if recap.energyKcal > 0 {
                tile("Energy", "\(Int(recap.energyKcal * shown)) kcal", "flame.fill", .orange)
            }
            if let hr = recap.averageHeartRate {
                tile("Avg heart rate", "\(Int(hr * shown)) bpm", "heart.fill", .pink)
            }
            if recap.effort > 0 {
                tile("Effort", "\(recap.effort)/10", "gauge.with.dots.needle.67percent", .purple)
            }
            if recap.streakWeeks > 0 {
                tile("Streak", "\(recap.streakWeeks) wk · \(recap.weekDays)/\(recap.weekGoal)", "flame", .orange)
            }
        }
        .onAppear {
            guard animated else { shown = 1; return }
            withAnimation(.easeOut(duration: 1.0).delay(0.4)) { shown = 1 }
        }
    }

    private func tile(_ title: String, _ value: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card(padding: 0, cornerRadius: 18)
    }
}

/// New records with a trophy each.
struct RecapRecordsCard: View {
    let recap: WorkoutRecap

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("New personal records", systemImage: "trophy.fill")
                .font(.headline)
                .foregroundStyle(.yellow)
                .symbolEffect(.bounce, value: recap.records.count)
            ForEach(recap.records) { record in
                HStack {
                    Text(record.exerciseName)
                    Spacer()
                    Text(recap.recordText(record))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(.subheadline)
            }
        }
        .padding()
        .card(padding: 0, cornerRadius: 20)
    }
}

/// Which exercises carried the workout.
struct RecapHighlightsCard: View {
    let recap: WorkoutRecap

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Highlights", systemImage: "star.fill")
                .font(.headline)
            ForEach(recap.highlights) { highlight in
                HStack {
                    Text(highlight.name).lineLimit(1)
                    Spacer()
                    Text(highlight.detail)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .font(.subheadline)
            }
        }
        .padding()
        .card(padding: 0, cornerRadius: 20)
    }
}

// MARK: - Share card

/// A 4:5 picture of the workout for Messages, Instagram & co. Only takes plain data, so it can be
/// rendered off-screen with `ImageRenderer`.
struct ShareCardView: View {
    let recap: WorkoutRecap

    var body: some View {
        let maxSets = max(1, recap.muscleSets.values.max() ?? 1)
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recap.date.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(recap.title)
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                }
                Spacer()
                if recap.streakWeeks > 0 {
                    VStack(spacing: 0) {
                        Image(systemName: "flame.fill")
                            .font(.title)
                            .foregroundStyle(LinearGradient(colors: [.yellow, .orange, .red], startPoint: .top, endPoint: .bottom))
                        Text("\(recap.streakWeeks) wk")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
            }

            HStack(alignment: .center, spacing: 14) {
                BodyMapPair(fill: { group in
                    let sets = recap.muscleSets[group] ?? 0
                    return sets > 0 ? MusclePalette.heat(0.25 + 0.75 * sets / maxSets) : Color.white.opacity(0.12)
                }, spacing: 4)
                .frame(height: 170)
                VStack(alignment: .leading, spacing: 10) {
                    stat(Format.minutes(recap.duration), "time")
                    stat("\(recap.completedSets)", "sets")
                    if recap.volumeKg > 0 { stat(Format.volume(recap.volumeKg, unit: recap.unit), "lifted") }
                    if recap.energyKcal > 0 { stat("\(Int(recap.energyKcal))", "kcal") }
                }
            }

            if let record = recap.records.first {
                HStack(spacing: 8) {
                    Image(systemName: "trophy.fill").foregroundStyle(.yellow)
                    Text("PR · \(record.exerciseName) \(recap.recordText(record))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.12), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(recap.highlights.prefix(3)) { highlight in
                    HStack {
                        Text(highlight.name).lineLimit(1)
                        Spacer()
                        Text(highlight.detail).monospacedDigit().lineLimit(1)
                    }
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                }
            }

            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: "dumbbell.fill")
                Text("George · your gym buddy")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.6))
        }
        .padding(24)
        .frame(width: 360, height: 450)
        .background(
            LinearGradient(colors: [Color(hex: "#0B1B3F"), Color(hex: "#2E7BFF"), Color(hex: "#7A3CFF")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .environment(\.colorScheme, .dark)
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.65))
        }
    }
}

/// Renders the share card and offers it through the share sheet.
struct ShareRecapButton: View {
    let recap: WorkoutRecap
    var prominent = true
    @State private var showPreview = false

    var body: some View {
        Button {
            showPreview = true
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
                .font(.headline)
                .frame(maxWidth: prominent ? .infinity : nil, minHeight: prominent ? 44 : nil)
        }
        .buttonStyle(.glassProminent)
        .sheet(isPresented: $showPreview) {
            ShareCardSheet(recap: recap)
                .presentationDetents([.large])
        }
    }
}

struct ShareCardSheet: View {
    let recap: WorkoutRecap
    @Environment(\.dismiss) private var dismiss
    @State private var image: Image?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ShareCardView(recap: recap)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                    .scaleEffect(0.9)
                if let image {
                    ShareLink(item: image, preview: SharePreview(recap.title, image: image)) {
                        Label("Share Picture", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.glassProminent)
                    .padding(.horizontal)
                } else {
                    ProgressView()
                }
                Text("Only what's on the picture is shared – no account, no link to your data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical)
            .navigationTitle("Share Workout")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { image = render() }
        }
    }

    @MainActor
    private func render() -> Image? {
        let renderer = ImageRenderer(content: ShareCardView(recap: recap))
        renderer.scale = 3
        #if os(iOS)
        return renderer.uiImage.map { Image(uiImage: $0) }
        #else
        return renderer.nsImage.map { Image(nsImage: $0) }
        #endif
    }
}

// MARK: - Overview section for a finished workout

/// Top of a finished workout's page: ring, headline, body map, records and the share button.
struct RecapOverviewSection: View {
    let session: WorkoutSession
    @Environment(GeorgeStore.self) private var store
    @Environment(MuscleAnalytics.self) private var muscles
    @Environment(HealthKitManager.self) private var health

    var body: some View {
        let recap = WorkoutRecap.make(session: session, store: store, muscles: muscles, health: health)
        Section {
            VStack(spacing: 16) {
                RecapHero(recap: recap, animated: false)
                if !recap.muscleSets.isEmpty {
                    WorkoutMuscleMap(sets: recap.muscleSets, title: "Muscles worked")
                }
                if !recap.records.isEmpty {
                    ForEach(recap.records) { record in
                        HStack {
                            Image(systemName: "trophy.fill").foregroundStyle(.yellow)
                            Text(record.exerciseName)
                            Spacer()
                            Text(recap.recordText(record)).fontWeight(.semibold).monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
                ShareRecapButton(recap: recap)
            }
            .padding(.vertical, 8)
        }
    }
}
