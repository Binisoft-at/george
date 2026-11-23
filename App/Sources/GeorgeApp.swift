import SwiftUI
import SwiftData
import UserNotifications
import BinisoftKit
import GeorgeCore

@main
struct GeorgeApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MainWindowGuard.self) private var windowGuard
    #endif
    @State private var store: GeorgeStore
    @State private var library: ExerciseLibrary
    @State private var health: HealthKitManager
    @State private var watch: PhoneWatchConnector
    @State private var live: LiveWorkoutController
    @State private var muscles: MuscleAnalytics
    @State private var sync: SyncMonitor
    /// Bumps the store revision after iCloud imports so analytics refresh.
    @State private var importRefresher: CloudImportRefresher
    /// Finished workouts for Thalia (shared App Group, this device; docs/THALIA.md).
    @State private var thalia: ThaliaSync
    @State private var toasts = ToastCenter()
    @State private var router = Router()

    let container: ModelContainer
    let mode: StorageMode
    private let launch = LaunchOptions.current
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppLog.bootstrap(appName: AppInfo.name)
        BinisoftTips.configure()
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        let opened = Persistence.open()
        container = opened.container
        mode = opened.mode
        let store = GeorgeStore(container: opened.container)
        let library = ExerciseLibrary()
        let health = HealthKitManager()
        let watch = PhoneWatchConnector()
        _store = State(initialValue: store)
        _library = State(initialValue: library)
        _health = State(initialValue: health)
        _watch = State(initialValue: watch)
        let live = LiveWorkoutController(store: store, health: health, watch: watch, library: library)
        _live = State(initialValue: live)
        // Siri, Shortcuts, widgets and Live Activity buttons reach the app through here.
        GeorgeIntents.register(store: store, live: live)
        // The watch link and the running workout come up at launch, not with the window: when iOS
        // launches George in the background (a watch message, or iOS ended it mid-workout) there may
        // be no window, and the watch's Start/Done must not be lost. The workout is attached on the
        // first main-actor turn, once the app object exists.
        if !LaunchOptions.current.isDemo {
            watch.activate()
            Task { @MainActor in live.restore() }
        }
        // A training reminder's "Start Workout" button.
        NotificationDelegate.registerCategories()
        NotificationDelegate.shared.onStartNextWorkout = { [store, live] in
            switch store.nextWorkout() {
            case .planned(let session): live.requestStart(.session(session))
            case .template(let template): live.requestStart(.template(template))
            case nil: live.requestStart(.empty(program: store.activeProgram, kind: nil, rescue: false))
            }
        }
        _muscles = State(initialValue: MuscleAnalytics(store: store, library: library, health: health))
        _importRefresher = State(initialValue: CloudImportRefresher(store: store))
        _sync = State(initialValue: SyncMonitor(mode: opened.mode, appName: AppInfo.name))
        // Writes nothing for -Demo, previews or an in-memory store; the first sync runs a few seconds after launch.
        let thalia = ThaliaSync(store: store, mode: opened.mode, launch: LaunchOptions.current)
        _thalia = State(initialValue: thalia)
        thalia.start()
        AppLog.info("Launch \(AppVersion.main.display), storage: \(opened.mode.title)", category: "app")
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                // Inside the environment below (it reads the store): reschedules training reminders.
                .reminderScheduling()
                .environment(store)
                .environment(library)
                .environment(health)
                .environment(watch)
                .environment(live)
                .environment(muscles)
                .environment(sync)
                .environment(thalia)
                .environment(toasts)
                .environment(router)
                .appearanceFromSettings()
                #if os(iOS)
                .toasts(toasts, bottomPadding: 120)
                #else
                .toasts(toasts, bottomPadding: 24)
                // A CSV opened from Finder goes to the open window – not a second window whose sheets
                // would show twice (the router is shared).
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                #endif
                .undoableChanges(in: container.mainContext)
                .task {
                    if !launch.isDemo {
                        // Normally done at launch already (see init); both do nothing the second time.
                        live.restore()
                        watch.activate()
                    }
                    // The exercise catalog (1.5 MB) and Apple Health load side by side.
                    async let healthLoaded: Void = loadHealth()
                    await library.load()
                    router.applyLaunchOptions(launch, store: store, live: live)
                    guard !launch.isDemo else {
                        health.healthSignals = DemoData.healthSignals(calendar: store.calendar)
                        health.readiness = BodyReadiness.evaluate(health.healthSignals, calendar: store.calendar)
                        return
                    }
                    await healthLoaded
                    live.syncWatch()
                    // The weekly automatic backup (Documents/Backups), once the launch work is done.
                    try? await Task.sleep(for: .seconds(8))
                    store.backUpIfDue()
                }
                // A value typed a moment ago and where the live workout stands are saved before the app
                // goes to the background.
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { live.saveState() }
                    // Back in the app: a match recorded on the watch since then counts toward streak and
                    // load (at most every ten minutes).
                    if phase == .active, !launch.isDemo, health.isAvailable, UserDefaults.standard.bool(forKey: Prefs.healthAsked) {
                        Task {
                            let before = health.workoutsVersion
                            await health.refreshIfStale()
                            if health.workoutsVersion != before { live.syncWatch() }
                        }
                    }
                    // Planning and template edits reach the widgets when leaving the app.
                    if phase == .background { WidgetBridge.write(snapshot: live.makeSnapshot()) }
                }
        }
        .modelContainer(container)
        #if os(macOS)
        .defaultSize(width: 1200, height: 780)
        .windowToolbarStyle(.unified)
        // macOS may otherwise finish launching without the main window (see MainWindowGuard).
        .defaultLaunchBehavior(.presented)
        #endif
        .commands {
            GeorgeCommands(router: router, live: live)
            // View → Show/Hide Sidebar, Customize Toolbar.
            SidebarCommands()
            ToolbarCommands()
        }

        #if os(macOS)
        // Live mode in a window of its own (LiveWindow.swift), so the main window stays usable while
        // logging. Opened by the main window or the Workout menu – never at launch on its own, never
        // restored with the other windows, and not listed in the Window menu while nothing runs.
        Window("Workout", id: LiveWindow.id) {
            LiveWindowRoot()
                .environment(store)
                .environment(library)
                .environment(health)
                .environment(watch)
                .environment(live)
                .environment(muscles)
                .environment(sync)
                .environment(thalia)
                .environment(toasts)
                .environment(router)
                .modelContainer(container)
                .appearanceFromSettings()
        }
        .defaultSize(width: 860, height: 840)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Settings {
            NavigationStack {
                SettingsView()
            }
            .frame(minWidth: 520, minHeight: 600)
            .environment(store)
            .environment(library)
            .environment(health)
            .environment(watch)
            .environment(live)
            .environment(muscles)
            .environment(sync)
            .environment(thalia)
            .environment(toasts)
            .environment(router)
            .modelContainer(container)
            .appearanceFromSettings()
        }
        #endif
    }

    /// Apple Health at launch: other apps' workouts (streak, load), the recovery signals, body mass.
    private func loadHealth() async {
        guard !launch.isDemo, health.isAvailable, UserDefaults.standard.bool(forKey: Prefs.healthAsked) else { return }
        await health.refreshIfStale()
        await health.loadSignals()
        store.healthBodyMassKg = health.latestBodyMassKg
    }
}

