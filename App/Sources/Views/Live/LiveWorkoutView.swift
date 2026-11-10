import SwiftUI
import BinisoftKit
import TipKit
import GeorgeCore

/// Full-screen "currently working out" mode. No big Done button: every set shows clearly whether it's
/// done, current or still open, and you tick whichever you did. Numbers are typed on a big keypad (tap)
/// or scrubbed (drag sideways). Momentum, the body figure and the set timer keep you moving.
struct LiveWorkoutView: View {
    @Environment(LiveWorkoutController.self) private var live
    @Environment(GeorgeStore.self) private var store
    @Environment(HealthKitManager.self) private var health
    @AppStorage(Prefs.motivation) private var motivationRaw = MotivationStyle.full.rawValue
    @State private var showFinish = false
    @State private var showEditor = false
    @State private var showAdd = false
    @State private var confirmDiscard = false
    @State private var editingSet: SetEditRequest?
    @State private var valuePad: ValuePadRequest?
    @State private var tutorial: URL?
    @State private var dragOffset: CGFloat = 0

    private var motivation: MotivationStyle { MotivationStyle(rawValue: motivationRaw) ?? .full }

    var body: some View {
        ZStack(alignment: .top) {
            background
            if let session = live.session {
                VStack(spacing: 0) {
                    topBar(session)
                    pager
                    bottomPanel
                }
                overlays
            } else {
                MessageView(title: "No workout running", systemImage: "figure.walk")
            }
        }
        .offset(y: max(0, dragOffset))
        .environment(\.liveActions, LiveActions(
            editValue: { setID, itemID, field in valuePad = ValuePadRequest(setID: setID, itemID: itemID, field: field) },
            editSet: { setID, itemID in editingSet = SetEditRequest(setID: setID, itemID: itemID) },
            tutorial: { tutorial = $0 }
        ))
        .sheet(isPresented: Binding(get: { live.showPanel }, set: { live.showPanel = $0 })) {
            LivePanelSheet(onFinish: {
                live.showPanel = false
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    showFinish = true
                }
            })
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showFinish) {
            FinishWorkoutSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showEditor) {
            LiveEditSheet()
        }
        .sheet(isPresented: $showAdd) {
            ExercisePickerSheet(defaultKind: live.session?.kind ?? .gym) { items, asGroup in
                live.edit { content in
                    if let focused = live.focusedItemID, !asGroup {
                        content.insert(items: items, afterItem: focused)
                    } else {
                        content.append(items: items, asGroup: asGroup)
                    }
                }
                if let first = items.first { live.focus(itemID: first.id) }
            }
        }
        .sheet(item: $valuePad) { request in
            ValuePadSheet(request: request)
                .presentationDetents([.height(560), .large])
        }
        .sheet(item: $editingSet) { request in
            NavigationStack {
                SetEditorSheet(
                    content: Binding(get: { live.content }, set: { live.replaceContent($0) }),
                    itemID: request.itemID, setID: request.setID, mode: .session(isLive: true)
                )
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(get: { tutorial.map { URLItem(url: $0) } }, set: { tutorial = $0?.url })) { item in
            LinkPlayerView(url: item.url)
        }
        .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Workout", role: .destructive) { live.discard() }
        } message: {
            Text("Nothing is saved and it won't count toward your streak.")
        }
        .onAppear { if !LaunchOptions.current.isDemo { live.requestNotificationPermission() } }
    }

    private var background: some View {
        LinearGradient(colors: [Color.accentColor.opacity(0.24), Color.clear, Color.accentColor.opacity(0.06)], startPoint: .top, endPoint: .bottom)
            .background(.background)
            .ignoresSafeArea()
    }

    // MARK: Top bar

    private func topBar(_ session: WorkoutSession) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    live.isPresented = false
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.headline)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityLabel("Minimise")

                VStack(spacing: 2) {
                    Text(session.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(spacing: 8) {
                            Text(Format.clock(Int(live.elapsed(at: context.date))))
                                .font(.title2.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(live.isPaused ? Color.secondary : Color.primary)
                            if let hr = live.heartRate {
                                Label("\(Int(hr))", systemImage: "heart.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.pink)
                                    .symbolEffect(.pulse)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { dragOffset = $0.translation.height }
                        .onEnded { value in
                            if value.translation.height > 120 { live.isPresented = false }
                            withAnimation(.snappy) { dragOffset = 0 }
                        }
                )

                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                        .font(.headline)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Add exercise")

                menu
            }
            MomentumHeader(motivation: motivation) { showFinish = true }
            #if os(iOS)
            ExerciseStrip()
            #endif
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var menu: some View {
        Menu {
            Button { showAdd = true } label: { Label("Add Exercise", systemImage: "plus") }
            Button { showEditor = true } label: { Label("Edit Workout", systemImage: "list.bullet.rectangle") }
            Menu {
                ForEach([30, 60, 90, 120, 180], id: \.self) { seconds in
                    Button(Format.shortDuration(seconds)) { live.startRest(seconds) }
                }
            } label: {
                Label("Start Rest Timer", systemImage: "timer")
            }
            Picker(selection: Binding(get: { live.intensity }, set: { live.setIntensity($0) })) {
                ForEach(CoachIntensity.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Today's Pace", systemImage: "gauge.with.dots.needle.33percent")
            }
            Button { live.togglePause() } label: {
                Label(live.isPaused ? "Resume" : "Pause", systemImage: live.isPaused ? "play" : "pause")
            }
            Button { live.toggleVoiceMute() } label: {
                Label(live.isVoiceMuted ? "Unmute Voice" : "Mute Voice", systemImage: live.isVoiceMuted ? "speaker.wave.2" : "speaker.slash")
            }
            Button { live.showPanel = true } label: { Label("Pace & Controls", systemImage: "rectangle.expand.vertical") }
            Divider()
            Button { showFinish = true } label: { Label("Finish Workout…", systemImage: "flag.checkered") }
            Button(role: .destructive) { confirmDiscard = true } label: { Label("Discard…", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.headline)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }

    // MARK: Pager – one page per exercise, supersets as one page

    @ViewBuilder
    private var pager: some View {
        let blocks = live.content.blocks
        #if os(iOS)
        TabView(selection: blockSelection) {
            ForEach(blocks) { block in
                ScrollView {
                    BlockPage(block: block, letter: groupLetter(for: block.id))
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .tag(Optional(block.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .animation(.snappy, value: live.focusedItemID)
        #else
        HStack(spacing: 0) {
            List(selection: Binding(get: { live.focusedItem?.id }, set: { if let id = $0 { live.focus(itemID: id) } })) {
                ForEach(live.content.allItems) { item in
                    HStack {
                        Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isComplete ? Color.accentColor : Color.secondary)
                        Text(item.name).lineLimit(1)
                        Spacer()
                        Text("\(item.completedSets)/\(item.sets.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(item.id)
                }
            }
            .frame(width: 230)
            ScrollView {
                if let block = focusedBlock {
                    BlockPage(block: block, letter: groupLetter(for: block.id))
                        .padding()
                }
            }
        }
        #endif
    }

    private var focusedBlock: WorkoutBlock? {
        guard let id = live.focusedItem?.id, let loc = live.content.locate(itemID: id) else { return live.content.blocks.first }
        return live.content.blocks[loc.block]
    }

    /// The pager shows blocks; focusing a block focuses its first open exercise.
    private var blockSelection: Binding<UUID?> {
        Binding(
            get: { focusedBlock?.id },
            set: { id in
                guard let id, id != focusedBlock?.id, let block = live.content.blocks.first(where: { $0.id == id }) else { return }
                let target = block.items.first { !$0.isComplete } ?? block.items.first
                // The page you swipe to is what you're doing now.
                if let target { live.focus(itemID: target.id) }
            }
        )
    }

    private func groupLetter(for blockID: UUID) -> String {
        let grouped = live.content.blocks.filter { $0.items.count > 1 }
        let index = grouped.firstIndex { $0.id == blockID } ?? 0
        return String(Character(UnicodeScalar(65 + (index % 26)) ?? "A"))
    }

    // MARK: Bottom

    @ViewBuilder
    private var bottomPanel: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 10) {
                if let request = live.effortRequest {
                    FeedbackCard(request: request)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                CoachBar(onExpand: { live.showPanel = true }, onFinish: { showFinish = true })
                    .transition(.opacity)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .animation(.snappy, value: live.restEndsAt)
        .animation(.snappy, value: live.effortRequest)
    }

    // MARK: Overlays

    @ViewBuilder
    private var overlays: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 150)
            if live.needsEnergyCheckIn {
                EnergyCheckInCard(readiness: CoachPrefs.healthSignals ? health.readiness : nil) { live.recordEnergy($0) }
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let celebration = live.celebration {
                CelebrationBanner(celebration: celebration, motivation: motivation)
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: live.celebration)
        .animation(.snappy, value: live.needsEnergyCheckIn)
    }

    private func move(by offset: Int) {
        let blocks = live.content.blocks
        guard let current = focusedBlock, let index = blocks.firstIndex(where: { $0.id == current.id }) else { return }
        let target = max(0, min(blocks.count - 1, index + offset))
        guard let item = blocks[target].items.first(where: { !$0.isComplete }) ?? blocks[target].items.first else { return }
        withAnimation(.snappy) { live.focus(itemID: item.id) }
        Haptics.tap()
    }
}

// MARK: - Actions handed down to rows

/// What rows can ask the live view to show (keypad, set editor, tutorial).
struct LiveActions {
    var editValue: (UUID, UUID, SetField) -> Void = { _, _, _ in }
    var editSet: (UUID, UUID) -> Void = { _, _ in }
    var tutorial: (URL) -> Void = { _ in }
}

private struct LiveActionsKey: EnvironmentKey {
    static let defaultValue = LiveActions()
}

extension EnvironmentValues {
    var liveActions: LiveActions {
        get { self[LiveActionsKey.self] }
        set { self[LiveActionsKey.self] = newValue }
    }
}

// MARK: - Pages

/// One page of the pager: a single exercise, or a superset/circuit shown side by side.
struct BlockPage: View {
    let block: WorkoutBlock
    let letter: String

    var body: some View {
        if block.items.count > 1 {
            SupersetCard(block: block, letter: letter)
        } else if let item = block.items.first {
            LiveExerciseCard(item: item)
        }
    }
}

/// One exercise: picture, name, what to try today, and its sets.
struct LiveExerciseCard: View {
    let item: WorkoutItem

    @Environment(LiveWorkoutController.self) private var live
    @Environment(ExerciseLibrary.self) private var library
    @Environment(GeorgeStore.self) private var store
    @Environment(\.liveActions) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ExerciseAnimation(urls: library.imageURLs(for: item), symbol: (item.kind ?? .gym).symbol, tint: .accentColor)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .onTapGesture(count: 2) { live.completeCurrentSet() }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                Text(item.prescription(unit: live.unit))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let notes = item.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.callout)
                        .italic()
                        .foregroundStyle(.secondary)
                }
            }

            ProgressionChip(item: item)

            TipView(GeorgeTips.LiveSetTip())

            VStack(spacing: 8) {
                ForEach(Array(item.sets.enumerated()), id: \.element.id) { index, set in
                    LiveSetRow(item: item, set: set, previous: previous(at: index), isCurrent: set.id == live.currentSet?.id)
                }
                Button {
                    live.edit { $0.addSet(to: item.id) }
                } label: {
                    Label("Add Set", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
            }

            TutorialRow(item: item)
        }
        .padding(.top, 10)
    }

    private func previous(at index: Int) -> WorkoutSet? {
        guard let sets = PreviousPerformanceCache.shared.sets(for: item.exerciseKey, store: store), !sets.isEmpty else { return nil }
        let candidate = index < sets.count ? sets[index] : sets[sets.count - 1]
        return candidate.isDone ? candidate : nil
    }
}

/// Watch a tutorial / how-to steps.
struct TutorialRow: View {
    let item: WorkoutItem
    @Environment(LiveWorkoutController.self) private var live
    @Environment(ExerciseLibrary.self) private var library
    @Environment(\.liveActions) private var actions

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if let link = item.links.first, let url = URL(string: link) {
                    actions.tutorial(url)
                } else if let url = TutorialLinks.youtubeSearch(for: item.name, kind: item.kind ?? live.session?.kind) {
                    actions.tutorial(url)
                }
            } label: {
                Label(item.links.isEmpty ? "Find Tutorial" : "Watch Tutorial", systemImage: "play.rectangle.fill")
            }
            .buttonStyle(.glass)
            .tint(.red)
            if let exercise = library.exercise(for: item), !exercise.steps.isEmpty {
                DisclosureGroup("How to") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(exercise.steps.enumerated()), id: \.offset) { index, step in
                            Text("\(index + 1). \(step)").font(.callout)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }
}

/// "Try 62.5 kg × 8 – last time 3 reps were left." Shown before the first set of an exercise.
struct ProgressionChip: View {
    let item: WorkoutItem
    @Environment(LiveWorkoutController.self) private var live
    @Environment(GeorgeStore.self) private var store

    var body: some View {
        if item.completedSets == 0, let suggestion {
            Button {
                apply(suggestion)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol(for: suggestion.kind))
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(for: suggestion))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(suggestion.reason + " · tap to use")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var suggestion: ProgressionSuggestion? {
        let last = PreviousPerformanceCache.shared.sets(for: item.exerciseKey, store: store)
        let plan = item.sets.first { !$0.isDone && $0.kind != .warmup }
        return ProgressionAdvisor.suggest(lastSets: last, mode: item.mode, plan: plan, incrementKg: live.unit.toKilograms(live.unit.increment))
    }

    private func title(for suggestion: ProgressionSuggestion) -> String {
        var parts: [String] = []
        if let weight = suggestion.weightKg { parts.append(Format.weight(weight, unit: live.unit)) }
        if let reps = suggestion.reps { parts.append("\(reps) reps") }
        let target = parts.joined(separator: " × ")
        switch suggestion.kind {
        case .addWeight: return "Go up: \(target)"
        case .addReps: return "One more rep: \(target)"
        case .keep: return "Match last time: \(target)"
        case .lighten: return "A step lighter: \(target)"
        }
    }

    private func symbol(for kind: ProgressionSuggestion.Kind) -> String {
        switch kind {
        case .addWeight: return "arrow.up.circle.fill"
        case .addReps: return "plus.circle.fill"
        case .keep: return "equal.circle.fill"
        case .lighten: return "arrow.down.circle.fill"
        }
    }

    private func apply(_ suggestion: ProgressionSuggestion) {
        live.edit { content in
            for set in item.sets where !set.isDone && set.kind != .warmup {
                content.updateSet(id: set.id) { s in
                    if let weight = suggestion.weightKg { s.setValue(.weight, weight, inSession: true) }
                    if let reps = suggestion.reps { s.setValue(.reps, Double(reps), inSession: true) }
                }
            }
        }
        Haptics.success()
    }
}

// MARK: - Sets

/// One set with a clear state: done (filled), current (highlighted, big editable numbers) or open.
struct LiveSetRow: View {
    let item: WorkoutItem
    let set: WorkoutSet
    let previous: WorkoutSet?
    let isCurrent: Bool

    @Environment(LiveWorkoutController.self) private var live
    @Environment(\.liveActions) private var actions
    @AppStorage(Prefs.motivation) private var motivationRaw = MotivationStyle.full.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SetStateBadge(index: item.displayIndex(of: set), isDone: set.isDone, isCurrent: isCurrent)
                VStack(alignment: .leading, spacing: 2) {
                    if isCurrent && !set.isDone {
                        Text("NOW")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(set.label(mode: item.mode, unit: live.unit))
                        .font(isCurrent ? .title3.weight(.bold) : .body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(set.isDone || isCurrent ? Color.primary : Color.secondary)
                    if let previous {
                        Text("Last: \(previous.label(mode: item.mode, unit: live.unit))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { actions.editValue(set.id, item.id, primaryField) }
                Spacer(minLength: 4)
                CheckButton(isDone: set.isDone, isCurrent: isCurrent, burst: (MotivationStyle(rawValue: motivationRaw) ?? .full) == .full) {
                    live.toggleSet(set.id)
                }
            }
            if isCurrent && !set.isDone {
                if item.mode == .time {
                    TimedSetDial(item: item, set: set)
                }
                ValueTiles(item: item, set: set)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isCurrent && !set.isDone ? Color.accentColor.opacity(0.8) : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.35) {
            Haptics.tap()
            actions.editSet(set.id, item.id)
        }
        .animation(.snappy, value: set.isDone)
        .animation(.snappy, value: isCurrent)
    }

    private var rowFill: Color {
        if set.isDone { return Color.accentColor.opacity(0.08) }
        if isCurrent { return Color.accentColor.opacity(0.16) }
        return Color.secondary.opacity(0.06)
    }

    private var primaryField: SetField {
        switch item.mode {
        case .reps: return .reps
        case .time: return .seconds
        case .distance: return .meters
        }
    }
}

/// Number circle: filled with a check when done, ringed when current, plain when open.
struct SetStateBadge: View {
    let index: String
    let isDone: Bool
    let isCurrent: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isDone ? Color.accentColor : (isCurrent ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12)))
            if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white)
            } else {
                Text(index)
                    .font(.headline)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            }
        }
        .frame(width: 34, height: 34)
        .overlay {
            if isCurrent && !isDone {
                Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The big tick. Bursts when a set is done (full motivation).
struct CheckButton: View {
    let isDone: Bool
    let isCurrent: Bool
    let burst: Bool
    let action: () -> Void

    @State private var burstTrigger = 0

    var body: some View {
        Button {
            if !isDone { burstTrigger += 1 }
            action()
        } label: {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: isCurrent ? 44 : 34))
                .foregroundStyle(isDone ? Color.accentColor : (isCurrent ? Color.accentColor : Color.secondary.opacity(0.5)))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            if burst {
                BurstView(trigger: burstTrigger)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(isDone ? "Mark set not done" : "Mark set done")
    }
}

/// Reps and weight (or time / distance) of the current set as big tiles: tap for the keypad,
/// drag sideways to step the number.
struct ValueTiles: View {
    let item: WorkoutItem
    let set: WorkoutSet
    @Environment(LiveWorkoutController.self) private var live
    @Environment(\.liveActions) private var actions

    var body: some View {
        HStack(spacing: 10) {
            ForEach(fields, id: \.self) { field in
                ValueTile(
                    text: text(for: field),
                    caption: caption(for: field),
                    onTap: { actions.editValue(set.id, item.id, field) },
                    onStep: { steps in step(field, by: steps) }
                )
            }
        }
    }

    private var fields: [SetField] {
        switch item.mode {
        case .reps: return [.reps, .weight]
        case .time: return [.seconds, .weight]
        case .distance: return [.meters, .seconds]
        }
    }

    private func text(for field: SetField) -> String {
        guard let value = set.value(field, inSession: true) else { return "–" }
        return field == .weight ? Format.number(live.unit.fromKilograms(value)) : Format.number(value)
    }

    private func caption(for field: SetField) -> String {
        switch field {
        case .reps: return "reps"
        case .weight: return live.unit.rawValue
        case .seconds: return "sec"
        case .meters: return "m"
        case .rpe: return "RPE"
        }
    }

    private func step(_ field: SetField, by steps: Int) {
        let size: Double
        switch field {
        case .weight: size = live.unit.toKilograms(live.unit.increment)
        case .seconds: size = 5
        case .meters: size = 50
        default: size = 1
        }
        let current = set.value(field, inSession: true) ?? 0
        live.updateSet(set.id) { $0.setValue(field, max(0, current + Double(steps) * size), inSession: true) }
    }
}

struct ValueTile: View {
    let text: String
    let caption: String
    let onTap: () -> Void
    let onStep: (Int) -> Void

    @State private var applied = 0
    @State private var dragging = false

    var body: some View {
        VStack(spacing: 2) {
            Text(text)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 8, weight: .bold))
                Text(caption)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(dragging ? 0.1 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(dragging ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    dragging = true
                    let steps = Int((value.translation.width / 22).rounded(.towardZero))
                    if steps != applied {
                        onStep(steps - applied)
                        applied = steps
                        Haptics.tap()
                    }
                }
                .onEnded { _ in
                    applied = 0
                    dragging = false
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Tap to type, drag sideways to change")
    }
}

// MARK: - Supersets

/// A superset/circuit as one board: exercises side by side, one row per round.
struct SupersetCard: View {
    let block: WorkoutBlock
    let letter: String

    @Environment(LiveWorkoutController.self) private var live
    @Environment(ExerciseLibrary.self) private var library
    @Environment(\.liveActions) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(block.items.enumerated()), id: \.element.id) { index, item in
                    VStack(spacing: 6) {
                        ExerciseThumb(urls: library.imageURLs(for: item), symbol: (item.kind ?? .gym).symbol, tint: .accentColor, size: 56)
                        Text("\(letter)\(index + 1)")
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(.white)
                            .background(Color.accentColor, in: Capsule())
                        Text(item.name)
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<block.maxSetCount, id: \.self) { round in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Round \(round + 1)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        ForEach(block.items) { item in
                            if item.sets.indices.contains(round) {
                                SupersetCell(item: item, set: item.sets[round], isCurrent: item.sets[round].id == live.currentSet?.id)
                            } else {
                                Text("—")
                                    .frame(maxWidth: .infinity, minHeight: 56)
                                    .foregroundStyle(.tertiary)
                                    .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                    }
                }
            }
            if let current = currentItemInBlock, let set = live.currentSet {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Now: \(current.name)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    ValueTiles(item: current, set: set)
                }
            }
            HStack {
                ForEach(block.items) { item in
                    Button {
                        live.edit { $0.addSet(to: item.id) }
                    } label: {
                        Label("Set", systemImage: "plus")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .padding(.top, 10)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: block.style.symbol)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(block.style.displayName) \(letter)")
                    .font(.title2.weight(.bold))
                Text(roundText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if block.setCountsDiffer {
                Button {
                    withAnimation(.snappy) { live.edit { $0.matchSetCounts(blockID: block.id) } }
                    Haptics.success()
                } label: {
                    Label("Match sets", systemImage: "equal.square")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glassProminent)
            }
        }
    }

    private var roundText: String {
        let done = block.items.map(\.completedSets).min() ?? 0
        let total = block.maxSetCount
        if block.setCountsDiffer {
            return block.items.map { "\($0.sets.count)" }.joined(separator: " · ") + " sets – tap Match sets to even them out"
        }
        return done >= total ? "All \(total) rounds done" : "Round \(done + 1) of \(total)"
    }

    private var currentItemInBlock: WorkoutItem? {
        guard let current = live.currentItem, block.items.contains(where: { $0.id == current.id }) else { return nil }
        return current
    }
}

struct SupersetCell: View {
    let item: WorkoutItem
    let set: WorkoutSet
    let isCurrent: Bool
    @Environment(LiveWorkoutController.self) private var live
    @Environment(\.liveActions) private var actions

    var body: some View {
        HStack(spacing: 6) {
            Text(set.label(mode: item.mode, unit: live.unit))
                .font(.subheadline.weight(isCurrent ? .bold : .medium))
                .monospacedDigit()
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .foregroundStyle(set.isDone || isCurrent ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { actions.editValue(set.id, item.id, item.mode == .reps ? .reps : (item.mode == .time ? .seconds : .meters)) }
            Button {
                live.toggleSet(set.id)
            } label: {
                Image(systemName: set.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 28))
                    .foregroundStyle(set.isDone || isCurrent ? Color.accentColor : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(set.isDone ? "Mark not done" : "Mark done")
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(set.isDone ? Color.accentColor.opacity(0.1) : (isCurrent ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isCurrent && !set.isDone ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .onLongPressGesture(minimumDuration: 0.35) {
            actions.editSet(set.id, item.id)
        }
        .animation(.snappy, value: set.isDone)
    }
}

// MARK: - Strip, rest, timer

/// Every exercise as a chip with its progress – tap to jump.
struct ExerciseStrip: View {
    @Environment(LiveWorkoutController.self) private var live

    var body: some View {
        let items = live.content.allItems
        let focused = live.focusedItem?.id
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let isFocused = item.id == focused
                        Button {
                            withAnimation(.snappy) { live.focus(itemID: item.id) }
                            Haptics.tap()
                        } label: {
                            HStack(spacing: 5) {
                                ZStack {
                                    Circle().fill(item.isComplete ? Color.accentColor : Color.secondary.opacity(0.18))
                                    if item.isComplete {
                                        Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                                    } else {
                                        Text("\(index + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 16, height: 16)
                                Text(item.name)
                                    .font(.caption.weight(isFocused ? .semibold : .regular))
                                    .lineLimit(1)
                                Text("\(item.completedSets)/\(item.sets.count)")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: 190)
                            .background(Capsule().fill(isFocused ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08)))
                            .overlay(Capsule().strokeBorder(isFocused ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: focused) { _, id in
                guard let id else { return }
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

/// Full editor over the running workout.
struct LiveEditSheet: View {
    @Environment(LiveWorkoutController.self) private var live
    @Environment(\.dismiss) private var dismiss
    @State private var editor = EditorState()

    var body: some View {
        let binding = Binding(get: { live.content }, set: { live.replaceContent($0) })
        NavigationStack {
            List {
                WorkoutEditorSections(
                    content: binding,
                    mode: .session(isLive: true),
                    defaultKind: live.session?.kind ?? .gym,
                    onToggleSet: { (setID: UUID) in live.toggleSet(setID) },
                    state: editor
                )
            }
            .groupedList()
            .workoutEditorSheets(content: binding, mode: .session(isLive: true), defaultKind: live.session?.kind ?? .gym, state: editor)
            .navigationTitle("Edit Workout")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
