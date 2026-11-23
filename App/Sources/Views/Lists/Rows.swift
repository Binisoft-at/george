import SwiftUI
import BinisoftKit
import SwiftData
import GeorgeCore

/// Notes-style row: bold title, then date + first line of detail.
struct SessionRow: View {
    let session: WorkoutSession
    var showProgram = false
    @Environment(GeorgeStore.self) private var store

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.title.isEmpty ? "Untitled Workout" : session.title)
                        .font(.headline)
                        .lineLimit(1)
                    if session.isRescue {
                        Image(systemName: "lifepreserver").font(.caption).foregroundStyle(.orange)
                    }
                    if session.isFavorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                }
                HStack(spacing: 6) {
                    Text(DateLabel.short(session.date))
                        .foregroundStyle(.primary.opacity(0.8))
                    Text(showsSubtitleLine ? session.summaryLine : detailLine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.subheadline)
                // A planned workout's focus ("CHEST + BACK + SHOULDERS") on a line of its own – not cut short.
                if showsSubtitleLine {
                    Text(session.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if showProgram, let program = session.program {
                    Label(program.name, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                if session.priority != .none {
                    Image(systemName: session.priority.symbol)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(session.priority.color)
                }
                if session.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // The separator runs from the row's edge (with the icon), not from the title.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }

    private var showsSubtitleLine: Bool { session.status == .planned && !session.subtitle.isEmpty }

    private var detailLine: String {
        if !session.subtitle.isEmpty && session.status == .planned { return session.subtitle }
        if session.status == .completed { return completedLine }
        if session.status.isPerformed { return session.summaryLine(energy: store.displayEnergy(for: session)) }
        if session.status == .active { return session.summaryLine }
        if !session.subtitle.isEmpty { return session.subtitle }
        if !session.notes.isEmpty { return session.notes.components(separatedBy: .newlines).first ?? "" }
        return session.summaryLine
    }

    /// A completed workout has every set done – the line shows what's more useful: time and energy.
    private var completedLine: String {
        var parts: [String] = []
        if session.durationSeconds > 0 { parts.append(Format.minutes(session.durationSeconds)) }
        // Measured on this device when the Watch recorded it, else George's estimate ("≈").
        if let energy = store.displayEnergy(for: session) { parts.append(energy.text) }
        if parts.isEmpty && session.setCount > 0 { parts.append("\(session.setCount) sets") }
        return parts.isEmpty ? session.kind.displayName : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusIcon: some View {
        let tint = Color(hex: session.displayColorHex)
        switch session.status {
        case .completed:
            // Done is the accent colour everywhere (live, lists, recap) – the kind keeps its colour on the badge.
            ZStack {
                Circle().fill(Tone.accent.opacity(0.18))
                Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(Tone.accent)
            }
            .frame(width: 30, height: 30)
        case .partial, .active:
            ZStack {
                ProgressRing(progress: session.progress, tint: tint, lineWidth: 3)
                Image(systemName: session.status == .active ? "play.fill" : session.kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 30, height: 30)
        case .planned:
            KindIcon(kind: session.kind, colorHex: session.colorHex, size: 30)
                .opacity(0.85)
        case .skipped:
            Image(systemName: "forward.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
        }
    }
}

struct TemplateRow: View {
    let template: WorkoutTemplate
    var showProgram = false
    /// The row selected in the Mac list: its ▶︎ shows (otherwise only on hover).
    var isSelected = false
    var onStart: (() -> Void)? = nil
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            KindIcon(kind: template.kind, colorHex: template.colorHex, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(template.name.isEmpty ? "Untitled" : template.name)
                        .font(.headline)
                        .lineLimit(1)
                    if template.isFavorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    if template.priority != .none {
                        Image(systemName: template.priority.symbol)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(template.priority.color)
                    }
                }
                Text(template.subtitle.isEmpty ? template.summaryLine : template.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if !template.subtitle.isEmpty {
                        Text(template.summaryLine)
                    }
                    if !template.scheduleDays.isEmpty {
                        Label(DateLabel.weekdayNames(template.scheduleDays), systemImage: "calendar")
                    }
                    if showProgram, let program = template.program {
                        Label(program.name, systemImage: "folder")
                    }
                }
                .font(.caption)
                #if os(macOS)
                // Tertiary is too faint on the Mac's list background.
                .foregroundStyle(.secondary)
                #else
                .foregroundStyle(.tertiary)
                #endif
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let onStart {
                #if os(macOS)
                // Mac: a small ▶︎ on the row under the pointer or the selected one – not a loud
                // button on every row.
                Button(action: onStart) {
                    Image(systemName: "play.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .opacity(isHovering || isSelected ? 1 : 0)
                .allowsHitTesting(isHovering || isSelected)
                .accessibilityLabel("Start \(template.name)")
                .help("Start \(template.name)")
                #else
                Button(action: onStart) {
                    Image(systemName: "play.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(Color(hex: template.displayColorHex))
                .accessibilityLabel("Start \(template.name)")
                #endif
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
        // The separator runs from the row's edge (with the icon), not from the title.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }
}

/// Context-menu items shared by every place a session appears.
struct SessionMenuItems: View {
    let session: WorkoutSession
    /// "Mark As → Completed" on a workout that wasn't done: opens the log sheet (date, minutes) instead.
    var onLogPast: ((WorkoutSession) -> Void)? = nil
    @Environment(GeorgeStore.self) private var store
    @Environment(LiveWorkoutController.self) private var live
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Query(sort: \Program.sortIndex) private var programs: [Program]

    var body: some View {
        if session.status != .completed {
            Button {
                live.requestStart(.session(session))
            } label: {
                Label(session.status == .active ? "Continue" : "Start", systemImage: "play.fill")
            }
        }
        Button {
            let copy = store.duplicate(session, asPlannedOn: Date())
            router.open(.session(copy.id))
        } label: {
            Label("Do Again Today", systemImage: "arrow.clockwise")
        }
        Menu {
            ForEach(1..<8, id: \.self) { offset in
                let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
                Button(date.formatted(.dateTime.weekday(.wide).day().month())) {
                    _ = store.duplicate(session, asPlannedOn: date)
                }
            }
        } label: {
            Label("Plan Again…", systemImage: "calendar.badge.plus")
        }
        Divider()
        if isRunningHere {
            // The running workout ends in live mode (effort, Apple Health), not by a status change.
            Button {
                live.isPresented = true
                live.finishRequest = true
            } label: {
                Label("Finish Workout…", systemImage: "flag.checkered")
            }
        } else {
            Menu {
                ForEach(SessionStatus.allCases.filter { $0 != .active }) { status in
                    Button {
                        if status == .completed && !session.status.isPerformed, let onLogPast {
                            onLogPast(session)
                        } else {
                            store.setStatus(status, for: [session])
                        }
                    } label: {
                        Label(status.displayName, systemImage: status.symbol)
                    }
                }
            } label: {
                Label("Mark As", systemImage: "checkmark.circle")
            }
        }
        Menu {
            ForEach(Priority.allCases) { priority in
                Button {
                    session.priority = priority
                    store.save()
                } label: {
                    Label(priority.displayName, systemImage: session.priority == priority ? "checkmark" : priority.symbol)
                }
            }
        } label: {
            Label("Priority", systemImage: "exclamationmark.circle")
        }
        Button {
            session.isPinned.toggle()
            store.save()
        } label: {
            Label(session.isPinned ? "Unpin" : "Pin", systemImage: session.isPinned ? "pin.slash" : "pin")
        }
        Button {
            session.isFavorite.toggle()
            store.save()
        } label: {
            Label(session.isFavorite ? "Unfavorite" : "Favorite", systemImage: session.isFavorite ? "star.slash" : "star")
        }
        Menu {
            Button("No Program") { store.move([session], to: nil) }
            ForEach(programs) { program in
                Button {
                    store.move([session], to: program)
                } label: {
                    Label(program.name, systemImage: session.program?.id == program.id ? "checkmark" : program.symbol)
                }
            }
        } label: {
            Label("Move to Program", systemImage: "folder")
        }
        Button {
            let template = store.saveAsTemplate(session, into: session.program)
            router.open(.template(template.id))
        } label: {
            Label("Save as Template", systemImage: "square.on.square")
        }
        Divider()
        if isRunningHere {
            // Live mode asks first (and keeps a continued workout's saved part).
            Button(role: .destructive) {
                live.isPresented = true
                live.discardRequest = true
            } label: {
                Label("Discard Workout…", systemImage: "trash")
            }
        } else {
            Button(role: .destructive) {
                router.close(.session(session.id))
                store.trash(session, toasts: toasts)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// The workout live mode is running on this device right now.
    private var isRunningHere: Bool { live.session?.id == session.id }
}

struct TemplateMenuItems: View {
    let template: WorkoutTemplate
    @Environment(GeorgeStore.self) private var store
    @Environment(LiveWorkoutController.self) private var live
    @Environment(PracticeSession.self) private var practice: PracticeSession?
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Query(sort: \Program.sortIndex) private var programs: [Program]
    @Binding var logPastFor: WorkoutTemplate?

    var body: some View {
        Button {
            if let practice { practice.startTapped = true } else { store.requestStart(template, live: live, toasts: toasts) }
        } label: {
            Label("Start Now", systemImage: "play.fill")
        }
        Menu {
            ForEach(0..<8, id: \.self) { offset in
                let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
                Button(offset == 0 ? "Today" : date.formatted(.dateTime.weekday(.wide).day().month())) {
                    let session = store.makeSession(from: template, date: date, start: false)
                    router.open(.session(session.id))
                }
            }
        } label: {
            Label("Plan For…", systemImage: "calendar.badge.plus")
        }
        Button {
            logPastFor = template
        } label: {
            Label("Log Past Workout…", systemImage: "clock.arrow.circlepath")
        }
        Divider()
        Button {
            let copy = store.duplicate(template)
            router.open(.template(copy.id))
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button {
            template.isFavorite.toggle()
            store.save()
        } label: {
            Label(template.isFavorite ? "Unfavorite" : "Favorite", systemImage: template.isFavorite ? "star.slash" : "star")
        }
        Menu {
            ForEach(Priority.allCases) { priority in
                Button {
                    template.priority = priority
                    store.save()
                } label: {
                    Label(priority.displayName, systemImage: template.priority == priority ? "checkmark" : priority.symbol)
                }
            }
        } label: {
            Label("Priority", systemImage: "exclamationmark.circle")
        }
        Menu {
            ForEach(programs) { program in
                Button {
                    store.move([template], to: program)
                } label: {
                    Label(program.name, systemImage: template.program?.id == program.id ? "checkmark" : program.symbol)
                }
            }
        } label: {
            Label("Move to Program", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) {
            router.close(.template(template.id))
            store.trash(template, toasts: toasts)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

/// Sheet to log a workout done without the app: from a template (a new session), or for a planned
/// session that was done but not tracked ("Mark As → Completed").
struct LogPastWorkoutSheet: View {
    let template: WorkoutTemplate?
    let session: WorkoutSession?
    /// Called instead of dismissing when shown inside another flow (e.g. the create sheet).
    var onDone: (() -> Void)? = nil
    @Environment(GeorgeStore.self) private var store
    @Environment(HealthKitManager.self) private var health
    @Environment(ExerciseLibrary.self) private var library
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    /// When it started; the workout always ends by now.
    @State private var date: Date
    @State private var minutes: Int
    @State private var saveToHealth = false
    /// The usual length and time of day come from the store, once, when the sheet opens.
    @State private var didLoad = false

    /// "I did UPPER but forgot to track it": started a workout's length ago, so it ends now.
    init(template: WorkoutTemplate, onDone: (() -> Void)? = nil) {
        self.template = template
        self.session = nil
        self.onDone = onDone
        let estimated = template.estimatedMinutes
        let minutes = estimated > 0 ? max(5, Int((Double(estimated) / 5).rounded()) * 5) : 40
        _minutes = State(initialValue: minutes)
        _date = State(initialValue: Date().addingTimeInterval(-Double(minutes * 60)))
    }

    /// Prefilled with the planned day (at the usual time when it was planned for a whole day) and the
    /// session's usual length.
    init(session: WorkoutSession, onDone: (() -> Void)? = nil) {
        self.template = nil
        self.session = session
        self.onDone = onDone
        let minutes = max(5, min(240, GeorgeStore.defaultMinutes(for: session)))
        _minutes = State(initialValue: minutes)
        _date = State(initialValue: PastLog.clamped(session.plannedDate ?? session.date, minutes: minutes, now: Date()))
    }

    /// The latest start that still ends by now.
    private var latestStart: Date { Date().addingTimeInterval(-Double(minutes * 60)) }

    /// Apple Health gets it unless it's there already (a workout continued from a saved one).
    private var canSaveToHealth: Bool { health.isAvailable && session?.healthWorkoutID == nil }

    private var name: String {
        template?.name ?? session.map { $0.templateName.isEmpty ? $0.title : $0.templateName } ?? "Workout"
    }

    var body: some View {
        Form {
            Section {
                DatePicker("Started", selection: $date, in: ...latestStart, displayedComponents: [.date, .hourAndMinute])
                Stepper("Duration: \(Format.minutes(Double(minutes * 60)))", value: $minutes, in: 5...240, step: 5)
            } footer: {
                Text("All sets of “\(name)” are marked as done with their planned numbers. You can edit them afterwards.")
            }
            if canSaveToHealth {
                Section {
                    Toggle(isOn: $saveToHealth) {
                        Label("Save to Apple Health", systemImage: "heart.text.square.fill")
                    }
                } footer: {
                    Text("Leave it off when your watch already recorded this workout – otherwise it counts twice in Fitness.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadDefaults)
        // A longer workout must still end by now: the start moves back.
        .onChange(of: minutes) { _, newMinutes in
            date = PastLog.clamped(date, minutes: newMinutes, now: Date())
        }
        .navigationTitle(session == nil ? "Log Past Workout" : "Mark as Done")
        .inlineTitle()
        .toolbar {
            if onDone == nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(session == nil ? "Log" : "Done") { log() }
                    .fontWeight(.semibold)
            }
        }
    }

    /// The usual length (median of the last times) and, for a day planned without a time, the usual
    /// time of day – filled in once, before anything is changed.
    private func loadDefaults() {
        guard !didLoad else { return }
        didLoad = true
        saveToHealth = canSaveToHealth && store.settings.saveToHealth
        if let template {
            minutes = store.defaultMinutes(for: template)
            date = Date().addingTimeInterval(-Double(minutes * 60))
        } else if let session {
            minutes = max(5, min(240, store.defaultMinutes(for: session)))
            date = store.pastLogStart(for: session.plannedDate ?? session.date, minutes: minutes)
        }
    }

    private func log() {
        let start = PastLog.clamped(date, minutes: minutes, now: Date())
        let logged: WorkoutSession
        if let session {
            store.markPerformed(session, date: start, minutes: minutes, bodyMassKg: health.latestBodyMassKg, exactTime: true)
            logged = session
        } else if let template {
            logged = store.logPastSession(from: template, date: start, minutes: minutes, bodyMassKg: health.latestBodyMassKg, exactTime: true)
        } else {
            return
        }
        if saveToHealth && canSaveToHealth { saveToAppleHealth(logged) }
        Haptics.success()
        if let onDone {
            onDone()
            router.afterDismiss { router.open(.session(logged.id)) }
        } else {
            if session == nil { router.open(.session(logged.id)) }
            dismiss()
        }
    }

    /// Like a finished workout: rings, Fitness and apps like Bevel see it (the link is kept, so it
    /// isn't saved twice).
    private func saveToAppleHealth(_ logged: WorkoutSession) {
        guard let start = logged.startedAt, let end = logged.endedAt else { return }
        let content = logged.content
        let done = content.allItems.filter { $0.completedSets > 0 }
        let request = HealthKitManager.SaveRequest(
            sessionID: logged.id, title: logged.title, kind: logged.kind, start: start, end: end,
            activeSeconds: logged.accumulatedSeconds, energyKcal: logged.energyKcal, effort: logged.effort,
            exercises: done.map(\.name),
            muscles: Array(Set(done.flatMap { library.muscles(for: $0) })).sorted(),
            completedSets: content.completedSets, volumeKg: content.volumeKg
        )
        Task {
            if let workoutID = await health.saveWorkout(request) {
                logged.healthWorkoutID = workoutID.uuidString
                store.save()
            }
        }
    }
}
