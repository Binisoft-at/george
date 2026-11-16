import SwiftUI
import BinisoftKit
import GeorgeCore

/// What the "can't finish / lower the weight" sheet is for.
struct DropWeightRequest: Identifiable {
    var id: UUID { setID }
    let setID: UUID
    let itemID: UUID
}

/// "I can't finish this set": tap the reps you managed, pick a lighter weight, keep going – the set
/// counts, a drop set starts right away.
struct DropWeightSheet: View {
    let request: DropWeightRequest
    @Environment(LiveWorkoutController.self) private var live
    @Environment(\.dismiss) private var dismiss
    @State private var repsDone: Int?
    @State private var newWeight: Double?
    @State private var applyToRemaining = true

    private var item: WorkoutItem? { live.content.item(id: request.itemID) }
    private var set: WorkoutSet? { item?.sets.first { $0.id == request.setID } }

    var body: some View {
        NavigationStack {
            if let item, let set, let weight = set.effectiveWeight, weight > 0 {
                let target = set.targetRepsValue ?? set.effectiveReps ?? 10
                let options = Self.weightOptions(from: weight, unit: live.unit)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Reps done at \(Format.weight(weight, unit: live.unit))")
                                .font(.headline)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(0...max(target, 1), id: \.self) { reps in
                                        chip("\(reps)", selected: (repsDone ?? max(0, target - 2)) == reps) { repsDone = reps }
                                    }
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Continue with")
                                .font(.headline)
                            HStack(spacing: 8) {
                                ForEach(options, id: \.kg) { option in
                                    Button {
                                        Haptics.tap()
                                        newWeight = option.kg
                                    } label: {
                                        VStack(spacing: 0) {
                                            Text(Format.weight(option.kg, unit: live.unit)).font(.headline).monospacedDigit()
                                            Text(option.caption).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, minHeight: 52)
                                        .background((newWeight ?? options.dropFirst().first?.kg ?? options.first?.kg) == option.kg ? Color.accentColor.opacity(0.22) : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    }
                                    .buttonStyle(.glass)
                                }
                            }
                        }
                        Toggle(isOn: $applyToRemaining) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Use it for the remaining sets")
                                Text("The open sets of \(item.name) get the lighter weight too.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        let chosen = newWeight ?? options.dropFirst().first?.kg ?? options.first?.kg ?? weight
                        Button {
                            live.dropWeight(repsDone: repsDone ?? max(0, target - 2), newWeightKg: chosen, applyToRemaining: applyToRemaining)
                            dismiss()
                        } label: {
                            Label("Drop to \(Format.weight(chosen, unit: live.unit)) & keep going", systemImage: "arrow.down.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.glassProminent)
                        Text("The reps you managed count as this set; a drop set with the lighter weight follows straight away – no rest.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }
                .navigationTitle("Lower the Weight")
                .inlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
            } else {
                MessageView(title: "No weight on this set", systemImage: "scalemass")
            }
        }
    }

    private func chip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(text)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .frame(width: 46, height: 46)
                .background(selected ? Color.accentColor.opacity(0.25) : Color.clear, in: Circle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }

    struct Option {
        let kg: Double
        let caption: String
    }

    /// One and two plate steps lighter, −20 % and −30 % (rounded to the step), each only once.
    static func weightOptions(from kg: Double, unit: WeightUnit) -> [Option] {
        let step = unit.increment
        let shown = unit.fromKilograms(kg)
        func rounded(_ value: Double) -> Double { max(step, (value / step).rounded() * step) }
        let candidates: [(Double, String)] = [
            (rounded(shown - step), "−1 step"), (rounded(shown - 2 * step), "−2 steps"),
            (rounded(shown * 0.8), "−20 %"), (rounded(shown * 0.7), "−30 %"),
        ]
        var seen = Set<Double>()
        var result: [Option] = []
        for (value, caption) in candidates where value < shown && !seen.contains(value) {
            seen.insert(value)
            result.append(Option(kg: unit.toKilograms(value), caption: caption))
        }
        return result.sorted { $0.kg > $1.kg }
    }
}

/// "Not available": alternatives for the same muscles (a different machine first), or search the
/// whole library. Done sets stay with the old exercise.
struct LiveSwapSheet: View {
    let itemID: UUID
    @Environment(LiveWorkoutController.self) private var live
    @Environment(ExerciseLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            if let item = live.content.item(id: itemID) {
                let alternatives = library.catalog.alternatives(for: item, limit: 10)
                List {
                    Section {
                        if alternatives.isEmpty {
                            Text("No close matches – search the library below.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(alternatives) { exercise in
                            Button {
                                live.swapExercise(itemID: itemID, with: exercise.makeItem(defaultRest: item.restSeconds))
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    ExerciseThumb(urls: library.imageURLs(for: exercise), symbol: exercise.displaySymbol, size: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(exercise.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text([exercise.equipment?.capitalized, exercise.primary.prefix(2).joined(separator: ", ")]
                                                .compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.triangle.swap")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    } header: {
                        Text("Same muscles")
                    } footer: {
                        Text(item.completedSets > 0
                             ? "The \(item.completedSets) set\(item.completedSets == 1 ? "" : "s") you've done stay with \(item.name); the open sets move over (with reps, without weights)."
                             : "The sets keep their reps or times; set the weight for the new exercise.")
                    }
                    Section {
                        Button {
                            showPicker = true
                        } label: {
                            Label("Search the Whole Library…", systemImage: "magnifyingglass")
                        }
                    }
                }
                .groupedList()
                .navigationTitle("Swap \(item.name)")
                .inlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
                .sheet(isPresented: $showPicker) {
                    ExercisePickerSheet(defaultKind: item.kind ?? live.session?.kind ?? .gym, singleSelection: true) { items, _ in
                        if let replacement = items.first {
                            live.swapExercise(itemID: itemID, with: replacement)
                            dismiss()
                        }
                    }
                }
            } else {
                MessageView(title: "Exercise not found", systemImage: "questionmark")
            }
        }
    }
}
