import SwiftUI
import BinisoftKit
import SwiftData
import TipKit
import GeorgeCore

struct SessionListView: View {
    let scope: SessionScope
    /// When shown inside a program, the program header (segmented control etc.) goes on top.
    var programHeader: AnyView? = nil
    /// Overrides the scope's title (e.g. "Workouts" in the tab).
    var title: String? = nil

    @Environment(GeorgeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Environment(LiveWorkoutController.self) private var live
    /// Everything but workouts in progress: a running workout saves on every tick, and the list isn't
    /// fetched again for that – its row (`sessions`) follows the workout by itself.
    @Query(filter: #Predicate<WorkoutSession> { $0.statusRaw != "active" }) private var stored: [WorkoutSession]
    @Query(sort: \Program.sortIndex) private var programs: [Program]

    @AppStorage("sessionGrouping") private var grouping: SessionGrouping = .date
    @AppStorage("sessionSort") private var sort: SessionSort = .date
    @AppStorage("hideSkipped") private var hideSkipped = false
    @State private var query = ""
    /// `query` once typing pauses: the list filters per word, not per letter.
    @State private var appliedQuery = ""
    /// Each workout's lowercased search text, kept between redraws.
    @State private var searchTexts = SearchTextCache()
    @State private var tokens: [SearchToken] = []
    @State private var isSelecting = false
    @State private var selection = Set<UUID>()
    /// Mac: rows ⌘-clicked or ⇧-clicked in the list. More than one shows the bulk actions.
    @State private var listSelection = Set<DetailItem>()
    @State private var confirmBulkDelete = false
    /// A workout running on another device, to be deleted once asked ("Running on your iPhone").
    @State private var deleteElsewhere: WorkoutSession?
    @State private var logSession: WorkoutSession?

    /// The Planned list reads soonest first unless another order was picked.
    private var effectiveSort: SessionSort {
        scope == .planned && sort == .date ? .planned : sort
    }

    // Split so the compiler type-checks it in time: the Delete questions are in `withDeleteDialogs`.
    var body: some View {
        withDeleteDialogs(listBody)
    }

    @ViewBuilder
    private var listBody: some View {
        // Filtered once per update (the overlay, the tip and the animation use the same list).
        let filtered = self.filtered
        let groups = SessionGrouper.group(effectiveSort.sort(filtered), by: grouping, calendar: store.calendar)

        Group {
            if isSelecting {
                List(selection: $selection) {
                    headerSection(hasRows: !filtered.isEmpty)
                    listContent(groups)
                }
                #if os(iOS)
                .environment(\.editMode, .constant(.active))
                #endif
            } else {
                NavList(selection: $listSelection) {
                    headerSection(hasRows: !filtered.isEmpty)
                    listContent(groups)
                }
            }
        }
        #if os(macOS)
        // The Delete key: the selected workout(s) go, with Undo – never the one running here, and one
        // running on another device only once asked.
        .onDeleteCommand(perform: deleteSelected)
        #endif
        .groupedList()
        .navigationTitle(title ?? scope.title)
        .searchable(text: $query, tokens: $tokens, prompt: "Search workouts, exercises, notes") { token in
            Label(token.title, systemImage: token.symbol)
        }
        .searchSuggestions {
            if query.isEmpty || query.hasPrefix("#") {
                ForEach(suggestedTokens) { token in
                    Label(token.title, systemImage: token.symbol)
                        .searchCompletion(token)
                }
            }
        }
        .task(id: query) { await applyQuery() }
        .overlay {
            if filtered.isEmpty {
                if !appliedQuery.isEmpty || !tokens.isEmpty {
                    ContentUnavailableView.search(text: appliedQuery)
                } else {
                    EmptyStateView(
                        title: "No Workouts Yet",
                        message: "Start a template, plan one for later, or log something you already did.",
                        symbol: "figure.strengthtraining.functional",
                        createTitle: "Create",
                        onCreate: { router.showCreate = true },
                        onImport: { router.showImport = true }
                    )
                }
            }
        }
        .toolbar { toolbarContent }
        .animation(.default, value: filtered.count)
        .sheet(item: $logSession) { session in
            NavigationStack { LogPastWorkoutSheet(session: session) }
        }
    }

    @ViewBuilder
    private func headerSection(hasRows: Bool) -> some View {
        if let programHeader {
            Section {
                programHeader
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
        if !isSelecting && hasRows {
            TipView(GeorgeTips.SwipeTip())
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        }
    }

    @ViewBuilder
    private func listContent(_ groups: [SessionGroup]) -> some View {
        ForEach(groups) { group in
            Section {
                ForEach(group.sessions) { session in
                    rowContent(session)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if session.status != .completed {
                            Button {
                                live.requestStart(.session(session))
                            } label: {
                                Label(session.status == .active ? "Continue" : "Start", systemImage: "play.fill")
                            }
                            .tint(.green)
                        }
                        Button {
                            session.isPinned.toggle()
                            store.save()
                        } label: {
                            Label(session.isPinned ? "Unpin" : "Pin", systemImage: session.isPinned ? "pin.slash.fill" : "pin.fill")
                        }
                        .tint(.orange)
                    }
                    // A full swipe never ends a workout in progress: the running one offers Open and
                    // Discard… (live mode asks first) instead of Delete.
                    .swipeActions(edge: .trailing, allowsFullSwipe: session.status != .active) {
                        if live.session?.id == session.id {
                            Button {
                                live.isPresented = true
                                live.discardRequest = true
                            } label: {
                                Label("Discard…", systemImage: "trash")
                            }
                            .tint(.red)
                            Button {
                                live.isPresented = true
                            } label: {
                                Label("Open", systemImage: "play.fill")
                            }
                            .tint(.green)
                        } else if session.status == .active {
                            // Running on another device: asks first (not a destructive role – the row
                            // would slide away before the answer).
                            Button {
                                deleteElsewhere = session
                            } label: {
                                Label("Delete…", systemImage: "trash")
                            }
                            .tint(.red)
                        } else {
                            Button(role: .destructive) {
                                router.close(.session(session.id))
                                store.trash(session, toasts: toasts)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        Button {
                            _ = store.duplicate(session, asPlannedOn: Date())
                        } label: {
                            Label("Again", systemImage: "arrow.clockwise")
                        }
                        .tint(.indigo)
                        if session.status == .planned {
                            Button {
                                store.setStatus(.skipped, for: [session])
                            } label: {
                                Label("Skip", systemImage: "forward")
                            }
                            .tint(.gray)
                        }
                    }
                    .contextMenu {
                        SessionMenuItems(session: session, onLogPast: { logSession = $0 },
                                         onDeleteRunningElsewhere: { deleteElsewhere = $0 })
                    } preview: {
                        WorkoutPreview(session: session)
                    }
                    .draggable("session:\(session.id.uuidString)")
                }
            } header: {
                if !group.title.isEmpty {
                    Text(group.title)
                }
            }
        }
    }

    @ViewBuilder
    private func rowContent(_ session: WorkoutSession) -> some View {
        if isSelecting {
            SessionRow(session: session, showProgram: showProgramInRows)
        } else {
            DetailLink(.session(session.id)) {
                SessionRow(session: session, showProgram: showProgramInRows)
            }
        }
    }

    // MARK: Delete

    /// One rule on every path (`SessionDelete`): the workout running here is discarded in live mode,
    /// one running on another device goes only once asked ("Running on your iPhone" – it stops
    /// there too), the rest with Undo. Bulk Delete asks once and says so when one runs elsewhere.
    private func withDeleteDialogs(_ base: some View) -> some View {
        base
        .confirmationDialog(SessionDelete.bulkTitle(count: bulkIDs.count), isPresented: $confirmBulkDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteBulk() }
        } message: {
            if let message = SessionDelete.bulk(selectedSessions.map { deleteCandidate($0) }).message {
                Text(message)
            }
        }
        .confirmationDialog(elsewhereTitle, isPresented: confirmsElsewhere, titleVisibility: .visible, presenting: elsewhereTarget) { session in
            Button("Delete", role: .destructive) { deleteAsked(session) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(SessionDelete.stopsThereToo)
        }
    }

    /// The workout asked about, while it still exists: one deleted meanwhile (on another device)
    /// closes the question and isn't read any further.
    private var elsewhereTarget: WorkoutSession? {
        guard let session = deleteElsewhere, session.modelContext != nil, !session.isDeleted else { return nil }
        return session
    }

    private var elsewhereTitle: String {
        elsewhereTarget.map { ThisDevice.runningTitle(for: $0) } ?? ""
    }

    private var confirmsElsewhere: Binding<Bool> {
        Binding(get: { elsewhereTarget != nil }, set: { if !$0 { deleteElsewhere = nil } })
    }

    private func deleteCandidate(_ session: WorkoutSession) -> SessionDelete.Candidate {
        SessionDelete.Candidate(isActive: session.status == .active, isLiveHere: session.id == live.session?.id,
                                deviceName: ThisDevice.ownerName(of: session))
    }

    /// The running workout isn't deleted behind live mode's back (it's discarded there).
    private func deleteBulk() {
        let chosen = selectedSessions
        let plan = SessionDelete.bulk(chosen.map { deleteCandidate($0) })
        let deletable = plan.deleted.map { chosen[$0] }
        if deletable.isEmpty {
            if plan.keptRunningHere { toasts.show("A running workout is discarded in live mode", symbol: "play.circle") }
        } else {
            for session in deletable { router.close(.session(session.id)) }
            store.trash(deletable, toasts: toasts, keptRunning: plan.keptRunningHere)
        }
        selection.removeAll()
        listSelection.removeAll()
        isSelecting = false
    }

    /// Deletes with Undo once asked – unless it's gone meanwhile, or now runs here (Continue Here).
    private func deleteAsked(_ session: WorkoutSession) {
        guard session.modelContext != nil, !session.isDeleted, session.id != live.session?.id else { return }
        router.close(.session(session.id))
        store.trash(session, toasts: toasts)
    }

    // MARK: Data

    /// The stored workouts plus those in progress (here or on another device; fetched by status, 0–2
    /// rows). A running workout's row redraws from its own changes; the list follows Start and Finish
    /// through `stored`, and a workout started or ended elsewhere through the revision.
    private var sessions: [WorkoutSession] {
        let _ = store.revision
        return stored + store.activeSessions
    }

    /// The program label only helps when there's more than one program to tell apart.
    private var showProgramInRows: Bool {
        if case .program = scope { return false }
        return programs.filter { !$0.isArchived }.count > 1
    }

    private var scoped: [WorkoutSession] {
        sessions.filter { session in
            switch scope {
            case .all: return true
            case .planned: return session.status == .planned
            case .done: return session.status.isPerformed
            case .favorites: return session.isFavorite
            case .kind(let kind): return session.kind == kind
            case .program(let id): return session.program?.id == id
            }
        }
    }

    /// Typing waits for a short pause before the list filters; clearing the search shows all at once.
    private func applyQuery() async {
        if !query.isEmpty {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
        }
        appliedQuery = query
    }

    private var filtered: [WorkoutSession] {
        let words = appliedQuery.lowercased().split(separator: " ").map(String.init)
        let texts = searchTexts
        return scoped.filter { session in
            if hideSkipped && session.status == .skipped { return false }
            if !tokens.allSatisfy({ $0.matches(session) }) { return false }
            guard !words.isEmpty else { return true }
            let raw = [session.title, session.subtitle, session.notes, session.exerciseNames, session.tagsRaw, session.program?.name ?? ""]
                .joined(separator: " ")
            // Lowercased once per change of the workout, not on every redraw.
            let haystack = texts.lowercased(raw, for: session)
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private var suggestedTokens: [SearchToken] {
        var result: [SearchToken] = Array(Set(scoped.map(\.kind))).sorted().map { .kind($0) }
        result += [.status(.planned), .status(.completed), .status(.partial)]
        let tags = Set(scoped.flatMap(\.tags)).sorted()
        result += tags.map { .tag($0) }
        result += [.priority(.high)]
        return result.filter { !tokens.contains($0) }
    }

    /// What the bulk actions work on: the rows ticked in Select mode, or (Mac) the rows ⌘-clicked.
    private var bulkIDs: Set<UUID> {
        if isSelecting { return selection }
        guard listSelection.count > 1 else { return [] }
        return Set(listSelection.compactMap { item -> UUID? in
            if case .session(let id) = item { return id }
            return nil
        })
    }

    /// Select mode, or more than one row selected on the Mac.
    private var showsBulkActions: Bool { isSelecting || bulkIDs.count > 1 }

    private var selectedSessions: [WorkoutSession] {
        let ids = bulkIDs
        return sessions.filter { ids.contains($0.id) }
    }

    #if os(macOS)
    /// The Delete key. Several rows: asks first, like the bulk Delete. One: gone with Undo. The
    /// workout running here is discarded in live mode; one running on another device asks first.
    private func deleteSelected() {
        if bulkIDs.count > 1 {
            confirmBulkDelete = true
            return
        }
        guard case .session(let id) = router.detail, let session = sessions.first(where: { $0.id == id }) else { return }
        if session.id == live.session?.id {
            toasts.show("A running workout is discarded in live mode", symbol: "play.circle")
            return
        }
        if session.status == .active {
            // Not live here: another device runs it ("Running on your iPhone – It stops there too.").
            deleteElsewhere = session
            return
        }
        router.close(.session(session.id))
        store.trash(session, toasts: toasts)
    }
    #endif

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .georgeTrailing) {
            if isSelecting {
                Button("Done") {
                    isSelecting = false
                    selection.removeAll()
                }
                .fontWeight(.semibold)
            } else {
                Menu {
                    Picker("Group By", selection: $grouping) {
                        ForEach(SessionGrouping.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Picker("Sort By", selection: $sort) {
                        ForEach(SessionSort.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Toggle("Hide Skipped", isOn: $hideSkipped)
                    Divider()
                    Button {
                        isSelecting = true
                    } label: {
                        Label("Select Workouts", systemImage: "checkmark.circle")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .help("Group, sort and select")
                Button {
                    router.showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create")
                .help("Create")
            }
        }
        // Select mode, or several rows ⌘-clicked on the Mac.
        if showsBulkActions {
            ToolbarItemGroup(placement: bulkPlacement) {
                Menu {
                    Button("No Program") { store.move(selectedSessions, to: nil) }
                    ForEach(programs) { program in
                        Button(program.name) { store.move(selectedSessions, to: program) }
                    }
                } label: {
                    Label("Move", systemImage: "folder")
                }
                .disabled(bulkIDs.isEmpty)
                .help("Move to a program")
                Spacer()
                Menu {
                    ForEach(SessionStatus.allCases.filter { $0 != .active }) { status in
                        Button(status.displayName) { mark(selectedSessions, as: status) }
                    }
                } label: {
                    Label("Mark", systemImage: "checkmark.circle")
                }
                .disabled(bulkIDs.isEmpty)
                .help("Mark as")
                Spacer()
                Button {
                    for session in selectedSessions { _ = store.duplicate(session, asPlannedOn: Date()) }
                    selection.removeAll()
                    listSelection.removeAll()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .disabled(bulkIDs.isEmpty)
                .help("Plan again today")
                Spacer()
                Button(role: .destructive) {
                    confirmBulkDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(bulkIDs.isEmpty)
                .help("Delete")
            }
        }
    }

    /// Bulk "Mark": the workout running here stays in progress – it's finished in live mode.
    private func mark(_ sessions: [WorkoutSession], as status: SessionStatus) {
        let markable = sessions.filter { $0.id != live.session?.id }
        if !markable.isEmpty { store.setStatus(status, for: markable) }
        if markable.count < sessions.count {
            toasts.show("The running workout stays in progress – finish it in live mode", symbol: "play.circle")
        }
    }

    private var bulkPlacement: ToolbarItemPlacement {
        #if os(iOS)
        return .bottomBar
        #else
        return .automatic
        #endif
    }
}

/// Each workout's lowercased search text (the Workouts list's search), made again only when the
/// text it's made from changes – not for every workout on every redraw.
final class SearchTextCache {
    private var entries: [ObjectIdentifier: (raw: String, lowered: String)] = [:]

    func lowercased(_ raw: String, for object: AnyObject) -> String {
        let key = ObjectIdentifier(object)
        if let entry = entries[key], entry.raw == raw { return entry.lowered }
        let lowered = raw.lowercased()
        entries[key] = (raw, lowered)
        return lowered
    }
}

/// Context-menu preview of a workout's exercises. Takes the workout and reads its exercises in its
/// own body – that runs when the preview opens, not for every row when the list is built.
struct WorkoutPreview: View {
    let title: String
    let subtitle: String
    let kind: WorkoutKind
    private let loadContent: () -> WorkoutContent
    @Environment(GeorgeStore.self) private var store

    init(session: WorkoutSession) {
        title = session.title
        subtitle = session.subtitle
        kind = session.kind
        loadContent = { session.content }
    }

    init(template: WorkoutTemplate) {
        title = template.name
        subtitle = template.subtitle
        kind = template.kind
        loadContent = { template.content }
    }

    var body: some View {
        let content = loadContent()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                KindIcon(kind: kind, size: 34)
                VStack(alignment: .leading) {
                    Text(title).font(.headline)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            ForEach(content.allItems.prefix(10)) { item in
                HStack {
                    Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.isComplete ? Color.green : Color.secondary)
                    Text(item.name).lineLimit(1)
                    Spacer()
                    Text(item.prescription(unit: store.unit))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.subheadline)
            }
            if content.exerciseCount > 10 {
                Text("+ \(content.exerciseCount - 10) more").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 340)
    }
}
