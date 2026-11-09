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
}

/// One thing to look at: a workout, template, exercise or muscle.
enum DetailItem: Hashable {
    case session(UUID)
    case template(UUID)
    case exercise(String)
    case muscle(String)
    case muscularLoad
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
    var sidebar: SidebarItem?
    var detail: DetailItem?

    // iPhone / iPad
    var tab: AppTab = .today
    var paths: [AppTab: [Route]] = [:]
    var insights: InsightsSection = .muscles
    var workoutsFilter: WorkoutsFilter = .all

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

    func request(_ request: Request) { pendingRequest = request }

    /// Shows a workout, template, exercise or muscle: the detail column on the Mac, a push on iPhone/iPad.
    func open(_ item: DetailItem, in sidebarItem: SidebarItem? = nil) {
        #if os(macOS)
        if let sidebarItem { sidebar = sidebarItem }
        detail = item
        #else
        if let sidebarItem { show(sidebarItem) }
        if paths[tab]?.last != .detail(item) {
            paths[tab, default: []].append(.detail(item))
        }
        #endif
    }

    /// Stops showing an item (e.g. after deleting it).
    func close(_ item: DetailItem) {
        if detail == item { detail = nil }
        for key in Array(paths.keys) {
            paths[key]?.removeAll { $0 == .detail(item) }
        }
    }

    /// Switches to a list screen: the sidebar selection on the Mac, the matching tab on iPhone/iPad.
    func show(_ item: SidebarItem) {
        #if os(macOS)
        sidebar = item
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
    func offerTourIfNeeded() {
        guard tour == nil else { return }
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
        case "live-mid", "live-superset":
            // Mid-workout: a few sets ticked, momentum up; "live-superset" jumps to the first superset.
            if let template = store.suggestedTemplate(in: store.activeProgram) {
                live.start(template: template)
                live.demoProgress(sets: 3, focusSuperset: launch.screen == "live-superset")
            }
        case "muscles":
            show(.muscles)
        case "stats":
            show(.stats)
        case "streak":
            show(.streak)
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
/// Mac: sidebar → list → detail, like Notes.
struct SplitRootView: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(LiveWorkoutController.self) private var live
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } content: {
            ScreenView(item: router.sidebar)
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 560)
        } detail: {
            NavigationStack {
                DetailScreen(item: router.detail)
            }
            .id(router.detail)
        }
        .safeAreaInset(edge: .bottom) {
            if live.isActive && !live.isPresented {
                MiniPlayerBar()
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: live.isActive && !live.isPresented)
        .onAppear {
            if router.sidebar == nil { router.sidebar = .today }
        }
    }
}
#else
/// iPhone/iPad: Liquid Glass tab bar (a sidebar on iPad), one stack per tab,
/// and the running workout as a "now playing" bar above the tabs.
struct TabRootView: View {
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
        .tabViewBottomAccessory {
            NowPlayingAccessory()
        }
    }
}

/// A tab's navigation stack, bound to the router so any screen can push.
struct TabStack<Root: View>: View {
    let tab: AppTab
    @ViewBuilder let root: () -> Root
    @Environment(Router.self) private var router

    var body: some View {
        let path = router.paths[tab] ?? []
        NavigationStack(path: Binding(get: { path }, set: { router.paths[tab] = $0 })) {
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
            .sheet(isPresented: $live.isPresented) {
                LiveWorkoutView()
                    .frame(minWidth: 560, idealWidth: 640, minHeight: 680, idealHeight: 760)
            }
            .sheet(isPresented: $router.showWelcome) {
                WelcomeView()
                    .frame(minWidth: 620, idealWidth: 680, minHeight: 680, idealHeight: 740)
            }
            .sheet(item: $router.tour) { request in
                TourView(request: request) { router.finishTour() }
                    .frame(minWidth: 760, idealWidth: 900, minHeight: 680, idealHeight: 780)
            }
            #endif
            .sheet(item: $live.summary) { summary in
                WorkoutSummarySheet(summary: summary)
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
                    router.offerTourIfNeeded()
                }
            }
            .onChange(of: router.pendingRequest) { _, request in
                guard let request else { return }
                router.pendingRequest = nil
                handle(request)
            }
            .onOpenURL { url in
                if url.pathExtension.lowercased() == "csv" {
                    ImportView.pendingURL = url
                    router.showImport = true
                }
            }
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
            let program = currentProgram ?? store.activeProgram
            let template = store.createTemplate(in: program)
            router.pickExercisesFor = template.id
            router.open(.template(template.id))
        case .newSession:
            let program = currentProgram ?? store.activeProgram
            let session = store.makeEmptySession(program: program, start: false)
            router.open(.session(session.id))
        case .startSuggested:
            if live.isActive {
                live.isPresented = true
            } else if let template = store.suggestedTemplate(in: store.activeProgram) {
                live.start(template: template)
            } else {
                live.startEmpty(program: store.activeProgram)
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
        case .none:
            MessageView(title: "George", systemImage: "dumbbell", message: "Pick a program or a list in the sidebar.")
        }
    }
}

/// The selected workout, template, exercise or muscle.
struct DetailScreen: View {
    let item: DetailItem?

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
        case .none:
            MessageView(title: "No Selection", systemImage: "square.text.square", message: "Choose a workout to see it here.")
        }
    }
}

// MARK: - Navigation helpers

/// A list that drives the Mac's detail column by selection and pushes on iPhone/iPad.
struct NavList<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(Router.self) private var router

    var body: some View {
        #if os(macOS)
        @Bindable var router = router
        List(selection: $router.detail) {
            content()
        }
        #else
        List {
            content()
        }
        #endif
    }
}

/// A row that opens a detail item (selection on the Mac, push on iPhone/iPad).
struct DetailLink<Label: View>: View {
    let item: DetailItem
    @ViewBuilder let label: () -> Label

    init(_ item: DetailItem, @ViewBuilder label: @escaping () -> Label) {
        self.item = item
        self.label = label
    }

    var body: some View {
        #if os(macOS)
        NavigationLink(value: item, label: label)
        #else
        NavigationLink(value: Route.detail(item), label: label)
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
    @Query private var templates: [WorkoutTemplate]

    var body: some View {
        let _ = templates.count + store.revision
        if live.isActive {
            active
        } else {
            idle
        }
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
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        if placement != .inline, let item = live.currentItem {
                            Text(item.name)
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
                live.completeCurrentSet()
            } label: {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.bold))
            }
            .disabled(live.currentSet == nil)
            .accessibilityLabel("Complete set")
        }
        .padding(.horizontal, 14)
    }

    private var idle: some View {
        let suggestion = store.suggestedTemplate(in: store.activeProgram)
        return HStack(spacing: 10) {
            Button {
                if let suggestion { live.start(template: suggestion) } else { router.showCreate = true }
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
                    Image(systemName: live.session?.kind.symbol ?? "figure.mixed.cardio")
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
                                    .foregroundStyle(.orange)
                            } else if let item = live.currentItem {
                                Text("· \(item.name)").lineLimit(1)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    live.completeCurrentSet()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.bold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(live.currentSet == nil)
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
