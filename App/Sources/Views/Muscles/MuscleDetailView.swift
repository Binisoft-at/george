import SwiftUI
import BinisoftKit
import Charts
import GeorgeCore

/// One muscle: freshness and recovery forecast, weekly sets vs. target, load status, exercises.
struct MuscleDetailView: View {
    let group: MuscleGroup
    @Environment(MuscleAnalytics.self) private var analytics
    @Environment(ExerciseLibrary.self) private var library
    @Environment(GeorgeStore.self) private var store

    var body: some View {
        let engine = analytics.engine
        let profile = store.profile
        let now = Date()
        let freshness = engine.freshness(of: group, at: now)
        let load = engine.loadSummary(group: group, days: 14)
        let weekly = engine.weeklySets(for: group, weeks: 12, now: now)
        let thisWeek = weekly.last?.sets ?? 0
        let ninety = DateInterval(start: now.addingTimeInterval(-90 * 86_400), end: now.addingTimeInterval(1))
        let exercises = engine.exercises(for: group, in: ninety)

        List {
            Section {
                HStack(spacing: 18) {
                    BodyMapPair(fill: { $0 == group ? color(for: freshness) : MusclePalette.empty }, selected: group, spacing: 4)
                        .frame(width: 120, height: 130)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(freshness.percent) %")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .monospacedDigit()
                        Text(freshness.isCalibrating ? "\(freshness.status.displayName) · calibrating" : freshness.status.displayName)
                            .font(.headline)
                            .foregroundStyle(freshness.isCalibrating ? Color.secondary : freshness.status.color)
                        Text(freshness.readyText)
                            .font(.subheadline)
                        if let last = freshness.lastTrained {
                            Text("Last trained \(last.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Not trained yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            } footer: {
                Text(freshness.isCalibrating
                     ? "Calibrating: after three workouts that train your \(group.displayName.lowercased()) within six weeks, George sizes the estimate to your usual volume."
                     : "Based on about \(Int(freshness.capacity.rounded())) hard sets per workout as your usual \(group.displayName.lowercased()) volume. Bigger muscles take longer to recover.")
            }

            Section("Recovery") {
                RecoveryChart(group: group, engine: engine, now: now)
                    .frame(height: 160)
                    .padding(.vertical, 6)
            }

            Section {
                WeeklySetsChart(weeks: weekly, target: profile.weeklySets)
                    .frame(height: 180)
                    .padding(.vertical, 6)
                Label(weeklyVerdict(thisWeek, target: profile.weeklySets), systemImage: thisWeek >= Double(profile.weeklySets.lowerBound) ? "checkmark.circle.fill" : "arrow.up.circle")
                    .font(.subheadline)
                    .foregroundStyle(thisWeek >= Double(profile.weeklySets.lowerBound) ? Color.green : Color.primary)
            } header: {
                Text("Sets per week")
            } footer: {
                Text("This week: \(Format.number((thisWeek * 10).rounded() / 10)) sets. Green band: \(profile.weeklySets.lowerBound)–\(profile.weeklySets.upperBound) hard sets per week – your target (\(profile.headline)). Moves that train it secondarily count half.")
            }

            Section("Muscular load") {
                NavigationLink {
                    MuscularLoadDetailView(group: group)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(Int(load.current.acute.rounded())) this week")
                                .font(.headline)
                                .monospacedDigit()
                            Spacer()
                            Text(load.current.status.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(load.current.status == .calibrating ? Color.secondary : load.current.status.color)
                        }
                        LoadGauge(point: load.current, maxValue: load.gaugeMax)
                    }
                    .padding(.vertical, 4)
                }
            }

            OptimalForYouSection(profile: profile, focus: focusText(freshness: freshness, profile: profile))

            Section("Exercises · last 90 days") {
                if exercises.isEmpty {
                    Text("No logged sets yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(exercises) { share in
                    if let exercise = library.exercise(id: share.exerciseKey) {
                        NavigationLink {
                            ExerciseDetailView(exerciseID: exercise.id)
                        } label: {
                            exerciseRow(share)
                        }
                    } else {
                        exerciseRow(share)
                    }
                }
            }
        }
        .groupedList()
        .navigationTitle(group.displayName)
    }

    private func weeklyVerdict(_ sets: Double, target: ClosedRange<Int>) -> String {
        let missing = Double(target.lowerBound) - sets
        if missing > 0 {
            return "\(Format.number((missing * 10).rounded() / 10)) more sets this week to reach your target."
        }
        if sets > Double(target.upperBound) {
            return "Above your target – more isn't always better; recovery counts too."
        }
        return "In your target range this week."
    }

    /// One plain sentence on what to do with this muscle now.
    private func focusText(freshness: MuscleFreshness, profile: TrainingProfile) -> String {
        let hours = profile.recoveryHours
        guard let last = freshness.lastTrained else {
            return "Your \(group.displayName.lowercased()) haven't been trained yet – start with \(profile.repRange.lowerBound)–\(profile.repRange.upperBound) reps."
        }
        let since = Int(Date().timeIntervalSince(last) / 3600)
        if since < hours.lowerBound {
            return "Trained \(since) h ago. Give it \(hours.lowerBound)–\(hours.upperBound) h before the next hard session."
        }
        return "Recovered enough for a hard session: \(profile.repRange.lowerBound)–\(profile.repRange.upperBound) reps, \(profile.repsInReserve.lowerBound)–\(profile.repsInReserve.upperBound) left in the tank."
    }

    private func color(for freshness: MuscleFreshness) -> Color {
        freshness.lastTrained == nil ? MusclePalette.empty : freshness.status.color
    }

    private func exerciseRow(_ share: MuscleExerciseShare) -> some View {
        HStack {
            Text(share.exerciseName)
            Spacer()
            Text("\(Format.number((share.sets * 10).rounded() / 10)) sets")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// Freshness over the last 4 days and the next 3, with the "recovered" threshold.
struct RecoveryChart: View {
    let group: MuscleGroup
    let engine: MuscleEngine
    let now: Date

    struct Sample: Identifiable {
        var id: String { "\(isForecast)-\(date.timeIntervalSince1970)" }
        let date: Date
        let percent: Double
        let isForecast: Bool
    }

    var body: some View {
        // Past and forecast share the "now" sample so the two lines meet.
        let samples = stride(from: -96, through: 72, by: 3).flatMap { hours -> [Sample] in
            let date = now.addingTimeInterval(Double(hours) * 3600)
            let percent = engine.freshness(of: group, at: date).freshness * 100
            if hours == 0 {
                return [Sample(date: date, percent: percent, isForecast: false), Sample(date: date, percent: percent, isForecast: true)]
            }
            return [Sample(date: date, percent: percent, isForecast: hours > 0)]
        }
        Chart {
            RectangleMark(
                xStart: .value("Start", samples.first?.date ?? now),
                xEnd: .value("End", samples.last?.date ?? now),
                yStart: .value("Recovered", MuscleEngine.recoveredThreshold * 100),
                yEnd: .value("Full", 100.0)
            )
            .foregroundStyle(FreshnessStatus.recovered.color.opacity(0.1))
            ForEach(samples) { sample in
                LineMark(x: .value("Time", sample.date), y: .value("Freshness", sample.percent), series: .value("Part", sample.isForecast ? "Forecast" : "Past"))
                    .foregroundStyle(sample.isForecast ? Color.secondary : Color.primary.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: sample.isForecast ? [4, 4] : []))
            }
            RuleMark(x: .value("Now", now))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .annotation(position: .top, alignment: .center) {
                    Text("Now").font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0.0, 40, 80, 100]) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text("\(Int(v)) %") }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel(format: .dateTime.weekday(.abbreviated))
            }
        }
    }
}

struct WeeklySetsChart: View {
    let weeks: [(weekStart: Date, sets: Double)]
    var target: ClosedRange<Int> = 10...20

    struct Row: Identifiable {
        var id: Date { weekStart }
        let weekStart: Date
        let sets: Double
    }

    var body: some View {
        let rows = weeks.map { Row(weekStart: $0.weekStart, sets: $0.sets) }
        let low = Double(target.lowerBound)
        let high = Double(target.upperBound)
        let top = max(high + 2, (rows.map(\.sets).max() ?? 0) * 1.1)
        Chart {
            if let first = rows.first?.weekStart, let last = rows.last?.weekStart {
                RectangleMark(
                    xStart: .value("Start", first, unit: .weekOfYear),
                    xEnd: .value("End", last.addingTimeInterval(7 * 86_400), unit: .weekOfYear),
                    yStart: .value("Low", low),
                    yEnd: .value("High", high)
                )
                .foregroundStyle(LoadStatus.productive.color.opacity(0.12))
            }
            ForEach(rows) { row in
                BarMark(x: .value("Week", row.weekStart, unit: .weekOfYear), y: .value("Sets", row.sets))
                    .foregroundStyle(MusclePalette.heat(min(1, row.sets / high)))
                    .cornerRadius(4)
            }
        }
        .chartYScale(domain: 0...top)
        .chartYAxis {
            AxisMarks(values: [0.0, low, high]) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel()
            }
        }
    }
}

/// Compact card: the most fatigued muscles right now.
struct MuscleFreshnessCard: View {
    @Environment(MuscleAnalytics.self) private var analytics
    @Environment(Router.self) private var router
    @AppStorage("muscleMetric") private var metric: MuscleMetric = .freshness

