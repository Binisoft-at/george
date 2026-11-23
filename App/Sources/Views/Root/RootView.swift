import SwiftUI
import SwiftData
import BinisoftKit
import GeorgeCore

/// Screens that list things (Mac sidebar items; pushed screens on iPhone/iPad).
enum SidebarItem: Hashable {
    case today
    case allSessions
    case planned
    case favorites
    case templates
    case program(UUID)
    case kind(String)
    case library
    case stats
    case streak
    case muscles
    case energy
    case routines

    /// Overview screens that fill the window on the Mac (no list + detail columns).
    var isDashboard: Bool {
        switch self {
        case .today, .muscles, .stats, .energy, .streak: return true
        default: return false
        }
    }
}

/// One thing to look at: a workout, template, exercise or muscle.
enum DetailItem: Hashable {
    case session(UUID)
    case template(UUID)
    case exercise(String)
    case muscle(String)
    case muscularLoad
    /// A ready-made stretch or yoga routine (`RoutineLibrary` id) – Mac: Stretch & Yoga's selection.
    case routine(String)
}

/// Tabs on iPhone and iPad. Programs appear as extra tabs in the iPad sidebar.
enum AppTab: Hashable {
    case today, workouts, plans, insights, search
    case program(UUID)
}

/// One entry of a tab's navigation stack.
enum Route: Hashable {
    case screen(SidebarItem)
    case detail(DetailItem)
}

enum InsightsSection: String, CaseIterable, Identifiable {
    case muscles, progress, energy, streak
    var id: String { rawValue }
    var title: String {
        switch self {
        case .muscles: return "Muscles"
        case .progress: return "Progress"
        case .energy: return "Energy"
        case .streak: return "Streak"
        }
    }
}

/// App-wide navigation state and one-shot requests from menus/shortcuts.
///
/// Mac: a three-column split view (`sidebar` → list → `detail`).
/// iPhone/iPad: a tab bar with one navigation stack per tab (`paths`).
@MainActor
@Observable
final class Router {
    enum Request: Hashable {
        case newSession, newTemplate, newProgram, importCSV, startSuggested, create
    }

    // Mac
    /// The sidebar selection. A dashboard always opens clean; a list gets back the item it showed
    /// last – never another list's item.
    var sidebar: SidebarItem? {
        get { sidebarSelection }
        set {
            guard newValue != sidebarSelection else { return }
            sidebarSelection = newValue
            detailPath = []
            detail = newValue.flatMap { lastDetail[$0] }
        }
    }
    /// The list's selection, shown in the detail column. Dashboards show opened items on `detailPath`.
    var detail: DetailItem? {
        get { detailSelection }
        set {
            guard newValue != detailSelection else { return }
            detailSelection = newValue
            detailPath = []
            if let sidebar, !sidebar.isDashboard { lastDetail[sidebar] = newValue }
        }
    }
    private var sidebarSelection: SidebarItem?
    private var detailSelection: DetailItem?
    /// Opened on top of the detail (a workout from a template's history, an exercise from a
    /// workout, a dashboard's workout or muscle) – with Back.
    var detailPath: [DetailItem] = []
    /// What each list showed last.
    @ObservationIgnored private var lastDetail: [SidebarItem: DetailItem] = [:]
    /// Main windows open right now (Mac): Settings brings one up before it shows something there.
    @ObservationIgnored var mainWindowCount = 0
    /// The workout window is open (Mac, `LiveWindowRoot`): a main window that opens doesn't bring it
    /// forward again.
    @ObservationIgnored var liveWindowIsOpen = false
    /// A CSV opened from Finder, dropped on the window or shared from another app – the import
    /// sheet loads it (also when it's open already).
    var importURL: URL?

    // iPhone / iPad
    var tab: AppTab = .today
    var paths: [AppTab: [Route]] = [:]
    var insights: InsightsSection = .muscles
    /// Screenshots: a sheet opened straight from `-DemoScreen`.
    var demoSheet: DemoSheet?
    var workoutsFilter: WorkoutsFilter = .all
    /// iPad at regular width (`SplitTabStack`): the item next to each tab's list, what was opened on
    /// top of it, and the tabs shown that way right now.
    var splitDetail: [AppTab: DetailItem] = [:]
    var splitPaths: [AppTab: [Route]] = [:]
    @ObservationIgnored var splitTabs: Set<AppTab> = []

    var pendingRequest: Request?
    var showSettings = false
    var showImport = false
    var showNewProgram = false
    var showCreate = false
    /// Opens the create sheet directly at a step.
    var createStep: CreateStep?
    /// George's welcome & setup pages (first launch, Settings → Help).
    var showWelcome = false
    /// The hands-on tour on a practice page (BinisoftKit tour engine).
    var tour: TourRequest?
    /// A freshly created template whose exercise picker should open right away.
    var pickExercisesFor: UUID?
    /// The program "New Template" in the create sheet preselects (nil: the active program).
    var newTemplateProgramID: UUID?
    /// "New Empty Workout" made a moment ago: left without adding anything, it goes again.
    var draftSessionID: UUID?

    func request(_ request: Request) { pendingRequest = request }

    /// Shows a workout, template, exercise or muscle: the detail column on the Mac and next to an
    /// iPad list (`SplitTabStack`), a push on iPhone and elsewhere on iPad.
    func open(_ item: DetailItem, in sidebarItem: SidebarItem? = nil) {
        #if os(macOS)
        if let sidebarItem { sidebar = sidebarItem }
        if sidebar?.isDashboard == true {
            // A dashboard fills the window: the item opens on top of it, with Back.
            if detailPath != [item] { detailPath = [item] }
        } else {
            detail = item
        }
        #else
        if let sidebarItem { show(sidebarItem) }
        if splitTabs.contains(tab) {
            // iPad: next to the list, not pushed over it.
            showInSplit(item, in: tab)
            return
        }
        if paths[tab]?.last != .detail(item) {
            paths[tab, default: []].append(.detail(item))
        }
        #endif
    }

