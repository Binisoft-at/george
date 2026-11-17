import SwiftUI
import BinisoftKit
import GeorgeCore

/// "Targets" (planned) or "Muscles worked" (performed) section for a workout or template,
/// with a readiness hint when targeted muscles are still recovering.
struct MuscleTargetsSection: View {
    let content: WorkoutContent
    let kind: WorkoutKind
    /// true: count completed sets only and skip the readiness hint.
    var performed = false
    @Environment(MuscleAnalytics.self) private var analytics

    var body: some View {
        let sets = analytics.plannedSets(content, completedOnly: performed, kind: kind)
        if !sets.isEmpty {
            Section {
                WorkoutMuscleMap(sets: sets, title: performed ? "Sets per muscle" : "Planned sets")
                if !performed {
                    ReadinessHint(fatigued: analytics.fatiguedTargets(of: content, kind: kind), readiness: analytics.readiness(of: content, kind: kind))
                }
            } header: {
                Text(performed ? "Muscles worked" : "Targets")
            } footer: {
                Text("Secondary muscles count half a set. Muscles come from the exercise library or the muscles you set on an exercise.")
            }
        } else if !MuscleEngine.countsAsHardSets(kind) {
            // Stretching, yoga, mobility and cardio: which muscles, not set counts.
            let muscles = analytics.plannedLoad(content, kind: kind)
                .filter { $0.value > 0 }
                .sorted { ($0.value, $1.key.displayName) > ($1.value, $0.key.displayName) }
                .prefix(6)
                .map { $0.key.displayName }
            if !muscles.isEmpty {
                Section {
                    Label("\(kind.isFlow ? "Stretches" : "Works"): \(muscles.joined(separator: ", "))", systemImage: kind.symbol)
                        .font(.subheadline)
                } header: {
                    Text(performed ? "Muscles worked" : "Targets")
                } footer: {
                    Text("\(kind.displayName) doesn't count as hard sets toward your weekly set targets – it adds a little load to the muscles it works.")
                }
            }
        }
    }
}

/// "Ready in ~14 h · Lower Back, Hamstrings" – the time first, then which muscles.
struct ReadinessHint: View {
    let fatigued: [MuscleFreshness]
    let readiness: Double
    var compact = false

    var body: some View {
        if fatigued.isEmpty {
            Label("Target muscles are recovered", systemImage: FreshnessStatus.recovered.symbol)
                .font(compact ? .caption : .subheadline)
                .foregroundStyle(FreshnessStatus.recovered.textColor)
        } else {
            let worst = fatigued[0]
            // The muscle that needs longest decides when the workout is fully ready.
            let slowest = fatigued.max { $0.hoursUntilRecovered < $1.hoursUntilRecovered } ?? worst
            if compact {
                Label {
                    Text("\(slowest.readyText) · \(fatigued.prefix(3).map(\.group.displayName).joined(separator: ", "))")
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: worst.status.symbol)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(worst.status.textColor)
                .accessibilityLabel("Muscles \(Int((readiness * 100).rounded())) % ready. \(slowest.readyText): \(fatigued.prefix(3).map(\.group.displayName).joined(separator: ", "))")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(slowest.readyText) · muscles \(Int((readiness * 100).rounded())) % ready", systemImage: worst.status.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(worst.status.textColor)
                    Text(fatigued.prefix(3).map { "\($0.group.displayName) \($0.percent) %" }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}
