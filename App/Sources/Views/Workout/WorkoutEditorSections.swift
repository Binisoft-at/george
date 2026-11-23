import SwiftUI
import BinisoftKit
import GeorgeCore

/// Whether the editor shows a reusable template or a concrete session (with checkable sets).
enum EditorMode: Equatable {
    case template
    case session(isLive: Bool)

    var isSession: Bool {
        if case .session = self { return true }
        return false
    }
}

/// The blocks/exercises part of a workout as List sections. Used inside a List.
struct WorkoutEditorSections: View {
    @Binding var content: WorkoutContent
    let mode: EditorMode
    let defaultKind: WorkoutKind
    var onToggleSet: ((UUID) -> Void)? = nil
    /// Off for a finished workout until Edit is tapped: no ticks by tap, no swipe actions, no "+",
    /// so scrolling through history can't change it.
    var isEditing: Bool = true

    @Bindable var state: EditorState
    /// A performed workout compares with the one before it ("Previous:"), never with itself or a
    /// later one. Nil for the live workout and plans: the latest before now ("Last:").
    var previousBefore: Date? = nil
    var excludingSessionID: UUID? = nil

    @Environment(GeorgeStore.self) private var store
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        ForEach(Array(content.blocks.enumerated()), id: \.element.id) { index, block in
            Section {
                if block.items.count > 1 || block.style.isGrouped {
                    BlockHeaderRow(block: block, letter: groupLetter(for: block.id)) { updated in
                        content.updateBlock(id: block.id) { $0 = updated }
                    } onUngroup: {
                        content.ungroup(blockID: block.id)
                    } onMatch: {
                        withAnimation(.snappy) { content.matchSetCounts(blockID: block.id) }
                        Haptics.success()
                    }
                    .disabled(!isEditing)
                    .listRowBackground(Color.accentColor.opacity(0.08))
                }
                ForEach(block.items) { item in
                    itemRow(item, in: block)
                        .listRowBackground(block.items.count > 1 ? Color.accentColor.opacity(0.05) : nil)
                }
                .onMove { source, destination in
                    content.moveItems(inBlock: block.id, fromOffsets: source, toOffset: destination)
                }
            } header: {
                sectionHeader(for: index)
            }
        }

