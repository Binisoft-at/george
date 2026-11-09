import SwiftUI
import BinisoftKit
import GeorgeCore

/// Welcome & setup: what George does and how — each page has a small demo to try — then the weekly
/// goal, units and how to start. Shown on first launch and from Settings → Help. It ends by offering
/// the hands-on tour (BinisoftKit tour engine, `TourView`).
struct WelcomeView: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(HealthKitManager.self) private var health
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.didOnboard) private var didOnboard = false
    @AppStorage(Prefs.welcomeVersion) private var welcomeVersion = 0
    @AppStorage(Prefs.healthAsked) private var healthAsked = false
    @State private var page: TutorialPage = .welcome
    @State private var goal = 3
    @State private var unit: WeightUnit = .kg

    var body: some View {
        ZStack {
            BrandBackdrop()
            VStack(spacing: 0) {
                topBar
                pager
                bottomBar
            }
        }
        .onAppear {
            goal = store.settings.weeklyGoal
            unit = store.settings.unit
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                ForEach(TutorialPage.allCases) { item in
                    Capsule()
                        .fill(item.rawValue <= page.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: item == page ? 22 : 8, height: 8)
                        .onTapGesture { withAnimation(.snappy) { page = item } }
                }
            }
            .animation(.snappy, value: page)
            Spacer()
            if page != .setup {
                Button("Skip") { withAnimation(.snappy) { page = .setup } }
                    .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .frame(height: 56)
    }

    @ViewBuilder
    private var pager: some View {
        #if os(iOS)
        TabView(selection: $page) {
            ForEach(TutorialPage.allCases) { item in
                ScrollView {
                    pageView(item)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .tag(item)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        #else
        ScrollView {
            pageView(page)
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .id(page)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
        }
        #endif
    }

    @ViewBuilder
    private var bottomBar: some View {
        if page != .setup {
            HStack(spacing: 12) {
                if page != .welcome {
                    Button {
                        go(-1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Back")
                }
                Button {
                    go(1)
                } label: {
                    Text(page == .welcome ? "Show me around" : "Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
            .frame(maxWidth: 560)
        }
    }

    private func go(_ delta: Int) {
        let next = TutorialPage(rawValue: page.rawValue + delta) ?? page
        withAnimation(.snappy) { page = next }
        Haptics.tap()
    }

    // MARK: Pages

    @ViewBuilder
    private func pageView(_ item: TutorialPage) -> some View {
        switch item {
        case .welcome:
            TutorialPageLayout(
                title: "Meet George",
                message: "Your gym buddy. Plans like Notes, trains like a coach — on iPhone, Apple Watch and Mac.",
                hint: nil
            ) {
                WelcomeDemo()
            }
        case .plan:
            TutorialPageLayout(
                title: "Plan with templates",
                message: "A program is a folder of templates — reusable workouts like UPPER or LOWER. Start one and George creates today's workout and names it for you.",
                hint: "Try it: tap a template"
            ) {
                PlanDemo()
            }
        case .train:
            TutorialPageLayout(
                title: "Train in live mode",
                message: "Big check-offs, a rest timer that starts by itself, last time's numbers and a big keypad (or drag) for reps and weight. A voice coach and a momentum flame keep you moving; your Apple Watch follows along.",
                hint: "Try it: tick off the sets"
            ) {
                TrainDemo()
            }
        case .adapt:
            TutorialPageLayout(
                title: "Change anything, anytime",
                message: "Machine taken? Swap the exercise. Feeling strong? Add a set. Build supersets, reorder or skip — even mid-workout — and save the changes back to the template.",
                hint: "Try it: Swap, + Set, Superset"
            ) {
                AdaptDemo()
            }
        case .streak:
            TutorialPageLayout(
                title: "Streaks that forgive",
                message: "Set a weekly goal, not a daily one. Every two successful weeks earn a save that protects your streak — or rescue a week with a quick 10-minute session.",
                hint: "Try it: tap the days"
            ) {
                StreakDemo()
            }
        case .muscles:
            TutorialPageLayout(
                title: "Know your muscles",
                message: "From the sets you log, George shows how recovered each muscle is, your sets per week and your muscular load — and warns you before you train a tired muscle.",
                hint: "Try it: tap a muscle"
            ) {
                MusclesDemo()
            }
        case .everywhere:
            TutorialPageLayout(
                title: "Yours, everywhere",
                message: "Your data syncs through your own iCloud — no account, no George servers. Workouts and calories go to Apple Health, and the Watch shows your sets and heart rate.",
                hint: nil
            ) {
                EverywhereDemo(healthAvailable: health.isAvailable, healthConnected: healthAsked) {
                    Task {
                        await health.requestAuthorization()
                        healthAsked = true
                    }
                }
            }
        case .setup:
            setupPage
        }
    }

    private var setupPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Let's set you up")
                    .font(.largeTitle.weight(.bold))
                Text("You can change all of this later in Settings.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Workout days per week", systemImage: "flame.fill")
                    .font(.headline)
                HStack(spacing: 8) {
                    ForEach(1...7, id: \.self) { day in
                        Button {
                            goal = day
                            Haptics.tap()
                        } label: {
                            Text("\(day)")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .foregroundStyle(goal == day ? Color.white : Color.primary)
                                .background(Circle().fill(goal == day ? Color.accentColor : Color.secondary.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(goalHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .card(padding: 0, cornerRadius: 22)

            VStack(alignment: .leading, spacing: 10) {
                Label("Weights in", systemImage: "scalemass.fill")
                    .font(.headline)
                Picker("Units", selection: $unit) {
                    Text("Kilograms").tag(WeightUnit.kg)
                    Text("Pounds").tag(WeightUnit.lb)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(16)
            .card(padding: 0, cornerRadius: 22)

            if store.fetchPrograms().isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("How do you want to start?", systemImage: "sparkles")
                        .font(.headline)
                    StartOption(title: "Try the sample program", subtitle: "Ready-made templates to explore", symbol: "wand.and.stars", isPrimary: true) {
                        store.loadSampleProgram()
                        finish { router.startTour() }
                    }
                    StartOption(title: "Import a plan (CSV)", subtitle: "From a spreadsheet — or ask an AI to write one", symbol: "square.and.arrow.down", isPrimary: false) {
                        finish { router.showImport = true }
                    }
                    StartOption(title: "Start from scratch", subtitle: "Create your first program and template", symbol: "plus", isPrimary: false) {
                        finish { router.showNewProgram = true }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Button {
                        finish { router.startTour() }
                    } label: {
                        Label("Take the 2-minute tour", systemImage: "graduationcap")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .primaryActionStyle()
                    .keyboardShortcut(.defaultAction)
                    Button("Not now") {
                        TourSchedule().markSeen(GeorgeTour.catalog)
                        finish()
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.top, 8)
    }

    private var goalHint: String {
        switch goal {
        case 1: return "A gentle start — one good session a week keeps the streak alive."
        case 2...3: return "A solid, sustainable rhythm for most people."
        case 4...5: return "Ambitious — rest days still count as part of the plan."
        default: return "Almost daily. Mix in mobility and easy days."
        }
    }

    private func finish(then action: (@MainActor () -> Void)? = nil) {
        let settings = store.settings
        if settings.goalHistory.isEmpty {
            settings.weeklyGoal = goal
            settings.goalHistory = [GoalChange(effectiveFrom: .distantPast, daysPerWeek: goal)]
        } else if settings.weeklyGoal != goal {
            settings.setWeeklyGoal(goal, calendar: store.calendar)
        }
        if settings.unit != unit { settings.unit = unit }
        store.save()
        didOnboard = true
        welcomeVersion = Prefs.currentWelcomeVersion
        Haptics.success()
        dismiss()
        if let action { router.afterDismiss(action) }
    }
}

enum TutorialPage: Int, CaseIterable, Identifiable {
    case welcome, plan, train, adapt, streak, muscles, everywhere, setup
    var id: Int { rawValue }
}

/// Demo on top, title and text below, optional "try it" hint.
private struct TutorialPageLayout<Demo: View>: View {
    let title: String
    let message: String
    let hint: String?
    @ViewBuilder let demo: () -> Demo

    var body: some View {
        VStack(spacing: 22) {
            demo()
                .frame(maxWidth: .infinity)
                .frame(minHeight: 280)
            VStack(spacing: 10) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint {
                    Label(hint, systemImage: "hand.tap.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 4)
                }
            }
        }
        .padding(.top, 8)
    }
}

private struct StartOption: View {
    let title: String
    let subtitle: String
    let symbol: String
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.headline)
                    .foregroundStyle(isPrimary ? Color.white : Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(isPrimary ? Color.accentColor : Color.accentColor.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card(padding: 0, cornerRadius: 20)
    }
}

// MARK: - Demos

private struct WelcomeDemo: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { ring in
                Circle()
                    .stroke(Color.accentColor.opacity(0.35 - Double(ring) * 0.1), lineWidth: 2)
                    .frame(width: 170 + CGFloat(ring) * 44, height: 170 + CGFloat(ring) * 44)
                    .scaleEffect(pulse ? 1.06 : 0.94)
                    .animation(.easeInOut(duration: 1.8).repeatForever().delay(Double(ring) * 0.25), value: pulse)
            }
            Image("GeorgeMark")
                .resizable()
                .scaledToFit()
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                .shadow(color: Color.accentColor.opacity(0.45), radius: 24, y: 8)
        }
        .frame(height: 300)
        .onAppear { pulse = true }
    }
}

private struct PlanDemo: View {
    @Environment(GeorgeStore.self) private var store
    @State private var started: String?

    private let templates: [(name: String, focus: String, symbol: String)] = [
        ("UPPER", "Chest, back, shoulders", "dumbbell.fill"),
        ("LOWER", "Legs and glutes", "figure.strengthtraining.traditional"),
        ("MOBILITY", "Hips, shoulders, wrists", "figure.cooldown"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text("PROGRAM").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Text("Gym – Strength Block").font(.headline)
                }
                Spacer()
            }
            ForEach(templates, id: \.name) { template in
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                        started = store.title(for: template.name, on: Date())
                    }
                    Haptics.success()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: template.symbol)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 34, height: 34)
                            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(template.name).font(.subheadline.weight(.semibold))
                            Text(template.focus).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            if let started {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Started").font(.caption).foregroundStyle(.secondary)
                        Text(started).font(.subheadline.weight(.semibold))
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(16)
        .card(padding: 0, cornerRadius: 26)
    }
}

private struct TrainDemo: View {
    @State private var done: [Bool] = [false, false, false]
    @State private var weights: [Double] = [60, 60, 60]
    @State private var restEndsAt: Date?

    private var current: Int? { done.firstIndex(of: false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bench Press").font(.title2.weight(.bold))
                    Text("3 × 8 · last time 57.5 kg").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "dumbbell.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            }
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.headline)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(done[index] ? Color.accentColor : Color.accentColor.opacity(0.15)))
                        .foregroundStyle(done[index] ? Color.white : Color.accentColor)
                    Text("8 × \(Format.number(weights[index])) kg")
                        .font(.headline)
                        .monospacedDigit()
                    Spacer()
                    if index == current {
                        HStack(spacing: 0) {
                            Button { weights[index] = max(0, weights[index] - 2.5) } label: { Image(systemName: "minus").frame(width: 30, height: 30) }
                            Button { weights[index] += 2.5 } label: { Image(systemName: "plus").frame(width: 30, height: 30) }
                        }
                        .buttonStyle(.plain)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                    Button {
                        withAnimation(.snappy) {
                            done[index].toggle()
                            restEndsAt = done[index] && done.contains(false) ? Date().addingTimeInterval(6) : nil
                        }
                        if done[index] { Haptics.success() }
                    } label: {
                        Image(systemName: done[index] ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 30))
                            .foregroundStyle(done[index] ? Color.accentColor : Color.secondary.opacity(0.6))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(index == current ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                )
            }
            if let restEndsAt {
                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    let remaining = max(0, restEndsAt.timeIntervalSince(context.date))
                    HStack(spacing: 12) {
                        ZStack {
                            ProgressRing(progress: remaining / 6, tint: .orange, lineWidth: 5)
                            Text("\(Int(remaining.rounded(.up)))").font(.headline.weight(.bold)).monospacedDigit()
                        }
                        .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Rest").font(.headline)
                            Text(remaining > 0 ? "Next: set \((current ?? 0) + 1)" : "Go!").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if current == nil {
                Label("Exercise done — on to the next one", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
        .padding(16)
        .card(padding: 0, cornerRadius: 26)
    }
}

private struct AdaptDemo: View {
    @State private var nameIndex = 0
    @State private var sets = 3
    @State private var superset = false

    private let names = ["Barbell Row", "Seated Cable Row", "Band Row", "Dumbbell Row"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                exerciseRow(name: names[nameIndex], detail: "\(sets) × 10", sets: sets)
                if superset {
                    exerciseRow(name: "Face Pull", detail: "\(sets) × 15", sets: sets)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(12)
            .overlay(alignment: .leading) {
                if superset {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .padding(.vertical, 12)
                }
            }
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if superset {
                Label("Superset A · \(sets) rounds", systemImage: "link")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy) { nameIndex = (nameIndex + 1) % names.count }
                    Haptics.tap()
                } label: {
                    Label("Swap", systemImage: "arrow.triangle.swap").frame(maxWidth: .infinity)
                }
                Button {
                    withAnimation(.snappy) { sets = sets >= 6 ? 3 : sets + 1 }
                    Haptics.tap()
                } label: {
                    Label("Set", systemImage: "plus").frame(maxWidth: .infinity)
                }
                Button {
                    withAnimation(.snappy) { superset.toggle() }
                    Haptics.tap()
                } label: {
                    Label(superset ? "Ungroup" : "Superset", systemImage: "link").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.glass)
            .font(.subheadline.weight(.semibold))
        }
        .padding(16)
        .card(padding: 0, cornerRadius: 26)
    }

    private func exerciseRow(name: String, detail: String, sets: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name)
                    .font(.headline)
                    .contentTransition(.opacity)
                    .id(name)
                    .transition(.push(from: .trailing))
                Spacer()
                Text(detail).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 6) {
                ForEach(0..<sets, id: \.self) { index in
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .frame(width: 24, height: 24)
                        .foregroundStyle(Color.accentColor)
                        .background(Circle().fill(Color.accentColor.opacity(0.15)))
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }
}

private struct StreakDemo: View {
    /// Two past weeks already reached the goal; the current week starts with one workout.
    @State private var thisWeek: Set<Int> = [0]
    private let goal = 3
    private let letters = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        let reached = thisWeek.count >= goal
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "flame.fill")
                    .font(.title)
                    .foregroundStyle(Color.orange.gradient)
                    .symbolEffect(.bounce, value: reached)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(reached ? 3 : 2) week streak")
                        .font(.title3.weight(.bold))
                        .contentTransition(.numericText())
                    Text(reached ? "Goal reached — streak extended!" : "\(goal - thisWeek.count) more this week")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { index in
                        Image(systemName: index < (reached ? 2 : 1) ? "shield.fill" : "shield")
                            .foregroundStyle(index < (reached ? 2 : 1) ? Color.cyan : Color.secondary.opacity(0.5))
                    }
                }
                .font(.subheadline)
            }
            weekRow(title: "2 weeks ago", days: [0, 2, 4], interactive: false)
            weekRow(title: "Last week", days: [1, 3, 5], interactive: false)
            weekRow(title: "This week", days: thisWeek, interactive: true)
            if reached {
                Label("Two good weeks in a row earn a save", systemImage: "shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.cyan)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(16)
        .card(padding: 0, cornerRadius: 26)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: thisWeek)
    }

    private func weekRow(title: String, days: Set<Int>, interactive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { day in
                    let isOn = days.contains(day)
                    VStack(spacing: 3) {
                        Text(letters[day]).font(.caption2).foregroundStyle(.secondary)
                        ZStack {
                            Circle().fill(isOn ? Color.orange : Color.secondary.opacity(0.15))
                            if isOn {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 24, height: 24)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard interactive else { return }
                        if thisWeek.contains(day) { thisWeek.remove(day) } else { thisWeek.insert(day) }
                        Haptics.tap()
                    }
                }
            }
            .opacity(interactive ? 1 : 0.75)
        }
    }
}

private struct MusclesDemo: View {
    @State private var selected: MuscleGroup? = .chest

    private let freshness: [MuscleGroup: Double] = [
        .chest: 0.45, .triceps: 0.55, .shoulders: 0.7, .quads: 0.92, .hamstrings: 0.85, .glutes: 0.88,
        .lats: 0.3, .biceps: 0.62, .upperBack: 0.5, .abs: 0.95, .calves: 1, .traps: 0.75,
    ]

    var body: some View {
        VStack(spacing: 12) {
            BodyMapPair(
                fill: { group in
                    guard let value = freshness[group] else { return MusclePalette.empty }
                    return status(value).color
                },
                selected: selected,
                onTap: { group in
                    withAnimation(.snappy) { selected = group }
                    Haptics.tap()
                },
                spacing: 16
            )
            .frame(height: 230)
            if let selected {
                let value = freshness[selected] ?? 1
                HStack {
                    Circle().fill(status(value).color).frame(width: 10, height: 10)
                    Text(selected.displayName).font(.headline)
                    Spacer()
                    Text("\(Int(value * 100)) % · \(status(value).displayName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(status(value).color)
                }
                .padding(.horizontal, 6)
                .contentTransition(.numericText())
            }
            HStack(spacing: 14) {
                legend(.recovered)
                legend(.fatigued)
                legend(.depleted)
            }
            .font(.caption)
        }
        .padding(16)
        .card(padding: 0, cornerRadius: 26)
    }

    private func status(_ value: Double) -> FreshnessStatus {
        if value >= MuscleEngine.recoveredThreshold { return .recovered }
        if value >= MuscleEngine.depletedThreshold { return .fatigued }
        return .depleted
    }

    private func legend(_ status: FreshnessStatus) -> some View {
        HStack(spacing: 4) {
            Circle().fill(status.color).frame(width: 8, height: 8)
            Text(status.displayName).foregroundStyle(.secondary)
        }
    }
}

private struct EverywhereDemo: View {
    let healthAvailable: Bool
    let healthConnected: Bool
    let connectHealth: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 22) {
                device("iphone", "iPhone")
                device("applewatch", "Watch")
                device("laptopcomputer", "Mac")
            }
            HStack(spacing: 8) {
                Image(systemName: "icloud.fill").foregroundStyle(Color.accentColor)
                Text("Synced through your iCloud").font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            if healthAvailable {
                Button(action: connectHealth) {
                    Label(healthConnected ? "Apple Health connected" : "Connect Apple Health", systemImage: healthConnected ? "checkmark.circle.fill" : "heart.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glass)
                .tint(.pink)
            }
        }
        .padding(20)
        .card(padding: 0, cornerRadius: 26)
    }

    private func device(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.accentColor.gradient)
                .frame(height: 50)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }
}
