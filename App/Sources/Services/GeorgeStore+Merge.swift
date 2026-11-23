import Foundation
import SwiftData
import BinisoftKit
import GeorgeCore

/// Records two devices created before they synced. iCloud (CloudKit) can't keep anything unique, so
/// a new Mac and the iPhone may each make settings, an exercise's personal notes, a break week or the
/// "Stretch & Yoga" folder. They are merged here – at launch and after every iCloud import – the
/// same way on every device, so all devices end up with the same single record.
extension GeorgeStore {
    func resolveDuplicates() {
        var merged: [String] = []
        // Merging isn't something ⌘Z should take back.
        saveWithoutUndo(bumping: false) {
            if mergeSettingsCopies() { merged.append("settings") }
            if mergeUserExerciseCopies() { merged.append("exercise notes") }
            if mergeExcusedWeekCopies() { merged.append("break weeks") }
            if mergeRoutinePrograms() { merged.append("Stretch & Yoga") }
        }
        guard !merged.isEmpty else { return }
        bump()
        AppLog.info("Merged copies from two devices: \(merged.joined(separator: ", "))", category: "sync")
    }

    // MARK: Settings

    /// The oldest record stays; it takes the values of the copy changed last (fresh defaults a new
    /// device made before its first sync never win over settings someone chose).
    private func mergeSettingsCopies() -> Bool {
        let all = (try? context.fetch(FetchDescriptor<SyncedSettings>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        guard all.count > 1,
              let plan = DuplicateMerge.plan(all.map { DuplicateMerge.Stamp(createdAt: $0.createdAt, updatedAt: $0.updatedAt) }) else { return false }
        let keep = all[plan.keep]
        if plan.source != plan.keep {
            copySettings(from: all[plan.source], to: keep)
        }
        for (index, extra) in all.enumerated() where index != plan.keep {
            context.delete(extra)
        }
        forgetCachedSettings()
        return true
    }

    /// Each setting from the copy changed last, unless it still has the default there and the older
    /// copy chose something: a new Mac that only picked a program before its first sync doesn't reset
    /// the iPhone's goal, units or profile.
    private func copySettings(from source: SyncedSettings, to target: SyncedSettings) {
        // Never inserted: only read for the defaults.
        let defaults = SyncedSettings()
        func pick<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<SyncedSettings, T>) {
            target[keyPath: keyPath] = DuplicateMerge.pick(source[keyPath: keyPath], over: target[keyPath: keyPath], default: defaults[keyPath: keyPath])
        }
        // The goal and its history belong together.
        if source.goalHistoryData != nil || source.weeklyGoal != defaults.weeklyGoal {
            target.weeklyGoal = source.weeklyGoal
            target.goalHistoryData = source.goalHistoryData ?? target.goalHistoryData
        }
        pick(\.unitRaw)
        pick(\.defaultRestSeconds)
        pick(\.namingPattern)
        // A device without programs yet has no active one: the other device's choice stays.
        target.activeProgramID = source.activeProgramID ?? target.activeProgramID
        pick(\.autoUseSaves)
        pick(\.rescueCountsDouble)
        pick(\.rescueMinutes)
        pick(\.minimumMinutes)
        pick(\.countHealthWorkouts)
        pick(\.saveToHealth)
        pick(\.bodyMassKg)
        pick(\.weekStartsOn)
        pick(\.prefillFromLastTime)
        pick(\.askToUpdateTemplate)
        pick(\.birthYear)
        pick(\.experienceRaw)
        pick(\.goalRaw)
        target.updatedAt = max(source.updatedAt, target.updatedAt)
    }

    // MARK: Exercise notes and links

    /// One record per exercise: notes joined when they differ, links combined, a favourite on either
    /// device stays a favourite, everything else from the copy changed last.
    private func mergeUserExerciseCopies() -> Bool {
        let all = (try? context.fetch(FetchDescriptor<UserExercise>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let groups = DuplicateMerge.groups(all.map(\.key))
        guard !groups.isEmpty else { return false }
        for group in groups {
            let copies = group.map { all[$0] }
            guard let plan = DuplicateMerge.plan(copies.map { DuplicateMerge.Stamp(createdAt: $0.createdAt, updatedAt: $0.updatedAt) }) else { continue }
            let keep = copies[plan.keep]
            let newest = copies.max { $0.updatedAt < $1.updatedAt } ?? keep
            let notes = DuplicateMerge.joinedNotes(copies.map(\.notes))
            let links = DuplicateMerge.unionLinks(copies.map(\.links))
            let favorite = copies.contains(where: \.isFavorite)
            let updated = newest.updatedAt
            if newest !== keep {
                if !newest.name.isEmpty { keep.name = newest.name }
                keep.kindRaw = newest.kindRaw
                keep.modeRaw = newest.modeRaw
                if !newest.musclesRaw.isEmpty { keep.musclesRaw = newest.musclesRaw }
                if !newest.equipment.isEmpty { keep.equipment = newest.equipment }
                if !newest.instructions.isEmpty { keep.instructions = newest.instructions }
                if !newest.imageURL.isEmpty { keep.imageURL = newest.imageURL }
                keep.isCustom = newest.isCustom
                keep.perSide = newest.perSide
            }
            keep.notes = notes
            keep.linksRaw = links.joined(separator: "\n")
            keep.isFavorite = favorite
            keep.updatedAt = updated
            for copy in copies where copy !== keep {
                context.delete(copy)
            }
        }
        return true
    }

    // MARK: Break weeks

    /// One break per week (two devices may each have marked it).
    private func mergeExcusedWeekCopies() -> Bool {
        let all = (try? context.fetch(FetchDescriptor<ExcusedWeek>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let cal = calendar
        let groups = DuplicateMerge.groups(all.map { cal.weekStart(for: $0.weekStart) })
        guard !groups.isEmpty else { return false }
        for group in groups {
            let copies = group.map { all[$0] }
            guard let keep = copies.first else { continue }
            if keep.reason.isEmpty, let reason = copies.first(where: { !$0.reason.isEmpty })?.reason {
                keep.reason = reason
            }
            for copy in copies.dropFirst() {
                context.delete(copy)
            }
        }
        return true
    }

    // MARK: "Stretch & Yoga"

    /// The routines folder made on two devices: its templates move into the oldest copy (a routine
    /// both added stays once, its workouts point at that one), and the other copies go.
    private func mergeRoutinePrograms() -> Bool {
        let copies = fetchPrograms().filter { isRoutineProgram($0) }.sorted { $0.createdAt < $1.createdAt }
        guard copies.count > 1, let keep = copies.first else { return false }
        var kept = keep.orderedTemplates
        let sessions = fetchSessions()
        for other in copies.dropFirst() {
            for template in other.orderedTemplates {
                if let same = kept.first(where: { $0.name == template.name }) {
                    for session in sessions where session.templateID == template.id {
                        session.templateID = same.id
                    }
                    context.delete(template)
                } else {
                    template.program = keep
                    kept.append(template)
                }
            }
            for session in other.allSessions {
                session.program = keep
            }
            if settings.activeProgramID == other.id {
                settings.activeProgramID = keep.id
            }
            // The moves are saved first, so deleting the empty copy can't take its old templates
            // (cascade) or workouts (nullify) with it.
            try? context.save()
            context.delete(other)
        }
        keep.touch()
        return true
    }
}

extension UserExercise {
    /// The record to show for an exercise while two devices' copies aren't merged yet: the one with
    /// notes or links, then the one changed last.
    static func preferred(_ entries: [UserExercise], key: String) -> UserExercise? {
        entries.filter { $0.key == key }.max { lhs, rhs in
            let lhsHasContent = !lhs.notes.isEmpty || !lhs.linksRaw.isEmpty
            let rhsHasContent = !rhs.notes.isEmpty || !rhs.linksRaw.isEmpty
            if lhsHasContent != rhsHasContent { return rhsHasContent }
            return lhs.updatedAt < rhs.updatedAt
        }
    }
}
