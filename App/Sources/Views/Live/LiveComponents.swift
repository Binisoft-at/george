import SwiftUI
import BinisoftKit
import GeorgeCore

// MARK: - Momentum header

/// Progress of the whole workout, the momentum flame and a body figure that fills up as the muscles
/// get their sets. Calm shows progress only; Off shows just the numbers.
struct MomentumHeader: View {
    let motivation: MotivationStyle
    let onFinish: () -> Void

    @Environment(LiveWorkoutController.self) private var live
    @Environment(MuscleAnalytics.self) private var muscles

    var body: some View {
        let done = live.content.completedSets
        let total = max(1, live.content.totalSets)
        HStack(spacing: 12) {
            if motivation != .off {
                MiniBodyFill(pulse: live.completionPulse)
                    .frame(width: 56, height: 50)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("\(done) of \(live.content.totalSets) sets")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer(minLength: 4)
                    if motivation == .full {
                        FlameBadge(pace: live.pace, intensity: live.intensity, pulse: live.completionPulse)
                    } else if live.intensity == .calm {
                        Label("Easy day", systemImage: "leaf.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                ProgressBar(progress: Double(done) / Double(total), hot: motivation == .full && live.pace.level == .onFire)
            }
            if live.content.isComplete {
                Button(action: onFinish) {
                    Label("Finish", systemImage: "flag.checkered")
                        .font(.subheadline.weight(.bold))
                }
                .buttonStyle(.glassProminent)
                .tint(.green)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.snappy, value: live.content.isComplete)
        .animation(.snappy, value: done)
    }
}

/// Capsule progress bar; glows orange → red while on fire.
struct ProgressBar: View {
    let progress: Double
    var hot = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(hot
                          ? AnyShapeStyle(LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing))
                          : AnyShapeStyle(Color.accentColor.gradient))
                    .frame(width: max(8, proxy.size.width * min(1, max(0, progress))))
                    .shadow(color: hot ? .orange.opacity(0.6) : .clear, radius: 6)
            }
        }
        .frame(height: 8)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: progress)
        .accessibilityElement()
        .accessibilityLabel("Workout progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

/// The flame: big and breathing when the sets come on time, smaller when steady, grey when slow.
struct FlameBadge: View {
    let pace: PaceTracker
    let intensity: CoachIntensity
    let pulse: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: pace.level == .slow ? "flame" : "flame.fill")
                .font(.system(size: pace.level == .onFire ? 20 : 16, weight: .bold))
                .foregroundStyle(style)
                .symbolEffect(.breathe, isActive: pace.level == .onFire)
                .symbolEffect(.bounce, value: pulse)
                .contentTransition(.symbolEffect(.replace))
            Text(text)
                .font(.caption.weight(.bold))
                .foregroundStyle(pace.level == .slow ? Color.secondary : Color.orange)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background((pace.level == .onFire ? Color.orange : Color.secondary).opacity(0.14), in: Capsule())
        .animation(.snappy, value: pace.level)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Momentum: \(text)")
    }

    private var style: AnyShapeStyle {
        switch pace.level {
        case .onFire: return AnyShapeStyle(LinearGradient(colors: [.yellow, .orange, .red], startPoint: .top, endPoint: .bottom))
        case .steady: return AnyShapeStyle(Color.orange)
        case .slow: return AnyShapeStyle(Color.secondary)
        }
    }

    private var text: String {
        switch pace.level {
        case .onFire: return pace.onTimeStreak >= 2 ? "\(pace.onTimeStreak) on time" : "On fire"
        case .steady: return "Steady"
        case .slow: return intensity == .calm ? "Easy pace" : "Pick it up"
        }
    }
}

/// Front and back figure; each muscle glows more the more of its planned sets are done.
struct MiniBodyFill: View {
    let pulse: Int
    @Environment(LiveWorkoutController.self) private var live
    @Environment(MuscleAnalytics.self) private var muscles

    var body: some View {
        let planned = muscles.plannedSets(live.content, completedOnly: false)
        let done = muscles.plannedSets(live.content, completedOnly: true)
        BodyMapPair(fill: { group in
            let plan = planned[group] ?? 0
            guard plan > 0 else { return Color.clear }
            let share = min(1, (done[group] ?? 0) / plan)
            return share > 0 ? MusclePalette.heat(0.25 + 0.75 * share) : Color.accentColor.opacity(0.18)
        }, spacing: 2)
        .keyframeAnimator(initialValue: 1.0, trigger: pulse) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(1.12, duration: 0.15)
                SpringKeyframe(1.0, duration: 0.4)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: pulse)
        .accessibilityLabel("Muscles worked so far")
    }
}

// MARK: - Bursts

