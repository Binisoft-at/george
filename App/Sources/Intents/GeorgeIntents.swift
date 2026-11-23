import Foundation
import AppIntents
import BinisoftKit
import GeorgeCore

/// Where App Intents (Siri, Shortcuts, the Action Button, Control Center, Live Activity and widget
/// buttons) reach the running app. GeorgeApp registers its store and live controller at launch –
/// also when the system launches George in the background just to run an intent.
@MainActor
enum GeorgeIntents {
    private(set) static var store: GeorgeStore?
    private(set) static var live: LiveWorkoutController?

    static func register(store: GeorgeStore, live: LiveWorkoutController) {
        self.store = store
        self.live = live
        WorkoutIntentRelay.handler = { action in try GeorgeIntents.handle(action) }
        // Siri learns the template names for "Start <template> in George" (refreshed again when
        // they change, see WidgetBridge.write).
        GeorgeShortcuts.updateAppShortcutParameters()
    }

    /// The controller, with a workout that was running when the app was closed attached again.
    private static func liveController() throws -> (LiveWorkoutController, GeorgeStore) {
        guard let store, let live else { throw GeorgeIntentError.notReady }
        if !live.isActive { live.restore() }
        return (live, store)
    }

    private static func handle(_ action: WorkoutIntentAction) throws -> String {
        let (live, store) = try liveController()
        switch action {
        case .startNext:
            if live.isActive {
                live.isPresented = true
                return "Your workout is already running."
            }
            guard let next = store.nextWorkout() else {
                // Nothing planned: an empty workout, like "Start Suggested Workout" in the menu.
                live.requestStart(.empty(program: store.activeProgram, kind: nil, rescue: false))
                return "Starting an empty workout."
            }
            switch next {
            case .planned(let session): live.requestStart(.session(session))
            case .template(let template): live.requestStart(.template(template))
            }
            return "Starting \(next.title)."

        case .primary:
            guard live.isActive else { throw GeorgeIntentError.noWorkout }
            // Paused: the big button carries on (as in the app) – it never logs a set then.
            if live.isPaused {
                live.primaryAction()
                return "Workout resumed."
            }
            guard live.currentSet != nil || live.content.nextPendingSet() != nil else {
                return "Every set is done. Finish the workout in George."
            }
            let wasStart = live.primaryIsStart
            live.primaryAction()
            return wasStart ? startedMessage(live) : loggedMessage(live)

        case .addRest(let seconds):
            guard live.isActive else { throw GeorgeIntentError.noWorkout }
            live.perform(.addRest(seconds))
            return "Rest is \(seconds) seconds longer."

        case .skipRest:
            guard live.isActive else { throw GeorgeIntentError.noWorkout }
            guard live.restEndsAt != nil else { return "You're not resting right now." }
            live.perform(.skipRest)
            return live.currentItem.map { "Rest skipped. Up now: \($0.name)." } ?? "Rest skipped."

        case .pause:
            guard live.isActive else { throw GeorgeIntentError.noWorkout }
            guard !live.isPaused else { return "Your workout is already paused." }
            live.perform(.pause)
            return "Workout paused."

        case .resume:
            guard live.isActive else { throw GeorgeIntentError.noWorkout }
            guard live.isPaused else { return "Your workout is already running." }
            live.perform(.resume)
            return "Workout resumed."
        }
    }

    private static func startedMessage(_ live: LiveWorkoutController) -> String {
        guard let item = live.currentItem else { return "Go." }
        return "Go: \(item.name)."
    }

    private static func loggedMessage(_ live: LiveWorkoutController) -> String {
        guard let item = live.currentItem, live.currentSet?.isDone == false else {
            return "Set done. That was the last one – finish the workout in George."
        }
        let rest = live.restRemaining()
        if rest > 0 { return "Set done. Rest \(rest) seconds, then \(item.name)." }
        return "Set done. Next: \(item.name)."
    }
}

// MARK: - Templates

