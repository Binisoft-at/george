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
        // Worked out once per update, not once per use (the search sorts the whole library).
        let favoriteKeys = self.favoriteKeys
        let results = self.results(favorites: favoriteKeys)
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
                    .contextMenu { AddToMenu(exercise: exercise) }
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
                .help("Filter by muscle")
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

    private func results(favorites: Set<String>) -> [LibraryExercise] {
        let all = library.search(query, kind: kind, muscle: muscle, equipment: nil, custom: userExercises)
        guard favoritesOnly else { return all }
        return all.filter { favorites.contains($0.id) }
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
    @State private var newLink = ""
    @State private var playing: URL?
    /// This exercise's sessions, from the shared history index (refreshed when the history changes).
    @State private var history: [ExercisePoint] = []
    @ScaledMetric(relativeTo: .caption) private var stepBadge: CGFloat = 22

    var body: some View {
        if let exercise = resolved {
            content(exercise)
        } else {
            MessageView(title: "Exercise not found", systemImage: "questionmark.circle")
        }
    }

    /// Two devices' copies (before they're merged): the one with notes or links, then the newest.
    private var userEntry: UserExercise? { UserExercise.preferred(userExercises, key: exerciseID) }

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
        List {
            // With history, "am I getting stronger?" comes first.
            if history.isEmpty {
                animationSection(exercise)
                headerSection(exercise)
            } else {
                headerSection(exercise)
                progressSection(exercise)
                animationSection(exercise)
            }

            if !exercise.steps.isEmpty {
                Section("How To") {
                    ForEach(Array(exercise.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold))
                                .frame(width: stepBadge, height: stepBadge)
                                .background(Circle().fill(exercise.kind.color.opacity(0.2)))
                            Text(step).font(.callout)
                        }
                    }
                    if let caution = exercise.caution {
                        Label(caution, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(Tone.cautionText)
                    }
                }
            }
            Section {
                // Checked how-to pages with photos or video (Yoga Journal, ACE, NHS …).
                ForEach(exercise.references, id: \.url) { reference in
                    Button {
                        playing = URL(string: reference.url)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("How-to with photos · \(reference.site)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(reference.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
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
        }
        .groupedList()
        .navigationTitle(exercise.name)
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .georgeTrailing) {
                AddToMenu(exercise: exercise)
            }
            ToolbarItem(placement: .georgeTrailing) {
                Button {
                    let entry = ensureUserEntry(for: exercise)
                    entry.isFavorite.toggle()
                    entry.updatedAt = Date()
                    store.save()
                } label: {
                    Image(systemName: userEntry?.isFavorite == true ? "star.fill" : "star")
                }
                .tint(.yellow)
                .help(userEntry?.isFavorite == true ? "Remove from favorites" : "Add to favorites")
            }
        }
        .sheet(item: Binding(get: { playing.map { URLItem(url: $0) } }, set: { playing = $0?.url })) { item in
            LinkPlayerView(url: item.url)
        }
        // Saves what was edited here; moves the revision only when something changed (also an edit
        // autosaved meanwhile) – just leaving the page doesn't make the app recompute.
        .onDisappear { store.save() }
        .task(id: "\(exercise.id)#\(store.historyRevision)") {
            history = StatsEngine.history(of: exercise.id, in: SessionHistory.shared.records(store))
        }
    }

    private func animationSection(_ exercise: LibraryExercise) -> some View {
        Section {
            ExerciseAnimation(urls: library.imageURLs(for: exercise), symbol: exercise.displaySymbol, tint: exercise.kind.color)
                .frame(height: history.isEmpty ? 240 : 180)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
    }

    private func headerSection(_ exercise: LibraryExercise) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(exercise.name).font(.title2.weight(.bold))
                if !exercise.aliases.isEmpty {
                    Text(exercise.aliases.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                }
                FlowLayout(spacing: 6) {
                    KindBadge(kind: exercise.kind, compact: true)
                    ForEach(exercise.primary, id: \.self) { Chip(text: $0.capitalized, systemImage: "target", tint: Tone.accent) }
                    ForEach(exercise.secondary, id: \.self) { Chip(text: $0.capitalized, tint: .secondary) }
                    if let equipment = exercise.equipment { Chip(text: equipment.capitalized, systemImage: "wrench.and.screwdriver", tint: .secondary) }
                    if let level = exercise.level { Chip(text: level.capitalized, systemImage: "chart.bar", tint: .secondary) }
                    ForEach(exercise.tags, id: \.self) { Chip(text: "#" + $0, tint: .secondary) }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func progressSection(_ exercise: LibraryExercise) -> some View {
        Section {
            ExerciseProgressChart(points: history, mode: exercise.mode, unit: store.unit)
                .padding(.vertical, 6)
            ForEach(Array(history.reversed().prefix(8))) { point in
                ExerciseSessionRow(point: point, mode: exercise.mode, unit: store.unit)
            }
        } header: {
            Text("Progress")
        }
    }
}

/// An exercise's history as a chart: e1RM (default), top set or volume for lifts with weight, total
/// reps for sessions without weight, the longest hold for timed moves. Records are marked in gold.
struct ExerciseProgressChart: View {
    let points: [ExercisePoint]
    let mode: ExerciseMode
    let unit: WeightUnit
    var chartHeight: CGFloat = 190
    @State private var metric: ProgressMetric?
    @State private var selection: Date?

    var body: some View {
        let available = ExerciseProgress.metrics(for: points, mode: mode)
        let current = metric.flatMap { available.contains($0) ? $0 : nil } ?? available.first
        VStack(alignment: .leading, spacing: 10) {
            if available.count > 1 {
                Picker("Measure", selection: Binding(get: { current ?? .oneRepMax }, set: { metric = $0 })) {
                    ForEach(available) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if let current {
                let samples = ExerciseProgress.samples(points, metric: current)
                summary(samples, metric: current)
                chart(samples, metric: current)
                    .frame(height: chartHeight)
                Text(current.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Nothing to chart yet – log reps, weight or time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ samples: [ProgressSample], metric: ProgressMetric) -> some View {
        let records = samples.filter(\.isRecord).count
        let best = samples.max { $0.value < $1.value }
        return HStack(alignment: .firstTextBaseline, spacing: 16) {
            if let last = samples.last {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Latest").font(.caption).foregroundStyle(.secondary)
                    Text(text(last, metric: metric)).font(.headline).monospacedDigit()
                }
            }
            if let best, samples.count > 1 {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Best").font(.caption).foregroundStyle(.secondary)
                    Text(text(best, metric: metric)).font(.headline).monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            if records > 0 {
                Label {
                    Text("\(records) \(records == 1 ? "record" : "records")").foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "trophy.fill").foregroundStyle(Tone.record)
                }
                .font(.caption.weight(.semibold))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func chart(_ samples: [ProgressSample], metric: ProgressMetric) -> some View {
        let selected = selection.flatMap { date in
            samples.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        }
        return Chart {
            ForEach(samples) { sample in
                LineMark(x: .value("Date", sample.date), y: .value(metric.title, plotted(sample.value, metric: metric)))
                    .foregroundStyle(Tone.accent)
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Date", sample.date), y: .value(metric.title, plotted(sample.value, metric: metric)))
                    .foregroundStyle(sample.isRecord ? Tone.record : Tone.accent)
                    .symbol(sample.isRecord ? BasicChartSymbolShape.diamond : .circle)
                    .symbolSize(sample.isRecord ? 90 : 28)
                    .accessibilityLabel(sample.date.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityValue(text(sample, metric: metric) + (sample.isRecord ? ", record" : ""))
            }
            if let selected {
                RuleMark(x: .value("Selected", selected.date))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selected.date.formatted(.dateTime.day().month(.abbreviated).year(.twoDigits)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(text(selected, metric: metric) + (selected.isRecord ? " · record" : ""))
                                .font(.caption.weight(.semibold))
                        }
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxisLabel { Text(axisLabel(metric)) }
        .chartXSelection(value: $selection)
    }

    private func plotted(_ value: Double, metric: ProgressMetric) -> Double {
        switch metric {
        case .oneRepMax, .topSet, .volume: return unit.fromKilograms(value)
        case .reps, .seconds: return value
        }
    }

    private func axisLabel(_ metric: ProgressMetric) -> String {
        switch metric {
        case .oneRepMax, .topSet, .volume: return unit.rawValue
        case .reps: return "reps"
        case .seconds: return "seconds"
        }
    }

    /// "96 kg", "80 kg × 3", "4.2k kg", "45 reps", "1:30".
    private func text(_ sample: ProgressSample, metric: ProgressMetric) -> String {
        switch metric {
        case .oneRepMax: return Format.estimate(sample.value, unit: unit)
        case .topSet: return Format.weight(sample.value, unit: unit) + (sample.reps.map { " × \($0)" } ?? "")
        case .volume: return Format.volume(sample.value, unit: unit)
        case .reps: return "\(Int(sample.value)) reps"
        case .seconds: return Format.clock(Int(sample.value))
        }
    }
}

/// One past session of an exercise: date and its sets.
struct ExerciseSessionRow: View {
    let point: ExercisePoint
    let mode: ExerciseMode
    let unit: WeightUnit

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(point.date.formatted(date: .abbreviated, time: .omitted))
            Spacer(minLength: 12)
            Text(point.sets.map { $0.label(mode: mode, unit: unit) }.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Last time" in depth, as a medium sheet: the progress chart and the last 4 sessions of one
/// exercise. The running workout isn't part of the history, so it shows what came before.
struct ExerciseHistorySheet: View {
    let exerciseKey: String
    let name: String
    @Environment(GeorgeStore.self) private var store
    @Environment(ExerciseLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var history: [ExercisePoint]?

    var body: some View {
        NavigationStack {
            List {
                if let history {
                    if history.isEmpty {
                        Text("No earlier sessions of this exercise yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        let exerciseMode = mode(of: history)
                        Section {
                            ExerciseProgressChart(points: history, mode: exerciseMode, unit: store.unit, chartHeight: 160)
                                .padding(.vertical, 4)
                        }
                        Section("Last sessions") {
                            ForEach(Array(history.reversed().prefix(4))) { point in
                                ExerciseSessionRow(point: point, mode: exerciseMode, unit: store.unit)
                            }
                        }
                    }
                }
            }
            .groupedList()
            .navigationTitle(name)
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if history == nil { ProgressView() }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .macSheet(width: 520, height: 600)
        .task(id: "\(exerciseKey)#\(store.historyRevision)") {
            history = StatsEngine.history(of: exerciseKey, in: SessionHistory.shared.records(store))
        }
    }

    private func mode(of points: [ExercisePoint]) -> ExerciseMode {
        if let exercise = library.exercise(id: exerciseKey) { return exercise.mode }
        let timed = points.contains { ($0.bestSeconds ?? 0) > 0 } && !points.contains { ($0.bestReps ?? 0) > 0 }
        return timed ? .time : .reps
    }
}
