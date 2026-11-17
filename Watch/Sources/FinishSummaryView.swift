import SwiftUI
import GeorgeCore

/// Shown after a workout was saved: time, sets, energy, heart rate, records and the streak.
struct FinishSummaryView: View {
    let summary: WatchFinishSummary
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                    Text(summary.title)
                        .font(.headline)
                        .lineLimit(2)

                    HStack(alignment: .top, spacing: 8) {
                        SummaryStat(symbol: "timer", tint: .yellow, value: Format.clock(Int(summary.durationSeconds.rounded())), caption: "Time")
                        SummaryStat(symbol: "checkmark.circle", tint: .green, value: "\(summary.completedSets)/\(summary.totalSets)", caption: "Sets")
                    }
                    if summary.energyKcal != nil || summary.averageHeartRate != nil {
                        HStack(alignment: .top, spacing: 8) {
                            if let kcal = summary.energyKcal, kcal > 0 {
                                SummaryStat(symbol: "flame.fill", tint: .orange, value: "\(Int(kcal.rounded()))", caption: "kcal")
                            }
                            if let heartRate = summary.averageHeartRate, heartRate > 0 {
                                SummaryStat(symbol: "heart.fill", tint: .red, value: "\(Int(heartRate.rounded()))", caption: "avg BPM")
                            }
                        }
                    }
                    if summary.records > 0 {
                        Label(summary.records == 1 ? "1 new record" : "\(summary.records) new records", systemImage: "trophy.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.yellow)
                    }
                    if let headline = summary.streakHeadline, !headline.isEmpty {
                        Label {
                            Text(headline)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "flame.fill").foregroundStyle(.orange)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    Button(action: onDone) {
                        Text("Done")
                    }
                    .buttonStyle(CapsuleButtonStyle(fill: .green, foreground: .black))
                    .handGestureShortcut(.primaryAction)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Summary")
        }
    }
}

private struct SummaryStat: View {
    let symbol: String
    let tint: Color
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(tint)
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
