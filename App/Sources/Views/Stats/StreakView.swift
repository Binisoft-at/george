import SwiftUI
import BinisoftKit
import SwiftData
import GeorgeCore

struct StreakView: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(HealthKitManager.self) private var health
    @Environment(LiveWorkoutController.self) private var live
    @Query private var sessions: [WorkoutSession]
    @Query private var excused: [ExcusedWeek]
    @State private var showRescue = false

    var body: some View {
        let _ = sessions.count + excused.count + store.revision
        let summary = store.streakSummary(healthEntries: health.externalWorkouts)
        let settings = store.settings

        List {
            Section {
                VStack(spacing: 14) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(summary.currentWeeks > 0 ? Color.orange.gradient : Color.secondary.gradient)
                        .symbolEffect(.bounce, value: summary.currentWeeks)
                    Text("\(summary.currentWeeks)")
                        .font(.system(size: 56, weight: .heavy, design: .rounded))
                        .contentTransition(.numericText())
                    Text(summary.currentWeeks == 1 ? "week streak" : "week streak")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    if summary.thisWeek.status == .onBreak {
                        // A break week: calm, nothing to chase.
                        Label(summary.headline, systemImage: "bed.double.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text(MacHealth.headline(summary, store: store))
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    WeekDotsView(week: summary.thisWeek, marks: store.dayMarks(for: summary.thisWeek))
                        .padding(.top, 6)
                    MacHealthNote(topic: .streak)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .card(padding: 0, cornerRadius: 28)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if (summary.thisWeek.status == .rescueAvailable || summary.thisWeek.status == .tight || summary.thisWeek.status == .atRisk)
                && MacHealth.offersRescue(store) {
                Section {
                    Button {
                        showRescue = true
                    } label: {
                        Label("Start a \(settings.rescueMinutes)-min rescue workout", systemImage: "lifepreserver")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.orange)
                    .disabled(live.isActive)
                } footer: {
                    Text("A rescue workout counts double (once per week). Pick a ready-made mobility or stretch routine – or a short band circuit.")
                }
            }

            Section("Saves") {
                HStack {
                    SavesBadge(credits: summary.credits, max: summary.maxCredits)
                        .font(.title2)
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("\(summary.credits) of \(summary.maxCredits)")
                            .font(.headline)
                        if let next = summary.weeksUntilNextCredit {
                            Text(next == 0 ? "Next save when this week ends" : "Next save in \(next) successful week\(next == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Fully stocked").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Every 2 weeks in a row that hit your goal earn a save. A missed week \(settings.autoUseSaves ? "uses one automatically" : "can be covered by a save") so your streak survives.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                StreakHeatmap(history: summary.history, current: summary.thisWeek)
                    .padding(.vertical, 6)
                HStack(spacing: 14) {
                    legend(.orange, "Goal met")
                    legend(.cyan, "Saved")
                    legend(.gray, "Break")
                    legend(.red.opacity(0.6), "Missed")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } header: {
                Text("History")
            } footer: {
                Text("Best streak: \(summary.bestWeeks) weeks · \(summary.totalWorkoutDays) workout days in total")
            }

            Section {
                let thisWeek = store.calendar.weekStart(for: Date())
                Button {
                    store.toggleExcused(weekStart: thisWeek)
                } label: {
                    Label(store.isExcused(weekStart: thisWeek) ? "Undo break for this week" : "Take a break this week (sick, travel…)", systemImage: "bed.double")
                }
                let lastWeek = store.calendar.addingWeeks(-1, to: thisWeek)
                Button {
                    store.toggleExcused(weekStart: lastWeek)
                } label: {
                    Label(store.isExcused(weekStart: lastWeek) ? "Undo break for last week" : "Mark last week as a break", systemImage: "calendar.badge.minus")
                }
            } footer: {
                Text("Break weeks don't count as missed and don't use a save.")
            }

            StreakSettingsSection()
        }
        .groupedList()
        .navigationTitle("Streak")
        .sheet(isPresented: $showRescue) {
            RescueSheet()
        }
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(title)
        }
    }
}

/// Weekly squares, newest at the end, like a contribution graph.
struct StreakHeatmap: View {
    let history: [WeekRecord]
    let current: CurrentWeek

    var body: some View {
        let recent = Array(history.suffix(25))
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 13), spacing: 5) {
            ForEach(recent) { week in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color(for: week))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Text("\(week.workoutDays)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(week.workoutDays > 0 ? 0.9 : 0))
                    }
                    .accessibilityLabel("\(week.weekStart.formatted(date: .abbreviated, time: .omitted)): \(week.workoutDays) of \(week.goal) days, \(week.outcome.rawValue)")
            }
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.orange, lineWidth: 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(current.progress * 0.8)))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Text("\(current.workoutDays)")
                        .font(.system(size: 9, weight: .bold))
                }
        }
    }

    private func color(for week: WeekRecord) -> Color {
        switch week.outcome {
        case .met: return .orange
        case .saved: return .cyan
        case .excused: return .gray.opacity(0.5)
        case .missed: return week.workoutDays > 0 ? .red.opacity(0.45) : .red.opacity(0.25)
        case .inProgress: return .secondary
        }
    }
}

