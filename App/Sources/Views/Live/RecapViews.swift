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

/// The share picture's look: dark midnight blue or clean white – both in George's blues.
enum ShareCardStyle: String, CaseIterable, Identifiable {
    case midnight, clean
    var id: String { rawValue }
    var title: String { self == .midnight ? "Midnight" : "Clean" }
}

/// Feed post (4:5) or story (9:16).
enum ShareCardFormat: String, CaseIterable, Identifiable {
    case post, story
    var id: String { rawValue }
    var title: String { self == .post ? "Post 4:5" : "Story 9:16" }
    /// Points; rendered at 3× → 1080 × 1350 / 1080 × 1920 pixels.
    var size: CGSize { self == .post ? CGSize(width: 360, height: 450) : CGSize(width: 360, height: 640) }
}

/// The workout as a picture for Messages, Instagram & co. Only takes plain data, so it renders
/// off-screen with `ImageRenderer`. One colour family (George's blues, gold only for records),
/// numbers big, everything else quiet.
struct ShareCardView: View {
    let recap: WorkoutRecap
    var style: ShareCardStyle = .midnight
    var format: ShareCardFormat = .post

    private var dark: Bool { style == .midnight }
    private var primary: Color { dark ? .white : BrandPalette.ink }
    private var secondary: Color { dark ? .white.opacity(0.62) : BrandPalette.ink.opacity(0.55) }
    private var accent: Color { dark ? BrandPalette.sky : BrandPalette.blue }
    private var hairline: Color { dark ? .white.opacity(0.14) : BrandPalette.ink.opacity(0.1) }

    var body: some View {
        let maxSets = max(1, recap.muscleSets.values.max() ?? 1)
        VStack(alignment: .leading, spacing: format == .story ? 22 : 16) {
            header
            VStack(alignment: .leading, spacing: 4) {
                Text(recap.title)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                Text(recap.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
            }
            statsRow
            HStack(alignment: .center, spacing: 14) {
                BodyMapPair(fill: { group in
                    let t = (recap.muscleSets[group] ?? 0) / maxSets
                    return dark ? BrandPalette.muscleOnDark(t) : BrandPalette.muscleOnLight(t)
                }, spacing: 4)
                .frame(height: format == .story ? 200 : 150)
                VStack(alignment: .leading, spacing: 7) {
                    Text("TOP LIFTS")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(secondary)
                    ForEach(recap.highlights.prefix(format == .story ? 4 : 3)) { highlight in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(highlight.name)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Text(highlight.detail)
                                .font(.caption2)
                                .foregroundStyle(secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let record = recap.records.first {
                HStack(spacing: 8) {
                    Image(systemName: "trophy.fill")
                        .foregroundStyle(BrandPalette.gold)
                    Text("PR · \(record.exerciseName)")
                        .foregroundStyle(primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(recap.recordText(record))
                        .foregroundStyle(dark ? BrandPalette.gold : Color(hex: "#B07D00"))
                        .monospacedDigit()
                }
                .font(.subheadline.weight(.bold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(BrandPalette.gold.opacity(dark ? 0.14 : 0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(26)
        .frame(width: format.size.width, height: format.size.height, alignment: .topLeading)
        .background(background)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image("GeorgeMark")
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text("GEORGE")
                .font(.caption.weight(.heavy))
                .tracking(2)
                .foregroundStyle(primary)
            Spacer()
            Text(recap.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(1)
                .foregroundStyle(secondary)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            stat(Format.minutes(recap.duration), "TIME")
            divider
            stat("\(recap.completedSets)", "SETS")
            if recap.volumeKg > 0 {
                divider
                stat(Format.volume(recap.volumeKg, unit: recap.unit), "LIFTED")
            } else if recap.energyKcal > 0 {
                divider
                stat("\(Int(recap.energyKcal))", "KCAL")
            }
        }
        .padding(.vertical, 12)
        .background(dark ? Color.white.opacity(0.07) : BrandPalette.ice.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var divider: some View {
        Rectangle().fill(hairline).frame(width: 1, height: 34)
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(caption)
                .font(.caption2.weight(.heavy))
                .tracking(1)
                .foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            if recap.streakWeeks > 0 {
                Label("\(recap.streakWeeks)-week streak", systemImage: "flame.fill")
                    .foregroundStyle(dark ? BrandPalette.gold : Color(hex: "#B07D00"))
            }
            Spacer()
            Text("your gym buddy")
                .foregroundStyle(secondary)
        }
        .font(.caption.weight(.semibold))
    }

    @ViewBuilder
    private var background: some View {
        if dark {
            ZStack {
                LinearGradient(colors: [BrandPalette.midnight, BrandPalette.navy, BrandPalette.royal], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [BrandPalette.blue.opacity(0.45), .clear], center: .topTrailing, startRadius: 10, endRadius: 320)
            }
        } else {
            ZStack {
                Color.white
                RadialGradient(colors: [BrandPalette.ice, .white.opacity(0)], center: .topTrailing, startRadius: 10, endRadius: 340)
            }
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

/// Pick format and style, see the picture, share it.
struct ShareCardSheet: View {
    let recap: WorkoutRecap
    @Environment(\.dismiss) private var dismiss
    @AppStorage("shareCardStyle") private var styleRaw = ShareCardStyle.midnight.rawValue
    @AppStorage("shareCardFormat") private var formatRaw = ShareCardFormat.post.rawValue
    @State private var image: Image?

    private var style: ShareCardStyle { ShareCardStyle(rawValue: styleRaw) ?? .midnight }
    private var format: ShareCardFormat { ShareCardFormat(rawValue: formatRaw) ?? .post }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Format", selection: $formatRaw) {
                        ForEach(ShareCardFormat.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Style", selection: $styleRaw) {
                        ForEach(ShareCardStyle.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    ShareCardView(recap: recap, style: style, format: format)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                        .scaleEffect(format == .story ? 0.82 : 0.92)
                        .frame(height: format.size.height * (format == .story ? 0.82 : 0.92))
                    if let image {
                        ShareLink(item: image, preview: SharePreview(recap.title, image: image)) {
                            Label("Share Picture", systemImage: "square.and.arrow.up")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.glassProminent)
                    } else {
                        ProgressView()
                    }
                    Text("Only what's on the picture is shared – no account, no link to your data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Share Workout")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: styleRaw + formatRaw) { image = render() }
        }
    }

    @MainActor
    private func render() -> Image? {
        let renderer = ImageRenderer(content: ShareCardView(recap: recap, style: style, format: format))
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
