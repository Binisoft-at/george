import SwiftUI
import BinisoftKit
import SwiftData
import Charts
import GeorgeCore

extension GeorgeStore {
    func fetchEnergy() -> [EnergyCheckIn] {
        (try? context.fetch(FetchDescriptor<EnergyCheckIn>(sortBy: [SortDescriptor(\.date)]))) ?? []
    }

    /// Today's "how's your energy" answer – one per day, a new answer replaces it.
    func logEnergyToday(_ level: Int) {
        let calendar = Calendar.current
        if let existing = fetchEnergy().last(where: { $0.source == "today" && calendar.isDateInToday($0.date) }) {
            existing.level = level
            existing.date = Date()
        } else {
            context.insert(EnergyCheckIn(level: level, source: "today"))
        }
        save()
        AppLog.info("Energy logged: \(level)", category: "energy")
    }

    /// Comparable workouts for the energy ↔ performance link.
    func performanceSamples() -> [PerformanceSample] {
        fetchSessions().filter { $0.status.isPerformed && $0.setCount > 0 }.map {
            PerformanceSample(date: $0.date, group: $0.templateID?.uuidString ?? $0.title,
                              volumeKg: $0.volumeKg, completion: Double($0.doneSetCount) / Double(max(1, $0.setCount)))
        }
    }
}

