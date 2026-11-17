import SwiftUI
import GeorgeCore

/// The set whose label was tapped on the metrics page.
struct SetLogTarget: Identifiable {
    let exerciseName: String
    let workoutSet: WatchSet
    let number: Int
    let setCount: Int
    /// The plan's current set (only then "Can't finish?" is offered).
    let isCurrent: Bool

    var id: UUID { workoutSet.id }
}

/// Weights on the unit's grid (2.5 kg / 5 lb), shown in the user's unit.
enum WeightStep {
    /// kg in the display unit, rounded to 0.01 (so 61.235 kg reads as 135 lb).
    static func display(_ kg: Double, unit: WeightUnit) -> Double {
        (unit.fromKilograms(kg) * 100).rounded() / 100
    }

    /// The next grid weight above `value`.
    static func up(from value: Double, unit: WeightUnit) -> Double {
        (steps(value, unit.increment).rounded(.down) + 1) * unit.increment
    }

    /// `count` grid steps below `value` (60 → 57.5 → 55 kg), never below zero.
    static func down(from value: Double, by count: Int, unit: WeightUnit) -> Double {
        max(0, (steps(value, unit.increment).rounded(.up) - Double(count)) * unit.increment)
    }

    /// `value / step`, snapped to a whole number when it is only off by rounding noise.
    private static func steps(_ value: Double, _ step: Double) -> Double {
        let raw = value / step
        let whole = raw.rounded()
        return abs(raw - whole) < 0.001 ? whole : raw
    }
}

/// Log what was really done: reps on a wheel (Digital Crown), the weight with − / +, then Done.
/// "Can't finish?" counts the reps done and continues lighter (a drop set on the phone).
struct SetLogSheet: View {
    let target: SetLogTarget
    let unit: WeightUnit
    let kind: WorkoutKind
    @Environment(WatchConnector.self) private var connector
    @Environment(\.dismiss) private var dismiss
    @State private var reps: Int
    /// In `unit`.
    @State private var weight: Double

    private let initialReps: Int
    private let initialWeight: Double

    init(target: SetLogTarget, unit: WeightUnit, kind: WorkoutKind) {
        self.target = target
        self.unit = unit
        self.kind = kind
        let startReps = max(0, target.workoutSet.reps ?? target.workoutSet.targetReps ?? 8)
        let startWeight = WeightStep.display(target.workoutSet.weightKg ?? 0, unit: unit)
        initialReps = startReps
        initialWeight = startWeight
        _reps = State(initialValue: startReps)
        _weight = State(initialValue: startWeight)
    }

    private var tracksReps: Bool {
        target.workoutSet.isTimed != true && (target.workoutSet.reps != nil || target.workoutSet.targetReps != nil)
    }

    private var tracksWeight: Bool { target.workoutSet.weightKg != nil }

    private var repRange: ClosedRange<Int> { 0...max(50, initialReps + 10) }

    /// One and two steps lighter than the weight on the stepper.
    private var lighterWeights: [Double] {
        [1, 2].map { WeightStep.down(from: weight, by: $0, unit: unit) }.filter { $0 > 0 && $0 < weight }
    }

    private var canLowerWeight: Bool {
        target.isCurrent && tracksReps && tracksWeight && !lighterWeights.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 6) {
                Text("Set \(target.number) of \(target.setCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if tracksReps || tracksWeight {
                    HStack(spacing: 6) {
                        if tracksReps { repsWheel }
                        if tracksWeight { weightStepper }
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    Text(target.workoutSet.label)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxHeight: .infinity)
                }
                Button(action: log) {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(CapsuleButtonStyle(fill: kind.tint, foreground: kind.onTint))
                if canLowerWeight {
                    NavigationLink {
                        LowerWeightView(reps: reps, weights: lighterWeights, unit: unit, kind: kind, onLower: lower)
                    } label: {
                        Text("Can't finish? Lower the weight")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(target.exerciseName)
        }
    }

    private var repsWheel: some View {
        VStack(spacing: 0) {
            Picker("Reps", selection: $reps) {
                ForEach(repRange, id: \.self) { value in
                    Text("\(value)")
                        .font(.title2.weight(.semibold))
                        .tag(value)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            Text("reps")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var weightStepper: some View {
        VStack(spacing: 2) {
            stepButton(systemImage: "plus", label: "More weight") {
                weight = WeightStep.up(from: weight, unit: unit)
            }
            Text(Format.number(weight))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
            stepButton(systemImage: "minus", label: "Less weight") {
                weight = WeightStep.down(from: weight, by: 1, unit: unit)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Weight \(Format.number(weight)) \(unit.rawValue)"))
    }

    private func stepButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.bold))
        }
        .buttonStyle(ChipButtonStyle())
        .accessibilityLabel(Text(label))
    }

    /// Sends what was done; an untouched weight stays nil so the planned kg is kept exactly.
    private func log() {
        let loggedReps = tracksReps ? reps : nil
        let weightChanged = tracksWeight && abs(weight - initialWeight) > 0.001
        connector.perform(.completeSet(id: target.workoutSet.id, reps: loggedReps, weightKg: weightChanged ? unit.toKilograms(weight) : nil))
        dismiss()
    }

    private func lower(to newWeight: Double) {
        connector.perform(.dropWeight(setID: target.workoutSet.id, repsDone: reps, newWeightKg: unit.toKilograms(newWeight)))
        dismiss()
    }
}

/// "Can't finish?": the reps done count, then on with a lighter weight.
private struct LowerWeightView: View {
    let reps: Int
    let weights: [Double]
    let unit: WeightUnit
    let kind: WorkoutKind
    let onLower: (Double) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("\(reps) reps done. Go on with:")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(weights, id: \.self) { weight in
                    Button {
                        onLower(weight)
                    } label: {
                        Text("\(Format.number(weight)) \(unit.rawValue)")
                    }
                    .buttonStyle(CapsuleButtonStyle(fill: kind.tint, foreground: kind.onTint))
                }
                Text("Change the reps on the previous screen.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle("Lower weight")
    }
}