    /// A link inside a detail (a workout in a template's history, an exercise from a workout): on
    /// the Mac and next to an iPad list it opens on top of the detail with Back, and the list keeps
    /// its selection. Elsewhere on iPhone/iPad the same as `open`.
    func push(_ item: DetailItem) {
        #if os(macOS)
        if sidebar?.isDashboard != true && detail == nil {
            detail = item
        } else if detailPath.last != item && !(detailPath.isEmpty && detail == item) {
            detailPath.append(item)
        }
        #else
        if splitTabs.contains(tab), let shown = splitDetail[tab] {
            // iPad: on top of the item next to the list, with Back; the list keeps its selection.
            let onTop = splitPaths[tab] ?? []
            let next = ListDetailPath.push(item, shown: shown, onTop: onTop, wrap: Route.detail)
            if next != onTop { splitPaths[tab] = next }
            return
        }
        open(item)
        #endif
    }

    /// Stops showing an item (e.g. after deleting it).
    func close(_ item: DetailItem) {
        if detail == item { detail = nil }
        detailPath.removeAll { $0 == item }
        lastDetail = lastDetail.filter { $0.value != item }
        for key in Array(paths.keys) {
            paths[key]?.removeAll { $0 == .detail(item) }
        }
        // iPad: the detail column next to a list.
        if splitDetail.values.contains(item) { splitDetail = splitDetail.filter { $0.value != item } }
        for key in Array(splitPaths.keys) where splitPaths[key]?.contains(.detail(item)) == true {
            splitPaths[key]?.removeAll { $0 == .detail(item) }
        }
    }

    /// Switches to a list screen: the sidebar selection on the Mac, the matching tab on iPhone/iPad.
    func show(_ item: SidebarItem) {
        #if os(macOS)
        // The same screen again (⌘1 on Today): back to its top.
        if sidebar == item { detailPath = [] } else { sidebar = item }
        #else
        switch item {
        case .today: select(.today)
        case .allSessions: workoutsFilter = .all; select(.workouts)
        case .planned: workoutsFilter = .planned; select(.workouts)
        case .favorites: workoutsFilter = .favorites; select(.workouts)
        case .kind: select(.workouts, path: [.screen(item)])
        case .templates: select(.plans, path: [.screen(item)])
        case .program: select(.plans, path: [.screen(item)])
        case .library: select(.search, path: [.screen(item)])
        case .stats: insights = .progress; select(.insights)
        case .streak: insights = .streak; select(.insights)
        case .muscles: insights = .muscles; select(.insights)
        case .energy: insights = .energy; select(.insights)
        case .routines: select(.plans, path: [.screen(item)])
        }
        #endif
    }

    private func select(_ tab: AppTab, path: [Route] = []) {
        self.tab = tab
        paths[tab] = path
    }

