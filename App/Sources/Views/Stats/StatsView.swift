import SwiftUI
import BinisoftKit
import SwiftData
import Charts
import GeorgeCore

/// Insights → Progress: "am I getting stronger?" – one calendar-week window for every tile and
/// chart, each tile compared with the period before, the lifts with their trend, the records of
/// the range. Muscular load and freshness live on Today and Muscles.
struct StatsView: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(MuscleAnalytics.self) private var muscleAnalytics
    @Environment(HealthKitManager.self) private var health
    @Environment(Router.self) private var router
    @State private var range: StatsRange = .twelveWeeks
    @State private var selectedWeek: Date?
    /// Built off the main thread whenever the inputs change (see `ModelKey`).
    @State private var model: ProgressModel?

    enum StatsRange: String, CaseIterable, Identifiable {
        case fourWeeks, twelveWeeks, sixMonths, year
        var id: String { rawValue }
        var weeks: Int {
            switch self {
            case .fourWeeks: return 4
            case .twelveWeeks: return 12
            case .sixMonths: return 26
            case .year: return 52
            }
        }
        var title: String {
            switch self {
            case .fourWeeks: return "4W"
            case .twelveWeeks: return "12W"
            case .sixMonths: return "6M"
            case .year: return "1Y"
            }
        }
    }

    private struct ModelKey: Hashable {
        var range: StatsRange
        var engine: MuscleAnalytics.EngineKey
        var sessionCount: Int
        var healthVersion: Int
        var weekStartsOn: Int
        /// What counts as a training day (Settings → Streak).
        var weeklyGoal: Int
        var minimumMinutes: Int
        var countHealthWorkouts: Bool
    }

    var body: some View {
        // Performed workouts move `historyRevision` (not a running workout's sets: no refetch per tick).
        let key = ModelKey(range: range, engine: muscleAnalytics.engineKey, sessionCount: store.historyRevision,
                           healthVersion: health.workoutsVersion, weekStartsOn: store.calendar.firstWeekday,
                           weeklyGoal: store.settings.weeklyGoal, minimumMinutes: store.settings.minimumMinutes,
                           countHealthWorkouts: store.settings.countHealthWorkouts)
        let unit = store.unit
        let target = store.profile.weeklySets

        List {
            Section {
                Picker("Range", selection: $range) {
                    ForEach(StatsRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if let model, !model.isEmpty {
                tiles(model, unit: unit)
                liftsSection(model, unit: unit)
                recordsSection(model, unit: unit)

                Section {
                    WorkoutDaysChart(weeks: model.weeks, goals: model.goals, selection: $selectedWeek)
                        .frame(height: 200)
                        .padding(.vertical, 8)
                } header: {
                    Text("Workout days per week")
                } footer: {
                    let mac = MacHealth.streakMissesWorkouts(store)
                    Text("Days that count for your streak (at least \(store.settings.minimumMinutes) min\(store.settings.countHealthWorkouts && !mac ? ", Apple Health workouts included" : "")). Dashed line: your weekly goal of that week." + (mac ? " " + MacHealth.note : ""))
                }

                Section {
                    MinutesChart(weeks: model.weeks)
                        .frame(height: 180)
                        .padding(.vertical, 8)
                } header: {
                    Text("Active minutes per week")
                } footer: {
                    Text("George workouts only – Apple Health time is in Time by type.")
                }

                if !model.muscles.isEmpty {
                    let rows = model.muscles.prefix(12).map { MuscleChart.Row(muscle: $0.group.displayName, sets: $0.sets, perWeek: $0.setsPerWeek) }
                    Section {
                        MuscleChart(rows: Array(rows), target: target)
                            .frame(height: CGFloat(rows.count) * 28 + 20)
                            .padding(.vertical, 8)
                    } header: {
                        Text("Hard sets per muscle and week")
                    } footer: {
                        Text("\(model.muscleAverageText). Dashed lines: your target \(target.lowerBound)–\(target.upperBound) (\(store.profile.headline)) – ↓ below, ✓ in target, ↑ above. Secondary muscles count half a set; stretching, yoga and other sports don't count.")
                    }
                }

                if !model.types.isEmpty {
                    Section {
                        KindChart(rows: model.types)
                            .frame(height: CGFloat(model.types.count) * 30 + 20)
                            .padding(.vertical, 8)
                    } header: {
                        Text("Time by type")
                    } footer: {
                        if model.types.contains(where: \.includesHealth) {
                            Label("Includes workouts from Apple Health (other apps and devices).", systemImage: "heart.fill")
                        }
                    }
                }
            }
        }
        .groupedList()
        .navigationTitle("Stats & Records")
        .overlay {
            if model?.isEmpty == true {
                MessageView(title: "No data yet", systemImage: "chart.xyaxis.line", message: "Finish a workout to see your progress here.")
            } else if model == nil {
                ProgressView()
            }
        }
        .task(id: key) {
            let records = SessionHistory.shared.records(store)
            let input = ProgressModel.Input(
                records: records, external: health.healthWorkouts, engine: muscleAnalytics.engine,
                calendar: store.calendar, weeks: range.weeks, now: Date(),
                trainingDays: store.trainingEntries(healthEntries: health.externalWorkouts),
                streakConfig: store.settings.streakConfig
            )
            let built = await Task.detached(priority: .userInitiated) { ProgressModel.build(input) }.value
            guard !Task.isCancelled else { return }
            model = built
        }
    }

    // MARK: Sections

    private func tiles(_ model: ProgressModel, unit: WeightUnit) -> some View {
        let now = model.current
        let before = model.previous
        // No "vs prev." against a period with no history; one that was only partly logged is marked.
        let coverage = model.previousCoverage
        let compares = coverage != .noHistory
        let partial = coverage == .partial
        return Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                StatTile(title: "Workouts", value: "\(now.workouts)", symbol: "figure.strengthtraining.functional",
                         delta: compares ? StatDelta(Double(now.workouts - before.workouts), partial: partial, format: { "\(Int($0))" }) : nil)
                StatTile(title: "Active time", value: Format.minutes(now.seconds), symbol: "clock",
                         delta: compares ? StatDelta(now.seconds - before.seconds, partial: partial, threshold: 60, format: { Format.minutes($0) }) : nil)
                // Done sets without warm-ups (stretches and holds included) – not the hard sets of Muscles.
                StatTile(title: "Working sets", value: "\(now.sets)", symbol: "checklist",
                         delta: compares ? StatDelta(Double(now.sets - before.sets), partial: partial, format: { "\(Int($0))" }) : nil)
                StatTile(title: "Volume", value: Format.volume(now.volumeKg, unit: unit), symbol: "scalemass",
                         delta: compares ? StatDelta(now.volumeKg - before.volumeKg, partial: partial, threshold: 1, format: { Format.volume($0, unit: unit) }) : nil)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } footer: {
            switch coverage {
            case .noHistory:
                Text("First \(range.title) – comparisons start next period.")
            case .partial:
                Text("Compared with the \(range.title) before, which is only partly logged. Working sets leave out warm-ups.")
            case .complete:
                Text("Compared with the \(range.title) before. Working sets leave out warm-ups.")
            }
        }
    }

    @ViewBuilder
    private func liftsSection(_ model: ProgressModel, unit: WeightUnit) -> some View {
        Section {
            if model.lifts.isEmpty {
                Text("Do an exercise at least twice in this range to see whether it's going up.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.lifts) { trend in
                Button {
                    if !trend.exerciseKey.hasPrefix("name:") { router.push(.exercise(trend.exerciseKey)) }
                } label: {
                    LiftTrendRow(trend: trend, unit: unit)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Lifts · \(range.title)")
        } footer: {
            if !model.lifts.isEmpty {
                Text("Your most-done exercises, first session of the range against the last: estimated one-rep max for lifts with weight, total reps without, the longest hold for timed moves.")
            }
        }
    }

    @ViewBuilder
    private func recordsSection(_ model: ProgressModel, unit: WeightUnit) -> some View {
        if !model.records.isEmpty {
            Section("Records · \(range.title)") {
                ForEach(Array(model.records.prefix(15))) { record in
                    Button {
                        if !record.exerciseKey.hasPrefix("name:") {
                            router.push(.exercise(record.exerciseKey))
                        }
                    } label: {
                        HStack {
                            Image(systemName: "trophy.fill")
                                .foregroundStyle(Tone.record)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading) {
                                Text(record.exerciseName).foregroundStyle(.primary)
                                Text(record.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(record.detail(unit: unit))
                                .font(.headline)
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Everything the Progress tab shows, computed in one go off the main thread.
struct ProgressModel: Sendable {
    struct Input: Sendable {
        var records: [SessionRecord]
        var external: [ExternalWorkout]
        var engine: MuscleEngine
        var calendar: Calendar
        var weeks: Int
        var now: Date
        /// The streak's training days (`GeorgeStore.trainingEntries`), so the days chart matches it.
        var trainingDays: [ActivityEntry]
        var streakConfig: StreakConfig
    }

    var weeks: [WeekStat]
    /// Each week's goal (it can change over time).
    var goals: [Date: Int]
    var current: PeriodTotals
    var previous: PeriodTotals
    /// How much of the period before has history – no "vs prev." against nothing.
    var previousCoverage: PeriodCoverage
    var muscles: [MuscleTotal]
    /// "Average per week in this range" – or "… of the last 8 weeks with data" while history is shorter.
    var muscleAverageText: String
    var types: [TypeTime]
    var records: [PersonalRecord]
    var lifts: [ExerciseTrend]
    var isEmpty: Bool

    static func build(_ input: Input) -> ProgressModel {
        let calendar = input.calendar
        let now = input.now
        // One window for everything: whole calendar weeks, the current one included.
        let start = calendar.addingWeeks(-(max(1, input.weeks) - 1), to: calendar.weekStart(for: now))
        let end = max(start, now).addingTimeInterval(1)
        let window = DateInterval(start: start, end: end)
        // The period before, just as long (so a half-finished week compares fairly).
        let previous = DateInterval(start: calendar.addingWeeks(-input.weeks, to: start),
                                    end: calendar.addingWeeks(-input.weeks, to: end))
        let weeks = StatsEngine.weekly(input.records, calendar: calendar, weeks: input.weeks, now: now, trainingDays: input.trainingDays,
                                       rescueCountsDouble: input.streakConfig.rescueCountsDouble)
        return ProgressModel(
            weeks: weeks,
            goals: Dictionary(weeks.map { ($0.weekStart, input.streakConfig.goal(forWeekStarting: $0.weekStart, calendar: calendar)) },
                              uniquingKeysWith: { a, _ in a }),
            current: StatsEngine.totals(of: input.records, in: window),
            previous: StatsEngine.totals(of: input.records, in: previous),
            previousCoverage: StatsEngine.coverage(of: input.records, in: previous),
            muscles: input.engine.totals(in: window, now: now).filter { $0.sets > 0 }.sorted { $0.setsPerWeek > $1.setsPerWeek },
            muscleAverageText: MuscleEngine.averageCaption(weeksCovered: input.engine.weeksCovered(in: window, now: now),
                                                           rangeWeeks: max(1, window.duration / (7 * 86_400))),
            types: StatsEngine.timeByType(input.records, external: input.external, in: window),
            records: StatsEngine.recordsSet(in: input.records, since: start),
            lifts: StatsEngine.topTrends(in: input.records, since: start, limit: 6),
            isEmpty: input.records.isEmpty
        )
    }
}

/// "+3 vs prev." under a tile ("(partial)" when the period before was only partly logged).
struct StatDelta {
    let text: String
    /// 1 more, -1 less, 0 about the same.
    let sign: Int
    /// The period before was only partly logged: shown in secondary colour, never as a win.
    let isPartial: Bool

    init(_ change: Double, partial: Bool = false, threshold: Double = 0.5, format: (Double) -> String) {
        isPartial = partial
        let suffix = partial ? " (partial)" : ""
        if abs(change) < threshold {
            text = "Same as prev." + suffix
            sign = 0
        } else {
            text = (change > 0 ? "+" : "−") + format(abs(change)) + " vs prev." + suffix
            sign = change > 0 ? 1 : -1
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    var delta: StatDelta? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            if let delta {
                Label(delta.text, systemImage: delta.sign > 0 ? "arrow.up.right" : (delta.sign < 0 ? "arrow.down.right" : "equal"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(delta.sign > 0 && !delta.isPartial ? Tone.goodText : Color.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card(padding: 0, cornerRadius: 20)
        .accessibilityElement(children: .combine)
    }
}

/// One lift: name, latest value, a sparkline and the change over the range.
struct LiftTrendRow: View {
    let trend: ExerciseTrend
    let unit: WeightUnit
    @ScaledMetric(relativeTo: .body) private var sparkWidth: CGFloat = 64
    @ScaledMetric(relativeTo: .body) private var sparkHeight: CGFloat = 28

    var body: some View {
        let change = deltaText
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(trend.exerciseName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(measureTitle) \(format(trend.last)) · \(trend.sessions)×")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Sparkline(points: trend.points)
                .frame(width: sparkWidth, height: sparkHeight)
            Label(change.text, systemImage: change.sign > 0 ? "arrow.up.right" : (change.sign < 0 ? "arrow.down.right" : "equal"))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(change.sign > 0 ? Tone.goodText : Color.secondary)
                .lineLimit(1)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(trend.exerciseName): \(measureTitle) \(format(trend.last)), \(change.sign == 0 ? "about the same" : change.text) over \(trend.sessions) sessions")
    }

    private var measureTitle: String {
        switch trend.measure {
        case .oneRepMax: return "e1RM"
        case .reps: return "Reps"
        case .seconds: return "Hold"
        }
    }

    private func format(_ value: Double) -> String {
        switch trend.measure {
        case .oneRepMax: return Format.estimate(value, unit: unit)
        case .reps: return "\(Int(value.rounded()))"
        case .seconds: return Format.clock(Int(value.rounded()))
        }
    }

    private var deltaText: (text: String, sign: Int) {
        if trend.measure == .oneRepMax {
            // The difference of the two numbers as shown (rounded in the display unit).
            let shown = Format.estimateValue(trend.last, unit: unit) - Format.estimateValue(trend.first, unit: unit)
            guard abs(shown) >= 0.25 else { return ("Same", 0) }
            return ((shown > 0 ? "+" : "−") + "\(Format.number(abs(shown))) \(unit.rawValue)", shown > 0 ? 1 : -1)
        }
        let delta = trend.delta
        let threshold: Double = 1
        guard abs(delta) >= threshold else { return ("Same", 0) }
        let sign = delta > 0 ? "+" : "−"
        switch trend.measure {
        case .oneRepMax:
            return (sign + Format.estimate(abs(delta), unit: unit), delta > 0 ? 1 : -1)
        case .reps:
            return (sign + "\(Int(abs(delta).rounded())) reps", delta > 0 ? 1 : -1)
        case .seconds:
            return (sign + Format.shortDuration(Int(abs(delta).rounded())), delta > 0 ? 1 : -1)
        }
    }
}

/// A tiny line of a trend, last point marked.
struct Sparkline: View {
    let points: [TrendPoint]

    var body: some View {
        let values = points.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let pad = max(0.5, (high - low) * 0.15)
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                    .foregroundStyle(Tone.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let last = points.last {
                PointMark(x: .value("Date", last.date), y: .value("Value", last.value))
                    .foregroundStyle(Tone.accent)
                    .symbolSize(24)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: (low - pad)...(high + pad))
        .accessibilityHidden(true)
    }
}

/// Bars of workout days per week with the goal as a dashed rule. Tap/drag to read a week.
struct WorkoutDaysChart: View {
    let weeks: [WeekStat]
    /// Each week's own goal (`StreakConfig.goal(forWeekStarting:)`) – a week is measured against the
    /// goal it had, like the streak history.
    let goals: [Date: Int]
    @Binding var selection: Date?

    private func goal(of week: WeekStat) -> Int { goals[week.weekStart] ?? 0 }

    var body: some View {
        let distinctGoals = Set(weeks.map { goal(of: $0) })
        Chart {
            ForEach(weeks) { week in
                let target = goal(of: week)
                // Days as the streak counts them (a rescue workout counts double).
                BarMark(
                    x: .value("Week", week.weekStart, unit: .weekOfYear),
                    y: .value("Days", week.effectiveDays)
                )
                .foregroundStyle(week.effectiveDays >= target ? Tone.accent : Tone.accent.opacity(0.4))
                .cornerRadius(4)
                .accessibilityValue("\(week.effectiveDays) of \(target) days\(week.effectiveDays >= target ? ", goal reached" : "")")
            }
            if distinctGoals.count > 1 {
                // The goal changed in this range: a step line, each week at its own goal.
                ForEach(weeks) { week in
                    LineMark(
                        x: .value("Week", week.weekStart, unit: .weekOfYear),
                        y: .value("Goal", goal(of: week)),
                        series: .value("Series", "Goal")
                    )
                    .interpolationMethod(.stepCenter)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(Color.secondary)
                }
            } else if let goal = distinctGoals.first {
                RuleMark(y: .value("Goal", goal))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(Color.secondary)
            }
            if let selection, let week = weeks.first(where: { Calendar.current.isDate($0.weekStart, equalTo: selection, toGranularity: .weekOfYear) }) {
                RuleMark(x: .value("Selected", week.weekStart, unit: .weekOfYear))
                    .foregroundStyle(Color.secondary.opacity(0.3))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(week.weekStart.formatted(.dateTime.day().month(.abbreviated)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(week.effectiveDays) days\(week.effectiveDays > week.workoutDays ? " (rescue counts double)" : "") · \(week.sessions) workouts")
                                .font(.caption.weight(.semibold))
                        }
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
            }
        }
        .chartYScale(domain: 0...7)
        .chartYAxis {
            AxisMarks(values: [0, 2, 4, 6]) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel()
            }
        }
        .chartXSelection(value: $selection)
    }
}

struct MinutesChart: View {
    let weeks: [WeekStat]

    var body: some View {
        Chart(weeks) { week in
            BarMark(
                x: .value("Week", week.weekStart, unit: .weekOfYear),
                y: .value("Minutes", week.minutes)
            )
            .foregroundStyle(Tone.accent)
            .cornerRadius(4)
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel()
            }
        }
    }
}

/// Hard sets per week for each muscle, coloured against the profile's weekly target (band behind).
struct MuscleChart: View {
    struct Row: Identifiable {
        var id: String { muscle }
        let muscle: String
        let sets: Double
        let perWeek: Double
    }
    let rows: [Row]
    var target: ClosedRange<Int> = 10...20

    var body: some View {
        Chart {
            // The target range as two dashed rules behind the bars.
            ForEach([target.lowerBound, target.upperBound], id: \.self) { bound in
                RuleMark(x: .value("Target", Double(bound)))
                    .foregroundStyle(Tone.inTarget.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            ForEach(rows) { row in
                let status = TargetStatus(row.perWeek, target: target)
                BarMark(
                    x: .value("Sets per week", row.perWeek),
                    y: .value("Muscle", row.muscle)
                )
                .foregroundStyle(TargetStatus.fill(row.perWeek, target: target))
                .cornerRadius(4)
                .annotation(position: .trailing) {
                    HStack(spacing: 2) {
                        Image(systemName: status.symbol)
                        Text(Format.number((row.perWeek * 10).rounded() / 10))
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(status.textColor)
                }
                .accessibilityValue("\(Format.number((row.perWeek * 10).rounded() / 10)) sets per week, \(status.title.lowercased())")
            }
        }
        .chartXAxis(.hidden)
    }
}

/// Minutes per type (George workouts and Apple Health workouts).
struct KindChart: View {
    let rows: [TypeTime]

    var body: some View {
        Chart(rows) { row in
            BarMark(
                x: .value("Minutes", row.minutes),
                y: .value("Type", row.title)
            )
            .foregroundStyle(row.kind.color)
            .cornerRadius(4)
            .annotation(position: .trailing) {
                HStack(spacing: 3) {
                    if row.includesHealth {
                        Image(systemName: "heart.fill").accessibilityLabel("Apple Health")
                    }
                    Text(Format.minutes(row.minutes * 60))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .chartXAxis(.hidden)
    }
}
