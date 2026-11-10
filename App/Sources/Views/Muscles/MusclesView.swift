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
struct MuscleValue: Identifiable {
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
    @Query private var sessions: [WorkoutSession]
    @AppStorage("muscleMetric") private var metric: MuscleMetric = .freshness
    @State private var range: MuscleRange = .month
    @State private var offset = 0
    @State private var dayOffset = 0
    @State private var bucketFilter: String?
    @State private var sortAscending = true

    var body: some View {
        let _ = sessions.count + store.revision
        let values = computeValues()
        let visible = values
            .filter { bucketFilter == nil || $0.bucket == bucketFilter }
            .filter { metric == .freshness || $0.sortKey > 0 || bucketFilter != nil }
            .sorted { sortAscending ? $0.sortKey < $1.sortKey : $0.sortKey > $1.sortKey }
        let colors = Dictionary(uniqueKeysWithValues: values.map { ($0.group, $0.color) })

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
                bucketChips(values)
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
    }

    // MARK: Controls

    /// All four metrics in one row: with icons when they fit, text only when they don't – never cut off.
    private var metricPicker: some View {
        ViewThatFits(in: .horizontal) {
            metricRow(showIcons: true)
            metricRow(showIcons: false)
        }
        .padding(.vertical, 2)
    }

    private func metricRow(showIcons: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(MuscleMetric.allCases) { item in
                Button {
                    withAnimation(.snappy) { metric = item }
                } label: {
                    Group {
                        if showIcons {
                            Label(item.shortTitle, systemImage: item.symbol)
                        } else {
                            Text(item.shortTitle)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .foregroundStyle(metric == item ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .glassEffect(metric == item ? .regular.interactive() : .clear.interactive(), in: Capsule())
            }
        }
    }

    private func bucketChips(_ values: [MuscleValue]) -> some View {
        let buckets = bucketOrder
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", color: nil, isOn: bucketFilter == nil) { bucketFilter = nil }
                ForEach(buckets, id: \.self) { bucket in
                    let sample = values.first { $0.bucket == bucket }?.color
                    chip(bucket, color: sample ?? bucketColor(bucket), isOn: bucketFilter == bucket) {
                        bucketFilter = bucketFilter == bucket ? nil : bucket
                    }
                }
            }
        }
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
    }

    @ViewBuilder
    private var periodControl: some View {
        if metric == .freshness {
            HStack {
                Button { dayOffset += 1 } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                Spacer()
                Text(dayTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button { dayOffset = max(0, dayOffset - 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .disabled(dayOffset == 0)
            }
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button { offset += 1 } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                    Picker("Range", selection: $range) {
                        ForEach(MuscleRange.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Button { offset = max(0, offset - 1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .disabled(offset == 0)
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

    private var bucketOrder: [String] {
        switch metric {
        case .freshness: return ["Recovered", "Fatigued", "Depleted"]
        case .sets: return ["Below target", "In target", "Above target"]
        case .volume, .load: return ["Low", "Medium", "High"]
        }
    }

    private func bucketColor(_ bucket: String) -> Color {
        switch bucket {
        case "Recovered": return FreshnessStatus.recovered.color
        case "Fatigued": return FreshnessStatus.fatigued.color
        case "Depleted": return FreshnessStatus.depleted.color
        case "Below target", "Low": return MusclePalette.heat(0.2)
        case "In target", "Medium": return MusclePalette.heat(0.6)
        default: return MusclePalette.heat(1)
        }
    }

    private var footer: String {
        switch metric {
        case .freshness:
            return "Freshness estimates how recovered each muscle is from your logged sets (secondary muscles count half). It's calibrated after three recent workouts per muscle."
        case .sets:
            let target = store.profile.weeklySets
            return "Sets per week — your target is \(target.lowerBound)–\(target.upperBound) hard sets per muscle and week (\(store.profile.headline); change it in Settings → Your Profile). Secondary muscles count half a set."
        case .volume:
            return "Volume = reps × weight. Band and bodyweight sets add sets and load, not kilograms."
        case .load:
            return "Muscular load combines sets, set type and effort. The card above compares your last 7 days with your usual 6 weeks."
        }
    }

    private func computeValues() -> [MuscleValue] {
        let engine = analytics.engine
        switch metric {
        case .freshness:
            return engine.freshness(at: referenceDate).map { f in
                let trained = f.lastTrained != nil
                var subtitle = "\(f.status.displayName) · \(f.percent) %"
                if f.status != .recovered { subtitle += " · " + f.readyText }
                if f.isCalibrating { subtitle += " · calibrating" }
                return MuscleValue(
                    group: f.group,
                    level: trained ? f.freshness : 0,
                    // Lighter while the estimate is still calibrating.
                    color: trained ? f.status.color.opacity(f.isCalibrating ? 0.6 : 1) : MusclePalette.empty,
                    title: f.group.displayName,
                    subtitle: trained ? subtitle : "Not trained yet",
                    subtitleColor: trained ? f.status.color : .secondary,
                    bucket: f.status.displayName,
                    sortKey: trained ? f.freshness : 2
                )
            }
        case .sets:
            let totals = engine.totals(in: interval)
            let maxValue = max(1, totals.map(\.setsPerWeek).max() ?? 1)
            return totals.map { t in
                let target = store.profile.weeklySets
                let bucket = t.setsPerWeek < Double(target.lowerBound) ? "Below target" : (t.setsPerWeek <= Double(target.upperBound) ? "In target" : "Above target")
                return MuscleValue(
                    group: t.group, level: t.setsPerWeek / maxValue, color: MusclePalette.heat(t.setsPerWeek / maxValue),
                    title: t.group.displayName,
                    subtitle: "\(Format.number((t.sets * 10).rounded() / 10)) sets · \(Format.number((t.setsPerWeek * 10).rounded() / 10))/week",
                    subtitleColor: .secondary, bucket: bucket, sortKey: t.setsPerWeek
                )
            }
        case .volume:
            let totals = engine.totals(in: interval)
            let values = totals.map(\.volumeKg)
            let maxValue = max(1, values.max() ?? 1)
            return totals.map { t in
                MuscleValue(
                    group: t.group, level: t.volumeKg / maxValue, color: MusclePalette.heat(t.volumeKg / maxValue),
                    title: t.group.displayName,
                    subtitle: Format.volume(t.volumeKg, unit: store.unit) + " · \(t.sessions) workouts",
                    subtitleColor: .secondary, bucket: tercile(t.volumeKg, of: maxValue), sortKey: t.volumeKg
                )
            }
        case .load:
            let totals = engine.totals(in: interval)
            let maxValue = max(0.1, totals.map(\.load).max() ?? 1)
            return totals.map { t in
                let status = engine.loadSummary(group: t.group, days: 1).current.status
                return MuscleValue(
                    group: t.group, level: t.load / maxValue, color: MusclePalette.heat(t.load / maxValue),
                    title: t.group.displayName,
                    subtitle: "\(Int(t.load.rounded())) load · now \(status.displayName.lowercased())",
                    subtitleColor: status == .calibrating ? .secondary : status.color,
                    bucket: tercile(t.load, of: maxValue), sortKey: t.load
                )
            }
        }
    }

    private func tercile(_ value: Double, of maxValue: Double) -> String {
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
                    .lineLimit(1)
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
