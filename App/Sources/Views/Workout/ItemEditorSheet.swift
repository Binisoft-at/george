import SwiftUI
import BinisoftKit
import SwiftData
import GeorgeCore

/// Full editor for one exercise inside a workout.
struct ItemEditorSheet: View {
    @Binding var content: WorkoutContent
    let itemID: UUID
    let mode: EditorMode
    /// The live tick (live mode): Done counts like a tick there. Nil: the set is ticked in the content.
    var onToggleDone: ((UUID) -> Void)? = nil

    @Environment(GeorgeStore.self) private var store
    @Environment(ExerciseLibrary.self) private var library
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
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
                        // On top of the workout or template (with Back on the Mac).
                        router.push(.exercise(exercise.id))
                    } label: {
                        Label("Open Exercise Details", systemImage: "info.circle")
                    }
                }
            }
            Section {
                Button(role: .destructive) {
                    let before = content
                    let name = item.wrappedValue.name
                    content.removeItem(id: itemID)
                    dismiss()
                    toasts.show("Removed \u{201C}\(name)\u{201D}", symbol: "trash.fill") { content = before }
                } label: {
                    Label("Remove Exercise", systemImage: "trash")
                }
            }
        }
        .formStyle(.grouped)
        .toasts(toasts, bottomPadding: 16)
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

    /// Done on a set (workouts only): the live tick in live mode, otherwise a tick in the content
    /// (with the time it was done and the planned numbers as logged ones).
    private var toggleDone: ((UUID) -> Void)? {
        guard mode.isSession else { return nil }
        if let onToggleDone { return onToggleDone }
        return { id in _ = content.toggleSet(id: id) }
    }

    private var setsSection: some View {
        Section {
            if item.wrappedValue.sets.count > 1 {
                AllSetsRow(content: $content, itemID: itemID, inSession: mode.isSession, unit: store.unit)
            }
            ForEach(Array(item.wrappedValue.sets.enumerated()), id: \.element.id) { index, set in
                SetEditRow(
                    set: Binding(
                        get: { content.set(id: set.id) ?? set },
                        set: { newValue in content.updateSet(id: set.id) { $0 = newValue } }
                    ),
                    index: item.wrappedValue.displayIndex(of: set),
                    mode: item.wrappedValue.mode,
                    inSession: mode.isSession,
                    unit: store.unit,
                    onToggleDone: toggleDone
                )
            }
            .onDelete { offsets in
                let before = content
                item.wrappedValue.sets.remove(atOffsets: offsets)
                toasts.show(offsets.count == 1 ? "Deleted set" : "Deleted \(offsets.count) sets", symbol: "trash.fill") { content = before }
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

/// "All sets": the number of sets, reps and weight (or time / distance) for every open working set
/// at once – e.g. all Deadlift sets +2.5 kg with one tap. Done sets and warm-ups stay as they are.
struct AllSetsRow: View {
    @Binding var content: WorkoutContent
    let itemID: UUID
    let inSession: Bool
    let unit: WeightUnit

    var body: some View {
        let item = content.item(id: itemID)
        let open = content.openSetIDs(of: itemID).count
        let total = item?.sets.count ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("All sets", systemImage: "square.stack.3d.up")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(open == total ? "every set" : "the \(open) open sets")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    stepper("\(total) sets", minus: total > 1 ? { content.setSetCount(of: itemID, to: total - 1) } : nil) {
                        content.setSetCount(of: itemID, to: total + 1)
                    }
                    switch item?.mode ?? .reps {
                    case .reps:
                        stepper(repsText, minus: { adjust(.reps, by: -1) }) { adjust(.reps, by: 1) }
                        stepper(weightText, minus: { adjust(.weight, by: -weightStep) }) { adjust(.weight, by: weightStep) }
                    case .time:
                        stepper(secondsText, minus: { adjust(.seconds, by: -5) }) { adjust(.seconds, by: 5) }
                    case .distance:
                        stepper(metersText, minus: { adjust(.meters, by: -50) }) { adjust(.meters, by: 50) }
                    }
                }
            }
            .disabled(open == 0)
        }
        .padding(.vertical, 2)
    }

    /// 2.5 kg, or 5 lb.
    private var weightStep: Double { unit == .kg ? 2.5 : unit.toKilograms(5) }

    private func value(_ field: SetField) -> Double? {
        content.allSetsValue(field, of: itemID, inSession: inSession)
    }

    private var repsText: String { value(.reps).map { "\(Int($0)) reps" } ?? "– reps" }
    private var weightText: String {
        guard let kg = value(.weight), kg > 0 else { return "no weight" }
        return Format.weight(kg, unit: unit)
    }
    private var secondsText: String { value(.seconds).map { Format.shortDuration(Int($0)) } ?? "– s" }
    private var metersText: String { value(.meters).map { Format.distance($0) } ?? "– m" }

    private func adjust(_ field: SetField, by delta: Double) {
        Haptics.tap()
        content.adjustOpenSets(of: itemID, field, by: delta, inSession: inSession)
    }

    private func stepper(_ title: String, minus: (() -> Void)?, plus: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            Button {
                minus?()
            } label: {
                Image(systemName: "minus")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
            }
            .disabled(minus == nil)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            Button(action: plus) {
                Image(systemName: "plus")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .background(Color.accentColor.opacity(0.1), in: Capsule())
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
    /// Done as a real tick (live: time, rest, pace, undo, records). Nil: the toggle only flips the flag.
    var onToggleDone: ((UUID) -> Void)? = nil

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
                    Toggle("Done", isOn: doneBinding)
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

    /// The Done toggle: a tick through `onToggleDone` when there is one.
    private var doneBinding: Binding<Bool> {
        guard let onToggleDone else { return $set.isDone }
        let id = set.id
        return Binding(get: { set.isDone }, set: { newValue in
            if newValue != set.isDone { onToggleDone(id) }
        })
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
    /// The live tick (live mode): Done counts like a tick there. Nil: the set is ticked in the content.
    var onToggleDone: ((UUID) -> Void)? = nil

    @Environment(GeorgeStore.self) private var store
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    /// Done on the set (workouts only): the live tick, or a tick in the content (time and numbers).
    private var toggleDone: ((UUID) -> Void)? {
        guard mode.isSession else { return nil }
        if let onToggleDone { return onToggleDone }
        return { id in _ = content.toggleSet(id: id) }
    }

    var body: some View {
        if let item = content.item(id: itemID), let set = content.set(id: setID) {
            Form {
                Section {
                    SetEditRow(
                        set: Binding(get: { content.set(id: setID) ?? set }, set: { newValue in content.updateSet(id: setID) { $0 = newValue } }),
                        index: item.displayIndex(of: set),
                        mode: item.mode,
                        inSession: mode.isSession,
                        unit: store.unit,
                        onToggleDone: toggleDone
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
                        let before = content
                        content.removeSet(id: setID)
                        dismiss()
                        toasts.show("Deleted set", symbol: "trash.fill") { content = before }
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
