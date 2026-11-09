#if os(iOS) || os(macOS)
import SwiftUI
import SwiftData
import Observation

// Undo everywhere (Theo): every delete, move and bulk change shows a toast with Undo, and the
// window's undo manager is attached to the model context so ⌘Z and shake-to-undo work for every
// change, not just text.

public struct Toast: Identifiable, Equatable {
    public let id = UUID()
    public var message: String
    public var symbol: String
    public var undo: (() -> Void)?

    public static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

@MainActor
@Observable
public final class ToastCenter {
    public private(set) var current: Toast?

    public init() {}

    /// Shows a short message; with `undo` it stays a little longer and offers an Undo button.
    public func show(_ message: String, symbol: String = "checkmark.circle.fill", undo: (() -> Void)? = nil) {
        let toast = Toast(message: message, symbol: symbol, undo: undo)
        let delay: Double = undo == nil ? 2.2 : 4.5
        withAnimation(.snappy) { current = toast }
        let id = toast.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.current?.id == id else { return }
            withAnimation(.snappy) { self.current = nil }
        }
    }

    public func performUndo() {
        let undo = current?.undo
        withAnimation(.snappy) { current = nil }
        undo?()
    }

    public func dismiss() {
        withAnimation(.snappy) { current = nil }
    }
}

private struct ToastView: View {
    let toast: Toast
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .foregroundStyle(Brand.accent)
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            if toast.undo != nil {
                Spacer(minLength: 8)
                Button("Undo", action: onUndo)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .floatingGlass(cornerRadius: 24)
        .padding(.horizontal, 16)
        .frame(maxWidth: 520)
        .sensoryFeedback(.success, trigger: toast.id)
    }
}

private struct ToastOverlay: ViewModifier {
    let center: ToastCenter
    let bottomPadding: CGFloat

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = center.current {
                ToastView(toast: toast, onUndo: center.performUndo)
                    .padding(.bottom, bottomPadding)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
    }
}

/// Lets SwiftData record undo steps with the window's undo manager (⌘Z, shake to undo).
private struct ModelUndoModifier: ViewModifier {
    let context: ModelContext
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        content
            .onAppear { context.undoManager = undoManager }
            .onChange(of: undoManager) { _, manager in context.undoManager = manager }
    }
}

public extension View {
    /// Shows the center's toasts at the bottom, above the tab bar.
    func toasts(_ center: ToastCenter, bottomPadding: CGFloat = 72) -> some View {
        modifier(ToastOverlay(center: center, bottomPadding: bottomPadding))
    }

    /// ⌘Z and shake-to-undo for every change in this context.
    func undoableChanges(in context: ModelContext) -> some View {
        modifier(ModelUndoModifier(context: context))
    }
}
#endif
