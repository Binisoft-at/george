import SwiftUI
import BinisoftKit
import SwiftData
import Charts
import GeorgeCore

struct StatsView: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(MuscleAnalytics.self) private var muscleAnalytics
    @Environment(Router.self) private var router
    @Query private var sessions: [WorkoutSession]
    @State private var range: StatsRange = .twelveWeeks
    @State private var selectedWeek: Date?

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

    var body: some View {
        let records = sessions.filter { $0.status.isPerformed }.map { $0.record() }
        let weeks = StatsEngine.weekly(records, calendar: store.calendar, weeks: range.weeks)
        let since = store.calendar.addingWeeks(-range.weeks, to: Date())
        let inRange = records.filter { $0.date >= since }

        List {
            Section {
                Picker("Range", selection: $range) {
                    ForEach(StatsRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                VStack(spacing: 12) {
                    MuscularLoadCard(openIn: .muscles)
                    MuscleFreshnessCard()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                    StatTile(title: "Workouts", value: "\(inRange.count)", symbol: "figure.strengthtraining.functional")
                    StatTile(title: "Active time", value: Format.minutes(inRange.reduce(0) { $0 + $1.durationSeconds }), symbol: "clock")
                    StatTile(title: "Sets", value: "\(inRange.reduce(0) { $0 + $1.content.completedSets })", symbol: "checklist")
                    StatTile(title: "Volume", value: Format.volume(inRange.reduce(0) { $0 + $1.content.volumeKg }, unit: store.unit), symbol: "scalemass")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                WorkoutDaysChart(weeks: weeks, goal: store.settings.weeklyGoal, selection: $selectedWeek)
                    .frame(height: 200)
                    .padding(.vertical, 8)
            } header: {
                Text("Workout days per week")
            } footer: {
                Text("Dashed line: your weekly goal of \(store.settings.weeklyGoal) days.")
            }

            Section("Active minutes per week") {
                MinutesChart(weeks: weeks)
                    .frame(height: 180)
                    .padding(.vertical, 8)
            }

            let muscles = muscleAnalytics.engine.totals(in: DateInterval(start: since, end: Date().addingTimeInterval(1)))
                .filter { $0.sets > 0 }
                .sorted { $0.sets > $1.sets }
            if !muscles.isEmpty {
                Section {
                    MuscleChart(rows: muscles.prefix(12).map { MuscleChart.Row(muscle: $0.group.displayName, sets: $0.sets, perWeek: $0.setsPerWeek) })
                        .frame(height: CGFloat(min(12, muscles.count)) * 28 + 20)
                        .padding(.vertical, 8)
                } header: {
                    Text("Sets per muscle")
                } footer: {
                    Text("Secondary muscles count half a set. Colour shows sets per week against the common 10–20 set target.")
                }
            }

            let kinds = StatsEngine.kindMinutes(in: inRange, since: since)
            if !kinds.isEmpty {
                Section("Time by type") {
                    KindChart(rows: kinds.map { KindChart.Row(kind: $0.kind, minutes: $0.minutes) })
                        .frame(height: CGFloat(kinds.count) * 30 + 20)
                        .padding(.vertical, 8)
                }
            }

            let prs = StatsEngine.personalRecords(in: records).filter { $0.metric == .weight || $0.metric == .duration }
            if !prs.isEmpty {
                Section("Personal records") {
                    ForEach(Array(prs.prefix(15))) { record in
                        Button {
                            if !record.exerciseKey.hasPrefix("name:") {
                                router.open(.exercise(record.exerciseKey))
                            }
                        } label: {
                            HStack {
                                Image(systemName: "trophy.fill").foregroundStyle(.yellow)
                                VStack(alignment: .leading) {
                                    Text(record.exerciseName).foregroundStyle(.primary)
                                    Text(record.date.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(record.metric == .weight ? Format.weight(record.value, unit: store.unit) : Format.shortDuration(Int(record.value)))
                                    .font(.headline)
                                    .monospacedDigit()
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            let exercises = StatsEngine.exercises(in: records)
            if !exercises.isEmpty {
                Section("Most trained") {
                    ForEach(Array(exercises.sorted { $0.sessions > $1.sessions }.prefix(10))) { summary in
                        Button {
                            if !summary.key.hasPrefix("name:") { router.open(.exercise(summary.key)) }
                        } label: {
                            HStack {
                                Text(summary.name).foregroundStyle(.primary)
                                Spacer()
                                Text("\(summary.sessions)×").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .groupedList()
        .navigationTitle("Stats & Records")
        .overlay {
            if records.isEmpty {
                MessageView(title: "No data yet", systemImage: "chart.xyaxis.line", message: "Finish a workout to see your progress here.")
            }
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let symbol: String

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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card(padding: 0, cornerRadius: 20)
    }
}

/// Bars of workout days per week with the goal as a dashed rule. Tap/drag to read a week.
struct WorkoutDaysChart: View {
    let weeks: [WeekStat]
    let goal: Int
    @Binding var selection: Date?

    var body: some View {
        Chart {
            ForEach(weeks) { week in
                BarMark(
                    x: .value("Week", week.weekStart, unit: .weekOfYear),
                    y: .value("Days", week.workoutDays)
                )
                .foregroundStyle(week.workoutDays >= goal ? Color.orange : Color.orange.opacity(0.45))
                .cornerRadius(4)
            }
            RuleMark(y: .value("Goal", goal))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(Color.secondary)
            if let selection, let week = weeks.first(where: { Calendar.current.isDate($0.weekStart, equalTo: selection, toGranularity: .weekOfYear) }) {
                RuleMark(x: .value("Selected", week.weekStart, unit: .weekOfYear))
                    .foregroundStyle(Color.secondary.opacity(0.3))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(week.weekStart.formatted(.dateTime.day().month(.abbreviated)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(week.workoutDays) days · \(week.sessions) workouts")
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
            .foregroundStyle(Color.blue)
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

struct MuscleChart: View {
    struct Row: Identifiable {
        var id: String { muscle }
        let muscle: String
        let sets: Double
        let perWeek: Double
    }
    let rows: [Row]

    var body: some View {
        Chart(rows) { row in
            BarMark(
                x: .value("Sets", row.sets),
                y: .value("Muscle", row.muscle)
            )
            .foregroundStyle(MusclePalette.heat(min(1, row.perWeek / 20)))
            .cornerRadius(4)
            .annotation(position: .trailing) {
                Text(Format.number((row.sets * 10).rounded() / 10))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis(.hidden)
    }
}

struct KindChart: View {
    struct Row: Identifiable {
        var id: String { kind.rawValue }
        let kind: WorkoutKind
        let minutes: Double
    }
    let rows: [Row]

    var body: some View {
        Chart(rows) { row in
            BarMark(
                x: .value("Minutes", row.minutes),
                y: .value("Type", row.kind.displayName)
            )
            .foregroundStyle(row.kind.color)
            .cornerRadius(4)
            .annotation(position: .trailing) {
                Text(Format.minutes(row.minutes * 60))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis(.hidden)
    }
}