        if content.isEmpty {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle.portrait")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.accentColor)
                    Text("No exercises yet")
                        .font(.headline)
                    Text("Pick from 1,000+ gym, band, stretching and yoga exercises — or type your own.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        state.insertAfterItemID = nil
                        state.swapItemID = nil
                        state.showPicker = true
                    } label: {
                        Label("Add Exercises", systemImage: "plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }

        Section {
            Button {
                state.insertAfterItemID = nil
                state.swapItemID = nil
                state.showPicker = true
            } label: {
                Label("Add Exercises", systemImage: "plus.circle.fill")
                    .font(.body.weight(.semibold))
            }
            Button {
                state.newSectionName = ""
                state.renamingSection = RenameRequest(old: nil)
            } label: {
                Label("Add Section", systemImage: "text.badge.plus")
            }
        } footer: {
            if !content.isEmpty {
                Text(content.summary(unit: store.unit))
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func sectionHeader(for index: Int) -> some View {
        let blocks = content.blocks
        let current: String? = blocks.indices.contains(index) ? blocks[index].section : nil
        let previous: String? = index > 0 && blocks.indices.contains(index - 1) ? blocks[index - 1].section : nil
        if let section = current, !section.isEmpty, section != previous {
            Text(section)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .contextMenu {
                    Button {
                        state.newSectionName = section
                        state.renamingSection = RenameRequest(old: section)
                    } label: {
                        Label("Rename Section", systemImage: "pencil")
                    }
                    Button {
                        content.renameSection(from: section, to: nil)
                    } label: {
                        Label("Remove Section Title", systemImage: "text.badge.minus")
                    }
                }
        }
    }

    private func groupLetter(for blockID: UUID) -> String {
        let grouped = content.blocks.filter { $0.items.count > 1 || $0.style.isGrouped }
        let index = grouped.firstIndex { $0.id == blockID } ?? 0
        return String(Character(UnicodeScalar(65 + (index % 26)) ?? "A"))
    }

    @ViewBuilder
    private func itemRow(_ item: WorkoutItem, in block: WorkoutBlock) -> some View {
        ItemRowView(
            item: item,
            mode: mode,
            isGrouped: block.items.count > 1,
            groupLabel: block.items.count > 1 ? groupLetter(for: block.id) + String((block.items.firstIndex { $0.id == item.id } ?? 0) + 1) : nil,
            tint: .accentColor,
            previous: previousSets(for: item),
            onToggleSet: { setID in
                if let onToggleSet { onToggleSet(setID) } else { content.toggleSet(id: setID) }
            },
            onEditSet: { setID in state.editingSet = SetEditRequest(setID: setID, itemID: item.id) },
            onAddSet: { content.addSet(to: item.id) },
            onOpen: { state.editingItemID = item.id },
            checkable: isEditing,
            previousLabel: excludingSessionID == nil ? "Last" : "Previous"
        )
        .swipeActions(edge: .trailing) {
            if isEditing {
                Button(role: .destructive) {
                    remove(item)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    state.swapItemID = item.id
                    state.showPicker = true
                } label: {
                    Label("Swap", systemImage: "arrow.triangle.swap")
                }
                .tint(.indigo)
            }
        }
        .swipeActions(edge: .leading) {
            if isEditing {
                Button {
                    content.addSet(to: item.id)
                } label: {
                    Label("Set", systemImage: "plus")
                }
                .tint(.blue)
                if mode.isSession {
                    Button {
                        content.setAllSets(of: item.id, done: !item.isComplete)
                    } label: {
                        Label(item.isComplete ? "Undo" : "All Done", systemImage: "checkmark.circle")
                    }
                    .tint(.green)
                }
            }
        }
        .contextMenu {
            itemMenu(item, in: block)
        }
    }

    /// Removes an exercise with all its sets; the toast's Undo puts the workout back as it was.
    private func remove(_ item: WorkoutItem) {
        let before = content
        content.removeItem(id: item.id)
        toasts.show("Removed \u{201C}\(item.name)\u{201D}", symbol: "trash.fill") { content = before }
    }

    @ViewBuilder
    private func itemMenu(_ item: WorkoutItem, in block: WorkoutBlock) -> some View {
        Button { state.editingItemID = item.id } label: { Label("Edit…", systemImage: "pencil") }
        Button {
            state.swapItemID = item.id
            state.showPicker = true
        } label: { Label("Swap Exercise…", systemImage: "arrow.triangle.swap") }
        Button { content.addSet(to: item.id) } label: { Label("Add Set", systemImage: "plus") }
        Button { content.duplicateItem(id: item.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button {
            state.insertAfterItemID = item.id
            state.showPicker = true
        } label: { Label("Insert Exercise After…", systemImage: "text.insert") }
        Divider()
        if content.blocks.last?.id != block.id {
            Button { content.groupWithNext(itemID: item.id) } label: { Label("Superset with Next", systemImage: "link") }
        }
        if block.items.count > 1 {
            Button { content.detach(itemID: item.id) } label: { Label("Remove from Group", systemImage: "link.badge.plus") }
        }
        Button { content.moveItem(id: item.id, by: -1) } label: { Label("Move Up", systemImage: "arrow.up") }
        Button { content.moveItem(id: item.id, by: 1) } label: { Label("Move Down", systemImage: "arrow.down") }
        Button {
            state.newSectionName = block.section ?? ""
            state.renamingSection = RenameRequest(old: block.section)
        } label: { Label("Rename Section…", systemImage: "textformat") }
        Divider()
        Button {
            state.tutorial = item.links.first.flatMap(URL.init(string:)) ?? TutorialLinks.youtubeSearch(for: item.name, kind: item.kind ?? defaultKind)
        } label: { Label("Watch Tutorial", systemImage: "play.rectangle") }
        Divider()
        Button(role: .destructive) { remove(item) } label: { Label("Delete", systemImage: "trash") }
    }

    private func previousSets(for item: WorkoutItem) -> [WorkoutSet]? {
        guard mode.isSession, store.settings.prefillFromLastTime else { return nil }
        return PreviousPerformanceCache.shared.sets(for: item.exerciseKey, store: store,
                                                    before: previousBefore, excluding: excludingSessionID)
    }
}

struct ItemID: Identifiable { let id: UUID }
struct URLItem: Identifiable {
    var id: String { url.absoluteString }
    let url: URL
}

/// "Last time" sets per exercise from one index of the performed history: built again only when the
/// history really changed (`SessionHistory.version` – not with template edits, plans or a running
/// workout's sets; iCloud imports too, see `CloudImportRefresher`), newest session first per
/// exercise, so a row's lookup doesn't rescan or re-sort the history.
@MainActor
final class PreviousPerformanceCache {
    static let shared = PreviousPerformanceCache()

    private struct Entry {
        let date: Date
        let sessionID: UUID
        let sets: [WorkoutSet]
    }

    private var index: [String: [Entry]] = [:]
    private var loadedRevision = -1
    private var loadedStore: ObjectIdentifier?

    /// The sets of the latest performed session before `date` (default: now) that did this exercise.
    /// The running workout is never in the history, so it needs no exclusion; pass `excluding` when
    /// editing a performed session so it doesn't find itself.
    func sets(for key: String, store: GeorgeStore, before date: Date? = nil, excluding sessionID: UUID? = nil) -> [WorkoutSet]? {
        refresh(store)
        let limit = date ?? Date()
        return index[key]?.first { $0.date < limit && $0.sessionID != sessionID }?.sets
    }

    private func refresh(_ store: GeorgeStore) {
        let id = ObjectIdentifier(store)
        let version = SessionHistory.shared.version(store)
        guard loadedRevision != version || loadedStore != id else { return }
        var built: [String: [Entry]] = [:]
        // Oldest first from the shared history – walk it backwards so each list is newest first.
        for record in SessionHistory.shared.records(store).reversed() {
            var seen = Set<String>()
            for item in record.content.allItems where item.completedSets > 0 && !seen.contains(item.exerciseKey) {
                seen.insert(item.exerciseKey)
                built[item.exerciseKey, default: []].append(Entry(date: record.date, sessionID: record.id, sets: item.sets))
            }
        }
        index = built
        loadedRevision = version
        loadedStore = id
    }
}

/// Header row of a superset / circuit block.
struct BlockHeaderRow: View {
    let block: WorkoutBlock
    let letter: String
    let onChange: (WorkoutBlock) -> Void
    let onUngroup: () -> Void
    var onMatch: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: block.style.symbol)
                .foregroundStyle(.tint)
            Text("\(block.style.displayName) \(letter)")
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if block.setCountsDiffer, let onMatch {
                Button {
                    onMatch()
                } label: {
                    Label("Match sets", systemImage: "equal.square")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityHint("Gives every exercise in this group \(block.maxSetCount) working sets")
            }
            Menu {
                Picker("Style", selection: Binding(get: { block.style }, set: { var b = block; b.style = $0; onChange(b) })) {
                    ForEach(BlockStyle.allCases.filter { $0 != .single }) { style in
                        Label(style.displayName, systemImage: style.symbol).tag(style)
                    }
                }
                Menu("Rounds") {
                    ForEach(1...10, id: \.self) { rounds in
                        Button("\(rounds) rounds") { applyRounds(rounds) }
                    }
                }
                Menu("Rest After Round") {
                    ForEach([0, 15, 30, 45, 60, 75, 90, 120, 150, 180], id: \.self) { seconds in
                        Button(seconds == 0 ? "No rest" : Format.shortDuration(seconds)) {
                            var b = block
                            b.restAfterRoundSeconds = seconds
                            onChange(b)
                        }
                    }
                }
                Divider()
                Button("Ungroup", systemImage: "link.badge.plus", action: onUngroup)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    /// Rounds count working sets: warm-ups, drop sets and a swapped exercise's replacement don't add one.
    private var detail: String {
        if block.setCountsDiffer {
            return block.laneRoundCounts.map { String($0) }.joined(separator: " · ") + " sets"
        }
        var parts = ["\(block.roundCount) rounds"]
        if let rest = block.restAfterRoundSeconds, rest > 0 { parts.append("rest \(Format.shortDuration(rest))") }
        return parts.joined(separator: " · ")
    }

    /// Every exercise gets `rounds` working sets (warm-ups and drop sets stay; sets already done are
    /// never removed).
    private func applyRounds(_ rounds: Int) {
        var b = block
        b.matchRounds(to: rounds)
        b.rounds = rounds
        onChange(b)
    }
}

struct RenameRequest: Identifiable {
    let id = UUID()
    var old: String?
}

struct SetEditRequest: Identifiable {
    var id: UUID { setID }
    var setID: UUID
    var itemID: UUID
}

/// Presentation state for the workout editor (lives on the List so sheets work for offscreen rows).
@MainActor
@Observable
final class EditorState {
    var editingItemID: UUID?
    var showPicker = false
    var swapItemID: UUID?
    var insertAfterItemID: UUID?
    var renamingSection: RenameRequest?
    var newSectionName = ""
    var editingSet: SetEditRequest?
    var tutorial: URL?
}

/// Attaches the editor's sheets/alerts. Apply to the List containing `WorkoutEditorSections`.
struct WorkoutEditorSheets: ViewModifier {
    @Binding var content: WorkoutContent
    let mode: EditorMode
    let defaultKind: WorkoutKind
    @Bindable var state: EditorState
    /// The live tick, so Done in the set and exercise editors counts like a tick in live mode.
    var onToggleSet: ((UUID) -> Void)? = nil

    func body(content view: Content) -> some View {
        view
            .sheet(isPresented: $state.showPicker) {
                ExercisePickerSheet(defaultKind: defaultKind, singleSelection: state.swapItemID != nil) { items, asGroup in
                    if let swapID = state.swapItemID, let replacement = items.first, mode.isSession,
                       content.item(id: swapID)?.sets.contains(where: \.isDone) == true {
                        // Mid-workout: the sets already done stay with the old exercise.
                        content.swapRemaining(itemID: swapID, with: replacement)
                    } else if let swapID = state.swapItemID, let replacement = items.first {
                        content.replaceExercise(
                            itemID: swapID, exerciseID: replacement.exerciseID, name: replacement.name,
                            kind: replacement.kind, mode: replacement.mode, muscles: replacement.muscles,
                            equipment: replacement.equipment, imageURL: replacement.imageURL
                        )
                    } else if let afterID = state.insertAfterItemID {
                        content.insert(items: items, afterItem: afterID)
                    } else {
                        content.append(items: items, asGroup: asGroup)
                    }
                    state.swapItemID = nil
                    state.insertAfterItemID = nil
                }
            }
            .sheet(item: Binding(get: { state.editingItemID.map { ItemID(id: $0) } }, set: { state.editingItemID = $0?.id })) { wrapper in
                NavigationStack {
                    ItemEditorSheet(content: $content, itemID: wrapper.id, mode: mode, onToggleDone: onToggleSet)
                }
            }
            .sheet(item: $state.editingSet) { request in
                NavigationStack {
                    SetEditorSheet(content: $content, itemID: request.itemID, setID: request.setID, mode: mode, onToggleDone: onToggleSet)
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: Binding(get: { state.tutorial.map { URLItem(url: $0) } }, set: { state.tutorial = $0?.url })) { item in
                LinkPlayerView(url: item.url)
            }
            .alert(
                state.renamingSection?.old == nil ? "New Section" : "Rename Section",
                isPresented: Binding(get: { state.renamingSection != nil }, set: { if !$0 { state.renamingSection = nil } })
            ) {
                TextField("e.g. WARM-UP, MAIN, FINISHER", text: $state.newSectionName)
                    .capitalizeCharacters()
                Button("Save") {
                    if let request = state.renamingSection {
                        if let old = request.old {
                            content.renameSection(from: old, to: state.newSectionName)
                        } else if !state.newSectionName.isEmpty {
                            // New section: exercises added next go into it.
                            content.blocks.append(WorkoutBlock(section: state.newSectionName, style: .single, items: []))
                            state.showPicker = true
                        }
                    }
                    state.renamingSection = nil
                }
                Button("Cancel", role: .cancel) { state.renamingSection = nil }
            }
            .onChange(of: state.showPicker) { _, isShowing in
                // Drop an empty placeholder section if nothing was added.
                if !isShowing { content.blocks.removeAll { $0.items.isEmpty } }
            }
    }
}

extension View {
    func workoutEditorSheets(content: Binding<WorkoutContent>, mode: EditorMode, defaultKind: WorkoutKind, state: EditorState,
                             onToggleSet: ((UUID) -> Void)? = nil) -> some View {
        modifier(WorkoutEditorSheets(content: content, mode: mode, defaultKind: defaultKind, state: state, onToggleSet: onToggleSet))
    }
}
