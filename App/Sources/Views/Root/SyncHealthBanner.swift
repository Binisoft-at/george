import SwiftUI
import BinisoftKit
import GeorgeCore

/// Saving or syncing doesn't work: a banner at the top of Today (iPhone, iPad) and a line at the
/// bottom of the Mac sidebar – which also says when George last synced. Red when nothing is saved
/// (data is lost on quit), orange for "this device only", a signed-out or unavailable iCloud and a
/// sync error that lasts 15 minutes. Hidden on Today while all is well. A tap opens Settings.
struct SyncHealthBanner: View {
    /// The Mac sidebar footer: always there, compact, "Synced 2 min ago" when all is well.
    var isSidebarFooter = false

    @Environment(SyncMonitor.self) private var sync
    @Environment(GeorgeStore.self) private var store
    @Environment(Router.self) private var router
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let health = current(at: context.date)
            if health.level != .ok {
                Button(action: openSyncSettings) {
                    problem(health)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Settings")
            } else if isSidebarFooter, let line = healthyLine {
                Button(action: openSyncSettings) {
                    Label(line, systemImage: "checkmark.icloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // Nothing to say: no size (the parent stacks it with spacing 0), but still here, so the
                // error clock below keeps running.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        // When the current sync error started (it shows once it lasts).
        .onChange(of: sync.state.lastError, initial: true) { _, error in
            if let error {
                if store.syncErrorSince == nil { store.syncErrorSince = (message: error, since: Date()) }
            } else {
                store.syncErrorSince = nil
            }
        }
    }

    private func current(at now: Date) -> SyncHealth {
        // A save that failed just now is a data problem too (it also shows once as a toast).
        if store.lastSaveError != nil {
            return SyncHealth(level: .critical, title: "Couldn't save – see App Log", detail: "Settings → Diagnostics → App Log.")
        }
        return SyncHealth.evaluate(sync.state, errorSince: store.syncErrorSince?.since, now: now)
    }

    /// "Synced 2 minutes ago" / "Syncing…" (Mac sidebar, iCloud only).
    private var healthyLine: String? {
        guard sync.state.mode.isSynced else { return nil }
        if sync.state.isSyncing { return "Syncing…" }
        if let last = sync.state.lastSync { return "Synced \(last.formatted(.relative(presentation: .named)))" }
        return "iCloud sync on"
    }

    private func problem(_ health: SyncHealth) -> some View {
        let tint: Color = health.level == .critical ? .red : Tone.warning
        let symbol = health.level == .critical ? "exclamationmark.triangle.fill" : "exclamationmark.icloud.fill"
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(isSidebarFooter ? Font.caption.weight(.semibold) : Font.headline)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(health.title)
                    .font(isSidebarFooter ? Font.caption.weight(.semibold) : Font.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let detail = health.detail, !isSidebarFooter {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if !isSidebarFooter {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(isSidebarFooter ? 8 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: isSidebarFooter ? 10 : 18, style: .continuous))
        .contentShape(Rectangle())
        .padding(.horizontal, isSidebarFooter ? 8 : 0)
        .padding(.top, isSidebarFooter ? 6 : 0)
        // On Today it sits above the date line, stacked without spacing.
        .padding(.bottom, isSidebarFooter ? 6 : 12)
        .accessibilityElement(children: .combine)
    }

    /// Settings, where "iCloud & Data" explains the problem and how to fix it.
    private func openSyncSettings() {
        #if os(macOS)
        openSettings()
        #else
        router.showSettings = true
        #endif
    }
}