/// Menu bar commands and keyboard shortcuts (Mac, iPad with keyboard).
struct GeorgeCommands: Commands {
    let router: Router
    let live: LiveWorkoutController
    /// The template or workout shown in the detail: ⌘↩ starts that one ("Start UPPER").
    @FocusedValue(\.startTarget) private var startTarget

    /// One meaning for ⌘↩, said in the menu: show the running workout, start what's shown, or the
    /// suggested workout.
    private var startTitle: String {
        if live.isActive { return "Show Live Workout" }
        return startTarget?.title ?? "Start Suggested Workout"
    }

    private func startFromMenu() {
        if live.isActive {
            // Shows the running workout (on the Mac `LiveMenuButton` also brings its window forward).
            live.isPresented = true
        } else if let startTarget {
            startTarget.perform()
        } else {
            router.request(.startSuggested)
        }
    }

    var body: some Commands {
        // File, Go and Help show things in the main window – on the Mac it opens again first when it
        // was closed (the workout window can stay open without it).
        CommandGroup(replacing: .newItem) {
            MainWindowMenuButton(title: "Create…", router: router, shortcut: KeyboardShortcut("n", modifiers: .command)) {
                router.request(.create)
            }
            MainWindowMenuButton(title: "New Empty Workout", router: router) { router.request(.newSession) }
            MainWindowMenuButton(title: "New Template", router: router, shortcut: KeyboardShortcut("n", modifiers: [.command, .option])) {
                router.request(.newTemplate)
            }
            MainWindowMenuButton(title: "New Program", router: router, shortcut: KeyboardShortcut("n", modifiers: [.command, .shift])) {
                router.request(.newProgram)
            }
            Divider()
            MainWindowMenuButton(title: "Import CSV…", router: router, shortcut: KeyboardShortcut("i", modifiers: .command)) {
                router.request(.importCSV)
            }
        }
        CommandMenu("Workout") {
            LiveMenuButton(title: startTitle, shortcut: KeyboardShortcut(.return, modifiers: .command), showsLive: live.isActive) {
                startFromMenu()
            }
            .disabled(!live.isActive && startTarget?.isEnabled == false)
            Button(live.isPaused ? "Resume Workout" : (live.primaryIsStart ? "Start Set" : "Complete Set")) { live.primaryAction() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(!live.isActive || live.currentSet == nil)
            Button(live.isPaused ? "Resume" : "Pause") { live.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!live.isActive)
            Divider()
            Button("Add 15 s Rest") { live.addRest(15) }
                .keyboardShortcut("=", modifiers: [.command, .shift])
                .disabled(!live.isActive)
            Button("Skip Rest") { live.skipRest() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(live.restEndsAt == nil)
            Button("Next Exercise") { live.moveThread(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!live.isActive)
            Button("Previous Exercise") { live.moveThread(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!live.isActive)
            Button(live.isVoiceMuted ? "Unmute Voice" : "Mute Voice") { live.toggleVoiceMute() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!live.isActive)
            Divider()
            // These open in live mode (its window on the Mac, brought forward even when it is behind).
            LiveMenuButton(title: "Add Exercise…", shortcut: KeyboardShortcut("a", modifiers: [.command, .shift])) {
                live.isPresented = true
                live.requestAddExercise = true
            }
            .disabled(!live.isActive)
            LiveMenuButton(title: "Finish Workout…", shortcut: KeyboardShortcut("f", modifiers: [.command, .shift])) {
                live.isPresented = true
                live.finishRequest = true
            }
            .disabled(!live.isActive)
            LiveMenuButton(title: "Discard Workout…") {
                live.isPresented = true
                live.discardRequest = true
            }
            .disabled(!live.isActive)
        }
        CommandMenu("Go") {
            goItem("Today", "1", .today)
            goItem("Workouts", "2", .allSessions)
            goItem("Templates", "3", .templates)
            goItem("Muscles", "4", .muscles)
            goItem("Stats & Records", "5", .stats)
            goItem("Energy", "6", .energy)
            goItem("Streak", "7", .streak)
            goItem("Exercise Library", "8", .library)
            goItem("Stretch & Yoga", "9", .routines)
        }
        CommandGroup(replacing: .help) {
            MainWindowMenuButton(title: "George Tour", router: router) { router.startTour() }
            MainWindowMenuButton(title: "Welcome & Setup…", router: router) { router.showWelcome = true }
        }
    }

    private func goItem(_ title: String, _ key: KeyEquivalent, _ item: SidebarItem) -> some View {
        MainWindowMenuButton(title: title, router: router, shortcut: KeyboardShortcut(key, modifiers: .command)) {
            router.show(item)
        }
    }
}

/// A menu item that shows something in the main window. On the Mac the window comes forward first
/// (it may be behind the workout window), or opens again when none is open – live mode's window can
/// stay open without it, and nothing would show.
private struct MainWindowMenuButton: View {
    let title: String
    let router: Router
    var shortcut: KeyboardShortcut? = nil
    let action: @MainActor () -> Void
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        Button(title) {
            #if os(macOS)
            if router.mainWindowCount == 0 {
                openWindow(id: "main")
            } else {
                MainWindowFront.bringForward()
            }
            #endif
            action()
        }
        .keyboardShortcut(shortcut)
    }
}

/// A Workout menu item that shows live mode. On the Mac it also opens the workout window, or brings
/// it to the front – also when no main window is open to notice the request (`LiveWindowPresenter`).
private struct LiveMenuButton: View {
    let title: String
    var shortcut: KeyboardShortcut? = nil
    /// Whether the item ends up in live mode (⌘↩ only does when a workout runs).
    var showsLive = true
    let action: @MainActor () -> Void
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        Button(title) {
            action()
            #if os(macOS)
            if showsLive { openWindow(id: LiveWindow.id) }
            #endif
        }
        .keyboardShortcut(shortcut)
    }
}
