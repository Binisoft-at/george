import SwiftUI
import BinisoftKit
import SwiftData
import GeorgeCore

/// Search the library (+ your own exercises) and add one or many — optionally as a superset.
struct ExercisePickerSheet: View {
    let defaultKind: WorkoutKind
    var singleSelection = false
    let onPick: ([WorkoutItem], Bool) -> Void

    @Environment(ExerciseLibrary.self) private var library
    @Environment(GeorgeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var customExercises: [UserExercise]

    @State private var query = ""
    @State private var kindFilter: WorkoutKind?
    @State private var muscleFilter: String?
    @State private var selected: [LibraryExercise] = []
    @State private var asGroup = false
    @State private var didSetDefaultKind = false
    /// The search's result, worked out when the search changes – not on every redraw or tap.
    @State private var results: [LibraryExercise] = []
    /// What `results` was searched with.
    @State private var searchedKey: SearchKey?
    /// Exercises of the last workouts, read once when the sheet opens.
    @State private var recent: [LibraryExercise] = []

    /// Everything the result list depends on.
    private struct SearchKey: Hashable {
        var query: String
        var kind: WorkoutKind?
        var muscle: String?
        var customCount: Int
        var libraryCount: Int
    }

    private var searchKey: SearchKey {
        SearchKey(query: trimmedQuery, kind: kindFilter, muscle: muscleFilter,
                  customCount: customExercises.count, libraryCount: library.catalog.exercises.count)
    }

    var body: some View {
        NavigationStack {
            List {
                if !singleSelection && !selected.isEmpty {
                    Section("Selected · \(selected.count)") {
                        ForEach(selected) { exercise in
                            Text(exercise.name)
                        }
                        .onDelete { selected.remove(atOffsets: $0) }
                        .onMove { selected.move(fromOffsets: $0, toOffset: $1) }
                        if selected.count > 1 {
                            Toggle(isOn: $asGroup) {
                                Label(selected.count == 2 ? "Add as Superset" : "Add as Circuit", systemImage: "link")
                            }
                        }
                    }
                }
                if query.isEmpty && kindFilter == nil && muscleFilter == nil && !recent.isEmpty {
                    Section("Recently Used") {
                        ForEach(recent) { exercise in row(exercise) }
                    }
                }
                if !trimmedQuery.isEmpty && results.first(where: { $0.name.caseInsensitiveCompare(trimmedQuery) == .orderedSame }) == nil {
                    Section {
                        Button {
                            createCustom()
                        } label: {
                            Label("Create “\(trimmedQuery)”", systemImage: "plus.circle.fill")
                        }
                    } footer: {
                        Text("Adds your own exercise. You can attach tutorial links to it later.")
                    }
                }
                Section(resultsTitle) {
                    ForEach(results) { exercise in row(exercise) }
                }
            }
            .groupedList()
            .navigationTitle(singleSelection ? "Swap Exercise" : "Add Exercises")
            .inlineTitle()
            .searchable(text: $query, prompt: "Search 1,000+ exercises")
            .safeAreaInset(edge: .top) { filterBar }
            .safeAreaInset(edge: .bottom) {
                if !singleSelection && !selected.isEmpty {
                    Button {
                        finish()
                    } label: {
                        Label(addTitle, systemImage: asGroup && selected.count > 1 ? "link" : "plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: selected.isEmpty)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if !singleSelection {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(selected.isEmpty ? "Add" : "Add \(selected.count)") {
                            finish()
                        }
                        .disabled(selected.isEmpty)
                        .fontWeight(.semibold)
                    }
                }
            }
            .onAppear {
                if !didSetDefaultKind {
                    didSetDefaultKind = true
                    if [WorkoutKind.band, .yoga, .stretch, .mobility].contains(defaultKind) {
                        kindFilter = defaultKind
                    }
                }
            }
            .task(id: searchKey) { await runSearch(searchKey) }
            // Once – again only if the library finishes loading while the sheet is open.
            .task(id: library.isLoaded) { loadRecent() }
        }
        .macSheet(width: 520, height: 640)
    }

    // MARK: Pieces

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "All", symbol: "square.grid.2x2", isOn: kindFilter == nil) { kindFilter = nil }
                ForEach(library.catalog.kinds) { kind in
                    filterChip(title: kind.shortName, symbol: kind.symbol, isOn: kindFilter == kind, tint: kind.color) {
                        kindFilter = kindFilter == kind ? nil : kind
                    }
                }
                Menu {
                    Button("Any Muscle") { muscleFilter = nil }
                    ForEach(library.catalog.allMuscles, id: \.self) { muscle in
                        Button(muscle.capitalized) { muscleFilter = muscle }
                    }
                } label: {
                    Label(muscleFilter?.capitalized ?? "Muscle", systemImage: "figure.arms.open")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(muscleFilter == nil ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.2)))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func filterChip(title: String, symbol: String, isOn: Bool, tint: Color = .accentColor, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(Capsule().fill(isOn ? tint : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func row(_ exercise: LibraryExercise) -> some View {
        let isSelected = selected.contains { $0.id == exercise.id }
        return Button {
            toggle(exercise)
        } label: {
            HStack(spacing: 12) {
                ExerciseThumb(urls: library.imageURLs(for: exercise), symbol: exercise.displaySymbol, tint: exercise.kind.color, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle(for: exercise))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if !singleSelection {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(for exercise: LibraryExercise) -> String {
        var parts = [exercise.kind.shortName]
        if !exercise.primary.isEmpty { parts.append(exercise.primary.prefix(2).map(\.capitalized).joined(separator: ", ")) }
        if let equipment = exercise.equipment, equipment != "body only" { parts.append(equipment.capitalized) }
        if exercise.source == "custom" { parts.append("Yours") }
        return parts.joined(separator: " · ")
    }

    private var addTitle: String {
        if asGroup && selected.count > 1 {
            return selected.count == 2 ? "Add as Superset" : "Add \(selected.count) as Circuit"
        }
        return selected.count == 1 ? "Add 1 Exercise" : "Add \(selected.count) Exercises"
    }

    // MARK: Data

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Searches when the query, a filter or the library changes. Typing waits for a short pause
    /// (one search per word, not per letter); filters and the first list come at once.
    private func runSearch(_ key: SearchKey) async {
        guard key != searchedKey else { return }
        if searchedKey != nil && !key.query.isEmpty {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
        }
        results = library.search(key.query, kind: key.kind, muscle: key.muscle, equipment: nil, custom: customExercises)
        searchedKey = key
    }

    private var resultsTitle: String {
        if let kindFilter { return "\(kindFilter.displayName) · \(results.count)" }
        return trimmedQuery.isEmpty ? "All Exercises" : "Results · \(results.count)"
    }

    /// Exercises from the last 15 workouts done, resolved against the library when possible. Fetched
    /// once (newest first, at most 15) instead of watching every workout with its stored sets.
    private func loadRecent() {
        let completed = SessionStatus.completed.rawValue
        let partial = SessionStatus.partial.rawValue
        var descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.statusRaw == completed || $0.statusRaw == partial },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 15
        let sessions = (try? modelContext.fetch(descriptor)) ?? []
        var seen = Set<String>()
        var result: [LibraryExercise] = []
        for session in sessions {
            for item in session.content.allItems where !seen.contains(item.exerciseKey) {
                seen.insert(item.exerciseKey)
                if let match = library.exercise(for: item) {
                    result.append(match)
                } else {
                    result.append(LibraryExercise(id: item.exerciseKey, name: item.name, kind: item.kind ?? session.kind, mode: item.mode, perSide: item.perSide))
                }
                if result.count >= 12 {
                    recent = result
                    return
                }
            }
        }
        recent = result
    }

    private func toggle(_ exercise: LibraryExercise) {
        if singleSelection {
            onPick([makeItem(exercise)], false)
            dismiss()
            return
        }
        Haptics.tap()
        if let index = selected.firstIndex(where: { $0.id == exercise.id }) {
            selected.remove(at: index)
        } else {
            selected.append(exercise)
        }
    }

    /// Adding: the exercise starts from last time's working sets (warm-ups left out), else the
    /// library's defaults. Swapping keeps the old sets, so it only takes the exercise itself.
    private func makeItem(_ exercise: LibraryExercise) -> WorkoutItem {
        let custom = customExercises.first { $0.key == exercise.id }
        if singleSelection {
            var item = exercise.makeItem(defaultRest: nil)
            if exercise.id.hasPrefix("name:") { item.exerciseID = nil }
            if let custom {
                item.links = custom.links
                if !custom.imageURL.isEmpty { item.imageURL = custom.imageURL }
            }
            return item
        }
        return store.prefilledItem(from: exercise, custom: custom)
    }

    private func createCustom() {
        let name = trimmedQuery
        let custom = UserExercise(key: "custom:\(UUID().uuidString)", name: name, kind: kindFilter ?? defaultKind, isCustom: true)
        custom.mode = (kindFilter ?? defaultKind).defaultMode
        modelContext.insert(custom)
        store.save()
        let exercise = custom.asLibraryExercise
        if singleSelection {
            onPick([makeItem(exercise)], false)
            dismiss()
        } else {
            selected.append(exercise)
            query = ""
        }
    }

    private func finish() {
        onPick(selected.map(makeItem), asGroup && selected.count > 1)
        dismiss()
    }
}
