import SwiftUI
import SwiftData
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
    @State private var toasts = ToastCenter()
    @State private var router = Router()

    let container: ModelContainer
    let mode: StorageMode
    private let launch = LaunchOptions.current

    init() {
        AppLog.bootstrap(appName: AppInfo.name)
        BinisoftTips.configure()
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
        _live = State(initialValue: LiveWorkoutController(store: store, health: health, watch: watch, library: library))
        _muscles = State(initialValue: MuscleAnalytics(store: store, library: library))
        _sync = State(initialValue: SyncMonitor(mode: opened.mode, appName: AppInfo.name))
        AppLog.info("Launch \(AppVersion.main.display), storage: \(opened.mode.title)", category: "app")
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(store)
                .environment(library)
                .environment(health)
                .environment(watch)
                .environment(live)
                .environment(muscles)
                .environment(sync)
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
                    }
                    live.syncWatch()
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
            Button("Complete Set") { live.completeCurrentSet() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(!live.isActive)
            Button(live.isPaused ? "Resume" : "Pause") { live.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!live.isActive)
            Button("Skip Rest") { live.skipRest() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(live.restEndsAt == nil)
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
        }
        CommandGroup(replacing: .help) {
            Button("George Tour") { router.startTour() }
            Button("Welcome & Setup…") { router.showWelcome = true }
        }
    }
}