    /// Runs `action` once a sheet that is closing right now is gone.
    func afterDismiss(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            action()
        }
    }

    // MARK: Tour

    /// Opens the hands-on tour (all steps). Sheets close first – one sheet at a time.
    func startTour(at step: String? = nil) {
        let request = TourRequest(steps: GeorgeTour.catalog.allSteps, startAt: step)
        let hadSheet = showSettings || showCreate || showImport || showNewProgram || showWelcome
        showSettings = false
        showCreate = false
        showImport = false
        showNewProgram = false
        showWelcome = false
        if hadSheet {
            afterDismiss { [weak self] in self?.tour = request }
        } else {
            tour = request
        }
    }

    /// Opens the tour by itself once after install, and the "What's new" steps after an update.
    func offerTourIfNeeded(live: LiveWorkoutController? = nil, store: GeorgeStore? = nil) {
        guard tour == nil else { return }
        // Never over a running workout, and not when a planned workout is due today (likely at the gym).
        if live?.isActive == true { return }
        if let store, case .planned = store.nextWorkout() { return }
        // After an update the Today card offers what's new – no automatic cover.
        guard TourSchedule().seenVersion == 0 else { return }
        let steps = TourSchedule().stepsToOffer(GeorgeTour.catalog)
        guard !steps.isEmpty else { return }
        AppLog.info("Tour offered (\(steps.count) steps)", category: "tour")
        tour = TourRequest(steps: steps, startAt: nil)
    }

    func finishTour() {
        TourSchedule().markSeen(GeorgeTour.catalog)
        tour = nil
    }

    // MARK: Launch arguments (screenshots in CI)

    /// `-Demo -DemoScreen <name>` opens a screen; `-Tour` / `-TourStep <id>` open the tour.
    func applyLaunchOptions(_ launch: LaunchOptions, store: GeorgeStore, live: LiveWorkoutController) {
        if launch.resetTour { TourSchedule().reset() }
        switch launch.screen {
        case "today":
            show(.today)
        case "workouts":
            show(.allSessions)
        case "plans":
            #if os(macOS)
            show(.templates)
            #else
            tab = .plans
            #endif
        case "templates":
            show(.templates)
        case "template":
            if let template = store.suggestedTemplate(in: store.activeProgram) ?? store.fetchTemplates().first {
                open(.template(template.id), in: .templates)
            }
        case "session":
            if let session = store.fetchSessions().filter({ $0.status.isPerformed }).max(by: { $0.date < $1.date }) {
                open(.session(session.id), in: .allSessions)
            }
        case "live":
            if let template = store.suggestedTemplate(in: store.activeProgram) {
                live.start(template: template)
            }
        case "live-mid", "live-superset", "live-panel", "live-feedback":
            // Mid-workout: a few sets ticked, momentum up; "live-superset" jumps to the first superset,
            // "live-panel" opens the coach panel, "live-feedback" finishes the first exercise.
            if let template = store.suggestedTemplate(in: store.activeProgram) {
                live.start(template: template)
                let screen = launch.screen ?? ""
                // Let the live screen finish appearing first (ticking during the presentation left
                // the screenshot blank).
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    let sets = screen == "live-feedback" ? (live.currentItem?.sets.count ?? 4) : 3
                    live.demoProgress(sets: sets, focusSuperset: screen == "live-superset", keepFeedback: screen == "live-feedback")
                    if screen == "live-panel" {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        live.showPanel = true
                    }
                }
            }
        case "live-offplan", "live-looking":
            // Looking ahead at the second exercise ("live-looking"), and ticking one of its sets
            // out of order ("live-offplan").
            if let template = store.suggestedTemplate(in: store.activeProgram) {
                live.start(template: template)
                let screen = launch.screen ?? ""
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    let items = live.content.allItems
                    guard items.count > 1 else { return }
                    live.view(itemID: items[1].id)
                    if screen == "live-offplan", let set = items[1].sets.first {
                        live.toggleSet(set.id)
                        live.skipRest()
                    }
                }
            }
        case "live-drop", "live-swap":
            if let template = store.suggestedTemplate(in: store.activeProgram) {
                live.start(template: template)
                let screen = launch.screen ?? ""
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    live.demoSheetRequest = screen == "live-drop" ? "drop" : "swap"
                }
            }
        case "finish":
            // The finish screen for the last workout of the demo history.
            if let session = store.fetchSessions().filter({ $0.status.isPerformed }).max(by: { $0.date < $1.date }) {
                let content = session.content
                let history = store.performedRecords()
                let templateOf = Dictionary(store.fetchSessions().map { ($0.id, $0.templateID) }, uniquingKeysWith: { a, _ in a })
                live.summary = LiveWorkoutController.FinishSummary(
                    sessionID: session.id, title: session.title, duration: session.durationSeconds,
                    completedSets: content.completedSets, totalSets: content.totalSets, volumeKg: content.volumeKg,
                    energyKcal: session.energyKcal, averageHeartRate: 128,
                    records: StatsEngine.newRecords(in: session.record(), comparedTo: history),
                    canUpdateTemplate: false, templateName: session.templateName, savedToHealth: true,
                    comparison: StatsEngine.compare(session.record(), templateID: session.templateID, previous: history) { templateOf[$0] ?? nil },
                    kind: session.kind,
                    coolDown: RoutineLibrary.all.first { $0.id == "post-workout" }
                )
            }
        case "share-card":
            if let session = store.fetchSessions().filter({ $0.status.isPerformed }).max(by: { $0.date < $1.date }) {
                demoSheet = .shareCard(session.id)
            }
        case "voice":
            demoSheet = .voice
        case "share":
            if let template = store.suggestedTemplate(in: store.activeProgram) ?? store.fetchTemplates().first {
                demoSheet = .share(template.id)
            }
        case "muscles":
            show(.muscles)
        case "stats":
            show(.stats)
        case "streak":
            show(.streak)
        case "routines":
            show(.routines)
        case "plan-week":
            demoSheet = .planWeek
        case "log-activity":
            demoSheet = .logActivity
        case "live-empty":
            live.start(store.makeEmptySession(program: store.activeProgram, start: true))
        case "live-paused":
            if let template = store.suggestedTemplate(in: store.activeProgram) {
                live.start(template: template)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    live.demoProgress(sets: 2, focusSuperset: false)
                    live.pause()
                }
            }
        case "live-flow":
            // A stretch routine: a per-side hold running (side 1 of 2).
            if let routine = RoutineLibrary.all.first(where: { $0.id == "hip-openers" }) {
                let template = store.templateForRoutine(routine, catalog: live.catalog).template
                live.start(template: template)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    live.startSet()
                }
            }
        case "energy":
            show(.energy)
        case "library":
            show(.library)
        case "create":
            showCreate = true
        case "settings":
            showSettings = true
        case "welcome":
            showWelcome = true
        default:
            break
        }
        if launch.startTour { startTour(at: launch.tourStep) }
    }
}

/// What ⌘↩ (Workout → Start …) starts: the template or workout open in the detail, published by its
/// screen while it is shown. Without one the menu starts the suggested workout.
struct StartCommand {
    /// "Start UPPER", "Continue W46: 2 UPPER - 10.11"
    var title: String
    var isEnabled = true
    var perform: () -> Void
}

struct StartTargetKey: FocusedValueKey {
    typealias Value = StartCommand
}

extension FocusedValues {
    var startTarget: StartCommand? {
        get { self[StartTargetKey.self] }
        set { self[StartTargetKey.self] = newValue }
    }
}

enum DemoSheet: Identifiable, Hashable {
    case voice
    case share(UUID)
    case shareCard(UUID)
    case planWeek
    case logActivity
    var id: String {
        switch self {
        case .voice: return "voice"
        case .planWeek: return "plan-week"
        case .logActivity: return "log-activity"
        case .share(let id): return "share-\(id)"
        case .shareCard(let id): return "card-\(id)"
        }
    }
}

/// `-DemoScreen share-card`: the share sheet of a workout.
struct DemoShareCard: View {
    let sessionID: UUID
    @Environment(GeorgeStore.self) private var store
    @Environment(MuscleAnalytics.self) private var muscles
    @Environment(HealthKitManager.self) private var health

    var body: some View {
        if let session = store.session(id: sessionID) {
            ShareCardSheet(recap: WorkoutRecap.make(session: session, store: store, muscles: muscles, health: health))
        }
    }
}

