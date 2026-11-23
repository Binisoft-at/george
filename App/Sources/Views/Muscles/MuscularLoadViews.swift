import SwiftUI
import BinisoftKit
import Charts
import GeorgeCore

/// Horizontal gauge: the track, a light fill up to this week's load, the optimal range stroked on
/// top (so the fill never hides it), then a marker at the current value.
struct LoadGauge: View {
    let point: LoadPoint
    let maxValue: Double
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let scale = maxValue > 0 ? width / maxValue : 0
            let low = min(width, point.optimalLow * scale)
            let high = min(width, point.optimalHigh * scale)
            let marker = min(width, max(0, point.acute * scale))
            let band = LoadStatus.productive.color
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.16))
                Capsule()
                    .fill(point.status.color.opacity(0.35))
                    .frame(width: max(height, marker))
                if point.status != .calibrating && high > low {
                    Capsule()
                        .fill(band.opacity(0.14))
                        .overlay(Capsule().strokeBorder(band, lineWidth: 2))
                        .frame(width: max(height, high - low))
                        .offset(x: low)
                }
                Circle()
                    .fill(.background)
                    .overlay(Circle().stroke(point.status.color, lineWidth: 3))
                    .frame(width: height, height: height)
                    .offset(x: max(0, min(width - height, marker - height / 2)))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Muscular load")
        .accessibilityValue(point.status == .calibrating ? point.spokenSummary : "\(point.spokenSummary), optimal \(point.bandText)")
    }
}

/// "Muscular Load" card: the last 7 days against your usual week.
struct MuscularLoadCard: View {
    @Environment(MuscleAnalytics.self) private var analytics
    @Environment(Router.self) private var router
    /// Where a tap should open the detail (keeps the current sidebar selection when nil).
    var openIn: SidebarItem? = nil

