#if os(macOS)
import AppKit
import CoreServices
import SwiftUI
import BinisoftKitCore

/// macOS can finish launching a SwiftUI app without opening its main window (seen in Theo and in
/// the template's CI screenshots). Use this as the app delegate:
///
///     @NSApplicationDelegateAdaptor(MainWindowGuard.self) private var windowGuard
///
/// and add `.defaultLaunchBehavior(.presented)` to the main WindowGroup. If shortly after launch
/// there is still no window, it sends the app the same "reopen" Apple event a click on the Dock
/// icon sends, which makes SwiftUI open one. (From Theo.)
public final class MainWindowGuard: NSObject, NSApplicationDelegate {
    @MainActor
    public static var hasVisibleWindow: Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Self.hasVisibleWindow else { return }
            AppLog.notice("No window after launch – sending a reopen event", category: "launch")
            NSApp.activate()
            let target = NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier)
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(kCoreEventClass),
                eventID: AEEventID(kAEReopenApplication),
                targetDescriptor: target,
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            do {
                _ = try event.sendEvent(options: [.noReply], timeout: 2)
            } catch {
                AppLog.warning("Reopen event failed: \(error.localizedDescription)", category: "launch")
            }
        }
    }
}
#endif