/// A ring of sparks flying out – played whenever `trigger` changes.
struct BurstView: View {
    let trigger: Int
    var colors: [Color] = [.accentColor, .orange, .yellow]
    var count = 12
    var distance: Double = 34

    var body: some View {
        // Plain values only inside the animator's content (it may run off the main actor).
        let sparks = BurstView.sparks(count: count, distance: distance, colors: colors)
        return KeyframeAnimator(initialValue: 1.0, trigger: trigger) { progress in
            ZStack {
                ForEach(sparks) { spark in
                    Circle()
                        .fill(spark.color)
                        .frame(width: 7, height: 7)
                        .scaleEffect(1 - 0.6 * progress)
                        .offset(x: spark.dx * (10 + spark.distance * progress), y: spark.dy * (10 + spark.distance * progress))
                        .opacity(progress >= 1 ? 0 : 1 - progress)
                }
            }
        } keyframes: { _ in
            KeyframeTrack {
                MoveKeyframe(0.0)
                CubicKeyframe(1.0, duration: 0.6)
            }
        }
        .accessibilityHidden(true)
    }

    struct Spark: Identifiable, Sendable {
        let id: Int
        let dx: Double
        let dy: Double
        let distance: Double
        let color: Color
    }

    nonisolated static func sparks(count: Int, distance: Double, colors: [Color]) -> [Spark] {
        (0..<count).map { index in
            let angle = Double(index) / Double(count) * 2 * Double.pi
            return Spark(id: index, dx: cos(angle), dy: sin(angle), distance: distance, color: colors[index % colors.count])
        }
    }
}

/// Confetti for the finish: lots of small pieces falling from the top.
struct ConfettiView: View {
    let trigger: Int
    var pieces = 48

