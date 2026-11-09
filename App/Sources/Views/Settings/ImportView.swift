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
    /// Set when a CSV is opened from another app.
    static var pendingURL: URL?

    @Environment(GeorgeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Program.sortIndex) private var programs: [Program]

    @State private var showFilePicker = false
    @State private var text = ""
    @State private var fileName = ""
    @State private var result: CSVImportResult?
    @State private var errorMessage: String?
    @State private var targetProgramID: UUID?
    @State private var replaceExisting = true
    @State private var copiedPrompt = false

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
                Section("Import Into") {
                    Picker("Program", selection: $targetProgramID) {
                        Text(result.programs.count == 1 ? "New / matching program “\(result.programs[0].name)”" : "New / matching programs").tag(UUID?.none)
                        ForEach(programs) { program in
                            Text(program.name).tag(Optional(program.id))
                        }
                    }
                    Toggle("Replace templates with the same name", isOn: $replaceExisting)
                }
                let workoutCount: Int = result.programs.reduce(0) { $0 + $1.workouts.count }
                Section {
                    Button {
                        performImport(result)
                    } label: {
                        Label("Import \(workoutCount) Workouts", systemImage: "square.and.arrow.down.fill")
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
        .onAppear {
            if let url = ImportView.pendingURL {
                ImportView.pendingURL = nil
                load(url: url)
            }
        }
    }

    @ViewBuilder
    private func previewSection(_ result: CSVImportResult) -> some View {
        Section {
            ForEach(result.programs, id: \.name) { program in
                VStack(alignment: .leading, spacing: 6) {
                    Label(program.name, systemImage: "folder.fill")
                        .font(.headline)
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
                            Text("\(workout.content.exerciseCount) ex.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
        let target = programs.first { $0.id == targetProgramID }
        let created = store.importPrograms(result.programs, into: target, replaceTemplates: replaceExisting)
        AppLog.info("Imported \(created.count) program(s), \(result.programs.reduce(0) { $0 + $1.workouts.count }) workouts", category: "import")
        if let first = created.first {
            if store.settings.activeProgramID == nil { store.setActive(first) }
            router.show(.program(first.id))
        }
        Haptics.success()
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