    var body: some View {
        let all = analytics.engine.freshness().filter { $0.lastTrained != nil }
        let tired = all.filter { $0.status != .recovered }.sorted { $0.freshness < $1.freshness }
        let shown = Array((tired.isEmpty ? all.sorted { ($0.lastTrained ?? .distantPast) > ($1.lastTrained ?? .distantPast) } : tired).prefix(6))
        Button {
            metric = .freshness
            router.show(.muscles)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Muscle Freshness", systemImage: "battery.75percent")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                if all.isEmpty {
                    Text("Log a workout to see how recovered each muscle is.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(tired.isEmpty ? "All trained muscles are recovered." : "\(tired.count) \(tired.count == 1 ? "muscle is" : "muscles are") still recovering.")
                        .font(.subheadline.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 10) {
                        ForEach(shown) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.group.displayName).font(.caption.weight(.semibold))
                                    Spacer()
                                    Text("\(item.percent) %").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                                DotBar(value: item.freshness, color: item.status.color)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card(padding: 0, cornerRadius: 24)
    }
}

/// Ten dots, filled up to `value` (0…1).
struct DotBar: View {
    let value: Double
    let color: Color

    var body: some View {
        let filled = Int((value * 10).rounded())
        HStack(spacing: 3) {
            ForEach(0..<10, id: \.self) { index in
                Circle()
                    .fill(index < filled ? color : Color.secondary.opacity(0.2))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}
