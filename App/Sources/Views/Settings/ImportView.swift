import SwiftUI
import BinisoftKit
import SwiftData
import UniformTypeIdentifiers
import GeorgeCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Import a program CSV (from Files, a shared file, or pasted text from another AI).
struct ImportView: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Program.sortIndex) private var programs: [Program]

    @State private var showFilePicker = false
    @State private var text = ""
    @State private var fileName = ""
    @State private var result: CSVImportResult?
    @State private var errorMessage: String?
    @State private var targetProgramID: UUID?
    /// Always off at first – for files and pasted text alike. Turning it on is your choice, and the
    /// import asks once more before it replaces anything.
    @State private var replaceExisting = false
    @State private var copiedPrompt = false
    /// The import waiting for "Replace and Import".
    @State private var confirmReplace: CSVImportResult?

    var body: some View {
        Form {
            Section {
                Button {
                    showFilePicker = true
                } label: {
                    Label("Choose CSV File…", systemImage: "doc.badge.plus")
                }
                Button {
                    pasteFromClipboard()
                } label: {
                    Label("Paste CSV Text", systemImage: "doc.on.clipboard")
                }
                if !fileName.isEmpty {
                    LabeledContent("Loaded", value: fileName)
                }
            } header: {
                Text("Source")
            } footer: {
                Text("Have another AI write your plan in George's CSV format, then paste it here.")
            }

            Section {
                Button {
                    copyPrompt()
                } label: {
                    Label(copiedPrompt ? "Copied!" : "Copy Prompt for Another AI", systemImage: copiedPrompt ? "checkmark" : "sparkles")
                }
                NavigationLink {
                    FormatGuideView()
                } label: {
                    Label("CSV Format Guide", systemImage: "book")
                }
            } header: {
                Text("Let an AI build it")
            } footer: {
                Text("The prompt explains the format. Add your goals, equipment and schedule — or paste your old Apple Notes workouts and ask it to convert them.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            if let result {
                previewSection(result)
                Section {
                    Picker("Program", selection: $targetProgramID) {
                        Text(result.programs.count == 1 ? "New / matching program “\(result.programs[0].name)”" : "New / matching programs").tag(UUID?.none)
                        ForEach(programs) { program in
                            Text(program.name).tag(Optional(program.id))
                        }
                    }
                    Toggle("Replace templates with the same name", isOn: $replaceExisting)
                } header: {
                    Text("Import Into")
                } footer: {
                    Text(replaceExisting
                         ? "A template with the same name gets the imported exercises, notes, tags and weekdays, and program notes are replaced. Its past workouts stay. A backup is saved first, and you can undo right after."
                         : "Nothing of yours is overwritten: a name that's taken gets a number, e.g. “UPPER (2)”, and imported program notes go below yours. A backup is saved first.")
                }
                Section {
                    Button {
                        if replaceExisting && (replaceCount(result) > 0 || replacesNotes(result)) {
                            confirmReplace = result
                        } else {
                            performImport(result)
                        }
                    } label: {
                        Label(importTitle(result), systemImage: "square.and.arrow.down.fill")
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .buttonStyle(.glassProminent)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Import CSV")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.commaSeparatedText, .plainText, .text, .data]) { outcome in
            switch outcome {
            case .success(let url): load(url: url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        // Replacing is never one tap: what goes is said once more.
        .confirmationDialog(
            confirmReplace.map { replaceQuestion($0) } ?? "Replace?",
            isPresented: Binding(get: { confirmReplace != nil }, set: { if !$0 { confirmReplace = nil } }),
            titleVisibility: .visible,
            presenting: confirmReplace
        ) { pending in
            Button("Replace and Import", role: .destructive) { performImport(pending) }
            Button("Cancel", role: .cancel) { confirmReplace = nil }
        } message: { pending in
            Text(replaceCount(pending) > 0
                 ? "Their exercises, notes, tags and weekdays become the imported ones. A backup is saved first, and you can undo right after."
                 : "Your program notes become the imported ones. A backup is saved first, and you can undo right after.")
        }
        // A CSV opened from Finder or another app, or dropped on the window – also one that comes
        // while this sheet is open already.
        .onChange(of: router.importURL, initial: true) { _, url in
            guard let url else { return }
            router.importURL = nil
            load(url: url)
        }
    }

    @ViewBuilder
    private func previewSection(_ result: CSVImportResult) -> some View {
        Section {
            ForEach(result.programs, id: \.name) { program in
                VStack(alignment: .leading, spacing: 6) {
                    Label(program.name, systemImage: "folder.fill")
                        .font(.headline)
                    if let line = notesLine(for: program) {
                        Label(line.text, systemImage: "note.text")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(line.caution ? Tone.cautionText : Color.secondary)
                    }
                    ForEach(program.workouts, id: \.name) { workout in
                        HStack {
                            KindIcon(kind: workout.kind, size: 24)
                            VStack(alignment: .leading) {
                                Text(workout.name).font(.subheadline.weight(.semibold))
                                Text(workout.subtitle.isEmpty ? workout.content.summary(unit: store.unit) : workout.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                tag(for: workout, in: program)
                                Text("\(workout.content.exerciseCount) ex.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning.line > 0 ? "Line \(warning.line): \(warning.message)" : warning.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Preview · \(result.rowCount) rows")
        }
    }

    // MARK: What the import does

    /// The template an imported workout would replace (or collide with), in the program it goes into.
    private func existing(_ workout: ImportedWorkout, in program: ImportedProgram) -> WorkoutTemplate? {
        let target = store.importTarget(for: program, into: programs.first { $0.id == targetProgramID })
        return target?.orderedTemplates.first { $0.name.caseInsensitiveCompare(workout.name) == .orderedSame }
    }

    @ViewBuilder
    private func tag(for workout: ImportedWorkout, in program: ImportedProgram) -> some View {
        if let old = existing(workout, in: program) {
            if replaceExisting {
                Text("Replaces your \(old.name)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Tone.cautionText)
            } else {
                let taken = store.importTarget(for: program, into: programs.first { $0.id == targetProgramID })?.orderedTemplates.map(\.name) ?? []
                Text("New · as \(ImportNaming.uniqueName(workout.name, taken: taken))")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Tone.goodText)
            }
        } else {
            Text("New")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Tone.goodText)
        }
    }

    /// What happens to an existing program's notes ("Program notes will be replaced").
    private func notesLine(for program: ImportedProgram) -> (text: String, caution: Bool)? {
        switch store.notesChange(for: program, into: programs.first { $0.id == targetProgramID }, replace: replaceExisting) {
        case .replace: return ("Program notes will be replaced", true)
        case .append: return ("Program notes are added below yours", false)
        case .set, .unchanged: return nil
        }
    }

    private func replacesNotes(_ result: CSVImportResult) -> Bool {
        result.programs.contains { notesLine(for: $0)?.caution == true }
    }

    /// "Replace UPPER and LOWER?", "Replace 3 templates?", "Replace the program notes?"
    private func replaceQuestion(_ result: CSVImportResult) -> String {
        let names = result.programs.flatMap { program in program.workouts.compactMap { existing($0, in: program)?.name } }
        switch names.count {
        case 0: return "Replace the program notes?"
        case 1: return "Replace your “\(names[0])”?"
        case 2: return "Replace “\(names[0])” and “\(names[1])”?"
        default: return "Replace \(names.count) templates?"
        }
    }

    private func replaceCount(_ result: CSVImportResult) -> Int {
        guard replaceExisting else { return 0 }
        return result.programs.reduce(0) { sum, program in
            sum + program.workouts.filter { existing($0, in: program) != nil }.count
        }
    }

    /// "Import 3 Workouts", "Import 2 · replace 1".
    private func importTitle(_ result: CSVImportResult) -> String {
        let total = result.programs.reduce(0) { $0 + $1.workouts.count }
        let replacing = replaceCount(result)
        if replacing > 0 { return "Import \(total - replacing) · replace \(replacing)" }
        return total == 1 ? "Import 1 Workout" : "Import \(total) Workouts"
    }

    // MARK: Actions

    private func load(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                errorMessage = "Couldn't read the file as text."
                return
            }
            fileName = url.lastPathComponent
            replaceExisting = false
            parse(string, defaultName: url.deletingPathExtension().lastPathComponent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pasteFromClipboard() {
        #if os(iOS)
        let pasted = UIPasteboard.general.string ?? ""
        #else
        let pasted = NSPasteboard.general.string(forType: .string) ?? ""
        #endif
        guard !pasted.isEmpty else {
            errorMessage = "The clipboard is empty."
            return
        }
        // AIs often wrap CSV in ``` fences.
        let cleaned = pasted
            .replacingOccurrences(of: "```csv", with: "")
            .replacingOccurrences(of: "```", with: "")
        fileName = "Pasted text"
        // Like a file: nothing is replaced unless you turn it on (and confirm).
        replaceExisting = false
        parse(cleaned, defaultName: "Imported Program")
    }

    private func parse(_ string: String, defaultName: String) {
        text = string
        do {
            result = try ProgramCSV.parse(string, defaultProgramName: defaultName)
            errorMessage = nil
        } catch {
            result = nil
            errorMessage = error.localizedDescription
        }
    }

    private func performImport(_ result: CSVImportResult) {
        confirmReplace = nil
        let target = programs.first { $0.id == targetProgramID }
        // Everything as it is now goes into Documents/Backups first (Settings → Import & Export).
        store.writeAutomaticBackup(reason: .beforeImport)
        let outcome = store.importProgramsWithUndo(result.programs, into: target, replaceTemplates: replaceExisting)
        AppLog.info("Imported \(outcome.programs.count) program(s), \(outcome.created) new, \(outcome.replaced) replaced", category: "import")
        if let first = outcome.programs.first {
            if store.settings.activeProgramID == nil { store.setActive(first) }
            router.show(.program(first.id))
        }
        Haptics.success()
        let message = outcome.replaced > 0
            ? "Imported \(outcome.created) · replaced \(outcome.replaced)"
            : (outcome.created == 1 ? "Imported 1 workout" : "Imported \(outcome.created) workouts")
        toasts.show(message, symbol: "square.and.arrow.down.fill", undo: outcome.undo)
        dismiss()
    }

    private func copyPrompt() {
        let prompt = FormatGuideView.bundledText(named: "AI_PROMPT") ?? "Write a George CSV."
        #if os(iOS)
        UIPasteboard.general.string = prompt
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        #endif
        copiedPrompt = true
        Haptics.success()
    }
}

/// Renders the bundled CSV format documentation.
struct FormatGuideView: View {
    static func bundledText(named name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    var body: some View {
        ScrollView {
            let text = FormatGuideView.bundledText(named: "CSV_FORMAT") ?? "Format guide not found."
            Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("CSV Format")
        .inlineTitle()
    }
}
