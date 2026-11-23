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
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    #endif
    @AppStorage(Prefs.showImages) private var showImages = true
    @AppStorage(Prefs.healthAsked) private var healthAsked = false
    @AppStorage(Prefs.barKg) private var barKg = 20.0
    @AppStorage(Prefs.plateSet) private var plateSetRaw = PlateSet.standard.rawValue
    @AppStorage(Prefs.offerCoolDown) private var offerCoolDown = true
    @AppStorage(Prefs.countOtherSports) private var countOtherSports = true
    @Query private var sessions: [WorkoutSession]
    @State private var exportPayload: ExportPayload?
    @State private var hintsReset = false

    var body: some View {
        let settings = store.settings
        Form {
            Section {
                Button("Hands-on Tour", systemImage: "graduationcap") { inMainWindow { router.startTour() } }
                Button("Welcome & Setup", systemImage: "hand.wave") {
                    #if os(iOS)
                    dismiss()
                    router.afterDismiss { router.showWelcome = true }
                    #else
                    inMainWindow { router.showWelcome = true }
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

            Section {
                Picker("Units", selection: Binding(get: { settings.unit }, set: { value in store.updateSettings { $0.unit = value } })) {
                    Text("Kilograms").tag(WeightUnit.kg)
                    Text("Pounds").tag(WeightUnit.lb)
                }
                Picker("Week starts on", selection: Binding(get: { settings.weekStartsOn }, set: { value in store.updateSettings { $0.weekStartsOn = value } })) {
                    Text("Monday").tag(2)
                    Text("Sunday").tag(1)
                    Text("Saturday").tag(7)
                }
                Toggle("Prefill weights from last time", isOn: Binding(get: { settings.prefillFromLastTime }, set: { value in store.updateSettings { $0.prefillFromLastTime = value } }))
                Toggle("Offer to update templates after edits", isOn: Binding(get: { settings.askToUpdateTemplate }, set: { value in store.updateSettings { $0.askToUpdateTemplate = value } }))
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Naming pattern", text: Binding(get: { settings.namingPattern }, set: { value in store.updateSettings { $0.namingPattern = value } }))
                        .font(.system(.body, design: .monospaced))
                    Text("Preview: \(SessionNamer(pattern: settings.namingPattern, calendar: store.calendar).title(templateName: "UPPER", date: Date(), indexInWeek: 2))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Tokens: {W} week · {N} # in week · {T} template · {D} day.month · {DATE} · {WD} weekday")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Picker("Barbell", selection: $barKg) {
                    ForEach(barChoices(for: settings.unit), id: \.self) { kg in
                        Text(Format.weight(kg, unit: settings.unit)).tag(kg)
                    }
                }
                Picker("Plates", selection: $plateSetRaw) {
                    ForEach(PlateSet.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Offer a cool-down after workouts", isOn: $offerCoolDown)
                Toggle("Count other sports in muscle recovery", isOn: $countOtherSports)
            } header: {
                Text("Training")
            } footer: {
                Text("Barbell and plates: for warm-up sets and “per side” plate maths. Other sports: tennis, runs and classes from Apple Health count toward muscle recovery and load.")
            }

            CoachSettingsSection()

            ProfileSettingsSection()

            StreakSettingsSection()

            Section {
                if health.isAvailable {
                    LabeledContent {
                        Text(healthStatus)
                            .foregroundStyle(health.isAuthorizedToShare ? Tone.goodText : Color.secondary)
                    } label: {
                        Label("Apple Health", systemImage: "heart.text.square.fill")
                    }
                    Button {
                        Task {
                            await health.requestAuthorization()
                            healthAsked = true
                        }
                    } label: {
                        Text(healthAsked ? "Review Apple Health Access" : "Connect Apple Health")
                    }
                    Toggle("Save workouts to Apple Health", isOn: Binding(get: { settings.saveToHealth }, set: { value in store.updateSettings { $0.saveToHealth = value } }))
                    LabeledContent("Other workouts found", value: "\(health.externalWorkouts.count) in 6 months")
                } else {
                    Text("Apple Health isn't available on this device. Your George workouts sync to your iPhone, which saves them to Health. Workouts from Apple Health (tennis, runs, other apps) stay on iPhone and Watch, so the streak, load and freshness here leave them out and can be lower.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                bodyWeightRow(settings: settings)
                if let error = health.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Apple Health")
            } footer: {
                Text("George writes the workout type, duration, calories and your effort rating. Apps like Fitness and Bevel read these; heart rate comes from the Apple Watch app. Calories are estimated with your body weight – Apple Health's latest value when there is one.")
            }

            #if os(iOS)
            Section {
                LabeledContent {
                    Text(watchStatus)
                        .multilineTextAlignment(.trailing)
                } label: {
                    Label("Apple Watch", systemImage: "applewatch")
                }
            } footer: {
                if watch.isPaired && !watch.isWatchAppInstalled {
                    Text("Install George on the watch: open the Watch app on this iPhone → My Watch → Available Apps → George → Install.")
                }
            }
            #endif

            SyncStatusSection(
                monitor: sync,
                footer: "George has no servers or accounts. Your workouts sync through your own private iCloud between iPhone, iPad and Mac."
            ) {
                DataLocationView(sections: GeorgeDataFacts.sections, monitor: sync)
            }

            ThaliaSettingsSection()

            Section {
                Button {
                    #if os(macOS)
                    inMainWindow { router.showImport = true }
                    #else
                    router.showImport = true
                    dismiss()
                    #endif
                } label: {
                    Label("Import Program from CSV", systemImage: "square.and.arrow.down")
                }
                Button {
                    exportPayload = ExportPayload(text: store.exportLogCSV(sessions: sessions), name: "George workout log")
                } label: {
                    Label("Export Workout Log (CSV)", systemImage: "square.and.arrow.up")
                }
                // Export Full Backup…, Restore from Backup…, Last backup (BackupViews.swift).
                BackupSettingsRows()
                Menu {
                    ForEach(GeorgeStore.SampleProgram.allCases) { sample in
                        Button {
                            addSample(sample)
                        } label: {
                            Label {
                                Text(sample.title)
                                Text(sample.detail)
                            } icon: {
                                Image(systemName: sample == .gym ? "dumbbell" : "figure.tennis")
                            }
                        }
                    }
                } label: {
                    Label("Add Sample Program", systemImage: "wand.and.stars")
                }
            } header: {
                Text("Import & Export")
            } footer: {
                Text("A full backup holds everything and can be restored – George also saves one each week and before every import. The workout log is a readable list for Numbers or Excel – it can't be imported back. Your data lives in iCloud.")
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

    // MARK: Pieces

    /// "Connected" only when Health really allows George to save workouts.
    private var healthStatus: String {
        if health.isAuthorizedToShare { return "Connected" }
        return healthAsked ? "Not allowed – Health app → Sharing → Apps → George" : "Not connected"
    }

    /// One body-weight row: Apple Health's value when there is one, otherwise your own.
    @ViewBuilder
    private func bodyWeightRow(settings: SyncedSettings) -> some View {
        if let mass = health.latestBodyMassKg {
            LabeledContent("Body weight", value: "\(Format.weight(mass, unit: settings.unit)) · from Apple Health")
        } else {
            LabeledContent("Body weight") {
                HStack(spacing: 4) {
                    NumberField(
                        placeholder: settings.unit.rawValue,
                        value: Binding(
                            get: { (settings.unit.fromKilograms(settings.bodyMassKg) * 10).rounded() / 10 },
                            set: { value in
                                guard let value, value > 0 else { return }
                                let kg = min(250, max(30, settings.unit.toKilograms(value)))
                                store.updateSettings { $0.bodyMassKg = kg }
                            }
                        ),
                        width: 70
                    )
                    .multilineTextAlignment(.trailing)
                    Text(settings.unit.rawValue)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var watchStatus: String {
        #if os(iOS)
        if !watch.isPaired { return "No watch paired" }
        if !watch.isWatchAppInstalled { return "George not installed" }
        return watch.isReachable ? "Connected" : "Installed · not reachable now"
        #else
        return ""
        #endif
    }

    private func barChoices(for unit: WeightUnit) -> [Double] {
        var choices: [Double] = unit == .kg ? [20, 15, 10, 7.5] : [unit.toKilograms(45), unit.toKilograms(35), unit.toKilograms(25), unit.toKilograms(15)]
        if !choices.contains(where: { abs($0 - barKg) < 0.01 }) { choices.insert(barKg, at: 0) }
        return choices
    }

    private func addSample(_ sample: GeorgeStore.SampleProgram) {
        guard let program = store.loadSampleProgram(sample) else { return }
        toasts.show("Added \u{201C}\(program.name)\u{201D}", symbol: "wand.and.stars")
        #if os(iOS)
        dismiss()
        router.afterDismiss { router.show(.program(program.id)) }
        #else
        inMainWindow { router.show(.program(program.id)) }
        #endif
    }

    /// Mac: Settings is a window of its own. The tour, Welcome, Import and a new sample program show
    /// in the main window – so Settings closes and the main window comes forward first (it opens
    /// again if it was closed), instead of everything appearing behind Settings or nowhere.
    /// iPhone/iPad: runs right away (Settings is a sheet there; the action closes it where needed).
    private func inMainWindow(_ action: @escaping @MainActor () -> Void) {
        #if os(macOS)
        let mainIsOpen = router.mainWindowCount > 0
        dismissWindow()
        if !mainIsOpen { openWindow(id: "main") }
        router.afterDismiss {
            // Once Settings is gone: the main window may be behind the workout window.
            if mainIsOpen { MainWindowFront.bringForward() }
            action()
        }
        #else
        action()
        #endif
    }
}

/// The plates at hand, for "per side" plate maths (Settings → Training).
enum PlateSet: String, CaseIterable, Identifiable {
    case standard, noSmall, pounds
    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "25 … 1.25 kg"
        case .noSmall: return "25 … 2.5 kg"
        case .pounds: return "45 … 2.5 lb"
        }
    }

    /// Plates per side in kilograms, heaviest first.
    var platesKg: [Double] {
        switch self {
        case .standard: return [25, 20, 15, 10, 5, 2.5, 1.25]
        case .noSmall: return [25, 20, 15, 10, 5, 2.5]
        case .pounds: return [45, 35, 25, 10, 5, 2.5].map { WeightUnit.lb.toKilograms($0) }
        }
    }

    static var current: PlateSet {
        PlateSet(rawValue: UserDefaults.standard.string(forKey: Prefs.plateSet) ?? "") ?? .standard
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
    /// On for your first own program only: a new program doesn't take over Today by itself.
    @State private var makeActive = false
    @State private var didLoad = false

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
                if program == nil {
                    Toggle("Make this my active program", isOn: $makeActive)
                }
            } footer: {
                if program == nil {
                    Text("Today's Up next and Plan This Week follow the active program.")
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
            if !didLoad {
                didLoad = true
                // Your first own program becomes active; the "Stretch & Yoga" routines folder doesn't count.
                makeActive = !store.fetchPrograms(includeArchived: false).contains { !store.isRoutineProgram($0) }
            }
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
            let created = store.createProgram(name: trimmed, kind: kind, colorHex: colorHex, symbol: symbol, activate: makeActive)
            created.subtitle = subtitle
            created.notes = notes
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
            DataFact("arrow.left.arrow.right", "Thalia", "If you use Thalia, George leaves a small note in the shared folder on this device for each finished workout (when, which template, its name). Thalia reads it there; nothing from Apple Health is in it. Settings → Thalia turns it off."),
            DataFact("photo", "Exercise pictures", "The exercise library is built into the app. Its pictures load from the open-source library online and are cached; tutorial links open YouTube or the site you added."),
        ]), at: 1)
        // The standard "Export" line promises a CSV of everything; George's CSV is a readable log.
        return sections.map { (section: DataSection) -> DataSection in
            guard section.facts.contains(where: { $0.title == "Export" }) else { return section }
            return DataSection(section.title, section.facts.map { (fact: DataFact) -> DataFact in
                guard fact.title == "Export" else { return fact }
                return DataFact("square.and.arrow.up", "Export", "Settings → Import & Export saves your workout log as a CSV to read in Numbers or Excel. It can't be imported back – your workouts are kept on your devices and in iCloud. Export Full Backup saves everything in one file you can restore; George also keeps its last 8 backups on this device (weekly and before every import), outside iCloud.")
            })
        }
    }
}
