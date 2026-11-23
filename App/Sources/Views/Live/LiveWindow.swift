#if os(macOS)
import SwiftUI
import AppKit

/// Mac: live mode is a window of its own ("Workout") – the plan, the history and the muscles stay
/// usable in the main window next to it. Closing it only hides live mode: the workout keeps running,
/// and the bar at the bottom of the main window or Workout → Show Live Workout (⌘↩) bring it back.
///
/// `LiveWorkoutController.isPresented` means "live mode is in front" here: the workout window is
/// open and the main window of the app. It turns false when another window comes in front (or the
/// workout window closes), so every Start, Open or Continue that sets it again brings the window
/// forward (`LiveWindowPresenter`). iPhone and iPad show live mode as a full-screen cover instead.
enum LiveWindow {
    static let id = "live"
}

/// The workout window's content.
struct LiveWindowRoot: View {
    @Environment(LiveWorkoutController.self) private var live
    @Environment(Router.self) private var router
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        LiveWorkoutView()
            .frame(minWidth: 560, idealWidth: 860, minHeight: 640, idealHeight: 840)
            .navigationTitle(live.session?.title ?? "Workout")
            // A CSV opened from Finder goes to the main window, never here.
            .handlesExternalEvents(preferring: [], allowing: [])
            .background {
                WindowStateObserver(
                    onMainChange: { isMain in
                        if isMain { router.liveWindowIsOpen = true }
                        // In front: live mode shows. Behind another window: the main window's bar shows.
                        let shown = isMain && live.isActive
                        if live.isPresented != shown { live.isPresented = shown }
                    },
                    onClose: { closed() }
                )
            }
            .onAppear {
                router.liveWindowIsOpen = true
                if !live.isActive { closeWhenIdle() }
            }
            .onDisappear { closed() }
            // Finished, discarded or ended on another device: the window goes.
            .onChange(of: live.isActive) { _, active in
                if !active { closeWhenIdle() }
            }
    }

    /// Closes the window once its sheets have closed (LiveWorkoutView) – not when "Save It and
    /// Start …" starts the next workout right away.
    private func closeWhenIdle() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !live.isActive { dismissWindow(id: LiveWindow.id) }
        }
    }

    /// The window closed (its close button, ⌘W, the hide button or the end of the workout).
    private func closed() {
        guard router.liveWindowIsOpen else { return }
        router.liveWindowIsOpen = false
        if live.isPresented { live.isPresented = false }
        // The workout ended: the celebration (or the Undo of a discard) shows in the main window –
        // it opens again if it was closed, instead of George being left without a window.
        if !live.isActive, router.mainWindowCount == 0 {
            openWindow(id: "main")
        }
    }
}

/// Main window: opens the workout window whenever live mode is asked for – a Start, the bar at the
/// bottom, Open or Finish… from a list, Siri – and brings it forward when it is behind.
struct LiveWindowPresenter: ViewModifier {
    @Environment(LiveWorkoutController.self) private var live
    @Environment(Router.self) private var router
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onAppear {
                // Live mode was asked for before this window was there (launch, a reopened window) –
                // not when the workout window is open already (it stays where it is).
                if live.isPresented && !router.liveWindowIsOpen { openWindow(id: LiveWindow.id) }
            }
            .onChange(of: live.isPresented) { _, shown in
                if shown { openWindow(id: LiveWindow.id) }
            }
            // Finish…, Discard… or Add Exercise while the workout window is behind: it comes forward,
            // and live mode opens what was asked for.
            .onChange(of: live.finishRequest || live.discardRequest || live.requestAddExercise) { _, requested in
                if requested { openWindow(id: LiveWindow.id) }
            }
    }
}

/// The main window that was in front last (Mac): menu commands and Settings bring it forward before
/// they show something there – it may be behind the workout window.
@MainActor
enum MainWindowFront {
    private static weak var window: NSWindow?

    static func note(_ window: NSWindow) {
        self.window = window
    }

    static func bringForward() {
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        } else if !window.isVisible {
            return
        }
        window.makeKeyAndOrderFront(nil)
    }
}

/// Watches the window around it (AppKit): whether it is the app's main window, and when it closes –
/// SwiftUI's `onDisappear` isn't called for the last window that closes. Sheets and popovers on the
/// window don't change its main-window status.
struct WindowStateObserver: NSViewRepresentable {
    var onMainChange: @MainActor (Bool) -> Void = { _ in }
    let onClose: @MainActor () -> Void
    /// The window itself, each time it becomes the main window.
    var onBecameMain: @MainActor (NSWindow) -> Void = { _ in }

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        update(view)
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        update(view)
    }

    @MainActor
    private func update(_ view: ObserverView) {
        view.onMainChange = onMainChange
        view.onClose = onClose
        view.onBecameMain = onBecameMain
    }

    final class ObserverView: NSView {
        var onMainChange: (@MainActor (Bool) -> Void)?
        var onClose: (@MainActor () -> Void)?
        var onBecameMain: (@MainActor (NSWindow) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        /// Only listens – clicks go to the content in front of it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            for token in tokens { center.removeObserver(token) }
            tokens = []
            guard let window else { return }
            if window.isMainWindow { onBecameMain?(window) }
            tokens.append(center.addObserver(forName: NSWindow.didBecomeMainNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onMainChange?(true)
                    if let window = self.window { self.onBecameMain?(window) }
                }
            })
            tokens.append(center.addObserver(forName: NSWindow.didResignMainNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onMainChange?(false) }
            })
            tokens.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClose?() }
            })
        }
    }
}
#endif