struct TourRequest: Identifiable {
    let id = UUID()
    let steps: [TourStep<GeorgeTourSnapshot>]
    let startAt: String?
}

enum WorkoutsFilter: String, CaseIterable, Identifiable {
    case all, planned, done, favorites
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .planned: return "Planned"
        case .done: return "Done"
        case .favorites: return "Favorites"
        }
    }
    var scope: SessionScope {
        switch self {
        case .all: return .all
        case .planned: return .planned
        case .done: return .done
        case .favorites: return .favorites
        }
    }
}

// MARK: - Root

struct RootView: View {
    var body: some View {
        Group {
            #if os(macOS)
            SplitRootView()
            #else
            TabRootView()
            #endif
        }
        .modifier(RootPresentation())
    }
}

#if os(macOS)
/// Mac: sidebar → list → detail, like Notes – one split view for every sidebar item, so switching
/// never builds the sidebar anew (its counts, scroll position and width stay). macOS always shows a
/// three-column split view's middle column, so the split view has two columns and the main column
/// lays out a list next to its selection (`MacMainColumn`), or a dashboard at full width.
struct SplitRootView: View {
    @Environment(Router.self) private var router
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Counted in `Router.mainWindowCount` (once, however the window closes).
    @State private var isCounted = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            MacMainColumn()
        }
        // Live mode is a window of its own (LiveWindow.swift): opened from here.
        .modifier(LiveWindowPresenter())
        .safeAreaInset(edge: .bottom) {
            MacNowPlaying()
        }
        // A CSV dragged from Finder onto the window opens the import.
        .dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in
            guard let csv = urls.first(where: { $0.pathExtension.lowercased() == "csv" }) else { return false }
            router.importURL = csv
            router.showImport = true
            return true
        }
        .onAppear {
            if router.sidebar == nil { router.sidebar = .today }
            if !isCounted {
                isCounted = true
                router.mainWindowCount += 1
            }
        }
        .onDisappear { windowClosed() }
        // `onDisappear` doesn't come when this is the last window that closes. The window in front
        // last is the one menu commands and Settings bring forward (`MainWindowFront`).
        .background {
            WindowStateObserver(onClose: { windowClosed() }, onBecameMain: { MainWindowFront.note($0) })
        }
    }

    private func windowClosed() {
        guard isCounted else { return }
        isCounted = false
        router.mainWindowCount = max(0, router.mainWindowCount - 1)
    }
}

/// The split view's main column. A list: the list, an edge to drag, and the list's selection (links
/// inside it – a template's history, an exercise – open on top, with Back). A dashboard: the whole
/// width, with a tapped muscle or workout on top (Back returns to the dashboard).
private struct MacMainColumn: View {
    @Environment(Router.self) private var router
    /// The list's width – the same for every list, kept per window.
    @SceneStorage("mac.listWidth") private var listWidth = 380.0

    var body: some View {
        if router.sidebar?.isDashboard == true {
            dashboard
        } else {
            HStack(spacing: 0) {
                ScreenView(item: router.sidebar)
                    .frame(width: Self.listColumn.clamped(listWidth))
                ColumnResizeHandle(width: $listWidth, column: Self.listColumn)
                detail
                    .frame(minWidth: 340, maxWidth: .infinity)
            }
        }
    }

    /// As wide as the split view's middle column was (GeorgeCore `ResizableColumn`).
    static let listColumn = ResizableColumn(range: 300...560, ideal: 380)

    private var dashboard: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.detailPath) {
            ScreenView(item: router.sidebar)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
                .navigationDestination(for: DetailItem.self) { item in
                    DetailScreen(item: item)
                }
        }
        // Each dashboard starts with its own stack.
        .id(router.sidebar)
    }

    private var detail: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.detailPath) {
            DetailScreen(item: router.detail, list: router.sidebar)
                .navigationDestination(for: DetailItem.self) { item in
                    DetailScreen(item: item)
                }
        }
        // Another selection starts a fresh stack.
        .id(router.detail)
    }
}

/// The edge between the list and the detail (Mac): drag it to make the list wider or narrower.
private struct ColumnResizeHandle: View {
    @Binding var width: Double
    let column: ResizableColumn
    @State private var dragStart: Double?

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? column.clamped(width)
                                if dragStart == nil { dragStart = start }
                                width = column.width(draggedFrom: start, by: Double(value.translation.width))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
            .zIndex(1)
            .accessibilityHidden(true)
    }
}

/// The Mac's bar at the bottom: the workout running here (a click opens its window or brings it
/// forward), or a workout running on another device – read-only, with "Continue Here".
private struct MacNowPlaying: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(LiveWorkoutController.self) private var live

    var body: some View {
        // Synced changes: another device starting or ending a workout moves the revision, its sets
        // move `liveRevision`.
        let _ = (store.revision, store.liveRevision)
        let other = live.isActive ? nil : live.workoutOnOtherDevice
        Group {
            // While a workout runs, also when its window is open: the bar stays put instead of
            // coming and going each time the other window is clicked.
            if live.isActive {
                MiniPlayerBar()
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let other {
                OtherDevicePlayerBar(session: other)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: live.isActive)
        .animation(.snappy, value: other?.id)
    }
}
#else
/// iPhone/iPad: Liquid Glass tab bar (a sidebar on iPad), one stack per tab,
/// and the running workout as a "now playing" bar above the tabs.
struct TabRootView: View {
    @Environment(LiveWorkoutController.self) private var live
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: \Program.sortIndex) private var programs: [Program]

    /// Programs get their own entries in the iPad sidebar only. On iPhone they would count as tabs
    /// and push Search into a "More" tab.
    private var sidebarPrograms: [Program] {
        sizeClass == .regular ? programs.filter { !$0.isArchived } : []
    }

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Today", systemImage: "sun.max.fill", value: AppTab.today) {
                TabStack(tab: .today) { TodayView() }
            }
            Tab("Workouts", systemImage: "list.bullet.rectangle.portrait.fill", value: AppTab.workouts) {
                TabStack(tab: .workouts) { WorkoutsTabView() }
            }
            Tab("Plans", systemImage: "square.stack.3d.up.fill", value: AppTab.plans) {
                TabStack(tab: .plans) { PlansView() }
            }
            Tab("Insights", systemImage: "chart.bar.xaxis", value: AppTab.insights) {
                TabStack(tab: .insights) { InsightsView() }
            }
            TabSection("Programs") {
                ForEach(sidebarPrograms) { program in
                    Tab(program.name, systemImage: program.symbol, value: AppTab.program(program.id)) {
                        TabStack(tab: .program(program.id)) { ProgramView(programID: program.id) }
                    }
                }
            }
            .defaultVisibility(.hidden, for: .tabBar)
            Tab(value: AppTab.search, role: .search) {
                TabStack(tab: .search) { SearchView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .liveWorkoutAccessory(enabled: live.isActive || live.workoutOnOtherDevice != nil)
    }
}

