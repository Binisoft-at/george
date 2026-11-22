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
                #endif
                .undoableChanges(in: container.mainContext)
                .task {
                    await library.load()
                    router.applyLaunchOptions(launch, store: store, live: live)
                    guard !launch.isDemo else {
                        health.healthSignals = DemoData.healthSignals(calendar: store.calendar)
                        health.readiness = BodyReadiness.evaluate(health.healthSignals, calendar: store.calendar)
                        return
                    }
                    live.restore()
                    watch.activate()
                    if health.isAvailable && UserDefaults.standard.bool(forKey: Prefs.healthAsked) {
                        await health.refresh()
                        await health.loadSignals()
                        store.healthBodyMassKg = health.latestBodyMassKg
                    }
                    live.syncWatch()
                }
                // A value typed a moment ago is saved before the app goes to the background.
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { live.flushPersist() }
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
        }

        #if os(macOS)
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
}

/// Menu bar commands and keyboard shortcuts (Mac, iPad with keyboard).
struct GeorgeCommands: Commands {
    let router: Router
    let live: LiveWorkoutController

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Create…") { router.request(.create) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Empty Workout") { router.request(.newSession) }
            Button("New Template") { router.request(.newTemplate) }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("New Program") { router.request(.newProgram) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Import CSV…") { router.request(.importCSV) }
                .keyboardShortcut("i", modifiers: .command)
        }
        CommandMenu("Workout") {
            Button(live.isActive ? "Show Live Workout" : "Start Suggested Workout") { router.request(.startSuggested) }
                .keyboardShortcut(.return, modifiers: .command)
            Button(live.primaryIsStart ? "Start Set" : "Complete Set") { live.primaryAction() }
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
            Button("Finish Workout…") {
                live.isPresented = true
                live.finishRequest = true
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!live.isActive)
            Button("Discard Workout…") {
                live.isPresented = true
                live.discardRequest = true
            }
            .disabled(!live.isActive)
        }
        CommandMenu("Go") {
            Button("Today") { router.show(.today) }
                .keyboardShortcut("1")
            Button("Workouts") { router.show(.allSessions) }
                .keyboardShortcut("2")
            Button("Templates") { router.show(.templates) }
                .keyboardShortcut("3")
            Button("Muscles") { router.show(.muscles) }
                .keyboardShortcut("4")
            Button("Stats & Records") { router.show(.stats) }
                .keyboardShortcut("5")
            Button("Energy") { router.show(.energy) }
                .keyboardShortcut("6")
            Button("Streak") { router.show(.streak) }
                .keyboardShortcut("7")
            Button("Exercise Library") { router.show(.library) }
                .keyboardShortcut("8")
            Button("Stretch & Yoga") { router.show(.routines) }
                .keyboardShortcut("9")
        }
        CommandGroup(replacing: .help) {
            Button("George Tour") { router.startTour() }
            Button("Welcome & Setup…") { router.showWelcome = true }
        }
    }
}
