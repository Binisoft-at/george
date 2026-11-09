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
        let sets = analytics.plannedSets(content, completedOnly: performed)
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
        }
    }
}

/// "Muscles ready 76 % — Chest 52 % (ready in ~10 h)…"
struct ReadinessHint: View {
    let fatigued: [MuscleFreshness]
    let readiness: Double
    var compact = false

    var body: some View {
        if fatigued.isEmpty {
            Label("Target muscles are recovered", systemImage: "checkmark.circle.fill")
                .font(compact ? .caption : .subheadline)
                .foregroundStyle(FreshnessStatus.recovered.color)
        } else {
            let worst = fatigued[0]
            let names = fatigued.prefix(3).map { "\($0.group.displayName) \($0.percent) %" }.joined(separator: " · ")
            VStack(alignment: .leading, spacing: 4) {
                Label("Muscles \(Int((readiness * 100).rounded())) % ready", systemImage: worst.status == .depleted ? "exclamationmark.triangle.fill" : "hourglass")
                    .font((compact ? Font.caption : .subheadline).weight(.semibold))
                    .foregroundStyle(worst.status.color)
                Text("\(names) — \(worst.readyText.lowercased())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 1 : 2)
            }
        }
    }
}