private extension View {
    /// The "now playing" bar above the tab bar – only while a workout runs (otherwise it covered
    /// content and doubled the Start buttons; Today has the Up Next card).
    @ViewBuilder
    func liveWorkoutAccessory(enabled: Bool) -> some View {
        #if os(iOS)
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: enabled) { NowPlayingAccessory() }
        } else if enabled {
            tabViewBottomAccessory { NowPlayingAccessory() }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// A tab's navigation stack, bound to the router so any screen can push. On iPad at regular width,
/// Workouts, Plans and the programs show their list with the chosen item next to it (`SplitTabStack`).
struct TabStack<Root: View>: View {
    let tab: AppTab
    @ViewBuilder let root: () -> Root
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let split = sizeClass == .regular && !PlatformInfo.isPhone && tab.showsListAndDetail
        Group {
            if split {
                SplitTabStack(tab: tab, root: root)
            } else {
                stack
            }
        }
        // What's open moves between the two layouts (multitasking, Slide Over).
        .onChange(of: split, initial: true) { _, isSplit in router.setSplit(isSplit, for: tab) }
    }

    private var stack: some View {
        let path = router.paths[tab] ?? []
        return NavigationStack(path: Binding(get: { path }, set: { router.paths[tab] = $0 })) {
            root()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .screen(let item): ScreenView(item: item)
                    case .detail(let item): DetailScreen(item: item)
                    }
                }
        }
    }
}
#endif

