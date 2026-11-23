import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The running workout on the Lock Screen and in the Dynamic Island: what's due now, set n of m,
/// the rest or hold countdown, and the buttons (Start/Done, +15 s, Skip rest). The buttons run
/// their intents in the app (LiveActivityIntent), which updates the activity.
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activitySystemActionForegroundColor(WidgetStyle.accent)
        } dynamicIsland: { context in
            let state = context.state
            let attributes = context.attributes
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 4) {
                        KindBadge(symbol: attributes.symbol, size: 30)
                        if !state.allSetsDone, state.setCount > 0 {
                            Text("\(state.setNumber)/\(state.setCount)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LiveCountdown(state: state, isStale: context.isStale, style: .expanded)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(state.allSetsDone ? "All sets done" : state.exercise)
                            .font(.headline)
                            .lineLimit(1)
                        Text(LiveText.subline(state, title: attributes.title))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LiveActions(state: state, isStale: context.isStale)
                        .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: attributes.symbol)
                    .foregroundStyle(WidgetStyle.accent)
            } compactTrailing: {
                LiveCountdown(state: state, isStale: context.isStale, style: .compact)
            } minimal: {
                LiveMinimal(state: state, symbol: attributes.symbol, isStale: context.isStale)
            }
            .keylineTint(WidgetStyle.accent)
        }
    }
}

/// Lines shared by the Lock Screen and the Dynamic Island.
enum LiveText {
    /// "Set 2 of 4 · 8 × 60 kg", or the workout's progress once everything is done.
    static func subline(_ state: WorkoutActivityAttributes.ContentState, title: String) -> String {
        if state.allSetsDone { return "\(title) · \(state.completedSets) of \(state.totalSets) sets" }
        return [state.setPosition, state.setLine].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Lock Screen

struct WorkoutLockScreenView: View {
    let attributes: WorkoutActivityAttributes
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                KindBadge(symbol: attributes.symbol, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attributes.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(state.allSetsDone ? "All sets done" : state.exercise)
                        .font(.headline)
                        .lineLimit(1)
                    let subline = LiveText.subline(state, title: attributes.title)
                    if !subline.isEmpty, !state.allSetsDone {
                        Text(subline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                LiveCountdown(state: state, isStale: isStale, style: .large)
            }
            LiveProgress(state: state, isStale: isStale)
            LiveActions(state: state, isStale: isStale)
        }
        .padding(16)
    }
}

/// The rest or hold countdown, "Paused", "Go", or the sets done.
struct LiveCountdown: View {
    enum Style { case large, expanded, compact }

    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool
    let style: Style

    var body: some View {
        if state.isPaused {
            switch style {
            case .compact:
                Image(systemName: "pause.fill").foregroundStyle(WidgetStyle.accent)
            case .large, .expanded:
                Label("Paused", systemImage: "pause.fill")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        } else if let countdown = state.countdown, !isStale {
            switch style {
            case .compact:
                Text(timerInterval: countdown.interval, countsDown: true)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 46)
                    .foregroundStyle(WidgetStyle.accent)
            case .large, .expanded:
                VStack(alignment: .trailing, spacing: 0) {
                    Text(countdown.isRest ? "Rest" : state.holdCaption)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(timerInterval: countdown.interval, countsDown: true)
                        .font(style == .large ? .title.weight(.semibold) : .title2.weight(.semibold))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: style == .large ? 96 : 76, alignment: .trailing)
                        .foregroundStyle(WidgetStyle.accent)
                }
            }
        } else if isStale, state.restEndsAt != nil {
            // The rest ran out before the app could update: the set is due.
            switch style {
            case .compact:
                Text("Go").font(.headline).foregroundStyle(WidgetStyle.accent)
            case .large, .expanded:
                VStack(alignment: .trailing, spacing: 0) {
                    Text("Rest over")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Go")
                        .font(style == .large ? .title.weight(.bold) : .title2.weight(.bold))
                        .foregroundStyle(WidgetStyle.accent)
                }
            }
        } else {
            switch style {
            case .compact:
                Text("\(state.completedSets)/\(state.totalSets)")
                    .monospacedDigit()
                    .foregroundStyle(WidgetStyle.accent)
            case .large, .expanded:
                VStack(alignment: .trailing, spacing: 0) {
                    Text("Sets")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(state.completedSets)/\(state.totalSets)")
                        .font(style == .large ? .title.weight(.semibold) : .title2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(WidgetStyle.accent)
                }
            }
        }
    }
}

/// The countdown as a draining bar, otherwise the workout's progress.
struct LiveProgress: View {
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let countdown = state.countdown, !isStale, !state.isPaused {
                ProgressView(timerInterval: countdown.interval, countsDown: true) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: state.workoutProgress)
            }
            Text("\(state.completedSets) of \(state.totalSets) sets done")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .tint(WidgetStyle.accent)
    }
}

/// +15 s and Skip while resting, and the big Start/Done button.
struct LiveActions: View {
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 8) {
            if state.isResting, !state.isPaused, !isStale {
                Button(intent: AddRestIntent(seconds: 15)) {
                    Label("15 s", systemImage: "plus")
                }
                .accessibilityLabel("Add 15 seconds of rest")
                Button(intent: SkipRestIntent()) {
                    Label("Skip", systemImage: "forward.end.fill")
                }
                .accessibilityLabel("Skip rest")
            }
            Spacer(minLength: 0)
            if state.isPaused {
                // Paused: the big button resumes – it never logs a set.
                Button(intent: ResumeWorkoutIntent()) {
                    Label(state.primaryLabel, systemImage: state.primarySymbol)
                        .font(.headline)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(WidgetStyle.accent)
                .accessibilityLabel("Resume the workout")
            } else if !state.allSetsDone {
                Button(intent: SetActionIntent()) {
                    Label(state.primaryLabel, systemImage: state.primarySymbol)
                        .font(.headline)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(WidgetStyle.accent)
            } else {
                Text("Finish in George")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .tint(WidgetStyle.accent)
        .labelStyle(.titleAndIcon)
    }
}

/// The smallest Dynamic Island: a draining ring while a countdown runs, else the kind's symbol.
struct LiveMinimal: View {
    let state: WorkoutActivityAttributes.ContentState
    let symbol: String
    let isStale: Bool

    var body: some View {
        if let countdown = state.countdown, !isStale, !state.isPaused {
            ProgressView(timerInterval: countdown.interval, countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                Image(systemName: countdown.isRest ? "timer" : "stopwatch")
                    .font(.system(size: 9, weight: .bold))
            }
            .progressViewStyle(.circular)
            .tint(WidgetStyle.accent)
        } else {
            Image(systemName: state.isPaused ? "pause.fill" : symbol)
                .foregroundStyle(WidgetStyle.accent)
        }
    }
}
