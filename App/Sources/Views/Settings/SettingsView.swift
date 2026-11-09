import SwiftUI
import BinisoftKit
import SwiftData
import GeorgeCore

struct SettingsView: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(HealthKitManager.self) private var health
    @Environment(PhoneWatchConnector.self) private var watch
    @Environment(ExerciseLibrary.self) private var library
    @Environment(Router.self) private var router
    @Environment(SyncMonitor.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.showImages) private var showImages = true
    @AppStorage(Prefs.healthAsked) private var healthAsked = false
    @Query private var sessions: [WorkoutSession]
    @State private var exportPayload: ExportPayload?
    @State private var hintsReset = false

    var body: some View {
        let settings = store.settings
        Form {
            Section {
                Button("Hands-on Tour", systemImage: "graduationcap") { router.startTour() }
                Button("Welcome & Setup", systemImage: "hand.wave") {
                    #if os(iOS)
                    dismiss()
                    router.afterDismiss { router.showWelcome = true }
                    #else
                    router.showWelcome = true
                    #endif
                }
                Button(hintsReset ? "Hints Come Back at the Next Launch" : "Show Hints Again", systemImage: "lightbulb") {
                    BinisoftTips.requestReset()
                    hintsReset = true
                }
                .disabled(hintsReset)
            } header: {
                Text("Help")
            } footer: {
                Text("The tour runs on a practice copy, so nothing you do there touches your workouts. Welcome & Setup explains streaks, muscles and sync, and sets your weekly goal.")
            }

            Section("Appearance") {
                AppearancePicker()
                Toggle("Show exercise images", isOn: $showImages)
            }

            Section("Training") {
                Picker("Units", selection: Binding(get: { settings.unit }, set: { settings.unit = $0; store.save() })) {
                    Text("Kilograms").tag(WeightUnit.kg)
                    Text("Pounds").tag(WeightUnit.lb)
                }
                Picker("Week starts on", selection: Binding(get: { settings.weekStartsOn }, set: { settings.weekStartsOn = $0; store.save() })) {
                    Text("Monday").tag(2)
                    Text("Sunday").tag(1)
                    Text("Saturday").tag(7)
                }
                Picker("Default rest", selection: Binding(get: { settings.defaultRestSeconds }, set: { settings.defaultRestSeconds = $0; store.save() })) {
                    ForEach([30, 45, 60, 75, 90, 120, 150, 180], id: \.self) { Text(Format.shortDuration($0)).tag($0) }
                }
                Toggle("Prefill weights from last time", isOn: Binding(get: { settings.prefillFromLastTime }, set: { settings.prefillFromLastTime = $0; store.save() }))
                Toggle("Offer to update templates after edits", isOn: Binding(get: { settings.askToUpdateTemplate }, set: { settings.askToUpdateTemplate = $0; store.save() }))
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Naming pattern", text: Binding(get: { settings.namingPattern }, set: { settings.namingPattern = $0; store.save() }))
                        .font(.system(.body, design: .monospaced))
                    Text("Preview: \(SessionNamer(pattern: settings.namingPattern, calendar: store.calendar).title(templateName: "UPPER", date: Date(), indexInWeek: 2))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Tokens: {W} week · {N} # in week · {T} template · {D} day.month · {DATE} · {WD} weekday")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            CoachSettingsSection()

            ProfileSettingsSection()

            StreakSettingsSection()

            Section {
                if health.isAvailable {
                    Button {
                        Task {
                            await health.requestAuthorization()
                            healthAsked = true
                        }
                    } label: {
                        Label(healthAsked ? "Review Apple Health Access" : "Connect Apple Health", systemImage: "heart.text.square.fill")
                    }
                    Toggle("Save workouts to Apple Health", isOn: Binding(get: { settings.saveToHealth }, set: { settings.saveToHealth = $0; store.save() }))
                    LabeledContent("Other workouts found", value: "\(health.externalWorkouts.count) in 6 months")
                    if let mass = health.latestBodyMassKg {
                        LabeledContent("Body weight (Health)", value: Format.weight(mass, unit: settings.unit))
                    }
                } else {
                    Text("Apple Health isn't available on this device. Workouts sync to your iPhone, which saves them to Health.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Stepper(
                    "Body weight for estimates: \(Format.weight(settings.bodyMassKg, unit: settings.unit))",
                    value: Binding(get: { settings.bodyMassKg }, set: { settings.bodyMassKg = $0; store.save() }),
                    in: 35...200, step: 1
                )
                if let error = health.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Apple Health")
            } footer: {
                Text("George writes the workout type, duration, calories and your effort rating. Apps like Fitness and Bevel read these; heart rate comes from the Apple Watch app.")
            }

            #if os(iOS)
            Section("Apple Watch") {
                LabeledContent("Paired", value: watch.isPaired ? "Yes" : "No")
                LabeledContent("George installed", value: watch.isWatchAppInstalled ? "Yes" : "No")
                LabeledContent("Reachable", value: watch.isReachable ? "Yes" : "No")
            }
            #endif

            SyncStatusSection(
                monitor: sync,
                footer: "George has no servers or accounts. Your workouts sync through your own private iCloud between iPhone, iPad and Mac."
            ) {
                DataLocationView(sections: GeorgeDataFacts.sections, monitor: sync)
            }

            Section {
                Button {
                    router.showImport = true
                    dismiss()
                } label: {
                    Label("Import Program from CSV", systemImage: "square.and.arrow.down")
                }
                Button {
                    exportPayload = ExportPayload(text: store.exportLogCSV(sessions: sessions), name: "George workout log")
                } label: {
                    Label("Export Workout Log (CSV)", systemImage: "square.and.arrow.up")
                }
                Button {
                    store.loadSampleProgram()
                } label: {
                    Label("Add Sample Program", systemImage: "wand.and.stars")
                }
            } header: {
                Text("Import & Export")
            } footer: {
                Text("The CSV export is also your backup: it opens in Numbers or Excel.")
            }

            Section {
                NavigationLink {
                    LogView(appName: AppInfo.name, mode: sync.state.mode)
                } label: {
                    Label("App Log", systemImage: "doc.text.magnifyingglass")
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("If something doesn't work: App Log → Copy log, and paste it into the chat.")
            }

            Section("About") {
                LabeledContent("Version", value: AppVersion.main.display)
                LabeledContent("Storage", value: sync.state.mode.title)
                LabeledContent("Exercise library", value: "\(library.catalog.exercises.count) exercises")
                ForEach(library.catalog.sources, id: \.id) { source in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name).font(.subheadline)
                        if let license = source.license {
                            Text(license).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        #endif
        .sheet(item: $exportPayload) { payload in
            ExportSheet(payload: payload)
        }
    }
}

/// Create or edit a program (folder).
struct ProgramEditorSheet: View {
    let program: Program?
    @Environment(GeorgeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var subtitle = ""
    @State private var kind: WorkoutKind = .gym
    @State private var colorHex = "#0A84FF"
    @State private var symbol = "folder.fill"
    @State private var notes = ""
    @State private var makeActive = true

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: symbol)
                        .font(.title)
                        .foregroundStyle(Color(hex: colorHex))
                        .frame(width: 56, height: 56)
                        .background(Color(hex: colorHex).opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack {
                        TextField("Name (e.g. Elastic Bands – Tennis)", text: $name)
                            .font(.headline)
                        TextField("Description", text: $subtitle)
                            .font(.subheadline)
                    }
                }
            }
            Section("Default type") {
                Picker("Type", selection: $kind) {
                    ForEach(WorkoutKind.presets) { Label($0.displayName, systemImage: $0.symbol).tag($0) }
                }
            }
            Section("Color") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                    ForEach(colorChoices, id: \.self) { hex in
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 32, height: 32)
                            .overlay { if hex == colorHex { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) } }
                            .onTapGesture { colorHex = hex }
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Icon") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                    ForEach(programSymbols, id: \.self) { name in
                        Image(systemName: name)
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .foregroundStyle(name == symbol ? Color.white : Color.primary)
                            .background(Circle().fill(name == symbol ? Color(hex: colorHex) : Color.secondary.opacity(0.12)))
                            .onTapGesture { symbol = name }
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Notes") {
                TextField("Goals, schedule, equipment…", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
            }
            if program == nil {
                Toggle("Make this my active program", isOn: $makeActive)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(program == nil ? "New Program" : "Edit Program")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(program == nil ? "Create" : "Save") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            guard let program else { return }
            name = program.name
            subtitle = program.subtitle
            kind = program.kind
            colorHex = program.colorHex
            symbol = program.symbol
            notes = program.notes
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let program {
            program.name = trimmed
            program.subtitle = subtitle
            program.kind = kind
            program.colorHex = colorHex
            program.symbol = symbol
            program.notes = notes
            program.touch()
            store.save()
        } else {
            let created = store.createProgram(name: trimmed, kind: kind, colorHex: colorHex, symbol: symbol)
            created.subtitle = subtitle
            created.notes = notes
            if makeActive { store.setActive(created) }
            store.save()
            router.show(.program(created.id))
        }
        dismiss()
    }
}

/// George's "Where your data lives" page: the standard Binisoft facts plus Apple Health and the Watch.
enum GeorgeDataFacts {
    static var sections: [DataSection] {
        var sections = DataSection.standard(appName: AppInfo.name, dataNoun: AppInfo.dataNoun)
        sections.insert(DataSection("Apple Health, Watch and exercises", [
            DataFact("heart.fill", "Apple Health", "Heart rate and measured calories are read from Apple Health and stay on the device – George never puts them in iCloud. Finished workouts go into Health, where Fitness and Bevel can see them."),
            DataFact("applewatch", "Apple Watch", "The Watch gets the running workout straight from your iPhone and records heart rate into Health."),
            DataFact("photo", "Exercise pictures", "The exercise library is built into the app. Its pictures load from the open-source library online and are cached; tutorial links open YouTube or the site you added."),
        ]), at: 1)
        return sections
    }
}