/// Sheets, the live workout, onboarding and menu requests — shared by both layouts.
struct RootPresentation: ViewModifier {
    @Environment(GeorgeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(LiveWorkoutController.self) private var live
    @Environment(ToastCenter.self) private var toasts
    @AppStorage(Prefs.didOnboard) private var didOnboard = false
    @AppStorage(Prefs.welcomeVersion) private var welcomeVersion = 0

    func body(content: Content) -> some View {
        @Bindable var router = router
        @Bindable var live = live

        content
            #if os(iOS)
            .fullScreenCover(isPresented: $live.isPresented) {
                LiveWorkoutView()
            }
            .fullScreenCover(isPresented: $router.showWelcome) {
                WelcomeView()
            }
            .fullScreenCover(item: $router.tour) { request in
                TourView(request: request) { router.finishTour() }
            }
            .sheet(isPresented: $router.showSettings) {
                NavigationStack { SettingsView() }
            }
            #else
            // Live mode: a window of its own on the Mac (`LiveWindowPresenter` on `SplitRootView`).
            .sheet(isPresented: $router.showWelcome) {
                WelcomeView()
                    .frame(minWidth: 620, idealWidth: 680, minHeight: 680, idealHeight: 740)
            }
            .sheet(item: $router.tour) { request in
                TourView(request: request) { router.finishTour() }
                    .frame(minWidth: 760, idealWidth: 900, minHeight: 680, idealHeight: 780)
            }
            #endif
            #if os(iOS)
            .fullScreenCover(item: $live.summary) { summary in
                FinishCelebrationView(summary: summary)
            }
            #else
            .sheet(item: $live.summary) { summary in
                FinishCelebrationView(summary: summary)
                    .frame(minWidth: 520, minHeight: 720)
            }
            #endif
            .sheet(item: $router.demoSheet) { sheet in
                switch sheet {
                case .voice:
                    NavigationStack { VoiceSettingsView() }
                case .share(let id):
                    if let template = store.template(id: id) { RoutineShareSheet(template: template) }
                case .shareCard(let id):
                    DemoShareCard(sessionID: id)
                case .planWeek:
                    PlanWeekSheet()
                case .logActivity:
                    NavigationStack { LogActivitySheet() }
                }
            }
            .sheet(isPresented: $router.showImport) {
                NavigationStack { ImportView() }
            }
            .sheet(isPresented: $router.showNewProgram) {
                NavigationStack { ProgramEditorSheet(program: nil) }
            }
            .sheet(isPresented: $router.showCreate) {
                WorkoutCreateSheet()
                    #if os(macOS)
                    .frame(minWidth: 520, minHeight: 620)
                    #endif
            }
            .onAppear {
                guard !LaunchOptions.current.isDemo else { return }
                if !didOnboard || welcomeVersion < Prefs.currentWelcomeVersion {
                    router.showWelcome = true
                } else {
                    router.offerTourIfNeeded(live: live, store: store)
                }
            }
            // Also one made just before this window opened (Mac: File → Create… with no main window).
            .onChange(of: router.pendingRequest, initial: true) { _, request in
                guard let request else { return }
                router.pendingRequest = nil
                handle(request)
            }
            // A Start while another workout runs – here or on another device (synced): ask instead
            // of ending it silently or running two at once.
            .confirmationDialog(
                startDialogTitle,
                isPresented: Binding(get: { live.pendingStart != nil }, set: { if !$0 { live.cancelPendingStart() } }),
                titleVisibility: .visible,
                presenting: live.pendingStart
            ) { target in
                if let other = live.otherDeviceSession {
                    // The workout and the start are taken from here, not from state the dialog's
                    // dismissal may already have cleared.
                    Button("Continue Here") { live.continueOtherDeviceWorkoutHere(other) }
                    if !live.pendingStartIsOtherDeviceWorkout {
                        Button("Start \(target.title) Anyway") { live.startAnyway(target, endingOn: other) }
                    }
                    Button("Cancel", role: .cancel) { live.cancelPendingStart() }
                } else {
                    Button("Keep Going with \(live.session?.title ?? "It")") { live.keepCurrentWorkout() }
                    Button("Finish It First") { live.finishCurrentFirst() }
                    Button("Save It and Start \(target.title)") {
                        Task { await live.finishCurrentAndStart() }
                    }
                    Button("Cancel", role: .cancel) { live.cancelPendingStart() }
                }
            } message: { target in
                if let other = live.otherDeviceSession {
                    Text(otherDeviceMessage(target: target, other: other))
                } else {
                    Text("Starting “\(target.title)” ends the running workout. Finishing first lets you rate it; saving keeps every set and the time so far.")
                }
            }
            // The running workout was deleted or ended here (a list, another window): let go. iCloud
            // imports call it directly (`CloudImportRefresher.didRefresh`).
            .onChange(of: store.revision) { _, _ in live.syncedStatusChanged() }
            // A save failed (details in the App Log): said once, until saving works again.
            .onChange(of: store.lastSaveError) { old, new in
                if old == nil, new != nil { toasts.show("Couldn't save – see App Log", symbol: "exclamationmark.triangle.fill") }
            }
            // A start refused because the workout can't be read on this device (Today, Siri, Watch …).
            .onChange(of: live.startRefusal) { _, message in
                guard let message else { return }
                toasts.show(message, symbol: "exclamationmark.triangle.fill")
                live.startRefusal = nil
            }
            // The running workout was continued on another device ("Continued on your Mac"); also
            // when that happened while George was closed (initial).
            .onChange(of: live.handOverNotice, initial: true) { _, message in
                guard let message else { return }
                toasts.show(message, symbol: "iphone.and.arrow.forward")
                live.handOverNotice = nil
            }
            .onOpenURL { url in
                if url.pathExtension.lowercased() == "csv" {
                    // The import sheet loads it – also when it's open already.
                    router.importURL = url
                    router.showImport = true
                }
            }
    }

    private var startDialogTitle: String {
        if let other = live.otherDeviceSession { return "“\(other.title)” is running on \(ThisDevice.ownerName(of: other))" }
        return live.session.map { "“\($0.title)” is still running" } ?? "A workout is running"
    }

    private func otherDeviceMessage(target: LiveWorkoutController.StartTarget, other: WorkoutSession) -> String {
        if live.pendingStartIsOtherDeviceWorkout {
            return "Continue it here to use this device from now on. Two devices running it would save over each other."
        }
        return "Starting “\(target.title)” here ends “\(other.title)” on \(ThisDevice.ownerName(of: other)) – the sets done there are kept, as stopped early."
    }

    private func handle(_ request: Router.Request) {
        switch request {
        case .create:
            router.showCreate = true
        case .newProgram:
            router.showNewProgram = true
        case .importCSV:
            router.showImport = true
        case .newTemplate:
            // Name, type and program first (the create sheet), like Today's New Template: nothing
            // empty lands in the rotation when you back out.
            if let program = currentProgram { router.newTemplateProgramID = program.id }
            router.createStep = .newTemplate
            router.showCreate = true
        case .newSession:
            let program = currentProgram ?? store.activeProgram
            let session = store.makeEmptySession(program: program, start: false)
            // Left empty, it's removed again (SessionDetailView).
            router.draftSessionID = session.id
            router.open(.session(session.id))
        case .startSuggested:
            if live.isActive {
                live.isPresented = true
            } else if let next = store.nextWorkout() {
                switch next {
                case .planned(let session): live.requestStart(.session(session))
                case .template(let template): live.requestStart(.template(template))
                }
            } else {
                live.requestStart(.empty(program: store.activeProgram, kind: nil, rescue: false))
            }
        }
    }

    private var currentProgram: Program? {
        if case .program(let id) = router.sidebar { return store.program(id: id) }
        return nil
    }
}

// MARK: - Screens

/// A list screen: the Mac's middle column, or a pushed/root screen on iPhone/iPad.
struct ScreenView: View {
    let item: SidebarItem?

    var body: some View {
        switch item {
        case .today:
            TodayView()
        case .allSessions:
            SessionListView(scope: .all)
        case .planned:
            SessionListView(scope: .planned)
        case .favorites:
            SessionListView(scope: .favorites)
        case .kind(let raw):
            SessionListView(scope: .kind(WorkoutKind(raw)))
        case .templates:
            TemplateListView(programID: nil)
        case .program(let id):
            ProgramView(programID: id)
                .id(id)
        case .library:
            ExerciseLibraryView()
        case .stats:
            StatsView()
        case .streak:
            StreakView()
        case .muscles:
            MusclesView()
        case .energy:
            EnergyView()
        case .routines:
            RoutinesView()
        case .none:
            MessageView(title: "George", systemImage: "dumbbell", message: "Pick a program or a list in the sidebar.")
        }
    }
}

/// The selected workout, template, exercise or muscle.
struct DetailScreen: View {
    let item: DetailItem?
    /// The list next to it (Mac): the empty state says what to choose.
    var list: SidebarItem? = nil

