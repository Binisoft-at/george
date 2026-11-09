import SwiftUI
import BinisoftKit
import SwiftData
import Charts
import GeorgeCore

struct ExerciseLibraryView: View {
    @Environment(ExerciseLibrary.self) private var library
    @Environment(Router.self) private var router
    @Query private var userExercises: [UserExercise]
    @State private var query = ""
    @State private var kind: WorkoutKind?
    @State private var muscle: String?
    @State private var favoritesOnly = false

    var body: some View {
        NavList {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("All", symbol: "square.grid.2x2", isOn: kind == nil && !favoritesOnly) {
                            kind = nil
                            favoritesOnly = false
                        }
                        chip("Favorites", symbol: "star.fill", isOn: favoritesOnly, tint: .yellow) { favoritesOnly.toggle() }
                        ForEach(library.catalog.kinds) { k in
                            chip(k.shortName, symbol: k.symbol, isOn: kind == k, tint: k.color) { kind = kind == k ? nil : k }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            Section("\(results.count) exercises") {
                ForEach(Array(results.prefix(500))) { exercise in
                    DetailLink(.exercise(exercise.id)) {
                        HStack(spacing: 12) {
                            ExerciseThumb(urls: library.imageURLs(for: exercise), symbol: exercise.displaySymbol, tint: exercise.kind.color, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(exercise.name).font(.body.weight(.medium)).lineLimit(1)
                                    if favoriteKeys.contains(exercise.id) {
                                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                                    }
                                }
                                Text([exercise.kind.shortName, exercise.primary.first?.capitalized, exercise.equipment?.capitalized].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .groupedList()
        .navigationTitle("Exercise Library")
        .searchable(text: $query, prompt: "Search by name, muscle, equipment")
        .toolbar {
            ToolbarItem(placement: .georgeTrailing) {
                Menu {
                    Button("Any Muscle") { muscle = nil }
                    ForEach(library.catalog.allMuscles, id: \.self) { m in
                        Button {
                            muscle = m
                        } label: {
                            Label(m.capitalized, systemImage: muscle == m ? "checkmark" : "figure.arms.open")
                        }
                    }
                } label: {
                    Image(systemName: muscle == nil ? "figure.arms.open" : "figure.arms.open.circle.fill")
                }
            }
        }
        .overlay {
            if !library.isLoaded {
                ProgressView("Loading library…")
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private var favoriteKeys: Set<String> {
        Set(userExercises.filter(\.isFavorite).map(\.key))
    }

    private var results: [LibraryExercise] {
        let all = library.search(query, kind: kind, muscle: muscle, equipment: nil, custom: userExercises)
        guard favoritesOnly else { return all }
        return all.filter { favoriteKeys.contains($0.id) }
    }

    private func chip(_ title: String, symbol: String, isOn: Bool, tint: Color = .accentColor, action: @escaping () -> Void) -> some View {
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
}

struct ExerciseDetailView: View {
    let exerciseID: String
    @Environment(ExerciseLibrary.self) private var library
    @Environment(GeorgeStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    @Query private var userExercises: [UserExercise]
    @Query private var sessions: [WorkoutSession]
    @State private var newLink = ""
    @State private var playing: URL?

    var body: some View {
        if let exercise = resolved {
            content(exercise)
        } else {
            MessageView(title: "Exercise not found", systemImage: "questionmark.circle")
        }
    }

    private var userEntry: UserExercise? { userExercises.first { $0.key == exerciseID } }

    private var resolved: LibraryExercise? {
        if let found = library.exercise(id: exerciseID) { return found }
        return userEntry?.asLibraryExercise
    }

    /// Creates the personal record for a library exercise on first edit.
    private func ensureUserEntry(for exercise: LibraryExercise) -> UserExercise {
        if let userEntry { return userEntry }
        let entry = UserExercise(key: exercise.id, name: exercise.name, kind: exercise.kind, isCustom: false)
        modelContext.insert(entry)
        return entry
    }

    @ViewBuilder
    private func content(_ exercise: LibraryExercise) -> some View {
        let history = StatsEngine.history(of: exercise.id, in: sessions.filter { $0.status.isPerformed }.map { $0.record() })
        List {
            Section {
                ExerciseAnimation(urls: library.imageURLs(for: exercise), symbol: exercise.displaySymbol, tint: exercise.kind.color)
                    .frame(height: 240)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(exercise.name).font(.title2.weight(.bold))
                    if !exercise.aliases.isEmpty {
                        Text(exercise.aliases.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    FlowLayout(spacing: 6) {
                        KindBadge(kind: exercise.kind, compact: true)
                        ForEach(exercise.primary, id: \.self) { Chip(text: $0.capitalized, systemImage: "target", tint: .red) }
                        ForEach(exercise.secondary, id: \.self) { Chip(text: $0.capitalized, tint: .orange) }
                        if let equipment = exercise.equipment { Chip(text: equipment.capitalized, systemImage: "wrench.and.screwdriver", tint: .secondary) }
                        if let level = exercise.level { Chip(text: level.capitalized, systemImage: "chart.bar", tint: .secondary) }
                        ForEach(exercise.tags, id: \.self) { Chip(text: "#" + $0, tint: .blue) }
                    }
                }
                .padding(.vertical, 4)
            }

            if !exercise.steps.isEmpty {
                Section("How To") {
                    ForEach(Array(exercise.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold))
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(exercise.kind.color.opacity(0.2)))
                            Text(step).font(.callout)
                        }
                    }
                }
            }

            Section {
                Button {
                    playing = TutorialLinks.youtubeSearch(for: exercise.name, kind: exercise.kind)
                } label: {
                    Label("Find a Tutorial on YouTube", systemImage: "play.rectangle.fill")
                }
                ForEach(userEntry?.links ?? [], id: \.self) { link in
                    Button {
                        playing = URL(string: link)
                    } label: {
                        HStack {
                            if let url = URL(string: link), let thumb = TutorialLinks.youtubeThumbnail(for: url) {
                                AsyncImage(url: thumb) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.1) }
                                    .frame(width: 80, height: 45)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            Text(link).font(.caption).lineLimit(2).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "play.circle.fill").font(.title2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    let entry = ensureUserEntry(for: exercise)
                    var links = entry.links
                    links.remove(atOffsets: offsets)
                    entry.links = links
                    store.save()
                }
                HStack {
                    TextField("Add your tutorial link", text: $newLink)
                        .urlKeyboard()
                    Button("Add") {
                        let trimmed = newLink.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.lowercased().hasPrefix("http") else { return }
                        let entry = ensureUserEntry(for: exercise)
                        entry.links = entry.links + [trimmed]
                        store.save()
                        newLink = ""
                    }
                    .disabled(!newLink.lowercased().hasPrefix("http"))
                }
            } header: {
                Text("Tutorials")
            } footer: {
                Text("Links saved here are used whenever this exercise appears in a workout.")
            }

            Section("Your Notes") {
                TextField("Setup, cues, band color…", text: Binding(
                    get: { userEntry?.notes ?? "" },
                    set: { value in
                        let entry = ensureUserEntry(for: exercise)
                        entry.notes = value
                        entry.updatedAt = Date()
                    }
                ), axis: .vertical)
                .lineLimit(2...8)
            }

            if !history.isEmpty {
                Section("Progress") {
                    ExerciseProgressChart(points: history, mode: exercise.mode, unit: store.unit)
                        .frame(height: 200)
                        .padding(.vertical, 6)
                    ForEach(Array(history.reversed().prefix(8))) { point in
                        HStack {
                            Text(point.date.formatted(date: .abbreviated, time: .omitted))
                            Spacer()
                            Text(point.sets.map { $0.label(mode: exercise.mode, unit: store.unit) }.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .groupedList()
        .navigationTitle(exercise.name)
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .georgeTrailing) {
                Button {
                    let entry = ensureUserEntry(for: exercise)
                    entry.isFavorite.toggle()
                    store.save()
                } label: {
                    Image(systemName: userEntry?.isFavorite == true ? "star.fill" : "star")
                }
                .tint(.yellow)
            }
        }
        .sheet(item: Binding(get: { playing.map { URLItem(url: $0) } }, set: { playing = $0?.url })) { item in
            LinkPlayerView(url: item.url)
        }
        .onDisappear { store.save() }
    }
}

struct ExerciseProgressChart: View {
    let points: [ExercisePoint]
    let mode: ExerciseMode
    let unit: WeightUnit

    var body: some View {
        Chart(points) { point in
            if mode == .reps, let weight = point.bestWeight, weight > 0 {
                LineMark(x: .value("Date", point.date), y: .value("Weight", unit.fromKilograms(weight)))
                    .interpolationMethod(.catmullRom)
                PointMark(x: .value("Date", point.date), y: .value("Weight", unit.fromKilograms(weight)))
            } else if mode == .time, let seconds = point.bestSeconds {
                LineMark(x: .value("Date", point.date), y: .value("Seconds", seconds))
                PointMark(x: .value("Date", point.date), y: .value("Seconds", seconds))
            } else if let reps = point.bestReps {
                LineMark(x: .value("Date", point.date), y: .value("Reps", reps))
                PointMark(x: .value("Date", point.date), y: .value("Reps", reps))
            }
        }
        .chartYAxisLabel { Text(axisLabel) }
    }

    private var axisLabel: String {
        if mode == .time { return "seconds" }
        if points.contains(where: { ($0.bestWeight ?? 0) > 0 }) { return unit.rawValue }
        return "reps"
    }
}
