import SwiftUI
import BinisoftKit
import SwiftData
import GeorgeCore

/// Notes-style row: bold title, then date + first line of detail.
struct SessionRow: View {
    let session: WorkoutSession
    var showProgram = false

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
                    Text(detailLine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.subheadline)
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
    }

    private var detailLine: String {
        if !session.subtitle.isEmpty && session.status == .planned { return session.subtitle }
        if session.status.isPerformed || session.status == .active { return session.summaryLine }
        if !session.subtitle.isEmpty { return session.subtitle }
        if !session.notes.isEmpty { return session.notes.components(separatedBy: .newlines).first ?? "" }
        return session.summaryLine
    }

    @ViewBuilder
    private var statusIcon: some View {
        let tint = Color(hex: session.displayColorHex)
        switch session.status {
        case .completed:
            ZStack {
                Circle().fill(tint.opacity(0.18))
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(tint)
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
    var onStart: (() -> Void)? = nil

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
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let onStart {
                Button(action: onStart) {
                    Image(systemName: "play.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(Color(hex: template.displayColorHex))
                .accessibilityLabel("Start \(template.name)")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Context-menu items shared by every place a session appears.
struct SessionMenuItems: View {
    let session: WorkoutSession
    @Environment(GeorgeStore.self) private var store
    @Environment(LiveWorkoutController.self) private var live
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Query(sort: \Program.sortIndex) private var programs: [Program]

    var body: some View {
        if session.status != .completed {
            Button {
                live.start(session)
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
        Menu {
            ForEach(SessionStatus.allCases.filter { $0 != .active }) { status in
                Button {
                    store.setStatus(status, for: [session])
                } label: {
                    Label(status.displayName, systemImage: status.symbol)
                }
            }
        } label: {
            Label("Mark As", systemImage: "checkmark.circle")
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
        Button(role: .destructive) {
            router.close(.session(session.id))
            if live.session?.id == session.id { live.discard() } else { store.trash(session, toasts: toasts) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
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
            if let practice { practice.startTapped = true } else { live.start(template: template) }
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

/// Sheet to log a workout done without the app.
struct LogPastWorkoutSheet: View {
    let template: WorkoutTemplate
    /// Called instead of dismissing when shown inside another flow (e.g. the create sheet).
    var onDone: (() -> Void)? = nil
    @Environment(GeorgeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var minutes = 40

    var body: some View {
        Form {
            Section {
                DatePicker("When", selection: $date, in: ...Date())
                Stepper("Duration: \(minutes) min", value: $minutes, in: 5...240, step: 5)
            } footer: {
                Text("All sets of “\(template.name)” are marked as done. You can edit them afterwards.")
            }
        }
        .navigationTitle("Log Past Workout")
        .inlineTitle()
        .toolbar {
            if onDone == nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Log") {
                    let session = store.logPastSession(from: template, date: date, minutes: minutes)
                    if let onDone {
                        onDone()
                        router.afterDismiss { router.open(.session(session.id)) }
                    } else {
                        router.open(.session(session.id))
                        dismiss()
                    }
                }
            }
        }
    }
}
