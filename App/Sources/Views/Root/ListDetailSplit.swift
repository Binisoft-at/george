import SwiftUI
import GeorgeCore

// iPad at regular width: Workouts, Plans and the program tabs show their list with the chosen
// workout, template or exercise next to it (like the Mac), instead of pushing each one full width.
// The list column keeps the tab's path (`Router.paths`), so lists opened from Plans stack there;
// the detail column shows `Router.splitDetail` with what was opened from it (`splitPaths`) on top.
// iPhone and compact iPad windows keep one stack per tab (`TabStack`).

extension AppTab {
    /// Tabs whose list gets its detail next to it on iPad.
    var showsListAndDetail: Bool {
        switch self {
        case .workouts, .plans, .program: return true
        case .today, .insights, .search: return false
        }
    }
}

extension Route {
    /// The item a detail entry shows (nil for a list screen).
    var detailItem: DetailItem? {
        if case .detail(let item) = self { return item }
        return nil
    }
}

private struct SplitListTabKey: EnvironmentKey {
    static let defaultValue: AppTab? = nil
}

extension EnvironmentValues {
    /// Set on an iPad list column (`SplitTabStack`): its rows select what the detail column shows
    /// (`NavList`, `DetailLink`) instead of pushing.
    var splitListTab: AppTab? {
        get { self[SplitListTabKey.self] }
        set { self[SplitListTabKey.self] = newValue }
    }
}

extension Router {
    /// Shows `item` next to `tab`'s list; what was opened on top of the previous item closes.
    func showInSplit(_ item: DetailItem?, in tab: AppTab) {
        if splitDetail[tab] != item { splitDetail[tab] = item }
        if splitPaths[tab]?.isEmpty == false { splitPaths[tab] = [] }
    }

    /// iPad: `tab` shows list and detail side by side (regular width) or one stack (compact) – an
    /// open workout or template moves along (GeorgeCore `ListDetailPath`).
    func setSplit(_ isSplit: Bool, for tab: AppTab) {
        guard isSplit != splitTabs.contains(tab) else { return }
        if isSplit {
            splitTabs.insert(tab)
            let parts = ListDetailPath.split(paths[tab] ?? [], item: { (route: Route) -> DetailItem? in route.detailItem })
            guard let item = parts.item else { return }
            paths[tab] = parts.lists
            splitDetail[tab] = item
            splitPaths[tab] = parts.onTop
        } else {
            splitTabs.remove(tab)
            let lists = paths[tab] ?? []
            let joined = ListDetailPath.join(lists: lists, item: splitDetail[tab], onTop: splitPaths[tab] ?? [], wrap: Route.detail)
            splitDetail[tab] = nil
            splitPaths[tab] = nil
            if joined != lists { paths[tab] = joined }
        }
    }
}

#if os(iOS)
/// iPad at regular width: a tab's lists on the left, the chosen item on the right.
struct SplitTabStack<Root: View>: View {
    let tab: AppTab
    let root: () -> Root
    @Environment(Router.self) private var router
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            listColumn
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
        } detail: {
            detailColumn
        }
        // Both columns stay visible in portrait too; the list can still be hidden with its button.
        .navigationSplitViewStyle(.balanced)
    }

    private var listColumn: some View {
        // Lists only: an item opened before the tab was split moves to the detail column (`setSplit`).
        let path = Array((router.paths[tab] ?? []).prefix(while: { $0.detailItem == nil }))
        return NavigationStack(path: Binding(get: { path }, set: { router.paths[tab] = $0 })) {
            root()
                .navigationDestination(for: Route.self) { route in
                    RouteScreen(route: route)
                }
        }
        .environment(\.splitListTab, tab)
    }

    private var detailColumn: some View {
        let item = router.splitDetail[tab]
        let path = router.splitPaths[tab] ?? []
        return NavigationStack(path: Binding(get: { path }, set: { router.splitPaths[tab] = $0 })) {
            DetailScreen(item: item, list: listShown)
                .navigationDestination(for: Route.self) { route in
                    RouteScreen(route: route)
                }
        }
        // Another item starts a fresh stack.
        .id(item)
    }

    /// The list next to the detail: the empty detail names what to choose.
    private var listShown: SidebarItem? {
        for route in (router.paths[tab] ?? []).reversed() {
            if case .screen(let item) = route { return item }
        }
        switch tab {
        case .workouts: return .allSessions
        case .program(let id): return .program(id)
        default: return .templates
        }
    }
}

/// One entry of a split column's stack.
private struct RouteScreen: View {
    let route: Route

    var body: some View {
        switch route {
        case .screen(let item): ScreenView(item: item)
        case .detail(let item): DetailScreen(item: item)
        }
    }
}
#endif
