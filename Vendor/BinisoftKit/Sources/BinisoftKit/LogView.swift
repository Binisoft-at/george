#if os(iOS) || os(macOS)
import SwiftUI
import Combine
import BinisoftKitCore

/// Settings → Diagnostics → App Log: what the app wrote, newest first, with "Copy log".
public struct LogView: View {
    let appName: String
    let mode: StorageMode?

    @State private var entries: [LogEntry] = []
    @State private var minimum: LogLevel = .info
    @State private var search = ""
    @State private var copied = false

    public init(appName: String, mode: StorageMode? = nil) {
        self.appName = appName
        self.mode = mode
    }

    private var filtered: [LogEntry] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.reversed().filter { entry in
            entry.level >= minimum && (needle.isEmpty
                || entry.message.lowercased().contains(needle)
                || entry.category.lowercased().contains(needle))
        }
    }

    public var body: some View {
        List {
            Section {
                Button {
                    Clipboard.copy(AppLog.exportText(appName: appName, mode: mode))
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy log", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                ShareLink(item: AppLog.exportText(appName: appName, mode: mode)) {
                    Label("Share log", systemImage: "square.and.arrow.up")
                }
                Picker("Show", selection: $minimum) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(level)
                    }
                }
            } footer: {
                Text("The log stays on this device. When something doesn't work, copy it into the chat.")
            }

            Section {
                if filtered.isEmpty {
                    Text("Nothing logged yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(filtered) { entry in
                    LogRow(entry: entry)
                }
            } header: {
                Text("\(filtered.count) entries")
            }
        }
        .searchable(text: $search)
        .navigationTitle("App Log")
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button("Clear", role: .destructive) { AppLog.shared.clear() }
            }
        }
        .onAppear { entries = AppLog.shared.entries }
        .onReceive(NotificationCenter.default.publisher(for: LogBuffer.didChange).receive(on: RunLoop.main)) { _ in
            entries = AppLog.shared.entries
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: entry.level.symbol)
                    .foregroundStyle(color)
                Text(entry.category)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(entry.date, format: .dateTime.day().month().hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(entry.message)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch entry.level {
        case .error: .red
        case .warning: .orange
        case .notice: .blue
        case .info, .debug: .secondary
        }
    }
}
#endif
