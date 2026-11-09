import SwiftUI
import BinisoftKit
import SwiftData
import GeorgeCore

struct SidebarView: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Environment(HealthKitManager.self) private var health
    @Query(sort: \Program.sortIndex) private var programs: [Program]
    @Query private var sessions: [WorkoutSession]
    @Query private var templates: [WorkoutTemplate]
    @State private var showArchived = false
    @State private var editingProgram: Program?
    @State private var programToDelete: Program?

    var body: some View {
        @Bindable var router = router

        List(selection: $router.sidebar) {
            Section {
                row(.today, title: "Today", symbol: "sun.max.fill", count: nil)
            }

            Section("Workouts") {
                row(.allSessions, title: "All Workouts", symbol: "list.bullet.rectangle", count: sessions.count)
                row(.planned, title: "Planned", symbol: "calendar", count: sessions.filter { $0.status == .planned }.count)
                row(.favorites, title: "Favorites", symbol: "star", count: sessions.filter(\.isFavorite).count)
                row(.templates, title: "All Templates", symbol: "square.on.square", count: templates.count)
            }

            Section {
                ForEach(visiblePrograms) { program in
                    programRow(program)
                }
                .onMove(perform: movePrograms)
                Button {
                    router.showNewProgram = true
                } label: {
                    Label("New Program", systemImage: "plus")
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            } header: {
                HStack {
                    Text("Programs")
                    Spacer()
                    if programs.contains(where: \.isArchived) {
                        Button(showArchived ? "Hide Archived" : "Show Archived") { showArchived.toggle() }
                            .font(.caption)
                            .buttonStyle(.borderless)
                    }
                }
            }

            if !usedKinds.isEmpty {
                Section("By Type") {
                    ForEach(usedKinds) { kind in
                        row(.kind(kind.rawValue), title: kind.displayName, symbol: kind.symbol, count: sessions.filter { $0.kind == kind }.count, tint: kind.color)
                    }
                }
            }

            Section("Insights") {
                row(.library, title: "Exercise Library", symbol: "books.vertical", count: nil)
                row(.muscles, title: "Muscles", symbol: "figure.strengthtraining.traditional", count: nil, tint: .red)
                row(.stats, title: "Stats & Records", symbol: "chart.xyaxis.line", count: nil)
                row(.energy, title: "Energy", symbol: "battery.75percent", count: nil, tint: .green)
                row(.streak, title: "Streak", symbol: "flame", count: nil, tint: .orange)
            }
        }
        .navigationTitle("George")
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .georgeLeading) {
                Button {
                    router.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            #endif
            ToolbarItem(placement: .georgeTrailing) {
                Menu {
                    Button { router.showCreate = true } label: { Label("Create…", systemImage: "plus.circle") }
                    Divider()
                    Button { router.request(.newSession) } label: { Label("New Workout", systemImage: "square.and.pencil") }
                    Button { router.request(.newTemplate) } label: { Label("New Template", systemImage: "square.on.square") }
                    Button { router.showNewProgram = true } label: { Label("New Program", systemImage: "folder.badge.plus") }
                    Divider()
                    Button { router.showImport = true } label: { Label("Import CSV…", systemImage: "square.and.arrow.down") }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $editingProgram) { program in
            NavigationStack { ProgramEditorSheet(program: program) }
        }
        .confirmationDialog(
            "Delete “\(programToDelete?.name ?? "")”?",
            isPresented: Binding(get: { programToDelete != nil }, set: { if !$0 { programToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Program and Templates", role: .destructive) {
                if let programToDelete {
                    if case .program(let id) = router.sidebar, id == programToDelete.id { router.sidebar = nil }
                    store.trash(programToDelete, toasts: toasts)
                }
                programToDelete = nil
            }
        } message: {
            Text("Templates are deleted. Logged workouts are kept under All Workouts.")
        }
        .refreshable {
            await refreshData()
        }
    }

    private func refreshData() async {
        await health.refresh()
        store.bump()
    }

    private var visiblePrograms: [Program] {
        programs
            .filter { showArchived || !$0.isArchived }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.sortIndex < rhs.sortIndex
            }
    }

    private var usedKinds: [WorkoutKind] {
        Array(Set(sessions.map(\.kind))).sorted()
    }

    private func movePrograms(from source: IndexSet, to destination: Int) {
        var ordered = visiblePrograms
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, program) in ordered.enumerated() { program.sortIndex = Double(index) }
        store.save()
    }

    private func row(_ item: SidebarItem, title: String, symbol: String, count: Int?, tint: Color? = nil) -> some View {
        NavigationLink(value: item) {
            HStack {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: symbol)
                        .foregroundStyle(tint ?? Color.accentColor)
                }
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder
    private func programRow(_ program: Program) -> some View {
        let isActive = store.settings.activeProgramID == program.id
        NavigationLink(value: SidebarItem.program(program.id)) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(program.name)
                            .lineLimit(1)
                        if isActive {
                            Text("Active program")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: program.symbol)
                        .foregroundStyle(Color(hex: program.colorHex))
                }
                Spacer()
                if program.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                }
                Text("\(program.allSessions.count + (program.templates?.count ?? 0))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .opacity(program.isArchived ? 0.5 : 1)
        }
        .dropDestination(for: String.self) { (items: [String], _: CGPoint) -> Bool in
            handleDrop(items, onto: program)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { programToDelete = program } label: { Label("Delete", systemImage: "trash") }
            Button { editingProgram = program } label: { Label("Edit", systemImage: "pencil") }
                .tint(.indigo)
        }
        .swipeActions(edge: .leading) {
            Button { store.setActive(program) } label: { Label("Set Active", systemImage: "star") }
                .tint(.orange)
            Button {
                program.isPinned.toggle()
                store.save()
            } label: { Label(program.isPinned ? "Unpin" : "Pin", systemImage: program.isPinned ? "pin.slash" : "pin") }
                .tint(.yellow)
        }
        .contextMenu {
            Button { store.setActive(program) } label: { Label("Set as Active Program", systemImage: "star") }
            Button { editingProgram = program } label: { Label("Edit…", systemImage: "pencil") }
            Button {
                program.isPinned.toggle()
                store.save()
            } label: { Label(program.isPinned ? "Unpin" : "Pin", systemImage: "pin") }
            Button {
                let copy = store.duplicate(program)
                router.sidebar = .program(copy.id)
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button {
                program.isArchived.toggle()
                store.save()
            } label: { Label(program.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox") }
            Divider()
            Button(role: .destructive) { programToDelete = program } label: { Label("Delete…", systemImage: "trash") }
        }
    }

    /// Drag workouts or templates onto a program to move them.
    private func handleDrop(_ items: [String], onto program: Program) -> Bool {
        var moved = false
        for item in items {
            let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { continue }
            if parts[0] == "session", let session = store.session(id: id) {
                store.move([session], to: program)
                moved = true
            } else if parts[0] == "template", let template = store.template(id: id) {
                store.move([template], to: program)
                moved = true
            }
        }
        if moved { Haptics.success() }
        return moved
    }
}
