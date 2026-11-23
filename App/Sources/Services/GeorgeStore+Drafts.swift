import Foundation
import SwiftData
import BinisoftKit
import GeorgeCore

// Empty drafts and the calories shown for a workout.

extension WorkoutTemplate {
    /// Something to train: exercises – or at least weekdays or notes (tennis needs no exercises). A
    /// template just created and left empty is not suggested, planned or offered on Today.
    var isPlannable: Bool {
        exerciseCount > 0 || !scheduleRaw.isEmpty || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension WorkoutSession {
    /// Nothing in it yet: no exercises, notes or focus line.
    var isEmptyDraft: Bool {
        exerciseCount == 0
            && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension GeorgeStore {
    // MARK: Empty drafts

    /// A planned workout with nothing in it (an empty workout nobody filled in): not "Planned
    /// today", not "Missed", not Up next. One from a template that is plannable stays (tennis).
    func isBlankPlan(_ session: WorkoutSession) -> Bool {
        guard session.status == .planned, session.isEmptyDraft else { return false }
        guard let templateID = session.templateID else { return true }
        return self.template(id: templateID)?.isPlannable != true
    }

    /// "New Empty Workout" left without adding anything (no exercises, notes, focus line or own
    /// title): it goes again instead of waiting as an empty planned workout. True when deleted.
    @discardableResult
    func discardIfEmptyDraft(sessionID: UUID) -> Bool {
        guard let session = self.session(id: sessionID), session.status == .planned, session.isEmptyDraft,
              isAutoTitle(session) || session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        AppLog.info("Empty new workout removed", category: "store")
        saveWithoutUndo(bumping: true) {
            context.delete(session)
        }
        return true
    }

    // MARK: Calories

    /// Measured calories from Apple Health for a session on this device (Watch-recorded workouts) –
    /// none when kept for one part of a workout continued and ended later (`keptNumbersCover`).
    func measuredEnergy(for session: WorkoutSession) -> Double? {
        let values: [UUID: (kcal: Double, keptAt: Date)]
        if let cache = measuredEnergyCache, cache.revision == revision {
            values = cache.values
        } else {
            let metrics = (try? context.fetch(FetchDescriptor<HealthMetrics>())) ?? []
            var fetched: [UUID: (kcal: Double, keptAt: Date)] = [:]
            for metric in metrics where metric.activeEnergyKcal > 0 {
                fetched[metric.sessionID] = (kcal: metric.activeEnergyKcal, keptAt: metric.updatedAt)
            }
            measuredEnergyCache = (revision: revision, values: fetched)
            values = fetched
        }
        guard let kept = values[session.id],
              MeasuredNumbers.keptNumbersCover(workoutEnd: session.endedAt, keptAt: kept.keptAt) else { return nil }
        return kept.kcal
    }

    /// What to show for a workout's calories: measured on this device when there is a value, else
    /// George's estimate (its text starts with "≈"). Measured values never sync (docs/HEALTH.md).
    func displayEnergy(for session: WorkoutSession) -> EnergyDisplay? {
        EnergyDisplay.choose(measured: measuredEnergy(for: session), estimated: session.energyKcal)
    }

    /// The heart rate and calories this device keeps for a workout (`HealthMetrics`): nil without;
    /// none (empty) when kept for one part only – continued after "stopped early" and ended later,
    /// on another device or from outside – so one part's numbers never stand for the whole workout.
    func measuredNumbers(for session: WorkoutSession) -> MeasuredNumbers? {
        healthMetrics(for: session.id).map { measuredNumbers($0, for: session) }
    }

    /// `kept`'s numbers as `session` shows them (`measuredNumbers(for:)`).
    func measuredNumbers(_ kept: HealthMetrics, for session: WorkoutSession) -> MeasuredNumbers {
        MeasuredNumbers(averageHeartRate: kept.averageHeartRate, maxHeartRate: kept.maxHeartRate, activeEnergy: kept.activeEnergyKcal)
            .shown(workoutEnd: session.endedAt, keptAt: kept.updatedAt)
    }
}