    var body: some View {
        switch item {
        case .session(let id):
            SessionDetailView(sessionID: id)
                .id(id)
        case .template(let id):
            TemplateDetailView(templateID: id)
                .id(id)
        case .exercise(let id):
            ExerciseDetailView(exerciseID: id)
                .id(id)
        case .muscle(let raw):
            if let group = MuscleGroup(rawValue: raw) {
                MuscleDetailView(group: group)
                    .id(raw)
            } else {
                MessageView(title: "Unknown muscle", systemImage: "questionmark.circle")
            }
        case .muscularLoad:
            MuscularLoadDetailView(group: nil)
        case .routine(let id):
            if let routine = RoutineLibrary.routine(id: id) {
                RoutineDetailView(routine: routine)
                    .id(id)
            } else {
                MessageView(title: "Unknown routine", systemImage: "questionmark.circle")
            }
        case .none:
            MessageView(title: "No Selection", systemImage: "square.text.square", message: emptyMessage)
        }
    }

    /// "Choose a template to see it here." – named after the list next to it.
    private var emptyMessage: String {
        switch list {
        case .templates: return "Choose a template to see it here."
        case .program: return "Choose a template or workout to see it here."
        case .library: return "Choose an exercise to see it here."
        case .routines: return "Choose a routine to see it here."
        default: return "Choose a workout to see it here."
        }
    }
}

// MARK: - Navigation helpers

/// A list that drives the Mac's detail column by selection (also next to an iPad list,
/// `SplitTabStack`) and pushes on iPhone and compact iPad windows.
///
/// Mac: ⌘-click and ⇧-click select several rows (`selection`, for the list's bulk actions); one
/// selected row is the detail column's item. On a dashboard, a row opens on top of it.
struct NavList<Content: View>: View {
    private let content: () -> Content
    private let selection: Binding<Set<DetailItem>>?
    @Environment(Router.self) private var router
    @State private var ownSelection = Set<DetailItem>()
    #if os(iOS)
    /// iPad next to its detail (`SplitTabStack`): a row picks what the detail column shows.
    @Environment(\.splitListTab) private var splitTab
    #endif

    init(selection: Binding<Set<DetailItem>>? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.selection = selection
        self.content = content
    }

    var body: some View {
        #if os(macOS)
        List(selection: macSelection) {
            content()
        }
        // Opened from elsewhere (Today, a menu): a multi-selection that doesn't hold it ends.
        .onChange(of: router.detail) { _, item in
            let store = selection ?? $ownSelection
            if store.wrappedValue.count > 1, let item, !store.wrappedValue.contains(item) {
                store.wrappedValue = []
            }
        }
        #else
        if let splitTab {
            List(selection: Binding<DetailItem?>(
                get: { router.splitDetail[splitTab] },
                set: { item in if let item { router.showInSplit(item, in: splitTab) } }
            )) {
                content()
            }
        } else {
            List {
                content()
            }
        }
        #endif
    }

    #if os(macOS)
    private var macSelection: Binding<Set<DetailItem>> {
        let store = selection ?? $ownSelection
        return Binding(
            get: {
                if router.sidebar?.isDashboard == true {
                    // A dashboard's list: the row opened on top of it stays highlighted.
                    return Set(router.detailPath.prefix(1))
                }
                // Several rows: the bulk selection; one row: the detail column's item (also when it
                // was opened from elsewhere).
                if store.wrappedValue.count > 1 { return store.wrappedValue }
                return router.detail.map { Set([$0]) } ?? []
            },
            set: { newValue in
                if router.sidebar?.isDashboard == true {
                    if let item = newValue.first, newValue.count == 1 { router.open(item) }
                    return
                }
                store.wrappedValue = newValue
                if newValue.count <= 1 { router.detail = newValue.first }
            }
        )
    }
    #endif
}

/// A row that opens a detail item (selection on the Mac and in an iPad list column, push elsewhere).
struct DetailLink<Label: View>: View {
    let item: DetailItem
    @ViewBuilder let label: () -> Label
    #if os(iOS)
    /// iPad next to its detail (`SplitTabStack`): a selectable row of `NavList`, like the Mac.
    @Environment(\.splitListTab) private var splitTab
    #endif

    init(_ item: DetailItem, @ViewBuilder label: @escaping () -> Label) {
        self.item = item
        self.label = label
    }

    var body: some View {
        #if os(macOS)
        // A selectable row of `NavList` (its selection opens the item) – not a link, so a click
        // never pushes onto the detail column's stack as well.
        label()
            .tag(item)
        #else
        if splitTab != nil {
            label()
                .tag(item)
        } else {
            NavigationLink(value: Route.detail(item), label: label)
        }
        #endif
    }
}

/// A row that opens a list screen (sidebar selection on the Mac, push on iPhone/iPad).
struct ScreenLink<Label: View>: View {
    let item: SidebarItem
    @ViewBuilder let label: () -> Label
    @Environment(Router.self) private var router

    init(_ item: SidebarItem, @ViewBuilder label: @escaping () -> Label) {
        self.item = item
        self.label = label
    }

    var body: some View {
        #if os(macOS)
        Button {
            router.show(item)
        } label: {
            label()
        }
        #else
        NavigationLink(value: Route.screen(item), label: label)
        #endif
    }
}

// MARK: - Now playing

#if os(iOS)
/// Bar above the tab bar: the running workout (tap to open, ✓ to complete the set), or a one-tap start.
struct NowPlayingAccessory: View {
    @Environment(LiveWorkoutController.self) private var live
    @Environment(GeorgeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        // Saved changes (templates, plans) move the revision, a workout on another device's sets
        // `liveRevision` – the bar isn't refetched on every tick of the workout running here.
        let _ = (store.revision, store.liveRevision)
        if live.isActive {
            active
        } else if let other = live.workoutOnOtherDevice {
            otherDevice(other)
        } else {
            idle
        }
    }

