import Foundation
import BinisoftKit
import GeorgeCore
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

/// Mirrors the running workout to the Lock Screen / Dynamic Island (Live Activity) and keeps the
/// Home Screen widgets current. The controller calls `start`, `update` and `end` with the same
/// state it sends to the watch.
///
/// Countdowns are dates the system animates by itself, so the activity is only updated when its
/// content really changes (a set logged, a rest started or extended, pause/resume).
@MainActor
final class LiveActivityBridge {
    static let shared = LiveActivityBridge()

    /// Screenshot and demo runs never touch the Lock Screen or the widgets.
    private let isEnabled = !LaunchOptions.current.isDemo
    /// The session the widgets were last refreshed for (nil: none running).
    private var widgetSessionID: UUID?
    private var widgetRefresh: Task<Void, Never>?

    #if os(iOS) && canImport(ActivityKit)
    private var activity: Activity<WorkoutActivityAttributes>?
    private var lastContent: WorkoutActivityAttributes.ContentState?
    /// Updates run one after the other, so an older state never overtakes a newer one.
    private var updateChain: Task<Void, Never>?
    /// The user swiped the activity away: don't bring it back for this workout.
    private var dismissedSessionID: UUID?
    /// Requests fail while the app is in the background (e.g. a start from the watch); retry later.
    private var lastFailedRequest: Date?
    #endif

    func start(_ state: WatchLiveState?) {
        guard isEnabled, let state else { return }
        #if os(iOS) && canImport(ActivityKit)
        lastFailedRequest = nil
        show(state)
        #endif
        widgetSessionID = state.sessionID
        refreshWidgetsSoon()
    }

    func update(_ state: WatchLiveState?) {
        guard isEnabled, let state else { return }
        #if os(iOS) && canImport(ActivityKit)
        show(state)
        #endif
        if widgetSessionID != state.sessionID {
            widgetSessionID = state.sessionID
            refreshWidgetsSoon()
        }
    }

    func end(_ state: WatchLiveState?) {
        guard isEnabled else { return }
        #if os(iOS) && canImport(ActivityKit)
        endAllActivities()
        dismissedSessionID = nil
        lastFailedRequest = nil
        #endif
        widgetSessionID = nil
        refreshWidgetsSoon()
    }

    /// Called with each fresh app snapshot (WidgetBridge.write): with no workout running, an
    /// activity left over from an earlier run (app killed mid-workout) goes away.
    func reconcile(hasLiveWorkout: Bool) {
        guard isEnabled, !hasLiveWorkout else { return }
        #if os(iOS) && canImport(ActivityKit)
        if activity != nil || !Activity<WorkoutActivityAttributes>.activities.isEmpty {
            endAllActivities()
        }
        #endif
    }

    // MARK: Widgets

    /// Rebuilds the widget snapshot once the current change has settled (after `end`, the
    /// controller first detaches and saves – the snapshot must see that).
    private func refreshWidgetsSoon() {
        widgetRefresh?.cancel()
        widgetRefresh = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, let live = GeorgeIntents.live else { return }
            WidgetBridge.write(snapshot: live.makeSnapshot())
        }
    }

    // MARK: Live Activity

    #if os(iOS) && canImport(ActivityKit)
    private func show(_ state: WatchLiveState) {
        let content = Self.content(for: state)
        if let activity, activity.attributes.sessionID == state.sessionID, isRunning(activity) {
            guard content != lastContent else { return }
            lastContent = content
            enqueue { await activity.update(ActivityContent(state: content, staleDate: content.staleDate)) }
            return
        }
        if let activity, activity.attributes.sessionID == state.sessionID, activity.activityState == .dismissed {
            dismissedSessionID = state.sessionID
        }
        activity = nil
        lastContent = nil
        guard dismissedSessionID != state.sessionID else { return }

        // Relaunched mid-workout: take the activity that's already on the Lock Screen.
        let existing = Activity<WorkoutActivityAttributes>.activities
        if let match = existing.first(where: { $0.attributes.sessionID == state.sessionID && isRunning($0) }) {
            activity = match
            lastContent = content
            enqueue { await match.update(ActivityContent(state: content, staleDate: content.staleDate)) }
        }
        let others = existing.filter { $0.id != activity?.id }
        if !others.isEmpty {
            enqueue {
                for other in others { await other.end(nil, dismissalPolicy: .immediate) }
            }
        }
        guard activity == nil else { return }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let lastFailedRequest, Date().timeIntervalSince(lastFailedRequest) < 30 { return }
        let attributes = WorkoutActivityAttributes(sessionID: state.sessionID, title: state.title, symbol: state.kind.symbol)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: content, staleDate: content.staleDate),
                pushType: nil
            )
            lastContent = content
            lastFailedRequest = nil
            AppLog.info("Live Activity started", category: "live-activity")
        } catch {
            lastFailedRequest = Date()
            AppLog.notice("Live Activity not started: \(error.localizedDescription)", category: "live-activity")
        }
    }

    private func endAllActivities() {
        let all = Activity<WorkoutActivityAttributes>.activities
        activity = nil
        lastContent = nil
        guard !all.isEmpty else { return }
        enqueue {
            for item in all { await item.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func isRunning(_ activity: Activity<WorkoutActivityAttributes>) -> Bool {
        activity.activityState == .active || activity.activityState == .stale
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = updateChain
        updateChain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// The watch state boiled down to what the Lock Screen shows.
    static func content(for state: WatchLiveState) -> WorkoutActivityAttributes.ContentState {
        let current = state.current
        let isTimed = current?.set.isTimed == true

        var restStart: Date?
        var restEnd: Date?
        if !state.isPaused, let end = state.restEndsAt {
            restEnd = end
            restStart = end.addingTimeInterval(-Double(max(1, state.restTotalSeconds ?? 0)))
        }

        var holdStart: Date?
        var holdEnd: Date?
        var holdSide: Int?
        if !state.isPaused, restEnd == nil, isTimed, let started = state.setStartedAt,
           let seconds = state.timedSetSeconds, seconds > 0 {
            if let side = state.holdSide(at: Date()) {
                // "30 s each side": the side that's running counts down (the app updates at the switch).
                holdStart = side.start
                holdEnd = side.end
                holdSide = side.number
            } else {
                holdStart = started
                holdEnd = started.addingTimeInterval(Double(seconds))
            }
        }

        // Same rule as LiveWorkoutController.primaryIsStart: Start while the set waits (Start button
        // on, or a hold), otherwise Done.
        let waiting = state.restEndsAt != nil || state.setStartedAt == nil
        let primaryIsStart = current != nil && waiting && ((state.usesStartButton ?? true) || isTimed)

        let line = current?.set.label ?? ""
        return WorkoutActivityAttributes.ContentState(
            exercise: current?.exercise.name ?? "",
            setLine: line == "—" ? "" : line,
            setNumber: current?.number ?? 0,
            setCount: current?.of ?? 0,
            completedSets: state.completedSets,
            totalSets: state.totalSets,
            restStartedAt: restStart,
            restEndsAt: restEnd,
            holdStartedAt: holdStart,
            holdEndsAt: holdEnd,
            isPaused: state.isPaused,
            primaryIsStart: primaryIsStart,
            holdSide: holdSide
        )
    }
    #endif
}
