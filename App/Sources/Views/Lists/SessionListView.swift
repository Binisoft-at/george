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
    @Query private var sessions: [WorkoutSession]
    @Query(sort: \Program.sortIndex) private var programs: [Program]

    @AppStorage("sessionGrouping") private var grouping: SessionGrouping = .date
    @AppStorage("sessionSort") private var sort: SessionSort = .date
    @AppStorage("hideSkipped") private var hideSkipped = false
    @State private var query = ""
    @State private var tokens: [SearchToken] = []
    @State private var isSelecting = false
    @State private var selection = Set<UUID>()
    @State private var confirmBulkDelete = false

    var body: some View {
        let groups = SessionGrouper.group(sort.sort(filtered), by: grouping, calendar: store.calendar)

        Group {
            if isSelecting {
                List(selection: $selection) {
                    headerSection
                    listContent(groups)
                }
                #if os(iOS)
                .environment(\.editMode, .constant(.active))
                #endif
            } else {
                NavList {
                    headerSection
                    listContent(groups)
                }
            }
        }
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
        .overlay {
            if filtered.isEmpty {
                if !query.isEmpty || !tokens.isEmpty {
                    ContentUnavailableView.search(text: query)
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
        .confirmationDialog("Delete \(selection.count) workouts?", isPresented: $confirmBulkDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.trash(selectedSessions, toasts: toasts)
                selection.removeAll()
                isSelecting = false
            }
        }
        .animation(.default, value: filtered.map(\.id))
    }

    @ViewBuilder
    private var headerSection: some View {
        if let programHeader {
            Section {
                programHeader
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
        if !isSelecting && !filtered.isEmpty {
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
                                live.start(session)
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
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            router.close(.session(session.id))
                            if live.session?.id == session.id { live.discard() } else { store.trash(session, toasts: toasts) }
                        } label: {
                            Label("Delete", systemImage: "trash")
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
                        SessionMenuItems(session: session)
                    } preview: {
                        WorkoutPreview(title: session.title, subtitle: session.subtitle, kind: session.kind, content: session.content)
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

    // MARK: Data

    private var showProgramInRows: Bool {
        if case .program = scope { return false }
        return true
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

    private var filtered: [WorkoutSession] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return scoped.filter { session in
            if hideSkipped && session.status == .skipped { return false }
            if !tokens.allSatisfy({ $0.matches(session) }) { return false }
            guard !words.isEmpty else { return true }
            let haystack = [session.title, session.subtitle, session.notes, session.exerciseNames, session.tagsRaw, session.program?.name ?? ""]
                .joined(separator: " ")
                .lowercased()
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

    private var selectedSessions: [WorkoutSession] {
        sessions.filter { selection.contains($0.id) }
    }

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
                Button {
                    router.showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create")
            }
        }
        if isSelecting {
            ToolbarItemGroup(placement: bulkPlacement) {
                Menu {
                    Button("No Program") { store.move(selectedSessions, to: nil) }
                    ForEach(programs) { program in
                        Button(program.name) { store.move(selectedSessions, to: program) }
                    }
                } label: {
                    Label("Move", systemImage: "folder")
                }
                .disabled(selection.isEmpty)
                Spacer()
                Menu {
                    ForEach(SessionStatus.allCases.filter { $0 != .active }) { status in
                        Button(status.displayName) { store.setStatus(status, for: selectedSessions) }
                    }
                } label: {
                    Label("Mark", systemImage: "checkmark.circle")
                }
                .disabled(selection.isEmpty)
                Spacer()
                Button {
                    for session in selectedSessions { _ = store.duplicate(session, asPlannedOn: Date()) }
                    selection.removeAll()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .disabled(selection.isEmpty)
                Spacer()
                Button(role: .destructive) {
                    confirmBulkDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            }
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

/// Context-menu preview of a workout's exercises.
struct WorkoutPreview: View {
    let title: String
    let subtitle: String
    let kind: WorkoutKind
    let content: WorkoutContent
    @Environment(GeorgeStore.self) private var store

    var body: some View {
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
