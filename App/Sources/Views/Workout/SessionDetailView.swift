import SwiftUI
import BinisoftKit
import SwiftData
import GeorgeCore

struct SessionDetailView: View {
    let sessionID: UUID
    @Query private var matches: [WorkoutSession]

    init(sessionID: UUID) {
        self.sessionID = sessionID
        _matches = Query(filter: #Predicate<WorkoutSession> { $0.id == sessionID })
    }

    var body: some View {
        if let session = matches.first {
            SessionDocument(session: session)
        } else {
            MessageView(title: "Workout not found", systemImage: "questionmark.square.dashed", message: "It may have been deleted on another device.")
        }
    }
}

private struct SessionDocument: View {
    @Bindable var session: WorkoutSession
    @Environment(GeorgeStore.self) private var store
    @Environment(LiveWorkoutController.self) private var live
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Query(sort: \Program.sortIndex) private var programs: [Program]
    @State private var content = WorkoutContent()
    @State private var loadedData: Data?
    @State private var editor = EditorState()
    @State private var newTag = ""
    @State private var confirmDelete = false
    @State private var showDetails = false

    private var isLive: Bool { live.session?.id == session.id }

    /// While this session is running, edits go through the live controller.
    private var contentBinding: Binding<WorkoutContent> {
        if isLive {
            return Binding(get: { live.content }, set: { live.replaceContent($0) })
        }
        return $content
    }

    var body: some View {
        List {
            if session.status.isPerformed && !isLive {
                RecapOverviewSection(session: session)
            }
            headerSection
            if session.status.isPerformed {
                StatsTilesSection(session: session)
            }
            WorkoutEditorSections(
                content: contentBinding,
                mode: .session(isLive: isLive),
                defaultKind: session.kind,
                onToggleSet: isLive ? { (setID: UUID) in live.toggleSet(setID) } : nil,
                state: editor
            )
            MuscleTargetsSection(content: contentBinding.wrappedValue, kind: session.kind, performed: session.status.isPerformed)
            notesSection
        }
        .groupedList()
        .safeAreaInset(edge: .bottom) { actionBar }
        .workoutEditorSheets(content: contentBinding, mode: .session(isLive: isLive), defaultKind: session.kind, state: editor)
        .navigationTitle(session.title.isEmpty ? "Workout" : session.title)
        .inlineTitle()
        .toolbar { toolbarItems }
        .onAppear(perform: load)
        .onChange(of: session.contentData) { _, newData in
            // External change (sync, watch, live view): reload unless it's our own write.
            if newData != loadedData && !isLive { load() }
        }
        .onChange(of: content) { _, newContent in
            guard !isLive, newContent != session.content else { return }
            session.content = newContent
            loadedData = session.contentData
            store.save()
        }
        .confirmationDialog("Delete this workout?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                router.close(.session(session.id))
                if isLive { live.discard() } else { store.trash(session, toasts: toasts) }
            }
        }
    }

    private func load() {
        content = session.content
        loadedData = session.contentData
    }

