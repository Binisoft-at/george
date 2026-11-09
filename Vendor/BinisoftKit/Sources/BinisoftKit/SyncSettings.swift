#if os(iOS) || os(macOS)
import SwiftUI
import BinisoftKitCore

/// Settings → "iCloud & Data": sync status dot, account, readable error, and the
/// "Where your data lives" page. From George.
public struct SyncStatusSection<DataPage: View>: View {
    let monitor: SyncMonitor
    let footer: String
    let dataPage: DataPage

    public init(monitor: SyncMonitor, footer: String, @ViewBuilder dataPage: () -> DataPage) {
        self.monitor = monitor
        self.footer = footer
        self.dataPage = dataPage()
    }

    public var body: some View {
        Section {
            LabeledContent("iCloud sync") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(monitor.state.isHealthy ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(monitor.summary)
                }
            }
            if monitor.state.mode.isSynced {
                LabeledContent("iCloud account", value: monitor.state.account.title)
            }
            if let error = monitor.state.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            NavigationLink {
                dataPage
            } label: {
                Label("Where your data lives", systemImage: "lock.icloud")
            }
        } header: {
            Text("iCloud & Data")
        } footer: {
            Text(footer)
        }
        .task { await monitor.refreshAccount() }
    }
}

/// One plain-language fact on the "Where your data lives" page.
public struct DataFact: Identifiable, Sendable {
    public var id: String { title }
    public let symbol: String
    public let title: String
    public let text: String

    public init(_ symbol: String, _ title: String, _ text: String) {
        self.symbol = symbol
        self.title = title
        self.text = text
    }
}

public struct DataSection: Identifiable, Sendable {
    public var id: String { title }
    public let title: String
    public let facts: [DataFact]

    public init(_ title: String, _ facts: [DataFact]) {
        self.title = title
        self.facts = facts
    }

    /// The facts that are true for every Binisoft app (SwiftData + private iCloud database).
    /// - Parameter dataNoun: what the app stores, e.g. "workouts", "tasks".
    public static func standard(appName: String, dataNoun: String) -> [DataSection] {
        [
            DataSection("Your \(dataNoun)", [
                DataFact("iphone", "On your devices", "\(appName) keeps your \(dataNoun) in a database inside the app on each device, so it works offline."),
                DataFact("icloud.fill", "Synced through your iCloud", "Changes travel through your private iCloud database (Apple CloudKit). Only your Apple Account can read it – not Binisoft, not anyone else."),
                DataFact("server.rack", "No \(appName) server", "There's no \(appName) server, login or analytics. Apple's iCloud is the only \u{201C}backend\u{201D}."),
                DataFact("eurosign.circle", "Free", "Syncing costs nothing. It uses a little of your iCloud storage."),
            ]),
            DataSection("Imports and practice data", [
                DataFact("doc.text.magnifyingglass", "Read on this device", "Files you import are read on this device. Nothing is uploaded anywhere except into your own iCloud."),
                DataFact("graduationcap", "Tour and demo data", "The tour's practice page and the demo data live in a separate store that never syncs."),
            ]),
            DataSection("Backup and deleting", [
                DataFact("square.and.arrow.up", "Export", "Settings → Import & Export gives you a CSV of everything."),
                DataFact("trash", "Delete", "Delete the app on every device, then remove \(appName)'s data in Settings → your name → iCloud → Manage Storage (on the Mac: System Settings → Apple Account → iCloud)."),
            ]),
        ]
    }
}

/// Plain-language answer to "where is my data, what's the backend, what does it cost?".
public struct DataLocationView: View {
    let sections: [DataSection]
    let monitor: SyncMonitor

    public init(sections: [DataSection], monitor: SyncMonitor) {
        self.sections = sections
        self.monitor = monitor
    }

    public var body: some View {
        Form {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.facts) { fact in
                        FactRow(fact: fact)
                    }
                }
            }
            Section("Status on this device") {
                LabeledContent("Sync", value: monitor.summary)
                LabeledContent("Storage", value: monitor.state.mode.title)
                if let container = monitor.state.mode.containerID {
                    LabeledContent("iCloud container", value: container)
                }
                switch monitor.state.mode {
                case .local(let reason?), .memory(let reason?):
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
                if let error = monitor.state.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Where Your Data Lives")
        .inlineNavigationTitle()
    }
}

private struct FactRow: View {
    let fact: DataFact

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: fact.symbol)
                .font(.title3)
                .foregroundStyle(Brand.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(fact.title).font(.headline)
                Text(fact.text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
#endif