    var body: some View {
        let summary = analytics.engine.loadSummary(days: 14)
        let point = summary.current
        Button {
            router.open(.muscularLoad, in: openIn)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Muscular Load", systemImage: "gauge.with.dots.needle.67percent")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                LoadHeadline(point: point)
                LoadGauge(point: point, maxValue: summary.gaugeMax)
                if point.showsRatio {
                    Text(point.detailLine)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(point.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                // Mac: other sports from Apple Health aren't here (load and freshness can be lower).
                MacHealthNote(topic: .load)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card(padding: 0, cornerRadius: 24)
    }
}

/// "150 % Fatigued / of your usual week" with the optimal range on the right.
struct LoadHeadline: View {
    let point: LoadPoint
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(point.headline)
                        .font(.system(compact ? .title : .largeTitle, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(point.status.displayName)
                        .font(.headline)
                        .foregroundStyle(point.status.textColor)
                }
                Text(point.headlineCaption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if point.status != .calibrating {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("Optimal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(point.bandText)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// History of the muscular load (whole body or one muscle) with the optimal range and status breakdown.
struct MuscularLoadDetailView: View {
    let group: MuscleGroup?
    @Environment(MuscleAnalytics.self) private var analytics
    @Environment(GeorgeStore.self) private var store
    @State private var range: LoadRange = .month
    @State private var selectedDay: Date?

    enum LoadRange: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, quarter = 91, year = 365
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .week: return "7D"
            case .month: return "30D"
            case .quarter: return "3M"
            case .year: return "1Y"
            }
        }
    }

    var body: some View {
        let engine = analytics.engine
        let summary = engine.loadSummary(group: group, days: range.rawValue)
        let selected = selectedDay.flatMap { day in summary.history.first { engine.calendar.isDate($0.day, inSameDayAs: day) } }
        let shown = selected ?? summary.current

        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(shown.day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LoadHeadline(point: shown)
                    LoadGauge(point: shown, maxValue: max(summary.gaugeMax, shown.acute * 1.15))
                    if shown.showsRatio {
                        Text(shown.detailLine)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Text(shown.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                Picker("Range", selection: $range) {
                    ForEach(LoadRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LoadHistoryChart(history: summary.history, selection: $selectedDay)
                    .frame(height: 220)
                    .padding(.vertical, 6)
                StatusStrip(history: summary.history)
                    .frame(height: 8)
            } header: {
                Text("Last \(range.rawValue) days")
            } footer: {
                Text("Line: your load of the previous 7 days, each day. Load adds up every muscle a set trains (a bench press set counts for chest, triceps and shoulders), weighted by how hard it was – so it is larger than your number of sets. Green band: your optimal range – \(store.profile.loadBandText) of your usual week (the weekly average of the last 6 weeks, or of the weeks so far). A jump above it only counts as High or Big jump when a muscle got more than \(store.profile.weeklySets.upperBound) sets in 7 days.")
            }

            Section("Breakdown") {
                let days = Dictionary(summary.breakdown.map { ($0.status, $0.days) }, uniquingKeysWith: +)
                let statuses = LoadStatus.allCases.filter { (days[$0] ?? 0) > 0 }
                let total = max(1, days.values.reduce(0, +))
                ForEach(statuses) { status in
                    let count = days[status] ?? 0
                    HStack(spacing: 10) {
                        Circle().fill(status.color).frame(width: 10, height: 10)
                        Text(status.displayName)
                        Spacer()
                        GeometryReader { proxy in
                            Capsule()
                                .fill(status.color.opacity(0.8))
                                .frame(width: max(4, proxy.size.width * CGFloat(count) / CGFloat(total)))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .frame(width: 90, height: 8)
                        Text("\(count) \(count == 1 ? "day" : "days")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 60, alignment: .trailing)
                    }
                }
            }

            Section {
                ForEach(LoadStatus.allCases) { status in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(status.color).frame(width: 10, height: 10).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(status.displayName).font(.subheadline.weight(.semibold))
                            Text(status.explanation).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("What the statuses mean")
            } footer: {
                Text("Load weighs every set: a working set counts 1, warm-ups ¼, drop sets ¾, sets to failure 1.1, scaled by RPE (or the workout's effort rating). Muscles a move trains secondarily count half. Stretching and yoga barely add load. With “Count other sports in muscle recovery” on in Settings, Apple Health workouts such as tennis or runs add load by duration and effort. Sleep, heart rate and cardio fitness aren't part of it.")
            }

            OptimalForYouSection(profile: store.profile, focus: loadFocus(store.profile))
        }
        .groupedList()
        .navigationTitle(group.map { "\($0.displayName) Load" } ?? "Muscular Load")
        .inlineTitle()
        .onChange(of: range) { _, _ in selectedDay = nil }
    }
}

struct LoadHistoryChart: View {
    let history: [LoadPoint]
    @Binding var selection: Date?

    var body: some View {
        let showPoints = history.count <= 31
        Chart {
            ForEach(history) { point in
                if point.status != .calibrating {
                    AreaMark(
                        x: .value("Day", point.day, unit: .day),
                        yStart: .value("Optimal low", point.optimalLow),
                        yEnd: .value("Optimal high", point.optimalHigh)
                    )
                    .foregroundStyle(LoadStatus.productive.color.opacity(0.18))
                    .interpolationMethod(.monotone)
                }
            }
            ForEach(history) { point in
                LineMark(x: .value("Day", point.day, unit: .day), y: .value("Load", point.acute))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
                if showPoints {
                    PointMark(x: .value("Day", point.day, unit: .day), y: .value("Load", point.acute))
                        .foregroundStyle(point.status.color)
                        .symbolSize(28)
                }
            }
            if let selection, let point = history.first(where: { Calendar.current.isDate($0.day, inSameDayAs: selection) }) {
                RuleMark(x: .value("Selected", point.day, unit: .day))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(point.day.formatted(.dateTime.day().month(.abbreviated)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(point.showsRatio ? "\(point.percentOfUsual) % · \(point.status.displayName)" : "\(Int(point.acuteSets.rounded())) sets · \(point.status.displayName)")
                                .font(.caption.weight(.semibold))
                        }
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel()
            }
        }
        .chartXSelection(value: $selection)
    }
}

/// Thin strip of the daily status colours under the chart.
struct StatusStrip: View {
    let history: [LoadPoint]

    var body: some View {
        HStack(spacing: history.count > 60 ? 0 : 1) {
            ForEach(history) { point in
                Rectangle().fill(point.status.color)
            }
        }
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

extension MuscularLoadDetailView {
    /// How to use the load range, for this person.
    func loadFocus(_ profile: TrainingProfile) -> String {
        "Keep your 7-day load at \(profile.loadBandText) of your usual week and raise it by about 10 % a week at most – bigger jumps are when overuse injuries happen. Below the range for weeks, you're maintaining rather than building."
    }
}