    // MARK: Header

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Title", text: $session.title, axis: .vertical)
                    .font(.title2.weight(.bold))
                    .onSubmit { store.save() }
                TextField("Subtitle (e.g. UPPER BODY + SHOULDER/WRIST HEALTH)", text: $session.subtitle, axis: .vertical)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                DatePicker(
                    session.status == .planned ? "Planned for" : "Date",
                    selection: Binding<Date>(
                        get: { session.status == .planned ? (session.plannedDate ?? Date()) : (session.startedAt ?? session.plannedDate ?? session.createdAt) },
                        set: { newDate in
                            if session.status == .planned { session.plannedDate = newDate } else { session.startedAt = newDate; session.plannedDate = newDate }
                            store.save()
                        }
                    ),
                    displayedComponents: session.status == .planned ? [.date] : [.date, .hourAndMinute]
                )
                .font(.subheadline)
                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 10) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                statusMenu
                                kindMenu
                                programMenu
                                priorityMenu
                                Button {
                                    session.isFavorite.toggle()
                                    store.save()
                                } label: {
                                    Chip(text: "Favorite", systemImage: session.isFavorite ? "star.fill" : "star", tint: session.isFavorite ? .yellow : .secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        TagEditor(tags: Binding(get: { session.tags }, set: { session.tags = $0; store.save() }))
                    }
                    .padding(.top, 6)
                } label: {
                    Text(detailsSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var detailsSummary: String {
        var parts = [session.status.displayName, session.kind.displayName]
        if let program = session.program { parts.append(program.name) }
        if session.priority != .none { parts.append(session.priority.displayName) }
        return parts.joined(separator: " · ")
    }

    /// Start / continue, always reachable at the bottom.
    @ViewBuilder
    private var actionBar: some View {
        if session.status != .completed && session.status != .skipped {
            Button {
                if isLive { live.isPresented = true } else { live.start(session) }
            } label: {
                Label(isLive ? "Open Live Workout" : (session.status == .partial ? "Continue Workout" : "Start Workout"), systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(.accentColor)
            .disabled(live.isActive && !isLive)
            .keyboardShortcut(.return, modifiers: .command)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .frame(maxWidth: 560)
        }
    }

    private var statusMenu: some View {
        Menu {
            ForEach(SessionStatus.allCases.filter { $0 != .active }) { status in
                Button {
                    store.setStatus(status, for: [session])
                } label: {
                    Label(status.displayName, systemImage: status.symbol)
                }
            }
        } label: {
            Chip(text: session.status.displayName, systemImage: session.status.symbol, tint: session.status == .completed ? .green : .blue)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var kindMenu: some View {
        Menu {
            ForEach(WorkoutKind.presets) { kind in
                Button {
                    session.kind = kind
                    store.save()
                } label: {
                    Label(kind.displayName, systemImage: kind.symbol)
                }
            }
        } label: {
            KindBadge(kind: session.kind, compact: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var programMenu: some View {
        Menu {
            Button("No Program") { store.move([session], to: nil) }
            ForEach(programs) { program in
                Button {
                    store.move([session], to: program)
                } label: {
                    Label(program.name, systemImage: program.symbol)
                }
            }
        } label: {
            Chip(text: session.program?.name ?? "No Program", systemImage: "folder", tint: session.program.map { Color(hex: $0.colorHex) } ?? .secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var priorityMenu: some View {
        Menu {
            ForEach(Priority.allCases) { priority in
                Button {
                    session.priority = priority
                    store.save()
                } label: {
                    Label(priority.displayName, systemImage: priority.symbol)
                }
            }
        } label: {
            Chip(text: session.priority == .none ? "Priority" : session.priority.displayName, systemImage: session.priority.symbol, tint: session.priority.color)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var notesSection: some View {
        Section("Notes") {
            TextField("How did it feel? Anything to change next time?", text: $session.notes, axis: .vertical)
                .lineLimit(3...12)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .georgeTrailing) {
            Menu {
                Button {
                    let copy = store.duplicate(session, asPlannedOn: Date())
                    router.open(.session(copy.id))
                } label: { Label("Do Again Today", systemImage: "arrow.clockwise") }
                Button {
                    let template = store.saveAsTemplate(session, into: session.program)
                    router.open(.template(template.id))
                } label: { Label("Save as New Template", systemImage: "square.on.square") }
                if session.templateID != nil {
                    Button {
                        store.updateTemplate(from: session)
                    } label: { Label("Update “\(session.templateName)” Template", systemImage: "arrow.triangle.2.circlepath") }
                }
                Button {
                    session.isPinned.toggle()
                    store.save()
                } label: { Label(session.isPinned ? "Unpin" : "Pin", systemImage: "pin") }
                if session.status.isPerformed {
                    Button {
                        content.resetProgress()
                    } label: { Label("Reset All Sets", systemImage: "arrow.uturn.backward") }
                }
                Divider()
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }
}

/// Summary tiles for a finished workout.
private struct StatsTilesSection: View {
    let session: WorkoutSession
    @Environment(GeorgeStore.self) private var store
    @Environment(HealthKitManager.self) private var health
    @State private var metrics: HealthMetrics?

    var body: some View {
        let energy = (metrics?.activeEnergyKcal ?? 0) > 0 ? (metrics?.activeEnergyKcal ?? 0) : session.energyKcal
        let heartRate = metrics?.averageHeartRate ?? 0
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                tile("Duration", Format.minutes(session.durationSeconds), "clock")
                tile("Sets", "\(session.doneSetCount)/\(session.setCount)", "checklist")
                if session.volumeKg > 0 { tile("Volume", Format.volume(session.volumeKg, unit: store.unit), "scalemass") }
                if energy > 0 { tile("Energy", "\(Int(energy)) kcal", "flame") }
                if heartRate > 0 { tile("Avg HR", "\(Int(heartRate)) bpm", "heart") }
                if session.effort > 0 { tile("Effort", "\(session.effort)/10", "gauge.with.dots.needle.67percent") }
            }
            .padding(.vertical, 4)
            if session.healthWorkoutID != nil {
                Label(session.recordedOnWatch ? "Recorded on Apple Watch · in Apple Health" : "Saved to Apple Health", systemImage: "heart.text.square.fill")
                    .font(.caption)
                    .foregroundStyle(.pink)
            }
        }
        .task(id: session.id) { await loadMetrics() }
    }

    /// Heart rate is kept on-device; on another iPhone/iPad it's read back from Apple Health.
    private func loadMetrics() async {
        metrics = store.healthMetrics(for: session.id)
        guard metrics == nil, health.isAvailable, let start = session.startedAt, let end = session.endedAt else { return }
        if let hr = await health.heartRate(from: start, to: end) {
            store.recordHealthMetrics(sessionID: session.id, averageHeartRate: hr.average, maxHeartRate: hr.max, activeEnergy: nil)
            metrics = store.healthMetrics(for: session.id)
        }
    }

    private func tile(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Editable tag chips.
struct TagEditor: View {
    @Binding var tags: [String]
    @State private var draft = ""

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Button {
                    tags.removeAll { $0 == tag }
                } label: {
                    HStack(spacing: 3) {
                        Text("#" + tag)
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            TextField("+ tag", text: $draft)
                .font(.caption)
                .frame(width: 80)
                .onSubmit {
                    let cleaned = draft.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "").replacingOccurrences(of: ",", with: "")
                    if !cleaned.isEmpty && !tags.contains(cleaned) { tags.append(cleaned) }
                    draft = ""
                }
        }
    }
}
