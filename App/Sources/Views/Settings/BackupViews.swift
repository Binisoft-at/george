import SwiftUI
import UniformTypeIdentifiers
import BinisoftKit
import GeorgeCore
#if os(macOS)
import AppKit
#endif

/// A backup file for Export Full Backup (JSON, see `BackupArchive`).
struct BackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// A backup opened for restoring, with what restoring it would do.
struct PendingRestore: Identifiable {
    let id = UUID()
    let archive: BackupArchive
    let plan: RestorePlan
    /// Where it came from ("George Backup 2026-11-23", "Weekly backup").
    let source: String
}

/// Settings → Import & Export: Export Full Backup…, Restore from Backup…, Last backup.
/// Each presenter sits on its own row (two file panels on one view don't get along).
struct BackupSettingsRows: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(ToastCenter.self) private var toasts
    @AppStorage(Prefs.lastBackupAt) private var lastBackupAt = 0.0
    @State private var exportFile: BackupFile?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var pending: PendingRestore?
    @State private var errorMessage: String?
    @State private var newestAutomatic: Date?

    var body: some View {
        Button {
            exportBackup()
        } label: {
            Label("Export Full Backup…", systemImage: "externaldrive")
        }
        .fileExporter(isPresented: $showExporter, document: exportFile, contentType: .json, defaultFilename: Self.exportName()) { result in
            switch result {
            case .success:
                lastBackupAt = Date().timeIntervalSinceReferenceDate
                AppLog.info("Full backup exported", category: "backup")
                toasts.show("Backup saved", symbol: "externaldrive.fill")
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { errorMessage = error.localizedDescription }
            }
            exportFile = nil
        }

        Button {
            showImporter = true
        } label: {
            Label("Restore from Backup…", systemImage: "clock.arrow.circlepath")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): open(url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $pending) { pending in
            NavigationStack { RestorePreviewView(pending: pending) }
        }
        .alert("Couldn't open the backup", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }

        NavigationLink {
            AutomaticBackupsView()
        } label: {
            LabeledContent {
                Text(lastBackupText)
            } label: {
                Label("Last backup", systemImage: "clock")
            }
        }
        .task { newestAutomatic = BackupFolder.newestDate() }
    }

    /// "3 days ago", "Never".
    private var lastBackupText: String {
        let newest = max(lastBackupAt, newestAutomatic?.timeIntervalSinceReferenceDate ?? 0)
        guard newest > 0 else { return "Never" }
        return Date(timeIntervalSinceReferenceDate: newest).formatted(.relative(presentation: .named))
    }

    /// "George Backup 2026-11-23" (the extension comes from the file type).
    static func exportName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "George Backup \(formatter.string(from: date))"
    }

    private func exportBackup() {
        do {
            exportFile = BackupFile(data: try store.backupData())
            showExporter = true
        } catch {
            AppLog.error("Backup export failed: \(error.localizedDescription)", category: "backup")
            errorMessage = error.localizedDescription
        }
    }

    private func open(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let archive = try BackupArchive.decode(try Data(contentsOf: url))
            pending = PendingRestore(archive: archive, plan: store.restorePlan(for: archive),
                                     source: url.deletingPathExtension().lastPathComponent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The automatic backups in Documents/Backups: open one to restore it, or back up now.
struct AutomaticBackupsView: View {
    @Environment(GeorgeStore.self) private var store
    @State private var entries: [BackupFolder.Entry] = []
    @State private var pending: PendingRestore?
    @State private var errorMessage: String?
    @State private var isWriting = false

    var body: some View {
        Form {
            Section {
                if entries.isEmpty {
                    Text("No automatic backups yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    Button {
                        open(entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(Color.primary)
                            Text("\(entry.reason.capitalized) · \(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Automatic Backups")
            } footer: {
                Text(footer)
            }
            Section {
                Button {
                    backUpNow()
                } label: {
                    Label(isWriting ? "Backing Up…" : "Back Up Now", systemImage: "externaldrive.badge.plus")
                }
                .disabled(isWriting)
                #if os(macOS)
                if let folder = BackupFolder.url, !entries.isEmpty {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([entries.first?.url ?? folder])
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                }
                #endif
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Backups")
        .inlineTitle()
        .task { reload() }
        .sheet(item: $pending) { pending in
            NavigationStack { RestorePreviewView(pending: pending) }
        }
        .alert("Couldn't open the backup", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var footer: String {
        #if os(iOS)
        return "George keeps \(BackupSchedule.keep): one a week (the last \(BackupSchedule.keepWeekly) always stay), and one before every import or restore. They're also in the Files app: On My iPhone (or iPad) › George › Backups."
        #else
        return "George keeps \(BackupSchedule.keep): one a week (the last \(BackupSchedule.keepWeekly) always stay), and one before every import or restore. Export Full Backup saves one wherever you like."
        #endif
    }

    private func reload() {
        entries = BackupFolder.entries()
    }

    private func backUpNow() {
        isWriting = true
        let task = store.writeAutomaticBackup(reason: .manual)
        Task {
            await task?.value
            isWriting = false
            reload()
        }
    }

    private func open(_ entry: BackupFolder.Entry) {
        do {
            let archive = try BackupArchive.decode(try Data(contentsOf: entry.url))
            pending = PendingRestore(archive: archive, plan: store.restorePlan(for: archive),
                                     source: "\(entry.reason.capitalized) backup")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// What restoring a backup does, then Restore. Nothing is deleted: missing records come back, changes
/// made since stay unless asked for, and a backup of how things are now is written first.
struct RestorePreviewView: View {
    let pending: PendingRestore
    @Environment(GeorgeStore.self) private var store
    @Environment(SyncMonitor.self) private var sync
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var includeChanged = false
    @State private var confirmBeforeSync = false

    /// iCloud hasn't brought this device's data yet (a new device): what it brings later would sit
    /// next to what a restore adds now – two of each, as iCloud can't keep records unique.
    private var iCloudStillLoading: Bool {
        sync.state.mode.isSynced && !store.cloudImportSeen
    }

    var body: some View {
        let plan = pending.plan
        Form {
            Section {
                LabeledContent("Made", value: pending.archive.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Holds", value: pending.archive.summary)
                if !pending.archive.appVersion.isEmpty {
                    LabeledContent("George", value: pending.archive.appVersion)
                }
            } header: {
                Text(pending.source)
            }

            Section {
                row("Comes back", plan.describe { $0.bringBack.count }, symbol: "arrow.uturn.backward.circle")
                if plan.relinkCount > 0 {
                    row("Back in their program", plan.relinkCount == 1 ? "1 item" : "\(plan.relinkCount) items", symbol: "link")
                }
                row("Changed since", plan.describe { $0.changedSince.count }, symbol: "pencil.circle")
                row("Same as now", "\(plan.sameCount)", symbol: "equal.circle")
                if plan.changedSinceCount > 0 {
                    Toggle("Put changed ones back as in the backup", isOn: $includeChanged)
                }
            } header: {
                Text("What a restore does")
            } footer: {
                Text(includeChanged
                     ? "Changed ones get the backup's version, so later edits to them are replaced. Workouts added since stay. A backup of how things are now is saved first."
                     : "Changed ones keep their newer version, and workouts added since stay. A backup of how things are now is saved first.")
            }

            if iCloudStillLoading {
                Section {
                    Label("iCloud hasn't finished loading on this device. Restoring now can show workouts, templates and programs twice. Best wait until it's done.",
                          systemImage: "exclamationmark.icloud")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    if iCloudStillLoading {
                        confirmBeforeSync = true
                    } else {
                        restore()
                    }
                } label: {
                    Label("Restore", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.glassProminent)
                .disabled(!plan.changesSomething(includingChanged: includeChanged))
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                if !plan.changesSomething(includingChanged: includeChanged) {
                    Text("Everything in this backup is here already.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Restore Backup")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        .alert("Restore Before iCloud Is Done?", isPresented: $confirmBeforeSync) {
            Button("Restore Anyway", role: .destructive) { restore() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("What iCloud still brings would show twice.")
        }
    }

    private func row(_ title: String, _ value: String, symbol: String) -> some View {
        LabeledContent {
            Text(value)
                .multilineTextAlignment(.trailing)
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private func restore() {
        let count = store.restoreBackup(pending.archive, includingChanged: includeChanged)
        Haptics.success()
        toasts.show(count == 1 ? "Restored 1 item" : "Restored \(count) items", symbol: "clock.arrow.circlepath")
        dismiss()
    }
}