    /// A workout running on another iPhone, iPad or Mac (synced): read-only, with "Continue here".
    private func otherDevice(_ session: WorkoutSession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(ThisDevice.runningTitle(for: session))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if placement != .inline {
                    Text("\(session.title) · \(session.content.completedSets)/\(session.content.totalSets) sets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button("Continue Here") { live.continueHere(session) }
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14)
    }

    private var active: some View {
        HStack(spacing: 10) {
            Button {
                live.isPresented = true
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        ProgressRing(progress: live.content.progress, tint: .accentColor, lineWidth: 3)
                        Image(systemName: live.isPaused ? "pause.fill" : (live.session?.kind.symbol ?? "figure.mixed.cardio"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            HStack(spacing: 6) {
                                Text(Format.clock(Int(live.elapsed(at: context.date))))
                                    .monospacedDigit()
                                    .font(.subheadline.weight(.semibold))
                                if live.restEndsAt != nil {
                                    Text("Rest \(Format.clock(live.restRemaining(at: context.date)))")
                                        .monospacedDigit()
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.teal)
                                }
                            }
                        }
                        if placement != .inline, let undo = live.undoableTick {
                            Text(undo.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if placement != .inline, let item = live.currentItem, let set = live.currentSet {
                            // Which set the button logs – never a blind tick.
                            Text("\(item.name) · \(set.label(mode: item.mode, unit: live.unit))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if placement != .inline {
                if live.undoableTick != nil {
                    Button("Undo") { live.undoLastTick() }
                        .font(.subheadline.weight(.semibold))
                } else if live.currentSet != nil {
                    Button {
                        live.primaryAction()
                    } label: {
                        Image(systemName: live.isPaused ? "play.fill" : (live.primaryIsStart ? "play.fill" : "checkmark"))
                            .font(.subheadline.weight(.bold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(accessoryLabel)
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private var accessoryLabel: String {
        // Paused: the button resumes (it never logs a set then).
        if live.isPaused { return "Resume the workout" }
        guard let item = live.currentItem, let set = live.currentSet else { return "Set" }
        let what = "\(item.name), \(set.label(mode: item.mode, unit: live.unit))"
        return live.primaryIsStart ? "Start \(what)" : "Mark \(what) done"
    }

    private var idle: some View {
        let suggestion = store.suggestedTemplate(in: store.activeProgram)
        return HStack(spacing: 10) {
            Button {
                if let suggestion { live.requestStart(.template(suggestion)) } else { router.showCreate = true }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(suggestion.map { "Start \($0.name)" } ?? "Start a workout")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if placement != .inline {
                            Text(suggestion.map { $0.subtitle.isEmpty ? $0.summaryLine : $0.subtitle } ?? "Pick a template or start empty")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                router.showCreate = true
            } label: {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.bold))
            }
            .accessibilityLabel("Create")
        }
        .padding(.horizontal, 14)
    }
}
#endif

/// Floating "now playing" bar shown on the Mac while a workout runs in the background.
struct MiniPlayerBar: View {
    @Environment(LiveWorkoutController.self) private var live

    var body: some View {
        Button {
            live.isPresented = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    ProgressRing(progress: live.content.progress, tint: .accentColor, lineWidth: 4)
                    // Paused: the pause glyph, as on iPhone.
                    Image(systemName: live.isPaused ? "pause.fill" : (live.session?.kind.symbol ?? "figure.mixed.cardio"))
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(live.session?.title ?? "Workout")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(spacing: 6) {
                            Text(Format.clock(Int(live.elapsed(at: context.date))))
                                .monospacedDigit()
                            if live.restEndsAt != nil {
                                Text("· Rest \(Format.clock(live.restRemaining(at: context.date)))")
                                    .monospacedDigit()
                                    .foregroundStyle(.teal)
                            } else if let item = live.currentItem {
                                Text("· \(item.name)").lineLimit(1)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let set = live.currentSet, let item = live.currentItem {
                    Text(set.label(mode: item.mode, unit: live.unit))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button {
                    live.primaryAction()
                } label: {
                    Image(systemName: live.isPaused || live.primaryIsStart ? "play.fill" : "checkmark")
                        .font(.body.weight(.bold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(live.currentSet == nil && !live.isPaused)
                .accessibilityLabel(live.isPaused ? "Resume the workout" : (live.primaryIsStart ? "Start the set" : "Mark set done"))
                .help(live.isPaused ? "Resume" : (live.primaryIsStart ? "Start the set" : "Mark set done"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .floatingGlass(cornerRadius: 28, interactive: true)
        .frame(maxWidth: 560)
    }
}

/// The Mac's bar while a workout runs on another device (synced): read-only, with "Continue Here".
/// Tapping it shows the workout (read-only while it runs there).
struct OtherDevicePlayerBar: View {
    let session: WorkoutSession
    @Environment(LiveWorkoutController.self) private var live
    @Environment(Router.self) private var router

    var body: some View {
        let content = session.content
        HStack(spacing: 12) {
            Button {
                router.open(.session(session.id), in: .allSessions)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        ProgressRing(progress: content.progress, tint: .secondary, lineWidth: 4)
                        Image(systemName: session.resumedAt == nil ? "pause.fill" : "iphone.and.arrow.forward")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ThisDevice.runningTitle(for: session))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(RunningWorkout.progressLine(title: session.title, content: content))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show this workout")
            Button("Continue Here") { live.continueHere(session) }
                .buttonStyle(.glass)
                .help("Take this workout over on this Mac")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .floatingGlass(cornerRadius: 28, interactive: true)
        .frame(maxWidth: 560)
    }
}