/// A workout template, for "Start <template> in George" and the Shortcuts app.
struct TemplateEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Workout"
    static let defaultQuery = TemplateQuery()

    var id: UUID
    var name: String
    var detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)")
    }

    @MainActor
    init(_ template: WorkoutTemplate) {
        id = template.id
        name = template.name
        detail = TemplateEntity.detail(exercises: template.exerciseCount, minutes: template.estimatedMinutes, program: template.program?.name)
    }

    static func detail(exercises: Int, minutes: Int, program: String?) -> String {
        var parts: [String] = []
        if exercises > 0 { parts.append("\(exercises) exercise\(exercises == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) min") }
        if let program, !program.isEmpty { parts.append(program) }
        return parts.joined(separator: " · ")
    }
}

struct TemplateQuery: EntityStringQuery {
    init() {}

    func entities(for identifiers: [UUID]) async throws -> [TemplateEntity] {
        await MainActor.run {
            identifiers.compactMap { id in GeorgeIntents.store?.template(id: id).map(TemplateEntity.init) }
        }
    }

    func entities(matching string: String) async throws -> [TemplateEntity] {
        await MainActor.run {
            TemplateQuery.all().filter { $0.name.localizedCaseInsensitiveContains(string) }
        }
    }

    func suggestedEntities() async throws -> [TemplateEntity] {
        await MainActor.run { TemplateQuery.all() }
    }

    /// The active program's templates first (in its order), then the others by last use.
    @MainActor
    static func all() -> [TemplateEntity] {
        guard let store = GeorgeIntents.store else { return [] }
        let program = store.activeProgram
        let ordered = program?.orderedTemplates ?? []
        let others = store.fetchTemplates()
            .filter { $0.program?.id != program?.id && $0.program?.isArchived != true }
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
        return (ordered + others).prefix(30).map(TemplateEntity.init)
    }
}

/// "Start UPPER in George".
struct StartTemplateIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Workout"
    static let description = IntentDescription("Starts one of your workout templates.")
    static let openAppWhenRun = true

    @Parameter(title: "Workout")
    var template: TemplateEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$template)")
    }

    init() {}

    init(template: TemplateEntity) {
        self.template = template
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let store = GeorgeIntents.store, let live = GeorgeIntents.live else { throw GeorgeIntentError.notReady }
        guard let found = store.template(id: template.id) else { throw GeorgeIntentError.templateNotFound }
        if !live.isActive { live.restore() }
        let wasActive = live.isActive
        live.requestStart(store.startTarget(for: found))
        if wasActive {
            return .result(dialog: "Another workout is running. Choose in George what to do with it.")
        }
        return .result(dialog: "Starting \(found.name).")
    }
}

// MARK: - Siri and Shortcuts

/// Phrases for Siri, Spotlight and the Action Button (English only: the project has no
/// localized string catalogs yet).
struct GeorgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartNextWorkoutIntent(),
            phrases: [
                "Start my workout in \(.applicationName)",
                "Start my next workout in \(.applicationName)",
                "Start a workout with \(.applicationName)",
                "Let's train with \(.applicationName)",
            ],
            shortTitle: "Start Workout",
            systemImageName: "figure.strengthtraining.traditional"
        )
        AppShortcut(
            intent: StartTemplateIntent(),
            phrases: [
                "Start \(\.$template) in \(.applicationName)",
                "Start \(\.$template) with \(.applicationName)",
            ],
            shortTitle: "Start a Template",
            systemImageName: "list.bullet.rectangle"
        )
        AppShortcut(
            intent: SetActionIntent(),
            phrases: [
                "Next set in \(.applicationName)",
                "Set done in \(.applicationName)",
                "Start my set in \(.applicationName)",
            ],
            shortTitle: "Next Set",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: AddRestIntent(),
            phrases: [
                "More rest in \(.applicationName)",
                "Add rest in \(.applicationName)",
            ],
            shortTitle: "Add Rest",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: SkipRestIntent(),
            phrases: [
                "Skip rest in \(.applicationName)",
                "Skip my rest in \(.applicationName)",
            ],
            shortTitle: "Skip Rest",
            systemImageName: "forward.end"
        )
        AppShortcut(
            intent: PauseWorkoutIntent(),
            phrases: [
                "Pause my workout in \(.applicationName)",
                "Pause \(.applicationName)",
            ],
            shortTitle: "Pause Workout",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: ResumeWorkoutIntent(),
            phrases: [
                "Resume my workout in \(.applicationName)",
                "Continue my workout in \(.applicationName)",
            ],
            shortTitle: "Resume Workout",
            systemImageName: "play.circle"
        )
    }
}