    var body: some View {
        let seeds = ConfettiView.seeds(pieces)
        return GeometryReader { proxy in
            let size = proxy.size
            KeyframeAnimator(initialValue: 1.0, trigger: trigger) { progress in
                ZStack {
                    ForEach(seeds) { seed in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(seed.color)
                            .frame(width: 7, height: 12)
                            .rotationEffect(.degrees(360 * progress * seed.spin))
                            .position(x: Double(size.width) * seed.column + sin(progress * 6 + seed.phase * 6) * 18,
                                      y: Double(size.height) * (0.15 + 0.85 * progress) * seed.speed - 20)
                            .opacity(progress >= 1 ? 0 : 1 - progress * progress)
                    }
                }
            } keyframes: { _ in
                KeyframeTrack {
                    MoveKeyframe(0.0)
                    LinearKeyframe(1.0, duration: 2.4)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    struct Seed: Identifiable, Sendable {
        let id: Int
        let column: Double
        let phase: Double
        let speed: Double
        let spin: Double
        let color: Color
    }

    /// Fixed pseudo-random pieces: spread across the width, each falling, swaying and spinning a bit differently.
    nonisolated static func seeds(_ count: Int) -> [Seed] {
        let palette: [Color] = [.accentColor, .orange, .yellow, .green, .pink, .purple]
        return (0..<count).map { index in
            let phase = Double((index * 7919) % 1000) / 1000
            return Seed(id: index, column: Double((index * 104729) % 1000) / 1000, phase: phase,
                        speed: 0.6 + 0.4 * phase, spin: phase > 0.5 ? 2 : -2, color: palette[index % palette.count])
        }
    }
}

// MARK: - Banners and prompts

/// "Bench Press done", "New best: 85 kg", "Halfway there".
struct CelebrationBanner: View {
    let celebration: LiveWorkoutController.Celebration
    let motivation: MotivationStyle

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: celebration.symbol)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(tint.gradient)
                .symbolEffect(.bounce, value: celebration.id)
                .overlay {
                    if motivation == .full {
                        BurstView(trigger: celebration.id.hashValue, colors: [tint, .orange, .yellow], distance: 40)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(celebration.title)
                    .font(.headline)
                Text(celebration.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .floatingGlass(cornerRadius: 24, tint: tint)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var tint: Color {
        switch celebration.kind {
        case .record: return .yellow
        case .allDone: return .green
        case .halfway: return .orange
        case .exercise: return .accentColor
        }
    }
}

/// One tap after an exercise's last set: how many more reps were in the tank? Feeds the next
/// suggestion. Disappears on its own.
struct EffortPromptCard: View {
    let request: LiveWorkoutController.EffortRequest
    @Environment(LiveWorkoutController.self) private var live

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("How many more reps could you have done?")
                        .font(.subheadline.weight(.semibold))
                    Text("\(request.itemName) · helps George pick next time's weight")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button {
                    live.answerEffort(repsInReserve: nil)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Skip")
            }
            HStack(spacing: 8) {
                ForEach(EffortChoice.all) { choice in
                    Button {
                        Haptics.tap()
                        live.answerEffort(repsInReserve: choice.id)
                    } label: {
                        VStack(spacing: 0) {
                            Text(choice.title).font(.headline)
                            Text(choice.caption).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .padding(14)
        .floatingGlass(cornerRadius: 24)
    }
}

private struct EffortChoice: Identifiable {
    let id: Int
    let title: String
    let caption: String

    static let all = [
        EffortChoice(id: 0, title: "0", caption: "All out"),
        EffortChoice(id: 1, title: "1", caption: "Hard"),
        EffortChoice(id: 2, title: "2", caption: "Solid"),
        EffortChoice(id: 3, title: "3+", caption: "Easy"),
    ]
}

/// Before the first set: how's your energy? Low energy makes the coach calmer for today.
struct EnergyCheckInCard: View {
    var readiness: BodyReadiness? = nil
    let onPick: (Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("How's your energy today?")
                        .font(.headline)
                    Text("George adapts the pace – and looks for your rhythm over the weeks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("Skip") { onPick(nil) }
                    .font(.subheadline)
                    .buttonStyle(.glass)
            }
            if let readiness {
                Label("\(readiness.headline) – \(readiness.summary)", systemImage: "heart.text.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            EnergyPicker(selected: readiness?.suggestedEnergy, onPick: { onPick($0) })
        }
        .padding(16)
        .floatingGlass(cornerRadius: 26)
    }
}

/// Five battery buttons, 1 (drained) … 5 (great).
struct EnergyPicker: View {
    var selected: Int? = nil
    let onPick: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { level in
                Button {
                    Haptics.tap()
                    onPick(level)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: EnergyEntry.symbol(for: level))
                            .font(.title3)
                            .foregroundStyle(EnergyPicker.color(for: level))
                        Text(EnergyEntry.label(for: level))
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(selected == level ? EnergyPicker.color(for: level).opacity(0.2) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Energy \(level) of 5: \(EnergyEntry.label(for: level))")
            }
        }
    }

    static func color(for level: Int) -> Color {
        switch level {
        case 1: return .red
        case 2: return .orange
        case 3: return .yellow
        case 4: return .green
        default: return .mint
        }
    }
}

// MARK: - Value pad

struct ValuePadRequest: Identifiable {
    let id = UUID()
    var setID: UUID
    var itemID: UUID
    var field: SetField
}

/// A big keypad for one set: switch between reps, weight, RPE…, tap a suggestion (last time,
/// previous set, plan, ± one step) or type. Both "," and "." work. Changes apply as you type.
struct ValuePadSheet: View {
    let request: ValuePadRequest

    @Environment(LiveWorkoutController.self) private var live
    @Environment(GeorgeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var field: SetField
    @State private var text = ""
    @State private var replaceOnType = true

    init(request: ValuePadRequest) {
        self.request = request
        _field = State(initialValue: request.field)
    }

    private var item: WorkoutItem? { live.content.item(id: request.itemID) }
    private var set: WorkoutSet? { item?.sets.first { $0.id == request.setID } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if let item, let set {
                    header(item, set)
                    if fields(for: item).count > 1 {
                        Picker("Value", selection: Binding(get: { field }, set: { switchField(to: $0) })) {
                            ForEach(fields(for: item), id: \.self) { Text(title(for: $0)).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    display
                    suggestions(item, set)
                    keypad
                    actions
                } else {
                    MessageView(title: "Set not found", systemImage: "questionmark")
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .navigationTitle(item?.name ?? "Set")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        commit()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear(perform: load)
        }
    }

    // MARK: Parts

    private func header(_ item: WorkoutItem, _ set: WorkoutSet) -> some View {
        HStack {
            Text("Set \(item.displayIndex(of: set))")
                .font(.subheadline.weight(.semibold))
            if set.isDone {
                Label("done", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            Text(set.label(mode: item.mode, unit: live.unit))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var display: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text.isEmpty ? "–" : text)
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(replaceOnType ? Color.accentColor : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(unitCaption)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .animation(.snappy, value: text)
        .accessibilityElement(children: .combine)
    }

    private func suggestions(_ item: WorkoutItem, _ set: WorkoutSet) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips(item, set)) { chip in
                    Button {
                        Haptics.tap()
                        text = Format.number(chip.value)
                        replaceOnType = true
                        commit()
                    } label: {
                        VStack(spacing: 0) {
                            Text(Format.number(chip.value)).font(.subheadline.weight(.bold)).monospacedDigit()
                            Text(chip.title).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private var keypad: some View {
        let keys: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], [allowsDecimal ? decimalSeparator : "", "0", "⌫"]]
        return VStack(spacing: 8) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { key in
                        if key.isEmpty {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 56)
                        } else {
                            Button {
                                press(key)
                            } label: {
                                Group {
                                    if key == "⌫" {
                                        Image(systemName: "delete.left")
                                    } else {
                                        Text(key)
                                    }
                                }
                                .font(.title.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.glass)
                            .accessibilityLabel(key == "⌫" ? "Delete" : key)
                        }
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if hasFollowingOpenSets {
                Button {
                    commit()
                    live.edit { $0.applyToFollowingSets(from: request.setID, inSession: true) }
                    Haptics.success()
                    dismiss()
                } label: {
                    Label("Same for the rest", systemImage: "arrow.down.to.line")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glass)
            }
            Button {
                commit()
                dismiss()
            } label: {
                Text("Save")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glassProminent)
        }
    }

    // MARK: Logic

    private func fields(for item: WorkoutItem) -> [SetField] {
        switch item.mode {
        case .reps: return [.reps, .weight, .rpe]
        case .time: return [.seconds, .weight]
        case .distance: return [.meters, .seconds]
        }
    }

    private func title(for field: SetField) -> String {
        switch field {
        case .reps: return "Reps"
        case .weight: return "Weight"
        case .seconds: return "Time (s)"
        case .meters: return "Distance"
        case .rpe: return "RPE"
        }
    }

    private var unitCaption: String {
        switch field {
        case .reps: return "reps"
        case .weight: return live.unit.rawValue
        case .seconds: return "sec"
        case .meters: return "m"
        case .rpe: return "RPE"
        }
    }

    private var allowsDecimal: Bool { field == .weight || field == .meters || field == .rpe }

    private var decimalSeparator: String { Locale.current.decimalSeparator ?? "." }

    private var step: Double {
        switch field {
        case .weight: return live.unit.increment
        case .seconds: return 5
        case .meters: return 50
        case .rpe: return 0.5
        case .reps: return 1
        }
    }

    private var hasFollowingOpenSets: Bool {
        guard let item, let index = item.sets.firstIndex(where: { $0.id == request.setID }) else { return false }
        return item.sets.indices.contains { $0 > index && !item.sets[$0].isDone }
    }

    /// Value of a set's field in the units shown (kg/lb for weight).
    private func shown(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return field == .weight ? live.unit.fromKilograms(value) : value
    }

    private struct Chip: Identifiable {
        var id: String { title }
        let title: String
        let value: Double
    }

    private func chips(_ item: WorkoutItem, _ set: WorkoutSet) -> [Chip] {
        var result: [Chip] = []
        func add(_ title: String, _ value: Double?) {
            guard let value, value >= 0 else { return }
            let rounded = (value * 100).rounded() / 100
            guard !result.contains(where: { $0.value == rounded }) else { return }
            result.append(Chip(title: title, value: rounded))
        }
        let index = item.sets.firstIndex { $0.id == set.id } ?? 0
        if let last = PreviousPerformanceCache.shared.sets(for: item.exerciseKey, store: store), !last.isEmpty {
            let match = index < last.count ? last[index] : last[last.count - 1]
            add("last time", shown(match.value(field, inSession: true)))
        }
        if index > 0 { add("previous set", shown(item.sets[index - 1].value(field, inSession: true))) }
        add("plan", shown(set.value(field, inSession: false)))
        if let current = NumberParser.double(text) {
            add("−\(Format.number(step))", max(0, current - step))
            add("+\(Format.number(step))", current + step)
        }
        return result
    }

    private func load() {
        guard let set else { return }
        text = shown(set.value(field, inSession: true)).map(Format.number) ?? ""
        replaceOnType = true
    }

    private func switchField(to newField: SetField) {
        commit()
        field = newField
        load()
    }

    private func press(_ key: String) {
        Haptics.tap()
        if replaceOnType {
            text = ""
            replaceOnType = false
        }
        switch key {
        case "⌫":
            if !text.isEmpty { text.removeLast() }
        case decimalSeparator:
            if !text.contains(decimalSeparator) && !text.contains(".") && !text.contains(",") {
                text = (text.isEmpty ? "0" : text) + decimalSeparator
            }
        default:
            guard text.count < 7 else { return }
            text = text == "0" ? key : text + key
        }
        commit()
    }

    /// Writes what's typed into the set (empty clears the field).
    private func commit() {
        let parsed = NumberParser.double(text)
        let stored = parsed.map { field == .weight ? live.unit.toKilograms($0) : $0 }
        let current = set?.value(field, inSession: true)
        guard stored != current else { return }
        live.updateSet(request.setID) { $0.setValue(field, stored, inSession: true) }
    }
}
