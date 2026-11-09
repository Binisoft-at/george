import SwiftUI
import BinisoftKit
import SwiftData
import GeorgeCore

/// Full editor for one exercise inside a workout.
struct ItemEditorSheet: View {
    @Binding var content: WorkoutContent
    let itemID: UUID
    let mode: EditorMode

    @Environment(GeorgeStore.self) private var store
    @Environment(ExerciseLibrary.self) private var library
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var newLink = ""
    @State private var showSwap = false
    @State private var playing: URL?

    private var item: Binding<WorkoutItem> {
        Binding(
            get: { content.item(id: itemID) ?? WorkoutItem(name: "") },
            set: { newValue in content.updateItem(id: itemID) { $0 = newValue } }
        )
    }

    var body: some View {
        Form {
            exerciseSection
            setsSection
            Section("Notes") {
                TextField("Cues, band color, setup…", text: Binding(get: { item.wrappedValue.notes ?? "" }, set: { item.wrappedValue.notes = $0.isEmpty ? nil : $0 }), axis: .vertical)
                    .lineLimit(2...8)
            }
            tutorialSection
            if let exercise = library.exercise(for: item.wrappedValue) {
                Section("From the Library") {
                    if !exercise.primary.isEmpty {
                        LabeledContent("Muscles", value: exercise.primary.map(\.capitalized).joined(separator: ", "))
                    }
                    if let equipment = exercise.equipment {
                        LabeledContent("Equipment", value: equipment.capitalized)
                    }
                    Button {
                        dismiss()
                        router.open(.exercise(exercise.id))
                    } label: {
                        Label("Open Exercise Details", systemImage: "info.circle")
                    }
                }
            }
            Section {
                Button(role: .destructive) {
                    content.removeItem(id: itemID)
                    dismiss()
                } label: {
                    Label("Remove Exercise", systemImage: "trash")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(item.wrappedValue.name.isEmpty ? "Exercise" : item.wrappedValue.name)
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showSwap) {
            ExercisePickerSheet(defaultKind: item.wrappedValue.kind ?? .gym, singleSelection: true) { items, _ in
                guard let replacement = items.first else { return }
                content.replaceExercise(
                    itemID: itemID, exerciseID: replacement.exerciseID, name: replacement.name, kind: replacement.kind,
                    mode: replacement.mode, muscles: replacement.muscles, equipment: replacement.equipment, imageURL: replacement.imageURL
                )
            }
        }
        .sheet(item: Binding(get: { playing.map { URLItem(url: $0) } }, set: { playing = $0?.url })) { link in
            LinkPlayerView(url: link.url)
        }
    }

    private var exerciseSection: some View {
        Section {
            TextField("Exercise name", text: item.name)
                .font(.headline)
            Button {
                showSwap = true
            } label: {
                Label("Swap from Library…", systemImage: "arrow.triangle.swap")
            }
            Picker("Type", selection: Binding(get: { item.wrappedValue.kind?.rawValue ?? "" }, set: { item.wrappedValue.kind = $0.isEmpty ? nil : WorkoutKind($0) })) {
                Text("Same as workout").tag("")
                ForEach(WorkoutKind.presets) { kind in
                    Label(kind.displayName, systemImage: kind.symbol).tag(kind.rawValue)
                }
            }
            Picker("Measure", selection: item.mode) {
                ForEach(ExerciseMode.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Each side (unilateral)", isOn: item.perSide)
            Picker("Rest", selection: Binding(get: { item.wrappedValue.restSeconds ?? -1 }, set: { item.wrappedValue.restSeconds = $0 < 0 ? nil : $0 })) {
                Text("Default (\(Format.shortDuration(store.settings.defaultRestSeconds)))").tag(-1)
                ForEach([0, 15, 30, 45, 60, 75, 90, 120, 150, 180, 240, 300], id: \.self) { seconds in
                    Text(seconds == 0 ? "None" : Format.shortDuration(seconds)).tag(seconds)
                }
            }
            TextField("Tempo (e.g. 3-1-1)", text: Binding(get: { item.wrappedValue.tempo ?? "" }, set: { item.wrappedValue.tempo = $0.isEmpty ? nil : $0 }))
            TextField("Equipment (e.g. red band, 2×12 kg)", text: Binding(get: { item.wrappedValue.equipment ?? "" }, set: { item.wrappedValue.equipment = $0.isEmpty ? nil : $0 }))
        }
    }

    private var setsSection: some View {
        Section {
            ForEach(Array(item.wrappedValue.sets.enumerated()), id: \.element.id) { index, set in
                SetEditRow(
                    set: Binding(
                        get: { content.set(id: set.id) ?? set },
                        set: { newValue in content.updateSet(id: set.id) { $0 = newValue } }
                    ),
                    index: item.wrappedValue.displayIndex(of: set),
                    mode: item.wrappedValue.mode,
                    inSession: mode.isSession,
                    unit: store.unit
                )
            }
            .onDelete { offsets in
                item.wrappedValue.sets.remove(atOffsets: offsets)
            }
            .onMove { source, destination in
                item.wrappedValue.sets.move(fromOffsets: source, toOffset: destination)
            }
            Button {
                content.addSet(to: itemID)
            } label: {
                Label("Add Set", systemImage: "plus")
            }
            if item.wrappedValue.sets.count > 1 {
                Button {
                    if let first = item.wrappedValue.sets.first {
                        content.applyToFollowingSets(from: first.id, inSession: mode.isSession)
                    }
                } label: {
                    Label("Copy First Set to All", systemImage: "square.on.square.dashed")
                }
            }
        } header: {
            Text("Sets")
        } footer: {
            Text(mode.isSession ? "Each set shows what you did – or will do, while it's open. Type 62,5 or 62.5." : "Reps can be a range (8-12) or AMRAP. Load is free text, e.g. a band color.")
        }
    }

    private var tutorialSection: some View {
        Section {
            ForEach(item.wrappedValue.links, id: \.self) { link in
                HStack {
                    if let url = URL(string: link), let thumb = TutorialLinks.youtubeThumbnail(for: url) {
                        AsyncImage(url: thumb) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.secondary.opacity(0.1)
                        }
                        .frame(width: 64, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text(link)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        playing = URL(string: link)
                    } label: {
                        Image(systemName: "play.circle.fill").font(.title3)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .onDelete { offsets in
                item.wrappedValue.links.remove(atOffsets: offsets)
            }
            HStack {
                TextField("Paste a YouTube or video link", text: $newLink)
                    .urlKeyboard()
                Button("Add") {
                    let trimmed = newLink.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.lowercased().hasPrefix("http") else { return }
                    item.wrappedValue.links.append(trimmed)
                    newLink = ""
                }
                .disabled(!newLink.lowercased().hasPrefix("http"))
            }
            Button {
                playing = TutorialLinks.youtubeSearch(for: item.wrappedValue.name, kind: item.wrappedValue.kind)
            } label: {
                Label("Find Tutorial on YouTube", systemImage: "magnifyingglass")
            }
        } header: {
            Text("Tutorials")
        }
    }
}

/// One set. In a workout: the numbers of this set – what you did, or will do while it's open
/// (one field each, so an edit always shows up). In a template: the plan.
struct SetEditRow: View {
    @Binding var set: WorkoutSet
    let index: String
    let mode: ExerciseMode
    let inSession: Bool
    let unit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Menu {
                    Picker("Set Type", selection: $set.kind) {
                        ForEach(SetKind.allCases) { Text($0.displayName).tag($0) }
                    }
                } label: {
                    Text(index)
                        .font(.caption.weight(.bold))
                        .frame(width: 26, height: 26)
                        .background(Color.accentColor.opacity(0.15), in: Circle())
                }
                fields
                if inSession {
                    Spacer(minLength: 0)
                    Toggle("Done", isOn: $set.isDone)
                        .labelsHidden()
                        .toggleStyle(.button)
                        .tint(.green)
                }
            }
            if let planText {
                Text("Plan was \(planText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch mode {
        case .reps:
            if inSession {
                NumberField(placeholder: "reps", value: field(.reps), allowsDecimal: false, width: 56)
            } else {
                TextField("Reps", text: Binding(get: { set.targetReps ?? "" }, set: { set.targetReps = $0.isEmpty ? nil : $0 }))
                    .frame(maxWidth: 70)
            }
            NumberField(placeholder: unit.rawValue, value: weight, width: 70)
            if inSession {
                NumberField(placeholder: "RPE", value: field(.rpe), width: 48)
            } else {
                TextField("Load", text: Binding(get: { set.targetLoad ?? "" }, set: { set.targetLoad = $0.isEmpty ? nil : $0 }))
            }
        case .time:
            NumberField(placeholder: "sec", value: field(.seconds), allowsDecimal: false, width: 60)
            NumberField(placeholder: unit.rawValue, value: weight, width: 70)
            if !inSession {
                TextField("Load", text: Binding(get: { set.targetLoad ?? "" }, set: { set.targetLoad = $0.isEmpty ? nil : $0 }))
            }
        case .distance:
            NumberField(placeholder: "m", value: field(.meters), width: 70)
            NumberField(placeholder: "sec", value: field(.seconds), allowsDecimal: false, width: 60)
        }
    }

    private func field(_ field: SetField) -> Binding<Double?> {
        Binding(get: { set.value(field, inSession: inSession) }, set: { set.setValue(field, $0, inSession: inSession) })
    }

    /// Weight in the person's unit (stored in kilograms).
    private var weight: Binding<Double?> {
        Binding(
            get: { set.value(.weight, inSession: inSession).map { (unit.fromKilograms($0) * 100).rounded() / 100 } },
            set: { set.setValue(.weight, $0.map { unit.toKilograms($0) }, inSession: inSession) }
        )
    }

    /// For a finished set whose numbers differ from the plan: the plan, for comparison.
    private var planText: String? {
        guard inSession, set.isDone else { return nil }
        let plan = set.label(mode: mode, unit: unit, preferActual: false)
        return plan != set.label(mode: mode, unit: unit) && plan != "—" ? plan : nil
    }
}

/// Quick editor for a single set (long-press on a chip).
struct SetEditorSheet: View {
    @Binding var content: WorkoutContent
    let itemID: UUID
    let setID: UUID
    let mode: EditorMode

    @Environment(GeorgeStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let item = content.item(id: itemID), let set = content.set(id: setID) {
            Form {
                Section {
                    SetEditRow(
                        set: Binding(get: { content.set(id: setID) ?? set }, set: { newValue in content.updateSet(id: setID) { $0 = newValue } }),
                        index: item.displayIndex(of: set),
                        mode: item.mode,
                        inSession: mode.isSession,
                        unit: store.unit
                    )
                } header: {
                    Text(item.name)
                } footer: {
                    Text("Type 62,5 or 62.5 – both work. Changes save as you type.")
                }
                Section {
                    if item.sets.last?.id != setID {
                        Button {
                            content.applyToFollowingSets(from: setID, inSession: mode.isSession)
                            Haptics.success()
                        } label: {
                            Label("Same for the Remaining Sets", systemImage: "arrow.down.to.line")
                        }
                    }
                    Button {
                        content.duplicateSet(id: setID)
                    } label: {
                        Label("Duplicate Set", systemImage: "plus.square.on.square")
                    }
                    Button(role: .destructive) {
                        content.removeSet(id: setID)
                        dismiss()
                    } label: {
                        Label("Delete Set", systemImage: "trash")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Set \(item.displayIndex(of: set))")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        } else {
            MessageView(title: "Set removed", systemImage: "xmark.circle")
        }
    }
}