// MARK: - Widgets

extension WidgetBridge {
    @MainActor private static var shortcutTemplatesKey: [String] = []

    /// Writes the Home Screen widgets' snapshot from the controller's snapshot (`makeSnapshot()`) plus
    /// the store's "next workout", reloading the widgets only when something changed. Also refreshes
    /// Siri's list of template names when templates changed, and clears a Live Activity left over from
    /// an earlier run when no workout is running. Cheap enough to call on every `syncWatch()`.
    @MainActor
    static func write(snapshot: WatchSnapshot) {
        // Screenshot and demo runs keep the real widgets as they are.
        guard !LaunchOptions.current.isDemo else { return }
        let store = GeorgeIntents.store
        let streak = snapshot.streak.map { streak in
            WidgetSnapshot.Streak(
                weeks: streak.weeks, doneDays: streak.doneDays, goal: streak.goal, headline: streak.headline,
                dots: streak.dots, weekStart: streak.weekStart ?? (store?.calendar ?? .current).weekStart(for: Date())
            )
        }
        let live = snapshot.live.map { WidgetSnapshot.Live(title: $0.title, symbol: $0.kind.symbol) }
        let next = store.flatMap(nextWorkout(in:)) ?? nextWorkout(from: snapshot)
        publish(WidgetSnapshot(next: next, streak: streak, live: live, updatedAt: snapshot.generatedAt))

        LiveActivityBridge.shared.reconcile(hasLiveWorkout: snapshot.live != nil)

        let templatesKey = snapshot.templates.map { "\($0.id)\($0.name)" }
        if templatesKey != shortcutTemplatesKey {
            shortcutTemplatesKey = templatesKey
            GeorgeShortcuts.updateAppShortcutParameters()
        }
    }

    /// Same as "Start my workout": today's planned session, otherwise the program's suggestion.
    @MainActor
    private static func nextWorkout(in store: GeorgeStore) -> WidgetSnapshot.Workout? {
        guard let next = store.nextWorkout() else { return nil }
        switch next {
        case .planned(let session):
            let minutes = Int((WorkoutPace.plannedSeconds(of: session.content, defaultRest: store.settings.defaultRestSeconds) / 60).rounded())
            return WidgetSnapshot.Workout(
                title: next.title,
                detail: TemplateEntity.detail(exercises: session.exerciseCount, minutes: minutes, program: nil),
                symbol: session.kind.symbol, isPlanned: true, programName: session.program?.name ?? "",
                plannedDay: store.calendar.startOfDay(for: store.plannedDay(of: session))
            )
        case .template(let template):
            return WidgetSnapshot.Workout(
                title: template.name,
                detail: TemplateEntity.detail(exercises: template.exerciseCount, minutes: template.estimatedMinutes, program: nil),
                symbol: template.kind.symbol, isPlanned: false, programName: template.program?.name ?? ""
            )
        }
    }

    /// Without the store (never in practice): the suggested template of the snapshot.
    private static func nextWorkout(from snapshot: WatchSnapshot) -> WidgetSnapshot.Workout? {
        guard let template = snapshot.templates.first(where: \.isSuggested) ?? snapshot.templates.first else { return nil }
        return WidgetSnapshot.Workout(
            title: template.name,
            detail: TemplateEntity.detail(exercises: template.exerciseCount, minutes: template.estimatedMinutes, program: nil),
            symbol: template.kind.symbol, isPlanned: false, programName: template.programName
        )
    }
}