/// Insights → Energy: how energy goes over the weeks, the best and worst weekdays, a rhythm if
/// there is one, and how energy goes with your workouts, sleep and HRV.
struct EnergyView: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(HealthKitManager.self) private var health
    @Query(sort: \EnergyCheckIn.date) private var checkIns: [EnergyCheckIn]
    @AppStorage(Prefs.healthSignals) private var healthSignals = true
    @AppStorage(Prefs.useStateOfMind) private var useStateOfMind = false
    /// State of Mind entries from Apple Health – in memory only, never stored or synced.
    @State private var moods: [EnergyEntry] = []
    @State private var moodMessage: String?
    @State private var isLoadingMoods = false

    var body: some View {
        let _ = store.revision
        let calendar = store.calendar
        let entries = mergedEntries(calendar: calendar)
        let performance = EnergyAnalysis.relativePerformance(store.performanceSamples())
        let insights = EnergyAnalysis.analyze(entries: entries, performance: performance, calendar: calendar)

        List {
            Section {
                EnergyTodayCard(compact: false)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }

            if entries.isEmpty {
                Section {
                    MessageView(title: "No check-ins yet", systemImage: "battery.50percent",
                                message: "Tap how you feel above – once a day, or answer the question before a workout. After a few weeks George shows your patterns and looks for a rhythm.")
                }
            } else {
                Section {
                    EnergyWeeksChart(weeks: Array(insights.weeks.suffix(12)))
                        .frame(height: 170)
                        .padding(.vertical, 6)
                    if let trend = insights.trendPerWeek, abs(trend) >= 0.1 {
                        Label(trend > 0 ? "Trending up over the last weeks" : "Trending down over the last weeks",
                              systemImage: trend > 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.subheadline)
                            .foregroundStyle(trend > 0 ? .green : .orange)
                    }
                } header: {
                    Text("Weekly Average")
                } footer: {
                    Text("\(insights.daysLogged) days with a check-in in the last 6 months.")
                }

                rhythmSection(insights)
                patternSection(insights, entries: entries)
            }

            healthSection(entries: entries)
        }
        .groupedList()
        .navigationTitle("Energy")
        .task {
            guard !LaunchOptions.current.isDemo else { return }
            if healthSignals, health.healthSignals.isEmpty {
                await health.loadSignals()
            }
            if useStateOfMind { await loadMoods() }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func rhythmSection(_ insights: EnergyInsights) -> some View {
        Section {
            if let cycle = insights.cycle {
                HStack(spacing: 14) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.title)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("About every \(cycle.periodDays) days")
                            .font(.headline)
                        Text("A \(cycle.strengthText) rhythm in your energy.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let low = cycle.nextLow, low > Date() {
                            Text("Next low expected around \(low.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))) – a good time for a lighter week.")
                                .font(.subheadline)
                        }
                    }
                }
                .padding(.vertical, 4)
            } else if let needMore = insights.needMoreData {
                VStack(alignment: .leading, spacing: 8) {
                    Text(needMore)
                        .font(.subheadline)
                    ProgressBar(progress: Double(insights.daysLogged) / Double(EnergyAnalysis.minimumDays))
                }
                .padding(.vertical, 4)
            } else {
                Label("No repeating rhythm so far – your energy doesn't follow a fixed cycle.", systemImage: "checkmark.circle")
                    .font(.subheadline)
            }
        } header: {
            Text("Rhythm")
        } footer: {
            Text("George compares your daily energy with itself shifted by 5–40 days. Only a clear match over at least two full cycles counts as a rhythm.")
        }
    }

    @ViewBuilder
    private func patternSection(_ insights: EnergyInsights, entries: [EnergyEntry]) -> some View {
        let symbols = Calendar.current.weekdaySymbols
        Section("Patterns") {
            if let best = insights.bestWeekday, let lowest = insights.lowestWeekday {
                LabeledContent {
                    Text(symbols[best - 1])
                } label: {
                    Label("Best day", systemImage: "sun.max.fill")
                }
                LabeledContent {
                    Text(symbols[lowest - 1])
                } label: {
                    Label("Lowest day", systemImage: "moon.zzz.fill")
                }
                WeekdayEnergyChart(averages: insights.weekdayAverages, firstWeekday: store.calendar.firstWeekday)
                    .frame(height: 110)
            } else {
                Text("No clear weekday pattern yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let r = insights.performanceCorrelation {
                correlationRow(r, symbol: "dumbbell.fill",
                               positive: "On high-energy days your workouts go better than usual.",
                               negative: "Interesting: your workouts go well even on low-energy days.",
                               none: "Your workouts go about the same whatever your energy – consistency wins.")
            } else {
                Text("After 8 workouts with a check-in George shows how energy and performance go together.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func healthSection(entries: [EnergyEntry]) -> some View {
        Section {
            Toggle(isOn: $healthSignals) {
                Label("Use Health signals", systemImage: "heart.text.square.fill")
            }
            .onChange(of: healthSignals) { _, on in
                Task { await health.loadSignals() }
                if !on { health.readiness = nil }
            }
            if healthSignals {
                if let readiness = health.readiness {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(readiness.headline).font(.subheadline.weight(.semibold))
                        Text(readiness.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                let calendar = store.calendar
                let sleep = health.healthSignals.compactMap { s in s.sleepHours.map { (date: s.day, value: $0) } }
                let hrv = health.healthSignals.compactMap { s in s.hrvMs.map { (date: s.day, value: $0) } }
                if let r = EnergyAnalysis.correlation(entries: entries, series: sleep, calendar: calendar) {
                    correlationRow(r, symbol: "bed.double.fill",
                                   positive: "More sleep, more energy – your check-ins follow your sleep.",
                                   negative: "Your energy doesn't follow your sleep the way you'd expect.",
                                   none: "Sleep and energy don't line up much for you.")
                }
                if let r = EnergyAnalysis.correlation(entries: entries, series: hrv, calendar: calendar) {
                    correlationRow(r, symbol: "waveform.path.ecg",
                                   positive: "Higher HRV mornings come with more energy – HRV is a good early hint for you.",
                                   negative: "Your energy moves against your HRV – it's not a reliable hint for you.",
                                   none: "HRV and energy don't line up much for you.")
                }
                if health.isAvailable {
                    Toggle(isOn: $useStateOfMind) {
                        Label(isLoadingMoods ? "Reading moods…" : "Include moods from Health (State of Mind)", systemImage: "face.smiling")
                    }
                    .onChange(of: useStateOfMind) { _, on in
                        if on { Task { await loadMoods() } } else { moods = []; moodMessage = nil }
                    }
                    Button {
                        Task {
                            await health.requestAuthorization()
                            await health.loadSignals()
                        }
                    } label: {
                        Label("Review Apple Health Access", systemImage: "lock.shield")
                    }
                }
                if let moodMessage {
                    Text(moodMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Apple Health")
        } footer: {
            Text("HRV, resting heart rate and sleep from your Apple Watch say how recovered you are – George shows it in the check-in and compares it with your answers. Moods you logged in the Health app (State of Mind) can fill in days without a check-in – read when you open this page, never stored. Health data never goes to iCloud.")
        }
    }

    private func correlationRow(_ r: Double, symbol: String, positive: String, negative: String, none: String) -> some View {
        let word = EnergyAnalysis.strengthWord(r)
        return Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(word == nil ? none : (r > 0 ? positive : negative))
                    .font(.subheadline)
                if let word {
                    Text("\(word.capitalized) link (r = \(Format.number((r * 100).rounded() / 100)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
        }
    }

    /// Check-ins, plus Health moods for days without a check-in.
    private func mergedEntries(calendar: Calendar) -> [EnergyEntry] {
        let own = checkIns.map { EnergyEntry(date: $0.date, level: $0.level) }
        guard useStateOfMind, !moods.isEmpty else { return own }
        let ownDays = Set(own.map { calendar.startOfDay(for: $0.date) })
        return own + moods.filter { !ownDays.contains(calendar.startOfDay(for: $0.date)) }
    }

    private func loadMoods() async {
        isLoadingMoods = true
        defer { isLoadingMoods = false }
        moods = await health.moodHistory()
        moodMessage = moods.isEmpty
            ? "No State of Mind entries in Apple Health (or access not allowed – see Review Apple Health Access)."
            : "\(moods.count) moods from Apple Health included."
        AppLog.info("State of Mind: \(moods.count) entries read", category: "energy")
    }
}

/// Today: how's your energy? One tap, changeable all day. Shows the Health hint when there is one.
struct EnergyTodayCard: View {
    var compact = true
    @Environment(GeorgeStore.self) private var store
    @Environment(HealthKitManager.self) private var health
    @Environment(Router.self) private var router
    @Query(sort: \EnergyCheckIn.date, order: .reverse) private var recent: [EnergyCheckIn]

    var body: some View {
        let today = recent.first { $0.source != "health" && Calendar.current.isDateInToday($0.date) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(today == nil ? "How's your energy today?" : "Energy today: \(EnergyEntry.label(for: today!.level))",
                      systemImage: EnergyEntry.symbol(for: today?.level ?? 3))
                    .font(.headline)
                    .foregroundStyle(today.map { EnergyPicker.color(for: $0.level) } ?? Color.primary)
                Spacer()
                if compact {
                    Button {
                        router.insights = .energy
                        router.show(.energy)
                    } label: {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Energy insights")
                }
            }
            if let readiness = health.readiness, CoachPrefs.healthSignals {
                Label("\(readiness.headline) – \(readiness.summary)", systemImage: "heart.text.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            EnergyPicker(selected: today?.level) { level in
                withAnimation(.snappy) { store.logEnergyToday(level) }
                Haptics.success()
            }
        }
        .padding(compact ? 14 : 4)
        .modifier(CardIf(enabled: compact))
    }
}

private struct CardIf: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.card(padding: 0, cornerRadius: 20) } else { content }
    }
}

/// Weekly average energy (1–5) as bars coloured by level.
struct EnergyWeeksChart: View {
    let weeks: [EnergyWeek]

    var body: some View {
        Chart(weeks) { week in
            BarMark(
                x: .value("Week", week.weekStart, unit: .weekOfYear),
                y: .value("Energy", week.average)
            )
            .foregroundStyle(EnergyPicker.color(for: Int(week.average.rounded())).gradient)
            .cornerRadius(4)
        }
        .chartYScale(domain: 0...5)
        .chartYAxis {
            AxisMarks(values: [1.0, 3.0, 5.0]) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel {
                    if let level = value.as(Double.self) { Text(EnergyEntry.label(for: Int(level.rounded()))) }
                }
            }
        }
    }
}

/// Average energy per weekday, in the order the week starts.
struct WeekdayEnergyChart: View {
    let averages: [Int: Double]
    let firstWeekday: Int

    var body: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let order = (0..<7).map { (firstWeekday - 1 + $0) % 7 + 1 }
        Chart(order, id: \.self) { weekday in
            BarMark(
                x: .value("Day", "\(order.firstIndex(of: weekday) ?? 0)\(symbols[weekday - 1])"),
                y: .value("Energy", averages[weekday] ?? 0)
            )
            .foregroundStyle(EnergyPicker.color(for: Int((averages[weekday] ?? 0).rounded())).opacity(averages[weekday] == nil ? 0.2 : 1))
            .cornerRadius(3)
        }
        .chartYScale(domain: 0...5)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let text = value.as(String.self) { Text(String(text.dropFirst())) }
                }
            }
        }
    }
}
