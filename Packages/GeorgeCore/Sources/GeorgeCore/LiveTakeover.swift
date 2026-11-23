import Foundation

/// Discard on a device that took the running workout over ("Continue Here"). How the workout looked
/// before its Start (`LiveResume.PreStart` in the app) is kept only on the device that started it,
/// so this device goes by the synced session: a workout saved before keeps that part, a planned one
/// goes back to the plan, and only one made by that Start is deleted.
public enum TakenOverDiscard {
    public enum Outcome: Equatable, Sendable {
        /// Made by the Start (a template or an empty workout): deleted, with Undo.
        case delete
        /// Planned before the Start: back to the plan, its ticks taken back.
        case backToPlan
        /// Saved before ("stopped early", then continued): what was saved stays, the sets ticked
        /// after `endedAt` (since continuing) are taken back.
        case keepEarlierPart(endedAt: Date)
    }

    /// A session made this close to its start was made by that Start.
    public static let madeByStartWithin: TimeInterval = 120

    /// - Parameters:
    ///   - endedAt: when the session ended before (a running workout only has one when it was saved
    ///     before and continued: Start never sets it, and clears it for a planned one).
    public static func outcome(createdAt: Date, startedAt: Date?, endedAt: Date?, now: Date = Date()) -> Outcome {
        if let endedAt { return .keepEarlierPart(endedAt: endedAt) }
        if createdAt < (startedAt ?? now).addingTimeInterval(-madeByStartWithin) { return .backToPlan }
        return .delete
    }

    /// The earlier part as it is kept: complete (every set done, or no sets at all: "just track
    /// time") or stopped early.
    public static func earlierPartIsComplete(_ content: WorkoutContent) -> Bool {
        content.totalSets == 0 || content.isComplete
    }

    /// The earlier part's active time: never more than it spanned (time logged after continuing,
    /// a pause on the way, is taken off that way).
    public static func earlierActiveSeconds(accumulated: Double, startedAt: Date?, endedAt: Date) -> Double {
        guard let startedAt else { return max(0, accumulated) }
        return max(0, min(accumulated, endedAt.timeIntervalSince(startedAt)))
    }
}

extension WorkoutContent {
    /// The sets ticked after `date` (every ticked set when nil) taken back: not done, no tick or
    /// start time. The numbers typed stay. A ticked set without a time counts as ticked before.
    public func takingBackSets(doneAfter date: Date?) -> WorkoutContent {
        var result = self
        for b in result.blocks.indices {
            for i in result.blocks[b].items.indices {
                for s in result.blocks[b].items[i].sets.indices {
                    let set = result.blocks[b].items[i].sets[s]
                    guard set.isDone else { continue }
                    if let date {
                        guard let doneAt = set.doneAt, doneAt > date else { continue }
                    }
                    result.blocks[b].items[i].sets[s].isDone = false
                    result.blocks[b].items[i].sets[s].doneAt = nil
                    result.blocks[b].items[i].sets[s].startedAt = nil
                }
            }
        }
        return result
    }
}

extension FinishTime {
    /// Where a workout in progress ends when it is ended from outside, without a finish sheet
    /// (another device's "Start … Anyway", Mark As): as the finish sheet would by default – at the
    /// last set + rest once nothing happened for `offerAfter` (with a set done) – otherwise now,
    /// or the last set + rest when a strength workout's clock ran past its limit (`resolvedEnd`).
    /// `clock` is the session's synced clock (another device's pause time isn't known).
    public static func endFromOutside(clock: LiveClock, kind: WorkoutKind, content: WorkoutContent,
                                      restSeconds: Double, now: Date) -> Date {
        let last = RunningWorkout.lastActivity(startedAt: clock.startedAt, resumedAt: clock.resumedAt, content: content)
        let suggested = content.completedSets > 0
            ? last.map { suggestedEnd(lastActivity: $0, restSeconds: restSeconds, pausedAt: clock.pausedAt, now: now) }
            : nil
        if let suggested, idleSeconds(lastActivity: last, pausedAt: clock.pausedAt, now: now) > offerAfter {
            return clamp(suggested, startedAt: clock.startedAt, now: now)
        }
        return resolvedEnd(requested: nil, chosen: false, clock: clock, kind: kind, suggestedEnd: suggested,
                           lastActivity: last, now: now)
    }
}