/// Goal + streak rules, and the reminders (shared with Settings).
struct StreakSettingsSection: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(HealthKitManager.self) private var health
    @AppStorage(Prefs.trainingReminders) private var reminders = false
    @AppStorage(Prefs.reminderMinutes) private var reminderMinutes = ReminderScheduler.defaultMinutes
    @State private var permissionDenied = false

    var body: some View {
        let settings = store.settings
        Section {
            Stepper(
                "Weekly goal: \(settings.weeklyGoal) day\(settings.weeklyGoal == 1 ? "" : "s")",
                value: Binding(get: { settings.weeklyGoal }, set: { value in
                    let calendar = store.calendar
                    store.updateSettings { $0.setWeeklyGoal(value, calendar: calendar) }
                }),
                in: 1...7
            )
            Toggle("Use saves automatically", isOn: Binding(get: { settings.autoUseSaves }, set: { value in store.updateSettings { $0.autoUseSaves = value } }))
            Toggle("Rescue workouts count double", isOn: Binding(get: { settings.rescueCountsDouble }, set: { value in store.updateSettings { $0.rescueCountsDouble = value } }))
            Stepper(
                "Rescue workout: \(settings.rescueMinutes) min",
                value: Binding(get: { settings.rescueMinutes }, set: { value in store.updateSettings { $0.rescueMinutes = value } }),
                in: 5...30, step: 5
            )
            Stepper(
                "Count workouts ≥ \(settings.minimumMinutes) min",
                value: Binding(get: { settings.minimumMinutes }, set: { value in store.updateSettings { $0.minimumMinutes = value } }),
                in: 5...60, step: 5
            )
            Toggle("Count other Apple Health workouts", isOn: Binding(get: { settings.countHealthWorkouts }, set: { value in store.updateSettings { $0.countHealthWorkouts = value } }))
        } header: {
            Text("Rules")
        } footer: {
            Text("A workout counts from \(settings.minimumMinutes) minutes – strength workouts with 3 or more sets also when they were logged without a time. A rescue workout counts from about \(Int((Double(settings.rescueMinutes) * 0.8).rounded())) minutes or one set.")
        }

        #if os(iOS)
        Section {
            Toggle(isOn: Binding(get: { reminders }, set: { setReminders($0) })) {
                Label("Training reminders", systemImage: "bell.badge")
            }
            if reminders {
                DatePicker(
                    "Time",
                    selection: Binding(
                        get: { reminderDate },
                        set: { date in
                            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                            reminderMinutes = (parts.hour ?? 17) * 60 + (parts.minute ?? 30)
                            ReminderScheduler.reschedule(store: store, healthEntries: health.externalWorkouts)
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
            }
            if permissionDenied {
                Text("Notifications are off for George – turn them on in iPhone Settings → Notifications → George.")
                    .font(.caption)
                    .foregroundStyle(Tone.cautionText)
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text("On days with a planned workout (or a template scheduled for that weekday), and once late in the week when your streak needs a workout day.")
        }
        #endif
    }

    private var reminderDate: Date {
        Calendar.current.date(bySettingHour: reminderMinutes / 60, minute: reminderMinutes % 60, second: 0, of: Date()) ?? Date()
    }

    private func setReminders(_ on: Bool) {
        guard on else {
            reminders = false
            ReminderScheduler.cancelAll()
            return
        }
        Task {
            let allowed = await ReminderScheduler.requestPermission()
            permissionDenied = !allowed
            reminders = allowed
            if allowed { ReminderScheduler.reschedule(store: store, healthEntries: health.externalWorkouts) }
        }
    }
}
