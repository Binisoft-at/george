import SwiftUI
import BinisoftKit
import SwiftData
import UniformTypeIdentifiers
import GeorgeCore

struct TemplateListView: View {
    /// nil = templates from every program.
    let programID: UUID?
    var programHeader: AnyView? = nil

    @Environment(GeorgeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Environment(LiveWorkoutController.self) private var live
    @Query private var templates: [WorkoutTemplate]
    @AppStorage("templateSort") private var sort: TemplateSort = .manual
    @State private var query = ""
    @State private var tokens: [SearchToken] = []
    @State private var logPastFor: WorkoutTemplate?

    var body: some View {
        NavList {
            if let programHeader {
                Section { programHeader }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
            if programID == nil {
                ForEach(groupedByProgram) { group in
                    Section(group.name) {
                        ForEach(group.templates) { template in row(template) }
                    }
                }
            } else {
                Section {
                    ForEach(sorted) { template in row(template) }
                        .onMove(perform: sort == .manual && query.isEmpty ? move : nil)
                } header: {
                    if !sorted.isEmpty { Text("Templates") }
                } footer: {
                    if !sorted.isEmpty {
                        Text("Tap ▶︎ to start a workout. It's named automatically (e.g. “W44: 3 UPPER - 29.10”) and saved under Workouts.")
                    }
                }
            }
        }
        .groupedList()
        .navigationTitle(programID == nil ? "All Templates" : "Templates")
        .searchable(text: $query, tokens: $tokens, prompt: "Search templates and exercises") { token in
            Label(token.title, systemImage: token.symbol)
        }
        .searchSuggestions {
            if query.isEmpty {
                ForEach(Array(Set(scoped.map(\.kind))).sorted().map { SearchToken.kind($0) }.filter { !tokens.contains($0) }) { token in
                    Label(token.title, systemImage: token.symbol).searchCompletion(token)
                }
            }
        }
        .overlay {
            if filtered.isEmpty {
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    EmptyStateView(
                        title: "No Templates",
                        message: "Templates are your reusable workouts. Create one, or import the plan you already have.",
                        symbol: "square.on.square",
                        createTitle: "New Template",
                        onCreate: newTemplate,
                        onImport: { router.showImport = true }
                    )
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .georgeTrailing) {
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(TemplateSort.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                Button(action: newTemplate) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $logPastFor) { template in
            NavigationStack { LogPastWorkoutSheet(template: template) }
        }
    }

    private func row(_ template: WorkoutTemplate) -> some View {
        DetailLink(.template(template.id)) {
            TemplateRow(template: template, showProgram: programID == nil) {
                live.start(template: template)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                live.start(template: template)
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .tint(.green)
            Button {
                let session = store.makeSession(from: template, date: Date(), start: false)
                router.open(.session(session.id))
            } label: {
                Label("Plan Today", systemImage: "calendar.badge.plus")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                router.close(.template(template.id))
                store.trash(template, toasts: toasts)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                let copy = store.duplicate(template)
                router.open(.template(copy.id))
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .tint(.indigo)
        }
        .contextMenu {
            TemplateMenuItems(template: template, logPastFor: $logPastFor)
        } preview: {
            WorkoutPreview(title: template.name, subtitle: template.subtitle, kind: template.kind, content: template.content)
        }
        .draggable("template:\(template.id.uuidString)")
    }

    private var scoped: [WorkoutTemplate] {
        guard let programID else { return templates }
        return templates.filter { $0.program?.id == programID }
    }

    private var filtered: [WorkoutTemplate] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return scoped.filter { template in
            if !tokens.allSatisfy({ $0.matches(template) }) { return false }
            guard !words.isEmpty else { return true }
            let haystack = [template.name, template.subtitle, template.notes, template.exerciseNames, template.tagsRaw]
                .joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private var sorted: [WorkoutTemplate] {
        switch sort {
        case .manual:
            return filtered.sorted { $0.sortIndex != $1.sortIndex ? $0.sortIndex < $1.sortIndex : $0.createdAt < $1.createdAt }
        case .name:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .lastUsed:
            return filtered.sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
        case .updated:
            return filtered.sorted { $0.updatedAt > $1.updatedAt }
        case .priority:
            return filtered.sorted { $0.priorityRaw > $1.priorityRaw }
        }
    }

    private struct ProgramGroup: Identifiable {
        var id: String { name }
        var name: String
        var templates: [WorkoutTemplate]
    }

    private var groupedByProgram: [ProgramGroup] {
        let dict = Dictionary(grouping: sorted) { $0.program?.name ?? "No Program" }
        return dict.keys.sorted().map { ProgramGroup(name: $0, templates: dict[$0] ?? []) }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = sorted
        ordered.move(fromOffsets: source, toOffset: destination)
        store.reorder(ordered)
    }

    private func newTemplate() {
        let template = store.createTemplate(in: store.program(id: programID) ?? (programID == nil ? store.activeProgram : nil))
        router.pickExercisesFor = template.id
        router.open(.template(template.id))
    }
}

/// A program folder: header with stats, a Templates / Workouts switch.
struct ProgramView: View {
    let programID: UUID
    @Environment(GeorgeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(LiveWorkoutController.self) private var live
    @Query private var programs: [Program]
    @AppStorage("programMode") private var mode: ProgramMode = .templates
    @State private var editing = false
    @State private var exportText: String?

    enum ProgramMode: String, CaseIterable, Identifiable {
        case templates, workouts
        var id: String { rawValue }
        var title: String { self == .templates ? "Templates" : "Workouts" }
    }

    var body: some View {
        if let program = programs.first(where: { $0.id == programID }) {
            content(program)
                .navigationTitle(program.name)
                .toolbar {
                    ToolbarItem(placement: .georgeTrailing) {
                        Menu {
                            Button { editing = true } label: { Label("Edit Program…", systemImage: "pencil") }
                            Button { store.setActive(program) } label: { Label("Set as Active Program", systemImage: "star") }
                            Button { router.showImport = true } label: { Label("Import CSV…", systemImage: "square.and.arrow.down") }
                            Button { exportText = store.exportCSV(for: program) } label: { Label("Export as CSV…", systemImage: "square.and.arrow.up") }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }
                }
                .sheet(isPresented: $editing) {
                    NavigationStack { ProgramEditorSheet(program: program) }
                }
                .sheet(item: Binding(get: { exportText.map { ExportPayload(text: $0, name: program.name) } }, set: { if $0 == nil { exportText = nil } })) { payload in
                    ExportSheet(payload: payload)
                }
        } else {
            MessageView(title: "Program not found", systemImage: "folder")
        }
    }

    @ViewBuilder
    private func content(_ program: Program) -> some View {
        let header = AnyView(ProgramHeader(program: program, mode: $mode))
        switch mode {
        case .templates:
            TemplateListView(programID: program.id, programHeader: header)
        case .workouts:
            SessionListView(scope: .program(program.id), programHeader: header)
        }
    }
}

struct ProgramHeader: View {
    let program: Program
    @Binding var mode: ProgramView.ProgramMode
    @Environment(GeorgeStore.self) private var store

    var body: some View {
        let calendar = store.calendar
        let thisWeek = program.performedSessions.filter { calendar.weekStart(for: $0.date) == calendar.weekStart(for: Date()) }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: program.symbol)
                    .font(.title2)
                    .foregroundStyle(Color(hex: program.colorHex))
                    .frame(width: 44, height: 44)
                    .background(Color(hex: program.colorHex).opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    if !program.subtitle.isEmpty {
                        Text(program.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Label("\(program.templates?.count ?? 0)", systemImage: "square.on.square")
                        Label("\(program.performedSessions.count)", systemImage: "checkmark.circle")
                        Label("\(thisWeek) this week", systemImage: "calendar")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if store.settings.activeProgramID == program.id {
                    Chip(text: "Active", systemImage: "star.fill", tint: .orange)
                }
            }
            Picker("Show", selection: $mode) {
                ForEach(ProgramView.ProgramMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}

struct ExportPayload: Identifiable {
    var id: String { name }
    var text: String
    var name: String
}

/// Shows exported CSV with share/copy options.
struct ExportSheet: View {
    let payload: ExportPayload
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(payload.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("\(payload.name).csv")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    ShareLink(item: CSVDocument(text: payload.text, name: payload.name), preview: SharePreview("\(payload.name).csv"))
                }
            }
        }
    }
}

/// Transferable CSV file for ShareLink / Files export.
struct CSVDocument: Transferable {
    let text: String
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { document in
            let safeName = document.name.replacingOccurrences(of: "/", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).csv")
            try document.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}
