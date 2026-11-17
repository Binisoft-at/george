import SwiftUI
import WidgetKit

/// The watch-face complication (and Smart Stack card): the rest countdown during a workout,
/// otherwise the next workout and this week's training days. Reads what the watch app writes
/// (ComplicationBridge).
@main
struct GeorgeWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        GeorgeComplication()
    }
}

struct ComplicationEntry: TimelineEntry {
    let date: Date
    let data: ComplicationData?

    /// The rest still runs at this entry's date.
    var restInterval: ClosedRange<Date>? {
        guard let live = data?.live, !live.isPaused, let interval = live.restInterval, interval.upperBound > date else { return nil }
        return interval
    }
}

struct ComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry {
        ComplicationEntry(date: Date(), data: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        let data: ComplicationData = context.isPreview ? .placeholder : (ComplicationBridge.read() ?? .placeholder)
        completion(ComplicationEntry(date: Date(), data: data))
    }

    /// Now, the moment the rest ends ("Go"), and midnight (a new day for the plan and the streak).
    /// The watch app reloads the timeline whenever the workout changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        let now = Date()
        let data = ComplicationBridge.read()
        var entries = [ComplicationEntry(date: now, data: data)]
        if let end = data?.live?.restEndsAt, end > now {
            entries.append(ComplicationEntry(date: end, data: data))
        }
        let calendar = Calendar.current
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           tomorrow > (entries.last?.date ?? now) {
            entries.append(ComplicationEntry(date: tomorrow, data: data))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct GeorgeComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ComplicationBridge.kind, provider: ComplicationProvider()) { entry in
            ComplicationView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("George")
        .description("Your rest countdown during a workout, otherwise your next workout.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ComplicationEntry

    private var live: ComplicationData.Live? { entry.data?.live }
    private var next: ComplicationData.Next? { entry.data?.next }

    private var symbol: String {
        live?.symbol ?? next?.symbol ?? "figure.strengthtraining.traditional"
    }

    /// What's due in a running workout ("Squat"), else its title.
    private var liveLine: String {
        guard let live else { return "" }
        return live.exercise.isEmpty ? live.title : live.exercise
    }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryCorner: corner
        default: inline
        }
    }

    // MARK: Circular

    @ViewBuilder private var circular: some View {
        if let interval = entry.restInterval {
            ProgressView(timerInterval: interval, countsDown: true) {
                Image(systemName: "timer")
            } currentValueLabel: {
                Text(timerInterval: interval, countsDown: true)
                    .monospacedDigit()
            }
            .progressViewStyle(.circular)
            .widgetAccentable()
        } else if let live {
            Gauge(value: Double(live.completedSets), in: 0...Double(max(1, live.totalSets))) {
                Image(systemName: symbol)
            } currentValueLabel: {
                Image(systemName: live.isPaused ? "pause.fill" : symbol)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        } else if let data = entry.data, data.goal > 0 {
            Gauge(value: Double(min(data.doneDays, data.goal)), in: 0...Double(data.goal)) {
                Image(systemName: "flame.fill")
            } currentValueLabel: {
                Image(systemName: symbol)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: symbol)
                    .font(.title3)
                    .widgetAccentable()
            }
        }
    }

    // MARK: Rectangular

    @ViewBuilder private var rectangular: some View {
        if let live {
            VStack(alignment: .leading, spacing: 1) {
                if let interval = entry.restInterval {
                    HStack(spacing: 4) {
                        Image(systemName: "timer")
                        Text("Rest")
                        Text(timerInterval: interval, countsDown: true)
                            .monospacedDigit()
                    }
                    .font(.headline)
                    .widgetAccentable()
                } else {
                    Label(live.isPaused ? "Paused" : (live.restEndsAt != nil ? "Go" : "Now"),
                          systemImage: live.isPaused ? "pause.fill" : symbol)
                        .font(.headline)
                        .widgetAccentable()
                }
                Text(liveLine)
                    .font(.body)
                    .lineLimit(1)
                Text("\(live.completedSets) of \(live.totalSets) sets")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Label(next?.isToday == true ? "Today" : "Next workout", systemImage: symbol)
                    .font(.headline)
                    .widgetAccentable()
                    .lineLimit(1)
                Text(next?.title ?? "Open George on your iPhone")
                    .font(.body)
                    .lineLimit(1)
                if let data = entry.data, data.goal > 0 {
                    Text("\(data.doneDays) of \(data.goal) days · \(data.streakWeeks)-week streak")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let detail = next?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Inline and corner

    @ViewBuilder private var inline: some View {
        if let interval = entry.restInterval {
            Label {
                Text(timerInterval: interval, countsDown: true)
            } icon: {
                Image(systemName: "timer")
            }
        } else if live != nil {
            Label(liveLine, systemImage: symbol)
        } else {
            Label(next?.title ?? "George", systemImage: symbol)
        }
    }

    @ViewBuilder private var corner: some View {
        if let interval = entry.restInterval {
            Image(systemName: "timer")
                .font(.title3)
                .widgetAccentable()
                .widgetLabel {
                    ProgressView(timerInterval: interval, countsDown: true) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                }
        } else {
            Image(systemName: symbol)
                .font(.title3)
                .widgetAccentable()
                .widgetLabel {
                    Text(live != nil ? liveLine : (next?.title ?? "George"))
                }
        }
    }
}
