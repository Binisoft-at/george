import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// Nil until the app has written its first snapshot.
    let snapshot: WidgetSnapshot?
}

/// Reads the app's snapshot. The app reloads the timelines when it changes; a second entry at
/// midnight moves "today" on the streak dots without the app.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snapshot: WidgetSnapshot = context.isPreview ? .placeholder : (WidgetBridge.read() ?? .placeholder)
        completion(SnapshotEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetBridge.read()
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        let entries = [SnapshotEntry(date: now, snapshot: snapshot), SnapshotEntry(date: tomorrow, snapshot: snapshot)]
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

// MARK: - Next workout

struct NextWorkoutWidget: Widget {
    static let kind = "NextWorkout"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            NextWorkoutView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Next Workout")
        .description("Your next workout and this week's training days.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct NextWorkoutView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var snapshot: WidgetSnapshot? { entry.snapshot }

    /// "Today" for a session planned for the snapshot's day, "In progress" while one runs.
    private var caption: String {
        if snapshot?.live != nil { return "In progress" }
        guard let next = snapshot?.next else { return "Next workout" }
        if next.isPlanned, let updated = snapshot?.updatedAt, Calendar.current.isDate(updated, inSameDayAs: entry.date) {
            return "Today"
        }
        return "Up next"
    }

    private var title: String {
        snapshot?.live?.title ?? snapshot?.next?.title ?? "No workout yet"
    }

    private var detail: String {
        if snapshot?.live != nil { return "Tap to continue" }
        if let next = snapshot?.next { return next.detail }
        return snapshot == nil ? "Open George to get started" : "Plan one in George"
    }

    private var symbol: String {
        snapshot?.live?.symbol ?? snapshot?.next?.symbol ?? "figure.strengthtraining.traditional"
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("\(caption): \(title)", systemImage: symbol)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label(caption, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .widgetAccentable()
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemMedium:
            HStack(alignment: .top, spacing: 16) {
                summary
                VStack(alignment: .trailing, spacing: 10) {
                    if snapshot?.next != nil || snapshot?.live != nil {
                        Button(intent: StartNextWorkoutIntent()) {
                            Label(snapshot?.live != nil ? "Open" : "Start", systemImage: "play.fill")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(WidgetStyle.accent)
                    }
                    Spacer(minLength: 0)
                    if let streak = snapshot?.streak {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(streak.weeks == 1 ? "1 week" : "\(streak.weeks) weeks")
                                .font(.headline)
                            Text("\(streak.doneDays) of \(streak.goal) this week")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        default:
            summary
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                KindBadge(symbol: symbol, size: 28)
                Text(caption.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(WidgetStyle.accent)
                    .widgetAccentable()
                    .lineLimit(1)
            }
            Text(title)
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            if let streak = snapshot?.streak {
                StreakDots(streak: streak, date: entry.date, showsLetters: false, dotSize: 9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Streak

struct StreakWidget: Widget {
    static let kind = "Streak"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            StreakView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Streak")
        .description("Your weekly streak and the days you trained this week.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct StreakView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var streak: WidgetSnapshot.Streak? { entry.snapshot?.streak }

    private var weeksText: String {
        guard let streak else { return "No streak yet" }
        return streak.weeks == 1 ? "1-week streak" : "\(streak.weeks)-week streak"
    }

    /// Days done this week (0 once the snapshot's week is over).
    private var doneDays: Int {
        guard let streak else { return 0 }
        return streak.todayIndex(on: entry.date) == nil ? 0 : streak.doneDays
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("\(weeksText) · \(doneDays)/\(streak?.goal ?? 0)", systemImage: "flame.fill")
        case .accessoryCircular:
            Gauge(value: Double(min(doneDays, max(1, streak?.goal ?? 1))), in: 0...Double(max(1, streak?.goal ?? 1))) {
                Image(systemName: "flame.fill")
            } currentValueLabel: {
                Text("\(streak?.weeks ?? 0)")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 3) {
                Label(weeksText, systemImage: "flame.fill")
                    .font(.headline)
                    .widgetAccentable()
                if let streak {
                    StreakDots(streak: streak, date: entry.date, showsLetters: false, dotSize: 8)
                    Text("\(doneDays) of \(streak.goal) days this week")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "flame.fill")
                        .font(.title3)
                        .foregroundStyle(WidgetStyle.accent)
                        .widgetAccentable()
                    Spacer()
                    Text("\(doneDays)/\(streak?.goal ?? 0)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(streak.map { "\($0.weeks)" } ?? "0")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                Text(streak?.weeks == 1 ? "week streak" : "weeks streak")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let streak {
                    StreakDots(streak: streak, date: entry.date)
                    Text(streak.todayIndex(on: entry.date) == nil ? "A new week" : streak.headline)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(entry.snapshot == nil ? "Open George to get started" : "Train to start a streak")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
