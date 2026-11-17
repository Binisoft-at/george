import SwiftUI
import SwiftData
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
    @State private var dropRequest: DropWeightRequest?
    @State private var swapItem: URLItemID?
    @State private var showCoachSettings = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var showReorder = false
    @State private var history: ExerciseHistoryRequest?

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
            tutorial: { tutorial = $0 },
            dropWeight: { setID, itemID in dropRequest = DropWeightRequest(setID: setID, itemID: itemID) },
            swap: { itemID in swapItem = URLItemID(id: itemID) },
            history: { key, name in history = ExerciseHistoryRequest(exerciseKey: key, name: name) }
        ))
        .onChange(of: live.requestAddExercise) { _, requested in
            guard requested else { return }
            live.requestAddExercise = false
            showAdd = true
        }
        .onChange(of: live.finishRequest) { _, requested in
            guard requested else { return }
            live.finishRequest = false
            showFinish = true
        }
        .sheet(isPresented: $showCoachSettings) {
            CoachSettingsSheet()
        }
        .sheet(isPresented: $showReorder) {
            ReorderBlocksSheet(content: Binding(get: { live.content }, set: { live.replaceContent($0) }))
        }
        .sheet(item: $history) { request in
            ExerciseHistorySheet(exerciseKey: request.exerciseKey, name: request.name)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: live.demoSheetRequest) { _, request in
            guard let request, let item = live.currentItem, let set = live.currentSet else { return }
            live.demoSheetRequest = nil
            if request == "drop" { dropRequest = DropWeightRequest(setID: set.id, itemID: item.id) }
            if request == "swap" { swapItem = URLItemID(id: item.id) }
        }
        .sheet(item: $dropRequest) { request in
            DropWeightSheet(request: request)
                .presentationDetents([.fraction(0.8), .large])
        }
        .sheet(item: $swapItem) { wrapper in
            LiveSwapSheet(itemID: wrapper.id)
                .presentationDetents([.medium, .large])
        }
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
                if let first = items.first { live.view(itemID: first.id) }
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
        .onChange(of: live.discardRequest) { _, requested in
            guard requested else { return }
            live.discardRequest = false
            confirmDiscard = true
        }
        .background {
            // Keyboard: ←/→ look at the previous/next exercise, ⌥←/⌥→ move the plan's thread.
            Group {
                Button("") { move(by: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { move(by: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { live.moveThread(by: -1) }.keyboardShortcut(.leftArrow, modifiers: .option)
                Button("") { live.moveThread(by: 1) }.keyboardShortcut(.rightArrow, modifiers: .option)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
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
            if !live.content.isEmpty {
                MomentumHeader(motivation: motivation) { showFinish = true }
            }
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
            Button { showReorder = true } label: { Label("Reorder Exercises", systemImage: "arrow.up.arrow.down") }
            if let item = live.currentItem, canAddWarmups(item) {
                Button { live.addWarmups(to: item.id) } label: { Label("Add Warm-up Sets", systemImage: "flame") }
            }
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
                Label("Today's Energy", systemImage: "gauge.with.dots.needle.33percent")
            }
            Button { live.togglePause() } label: {
                Label(live.isPaused ? "Resume" : "Pause", systemImage: live.isPaused ? "play" : "pause")
            }
            Button { live.toggleVoiceMute() } label: {
                Label(live.isVoiceMuted ? "Unmute Voice" : "Mute Voice", systemImage: live.isVoiceMuted ? "speaker.wave.2" : "speaker.slash")
            }
            Button { live.showPanel = true } label: { Label("Pace & Controls", systemImage: "rectangle.expand.vertical") }
            Button { showCoachSettings = true } label: { Label("Coach Settings…", systemImage: "slider.horizontal.3") }
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
        if blocks.isEmpty {
            EmptyLiveWorkout(onAdd: { showAdd = true })
        } else {
            pages(blocks)
        }
    }

    @ViewBuilder
    private func pages(_ blocks: [WorkoutBlock]) -> some View {
        #if os(iOS)
        if sizeClass == .regular {
            // iPad: the whole plan on the left, the exercise on the right – not a stretched phone.
            splitPager(blocks)
        } else {
            TabView(selection: blockSelection) {
                ForEach(blocks) { block in
                    ScrollViewReader { proxy in
                        ScrollView {
                            BlockPage(block: block, letter: groupLetter(for: block.id))
                                .padding(.horizontal)
                                .padding(.bottom, 24)
                        }
                        .scrollIndicators(.hidden)
                        .onAppear { scrollToCurrent(in: block, proxy: proxy, animated: false) }
                        .onChange(of: live.currentSet?.id) { _, _ in scrollToCurrent(in: block, proxy: proxy, animated: true) }
                    }
                    .tag(Optional(block.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.snappy, value: live.focusedItemID)
        }
        #else
        splitPager(blocks)
        #endif
    }

    /// Mac and iPad: the exercises as a list (what's due marked), the selected one next to it.
    private func splitPager(_ blocks: [WorkoutBlock]) -> some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { live.focusedItem?.id }, set: { if let id = $0 { live.view(itemID: id) } })) {
                ForEach(live.content.allItems) { item in
                    HStack {
                        Image(systemName: item.isComplete ? "checkmark.circle.fill" : (item.id == live.currentItem?.id ? "play.circle.fill" : "circle"))
                            .foregroundStyle(item.isComplete || item.id == live.currentItem?.id ? Color.accentColor : Color.secondary)
                        Text(item.name).lineLimit(1)
                        Spacer()
                        Text("\(item.completedSets)/\(item.sets.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(item.id)
                    .accessibilityLabel("\(item.name), \(item.completedSets) of \(item.sets.count)\(item.id == live.currentItem?.id ? ", due now" : "")")
                }
            }
            .frame(width: 250)
            ScrollViewReader { proxy in
                ScrollView {
                    if let block = focusedBlock {
                        BlockPage(block: block, letter: groupLetter(for: block.id))
                            .padding()
                            .frame(maxWidth: 640)
                            .frame(maxWidth: .infinity)
                            .onAppear { scrollToCurrent(in: block, proxy: proxy, animated: false) }
                            .onChange(of: live.currentSet?.id) { _, _ in scrollToCurrent(in: block, proxy: proxy, animated: true) }
                    }
                }
            }
        }
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
                // Swiping only looks – the plan decides what's due.
                if let target { live.view(itemID: target.id) }
            }
        )
    }

    private func groupLetter(for blockID: UUID) -> String {
        let grouped = live.content.blocks.filter { $0.style.isGrouped && $0.items.count > 1 }
        let index = grouped.firstIndex { $0.id == blockID } ?? 0
        return String(Character(UnicodeScalar(65 + (index % 26)) ?? "A"))
    }

    /// Keeps the set that's due in view (its numbers and the tick start below the top of the page).
    private func scrollToCurrent(in block: WorkoutBlock, proxy: ScrollViewProxy, animated: Bool) {
        guard let set = live.currentSet, block.items.contains(where: { $0.sets.contains { $0.id == set.id } }) else { return }
        let grouped = block.style.isGrouped && block.items.count > 1
        // After the layout settles (the picture shrinks after the first set, rows change height).
        DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.35 : 0.1)) {
            if grouped {
                if animated { withAnimation(.snappy) { proxy.scrollTo("now-\(block.id)", anchor: .center) } }
                else { proxy.scrollTo("now-\(block.id)", anchor: .center) }
            } else {
                if animated { withAnimation(.snappy) { proxy.scrollTo(set.id, anchor: .center) } }
                else { proxy.scrollTo(set.id, anchor: .center) }
            }
        }
    }

    /// Weighted rep exercises from 40 kg up get an "Add warm-up sets" offer (once, before the first set).
    private func canAddWarmups(_ item: WorkoutItem) -> Bool {
        item.mode == .reps && item.completedSets == 0 && !item.sets.contains { $0.kind == .warmup }
            && (item.sets.compactMap(\.effectiveWeight).max() ?? 0) >= 40
    }

    // MARK: Bottom

    @ViewBuilder
    private var bottomPanel: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 10) {
                if let notice = live.offPlanNotice {
                    OffPlanCard(notice: notice)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if live.isViewingElsewhere {
                    ViewingPill()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let request = live.effortRequest {
                    FeedbackCard(request: request)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let tick = live.undoableTick {
                    UndoTickPill(tick: tick)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                VoiceIntroBanner()
                CoachBar(onExpand: { live.showPanel = true }, onFinish: { showFinish = true })
                    .transition(.opacity)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .animation(.snappy, value: live.restEndsAt)
        .animation(.snappy, value: live.effortRequest)
        .animation(.snappy, value: live.undoableTick)
        .animation(.snappy, value: live.offPlanNotice)
        .animation(.snappy, value: live.isViewingElsewhere)
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
        withAnimation(.snappy) { live.view(itemID: item.id) }
        Haptics.tap()
    }
}

// MARK: - Actions handed down to rows

/// What rows can ask the live view to show (keypad, set editor, tutorial).
struct LiveActions {
    var editValue: (UUID, UUID, SetField) -> Void = { _, _, _ in }
    var editSet: (UUID, UUID) -> Void = { _, _ in }
    var tutorial: (URL) -> Void = { _ in }
    /// "Can't finish": lower the weight mid-set (set id, item id).
    var dropWeight: (UUID, UUID) -> Void = { _, _ in }
    /// "Not available": swap the exercise (item id).
    var swap: (UUID) -> Void = { _ in }
    /// History of an exercise (key, name) – the "Last:" line.
    var history: (String, String) -> Void = { _, _ in }
}

struct ExerciseHistoryRequest: Identifiable {
    var id: String { exerciseKey }
    let exerciseKey: String
    let name: String
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
        if block.style.isGrouped && block.items.count > 1 {
            SupersetCard(block: block, letter: letter)
        } else {
            VStack(spacing: 24) {
                ForEach(block.items) { item in
                    LiveExerciseCard(item: item)
                }
            }
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
    @Query private var userExercises: [UserExercise]

    /// The user's own notes and links for this exercise ("Seat 4, red band").
    private var userEntry: UserExercise? {
        let key = item.exerciseID ?? library.exercise(for: item)?.id
        guard let key else { return nil }
        return userExercises.first { $0.key == key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ExerciseAnimation(urls: library.imageURLs(for: item), symbol: (item.kind ?? .gym).symbol, tint: .accentColor)
                // Smaller once you know the movement – the sets matter more then.
                .frame(height: item.completedSets > 0 ? 96 : 150)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .onTapGesture(count: 2) {
                    // Only the exercise that's due is ticked by a double tap; elsewhere it brings you there.
                    if live.planPosition(of: item) == .now {
                        live.primaryAction()
                    } else {
                        live.returnToCurrent()
                    }
                }
                .animation(.snappy, value: item.completedSets > 0)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    PlanPositionChip(position: live.planPosition(of: item))
                    Spacer()
                    if !item.isComplete {
                        Button {
                            actions.swap(item.id)
                        } label: {
                            Label("Swap", systemImage: "arrow.triangle.swap")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.glass)
                        .accessibilityHint("Pick another exercise for the same muscles")
                        .popoverTip(GeorgeTips.SwapTip())
                    }
                }
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
                if let setup = userEntry?.notes, !setup.isEmpty, setup != item.notes {
                    Label(setup, systemImage: "wrench.adjustable")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Your setup: \(setup)")
                }
            }

            StationChips(item: item)

            ProgressionChip(item: item)

            TipView(GeorgeTips.LiveSetTip())

            VStack(spacing: 8) {
                ForEach(item.sets) { set in
                    LiveSetRow(item: item, set: set, previous: previous(for: set), isCurrent: set.id == live.currentSet?.id)
                        .id(set.id)
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

            TutorialRow(item: item, userLinks: userEntry?.links ?? [])
        }
        .padding(.top, 10)
    }

    private func previous(for set: WorkoutSet) -> WorkoutSet? {
        LastTime.matching(set, in: item, previous: PreviousPerformanceCache.shared.sets(for: item.exerciseKey, store: store))
    }
}

/// Watch a tutorial / how-to steps.
struct TutorialRow: View {
    let item: WorkoutItem
    var userLinks: [String] = []
    @Environment(LiveWorkoutController.self) private var live
    @Environment(ExerciseLibrary.self) private var library
    @Environment(\.liveActions) private var actions

    /// The exercise's own link, else the one saved in the library for this exercise.
    private var link: String? { item.links.first ?? userLinks.first }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if let link, let url = URL(string: link) {
                    actions.tutorial(url)
                } else if let url = TutorialLinks.youtubeSearch(for: item.name, kind: item.kind ?? live.session?.kind) {
                    actions.tutorial(url)
                }
            } label: {
                Label(link == nil ? "Find Tutorial" : "Watch Tutorial", systemImage: "play.rectangle.fill")
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
    @Environment(MuscleAnalytics.self) private var analytics
    /// This week's muscular load for the exercise's muscles (the advice holds back when it's high).
    @State private var loadStatus: LoadStatus?

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
            .task(id: item.id) { loadStatus = currentLoadStatus() }
        }
    }

    private var suggestion: ProgressionSuggestion? {
        let last = PreviousPerformanceCache.shared.sets(for: item.exerciseKey, store: store)
        let plan = item.sets.first { !$0.isDone && $0.kind != .warmup }
        return ProgressionAdvisor.suggest(lastSets: last, mode: item.mode, plan: plan, incrementKg: live.unit.toKilograms(live.unit.increment),
                                          intensity: live.intensity, loadStatus: loadStatus)
    }

    /// The highest load status among the exercise's main muscles.
    private func currentLoadStatus() -> LoadStatus? {
        let order: [LoadStatus] = [.calibrating, .detraining, .peaking, .maintaining, .productive, .fatigued, .overtraining]
        let groups = analytics.contributions(for: item).filter { $0.weight >= 1 }.map(\.group)
        let statuses = groups.map { analytics.engine.loadSummary(group: $0, days: 1).current.status }
        return statuses.max { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
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
                        Button {
                            actions.history(item.exerciseKey, item.name)
                        } label: {
                            Label("Last: \(previous.label(mode: item.mode, unit: live.unit))", systemImage: "chart.line.uptrend.xyaxis")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows this exercise's history")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { actions.editValue(set.id, item.id, primaryField) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { actions.editValue(set.id, item.id, primaryField) }
                Spacer(minLength: 4)
                CheckButton(isDone: set.isDone, isCurrent: isCurrent, burst: (MotivationStyle(rawValue: motivationRaw) ?? .full) == .full,
                            label: "\(item.name), set \(item.displayIndex(of: set)) of \(item.sets.count), \(set.label(mode: item.mode, unit: live.unit))") {
                    live.toggleSet(set.id)
                }
            }
            if isCurrent && !set.isDone {
                if item.mode == .time {
                    TimedSetDial(item: item, set: set)
                }
                ValueTiles(item: item, set: set)
                if let plates = plateText {
                    Label(plates, systemImage: "circle.grid.2x1")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Plates: \(plates)")
                }
                // While the set is being done (or always, without the Start button).
                if (set.effectiveWeight ?? 0) > 0, live.phase == .working || !CoachPrefs.startButton {
                    Button {
                        actions.dropWeight(set.id, item.id)
                    } label: {
                        Label("Can't finish? Lower the weight", systemImage: "arrow.down.circle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.glass)
                    .tint(.orange)
                    .popoverTip(GeorgeTips.LowerWeightTip())
                }
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
        .contextMenu {
            Button { actions.editSet(set.id, item.id) } label: { Label("Edit Set…", systemImage: "slider.horizontal.3") }
            if !set.isDone && !isCurrent {
                Button { live.makeCurrent(setID: set.id) } label: { Label("Do This Set Now", systemImage: "play.circle") }
            }
            if !item.isComplete {
                Button { actions.swap(item.id) } label: { Label("Swap Exercise…", systemImage: "arrow.triangle.swap") }
            }
        }
        .animation(.snappy, value: set.isDone)
        .animation(.snappy, value: isCurrent)
    }

    private var rowFill: Color {
        if set.isDone { return Color.accentColor.opacity(0.08) }
        if isCurrent { return Color.accentColor.opacity(0.16) }
        return Color.secondary.opacity(0.06)
    }

    /// "20 + 15 per side" for barbell lifts.
    private var plateText: String? {
        guard item.mode == .reps, let weight = set.effectiveWeight, weight > CoachPrefs.barKg,
              (item.equipment ?? "").lowercased().contains("barbell") || item.name.lowercased().contains("barbell") else { return nil }
        return PlateMath.text(totalKg: weight, barKg: CoachPrefs.barKg, plates: PlateSet.current.platesKg, unit: live.unit)
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
    /// "Bench Press, set 2 of 4, 8 × 60 kg" for VoiceOver.
    var label: String = ""
    let action: () -> Void

    @State private var burstTrigger = 0
    @ScaledMetric(relativeTo: .title) private var currentSize: CGFloat = 44
    @ScaledMetric(relativeTo: .title) private var openSize: CGFloat = 34
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            if !isDone { burstTrigger += 1 }
            action()
        } label: {
            Group {
                if isDone {
                    // White check on the accent disc in light and dark mode alike.
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary.opacity(0.5))
                }
            }
                .font(.system(size: isCurrent ? currentSize : openSize))
                .contentTransition(.symbolEffect(.replace))
                .frame(minWidth: 52, minHeight: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            if burst && !reduceMotion {
                BurstView(trigger: burstTrigger)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(label.isEmpty ? "Set" : label)
        .accessibilityValue(isDone ? "Done" : (isCurrent ? "Due now" : "Open"))
        .accessibilityHint(isDone ? "Double-tap to mark not done" : "Double-tap to mark done")
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
                    accessibilityName: accessibilityName(for: field),
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

    private func accessibilityName(for field: SetField) -> String {
        switch field {
        case .reps: return "Reps"
        case .weight: return "Weight in \(live.unit == .kg ? "kilograms" : "pounds")"
        case .seconds: return "Seconds"
        case .meters: return "Meters"
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
        // Computed from the stored set, so quick taps add up instead of overwriting each other.
        live.updateSet(set.id) { stored in
            let current = stored.value(field, inSession: true) ?? 0
            stored.setValue(field, max(0, current + Double(steps) * size), inSession: true)
        }
    }
}

/// One number of the current set: − and + step it (sweaty hands, no drag that fights the page
/// swipe), a tap on the number opens the keypad.
struct ValueTile: View {
    let text: String
    let caption: String
    var accessibilityName: String = ""
    let onTap: () -> Void
    let onStep: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            stepButton(-1, symbol: "minus")
            Button(action: onTap) {
                VStack(spacing: 0) {
                    Text(text)
                        .font(.largeTitle.weight(.bold))
                        .fontDesign(.rounded)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            stepButton(1, symbol: "plus")
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName.isEmpty ? caption : accessibilityName)
        .accessibilityValue(text)
        .accessibilityHint("Swipe up or down to change, double-tap to type")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onStep(1)
            case .decrement: onStep(-1)
            @unknown default: break
            }
        }
    }

    private func stepButton(_ steps: Int, symbol: String) -> some View {
        Button {
            onStep(steps)
            Haptics.tap()
        } label: {
            Image(systemName: symbol)
                .font(.headline.weight(.bold))
                .frame(width: 44, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .buttonRepeatBehavior(.enabled)
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
                            .contextMenu {
                                if !item.isComplete {
                                    Button { actions.swap(item.id) } label: { Label("Swap Exercise…", systemImage: "arrow.triangle.swap") }
                                }
                            }
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
            ForEach(Array(rounds.enumerated()), id: \.offset) { round, slots in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Round \(round + 1)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        ForEach(block.items) { item in
                            let cells = slots.filter { block.items.indices.contains($0.itemIndex) && block.items[$0.itemIndex].id == item.id }
                            if cells.isEmpty {
                                Text("—")
                                    .frame(maxWidth: .infinity, minHeight: 56)
                                    .foregroundStyle(.tertiary)
                                    .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            } else {
                                VStack(spacing: 4) {
                                    ForEach(cells, id: \.setIndex) { slot in
                                        let set = item.sets[slot.setIndex]
                                        SupersetCell(item: item, set: set, isCurrent: set.id == live.currentSet?.id)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    // What's due is edited right under its round, not at the bottom of the board.
                    if slots.contains(where: { slot in block.items.indices.contains(slot.itemIndex) && block.items[slot.itemIndex].sets[slot.setIndex].id == live.currentSet?.id }),
                       let current = currentItemInBlock, let set = live.currentSet {
                        nowTiles(current, set)
                    }
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

    /// Rounds as the plan runs them (drop sets with their set, a swapped exercise continuing its round).
    private var rounds: [[WorkoutContent.RoundSlot]] {
        guard let index = live.content.blocks.firstIndex(where: { $0.id == block.id }) else { return [] }
        return live.content.roundGrid(ofBlock: index)
    }

    private func nowTiles(_ current: WorkoutItem, _ set: WorkoutSet) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Now: \(current.name)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            ValueTiles(item: current, set: set)
            if (set.effectiveWeight ?? 0) > 0, live.phase == .working || !CoachPrefs.startButton {
                Button {
                    actions.dropWeight(set.id, current.id)
                } label: {
                    Label("Can't finish? Lower the weight", systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glass)
                .tint(.orange)
                .popoverTip(GeorgeTips.LowerWeightTip())
            }
        }
        .padding(.top, 4)
        .id("now-\(block.id)")
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
                    .font(.title)
                    .foregroundStyle(set.isDone || isCurrent ? Color.accentColor : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.name), \(set.kind == .drop ? "drop set" : "set \(item.displayIndex(of: set))"), \(set.label(mode: item.mode, unit: live.unit))")
            .accessibilityValue(set.isDone ? "Done" : (isCurrent ? "Due now" : "Open"))
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

/// Every exercise as a chip with its progress – tap to look. The exercise that's due carries a
/// filled marker, the one you're looking at a highlight.
struct ExerciseStrip: View {
    @Environment(LiveWorkoutController.self) private var live

    var body: some View {
        let items = live.content.allItems
        let focused = live.focusedItem?.id
        let due = live.currentItem?.id
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let isFocused = item.id == focused
                        let isDue = item.id == due
                        Button {
                            withAnimation(.snappy) { live.view(itemID: item.id) }
                            Haptics.tap()
                        } label: {
                            HStack(spacing: 6) {
                                ZStack {
                                    Circle().fill(item.isComplete || isDue ? Color.accentColor : Color.secondary.opacity(0.18))
                                    if item.isComplete {
                                        Image(systemName: "checkmark").font(.caption2.weight(.heavy)).foregroundStyle(.white)
                                    } else if isDue {
                                        Image(systemName: "play.fill").font(.caption2.weight(.heavy)).foregroundStyle(.white)
                                    } else {
                                        Text("\(index + 1)").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 22, height: 22)
                                Text(item.name)
                                    .font(.caption.weight(isFocused || isDue ? .semibold : .regular))
                                    .lineLimit(1)
                                Text("\(item.completedSets)/\(item.sets.count)")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: 44)
                            .frame(maxWidth: 200)
                            .background(Capsule().fill(isFocused ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08)))
                            .overlay(Capsule().strokeBorder(isFocused || isDue ? Color.accentColor.opacity(isDue ? 1 : 0.6) : Color.clear, lineWidth: isDue ? 1.5 : 1))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.name), \(item.completedSets) of \(item.sets.count) sets\(isDue ? ", due now" : "")\(item.isComplete ? ", done" : "")")
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

/// Small helpers at the station: warm-up sets before heavy lifts, the band in use.
struct StationChips: View {
    let item: WorkoutItem
    @Environment(LiveWorkoutController.self) private var live

    var body: some View {
        let warmups = canAddWarmups
        let band = isBand
        if warmups || band {
            HStack(spacing: 8) {
                if warmups {
                    Button {
                        live.addWarmups(to: item.id)
                    } label: {
                        Label("Add warm-up sets", systemImage: "flame")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .accessibilityHint("Empty bar, then 50, 70 and 85 percent of your top weight")
                }
                if band {
                    Menu {
                        ForEach(["Yellow", "Red", "Green", "Blue", "Black", "Purple", "Orange"], id: \.self) { color in
                            Button(color) { setBand(color.lowercased() + " band") }
                        }
                        Button("No band") { setBand(nil) }
                    } label: {
                        Label("Band: \(currentBand ?? "choose")", systemImage: "circle.dashed")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .accessibilityHint("Changes the band for the open sets")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var canAddWarmups: Bool {
        item.mode == .reps && item.completedSets == 0 && !item.sets.contains { $0.kind == .warmup }
            && (item.sets.compactMap(\.effectiveWeight).max() ?? 0) >= 40
    }

    private var isBand: Bool {
        item.kind == .band || (item.equipment ?? "").lowercased().contains("band") || item.sets.contains { ($0.targetLoad ?? "").lowercased().contains("band") }
    }

    private var currentBand: String? {
        (item.sets.first { !$0.isDone } ?? item.sets.last)?.targetLoad
    }

    private func setBand(_ band: String?) {
        live.edit { content in
            for set in item.sets where !set.isDone {
                content.updateSet(id: set.id) { $0.targetLoad = band }
            }
        }
        Haptics.tap()
    }
}

/// "Bench Press · set 2 of 4 done · Undo" for a few seconds after each tick.
struct UndoTickPill: View {
    let tick: LiveWorkoutController.UndoableTick
    @Environment(LiveWorkoutController.self) private var live

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text(tick.text)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Button("Undo") { live.undoLastTick() }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.glass)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Once, in the first live workout: the voice coach speaks out loud – keep it, headphones only, or off.
struct VoiceIntroBanner: View {
    @AppStorage(Prefs.voiceBannerSeen) private var seen = false
    @AppStorage(Prefs.voiceCoach) private var voiceOn = true
    @AppStorage(Prefs.voiceRoute) private var route = VoiceRoute.everywhere.rawValue

    var body: some View {
        if !seen && voiceOn && !LaunchOptions.current.isDemo {
            VStack(alignment: .leading, spacing: 8) {
                Label("The voice coach speaks out loud – also on the phone's speaker.", systemImage: "speaker.wave.2.fill")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 8) {
                    Button("Keep") { seen = true }
                        .buttonStyle(.glassProminent)
                    Button("Headphones only") {
                        route = VoiceRoute.headphones.rawValue
                        seen = true
                    }
                    .buttonStyle(.glass)
                    Button("Off") {
                        voiceOn = false
                        seen = true
                    }
                    .buttonStyle(.glass)
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

/// Full editor over the running workout.
struct LiveEditSheet: View {
    @Environment(LiveWorkoutController.self) private var live
    @Environment(\.dismiss) private var dismiss
    @State private var editor = EditorState()
    @State private var showReorder = false

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
                ToolbarItem(placement: .primaryAction) {
                    Button { showReorder = true } label: { Label("Reorder", systemImage: "arrow.up.arrow.down") }
                }
            }
            .sheet(isPresented: $showReorder) {
                ReorderBlocksSheet(content: binding)
            }
        }
    }
}

/// Identifiable wrapper for a sheet keyed by an exercise id.
struct URLItemID: Identifiable {
    let id: UUID
}

/// An empty workout (started without a template, a tennis match, a run): add exercises, take a
/// ready-made routine's moves, or just let the clock run and finish.
struct EmptyLiveWorkout: View {
    let onAdd: () -> Void
    @Environment(LiveWorkoutController.self) private var live
    @Environment(ExerciseLibrary.self) private var library

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("What are you doing today?")
                    .font(.title2.weight(.bold))
                Button(action: onAdd) {
                    row("plus.circle.fill", "Add exercises", "From the library or your own")
                }
                .buttonStyle(.plain)
                Menu {
                    ForEach(RoutineLibrary.all) { routine in
                        Button {
                            let moves = routine.content(using: library.catalog)
                            live.edit { $0.append(items: moves.allItems, asGroup: false) }
                        } label: {
                            Label(routine.name, systemImage: routine.symbol)
                        }
                    }
                } label: {
                    row("figure.yoga", "Use a stretch or yoga routine", "Its moves come into this workout")
                }
                .buttonStyle(.plain)
                row("stopwatch", "Just track the time", "Tennis, a run, a class: the clock runs – tap Finish when you're done")
            }
            .padding()
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
