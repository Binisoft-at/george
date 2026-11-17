import SwiftUI
import BinisoftKit
import SwiftData
import GeorgeCore

enum MuscleMetric: String, CaseIterable, Identifiable {
    case freshness, sets, volume, load
    var id: String { rawValue }
    var title: String {
        switch self {
        case .freshness: return "Freshness"
        case .sets: return "Sets"
        case .volume: return "Volume"
        case .load: return "Muscular Load"
        }
    }
    /// For the picker row.
    var shortTitle: String { self == .load ? "Load" : title }
    var symbol: String {
        switch self {
        case .freshness: return "battery.75percent"
        case .sets: return "number"
        case .volume: return "scalemass"
        case .load: return "gauge.with.dots.needle.67percent"
        }
    }
}

/// One muscle's value for the current metric.
struct MuscleValue: Identifiable, Sendable {
    var id: MuscleGroup { group }
    var group: MuscleGroup
    /// 0…1 used for colour and level bars.
    var level: Double
    var color: Color
    var title: String
    var subtitle: String
    var subtitleColor: Color
    var bucket: String
    var sortKey: Double
}

struct MusclesView: View {
    @Environment(MuscleAnalytics.self) private var analytics
    @Environment(GeorgeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var sessions: [WorkoutSession]
    @AppStorage("muscleMetric") private var metric: MuscleMetric = .freshness
    @State private var range: MuscleRange = .month
    @State private var offset = 0
    @State private var dayOffset = 0
    @State private var bucketFilter: String?
    @State private var sortAscending = true
    /// Computed off the main thread whenever the inputs change (see `valuesKey`).
    @State private var values: [MuscleValue] = []

    /// Everything the list depends on.
    private struct ValuesKey: Hashable {
        var metric: MuscleMetric
        var range: MuscleRange
        var offset: Int
        var dayOffset: Int
        var engine: MuscleAnalytics.EngineKey
        var sessionCount: Int
        var targetLow: Int
        var targetHigh: Int
        var unit: String
    }

    var body: some View {
        let target = store.profile.weeklySets
        let key = ValuesKey(metric: metric, range: range, offset: offset, dayOffset: dayOffset, engine: analytics.engineKey,
                            sessionCount: sessions.count, targetLow: target.lowerBound, targetHigh: target.upperBound,
                            unit: store.unit.rawValue)
        let visible = values
            .filter { bucketFilter == nil || $0.bucket == bucketFilter }
            .filter { metric == .freshness || $0.sortKey > 0 || bucketFilter != nil }
            .sorted { sortAscending ? $0.sortKey < $1.sortKey : $0.sortKey > $1.sortKey }
        let colors = Dictionary(values.map { ($0.group, $0.color) }, uniquingKeysWith: { a, _ in a })

        NavList {
            Section {
                MuscularLoadCard()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                metricPicker
                BodyMapPair(fill: { colors[$0] ?? MusclePalette.empty }, onTap: { router.open(.muscle($0.rawValue)) })
                    .frame(height: 300)
                    .padding(.vertical, 8)
                bucketChips
                periodControl
            }
            .listRowSeparator(.hidden)

            Section {
                ForEach(visible) { value in
                    DetailLink(.muscle(value.group.rawValue)) {
                        MuscleRow(value: value)
                    }
                }
                if visible.isEmpty {
                    Text(metric == .freshness ? "No muscles match this filter." : "No training in this period.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text(bucketFilter ?? "All Muscles")
                    Spacer()
                    Button {
                        sortAscending.toggle()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Reverse order")
                }
            } footer: {
                Text(footer)
            }
        }
        .groupedList()
        .navigationTitle("Muscles")
        .onChange(of: metric) { _, newMetric in
            bucketFilter = nil
            sortAscending = newMetric == .freshness
        }
        .task(id: key) {
            let input = MuscleValues.Input(
                metric: metric, engine: analytics.engine, referenceDate: referenceDate, interval: interval,
                target: target, unit: store.unit
            )
            let computed = await Task.detached(priority: .userInitiated) { MuscleValues.compute(input) }.value
            guard !Task.isCancelled else { return }
            values = computed
        }
    }

    // MARK: Controls

    /// The four metrics as one segmented control – always fully readable.
    private var metricPicker: some View {
        Picker("Metric", selection: Binding(get: { metric }, set: { new in
            if reduceMotion { metric = new } else { withAnimation(.snappy) { metric = new } }
        })) {
            ForEach(MuscleMetric.allCases) { item in
                Text(item.shortTitle).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.vertical, 2)
    }

    private var bucketChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", color: nil, isOn: bucketFilter == nil) { bucketFilter = nil }
                ForEach(MuscleValues.buckets(for: metric), id: \.self) { bucket in
                    chip(bucket, color: MuscleValues.bucketColor(bucket), isOn: bucketFilter == bucket) {
                        bucketFilter = bucketFilter == bucket ? nil : bucket
                    }
                }
            }
        }
        .scrollClipDisabled()
    }

    private func chip(_ title: String, color: Color?, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let color { Circle().fill(color).frame(width: 8, height: 8) }
                Text(title)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(isOn ? Color.secondary.opacity(0.3) : Color.secondary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    @ViewBuilder
    private var periodControl: some View {
        if metric == .freshness {
            HStack {
                Button { dayOffset += 1 } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Previous day")
                Spacer()
                Text(dayTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button { dayOffset = max(0, dayOffset - 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .disabled(dayOffset == 0)
                    .accessibilityLabel("Next day")
            }
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button { offset += 1 } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Earlier")
                    Picker("Range", selection: $range) {
                        ForEach(MuscleRange.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Button { offset = max(0, offset - 1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .disabled(offset == 0)
                        .accessibilityLabel("Later")
                }
                Text(intervalTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: range) { _, _ in offset = 0 }
        }
    }

    // MARK: Data

    private var referenceDate: Date {
        dayOffset == 0 ? Date() : store.calendar.addingDays(-dayOffset, to: store.calendar.startOfDay(for: Date())).addingTimeInterval(86_399)
    }

    private var interval: DateInterval {
        range.interval(endingAt: Date(), offset: offset, calendar: store.calendar)
    }

    private var dayTitle: String {
        let date = referenceDate
        let text = date.formatted(.dateTime.day().month(.wide))
        return dayOffset == 0 ? "Today, \(text)" : date.formatted(.dateTime.weekday(.wide)) + ", " + text
    }

    private var intervalTitle: String {
        let end = interval.end.addingTimeInterval(-1)
        return interval.start.formatted(.dateTime.day().month(.abbreviated)) + " – " + end.formatted(.dateTime.day().month(.abbreviated).year())
    }

    private var footer: String {
        switch metric {
        case .freshness:
            return "Freshness estimates how recovered each muscle is from your logged sets (secondary muscles count half). It's calibrated after three recent workouts per muscle."
        case .sets:
            let target = store.profile.weeklySets
            return "Hard sets per week against your target of \(target.lowerBound)–\(target.upperBound) per muscle (\(store.profile.headline); change it in Settings → Your Profile). Light blue: below, green: in target, amber: above. Secondary muscles count half a set; stretching, yoga and other sports don't count as sets."
        case .volume:
            return "Volume = reps × weight. Band and bodyweight sets add sets and load, not kilograms."
        case .load:
            return "Muscular load combines sets, set type and effort – and, with “Count other sports” on in Settings, your Apple Health workouts. The card above compares your last 7 days with your usual week (optimal \(store.profile.loadBandText))."
        }
    }
}

/// The per-muscle values of the Muscles screen, computed off the main thread.
enum MuscleValues {
    struct Input: Sendable {
        var metric: MuscleMetric
        var engine: MuscleEngine
        var referenceDate: Date
        var interval: DateInterval
        var target: ClosedRange<Int>
        var unit: WeightUnit
    }

    static func buckets(for metric: MuscleMetric) -> [String] {
        switch metric {
        case .freshness: return FreshnessStatus.allCases.map(\.displayName)
        case .sets: return TargetStatus.allCases.map(\.title)
        case .volume, .load: return ["Low", "Medium", "High"]
        }
    }

    static func bucketColor(_ bucket: String) -> Color {
        if let status = FreshnessStatus.allCases.first(where: { $0.displayName == bucket }) { return status.color }
        if let status = TargetStatus.allCases.first(where: { $0.title == bucket }) { return status.color }
        switch bucket {
        case "Low": return MusclePalette.heat(0.2)
        case "Medium": return MusclePalette.heat(0.6)
        default: return MusclePalette.heat(1)
        }
    }

    static func compute(_ input: Input) -> [MuscleValue] {
        let engine = input.engine
        switch input.metric {
        case .freshness:
            return engine.freshness(at: input.referenceDate).map { f in
                let trained = f.lastTrained != nil
                var subtitle = f.status == .recovered
                    ? "Recovered · \(f.percent) %"
                    : "\(f.readyText) · \(f.status.displayName) \(f.percent) %"
                if f.isCalibrating { subtitle += " · calibrating" }
                return MuscleValue(
                    group: f.group,
                    level: trained ? f.freshness : 0,
                    // Lighter while the estimate is still calibrating.
                    color: trained ? f.status.color.opacity(f.isCalibrating ? 0.6 : 1) : MusclePalette.empty,
                    title: f.group.displayName,
                    subtitle: trained ? subtitle : "Not trained yet",
                    subtitleColor: trained ? f.status.textColor : .secondary,
                    bucket: f.status.displayName,
                    sortKey: trained ? f.freshness : 2
                )
            }
        case .sets:
            let target = input.target
            return engine.totals(in: input.interval).map { t in
                let status = TargetStatus(t.setsPerWeek, target: target)
                let perWeek = Format.number((t.setsPerWeek * 10).rounded() / 10)
                return MuscleValue(
                    group: t.group,
                    level: min(1, t.setsPerWeek / Double(max(1, target.upperBound))),
                    color: TargetStatus.fill(t.setsPerWeek, target: target),
                    title: t.group.displayName,
                    subtitle: "\(perWeek) sets/week · \(status.title.lowercased())",
                    subtitleColor: t.sets > 0 ? status.textColor : .secondary,
                    bucket: status.title,
                    sortKey: t.setsPerWeek
                )
            }
        case .volume:
            let totals = engine.totals(in: input.interval)
            let maxValue = max(1, totals.map(\.volumeKg).max() ?? 1)
            return totals.map { t in
                MuscleValue(
                    group: t.group, level: t.volumeKg / maxValue, color: MusclePalette.heat(t.volumeKg / maxValue),
                    title: t.group.displayName,
                    subtitle: Format.volume(t.volumeKg, unit: input.unit) + " · \(t.sessions) workouts",
                    subtitleColor: .secondary, bucket: tercile(t.volumeKg, of: maxValue), sortKey: t.volumeKg
                )
            }
        case .load:
            let totals = engine.totals(in: input.interval)
            let maxValue = max(0.1, totals.map(\.load).max() ?? 1)
            return totals.map { t in
                let now = engine.loadSummary(group: t.group, days: 1, now: input.referenceDate).current
                let subtitle = now.showsRatio
                    ? "\(Int(t.load.rounded())) hard sets · now \(now.status.displayName.lowercased()) (\(now.percentOfUsual) %)"
                    : "\(Int(t.load.rounded())) hard sets · \(now.status.displayName.lowercased())"
                return MuscleValue(
                    group: t.group, level: t.load / maxValue, color: MusclePalette.heat(t.load / maxValue),
                    title: t.group.displayName,
                    subtitle: subtitle,
                    subtitleColor: now.status.textColor,
                    bucket: tercile(t.load, of: maxValue), sortKey: t.load
                )
            }
        }
    }

    private static func tercile(_ value: Double, of maxValue: Double) -> String {
        let ratio = value / maxValue
        if ratio < 0.34 { return "Low" }
        if ratio < 0.67 { return "Medium" }
        return "High"
    }
}

struct MuscleRow: View {
    let value: MuscleValue

    var body: some View {
        HStack(spacing: 12) {
            BodyFigure(side: value.group.preferredSide, fill: { $0 == value.group ? value.color : MusclePalette.empty.opacity(0.6) })
                .frame(width: 22, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(value.title).font(.headline)
                Text(value.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(value.subtitleColor)
                    .lineLimit(2)
            }
            Spacer()
            LevelBars(level: value.level, color: value.color)
        }
        .padding(.vertical, 2)
    }
}

extension MuscleGroup {
    /// Which side of the body map shows this muscle best.
    var preferredSide: BodyMap.Side {
        switch self {
        case .triceps, .traps, .upperBack, .lats, .lowerBack, .glutes, .hamstrings: return .back
        default: return .front
        }
    }
}
