import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// Small cross-platform helpers (from Finn's Platform.swift) so app code stays free of #if.

public extension View {
    /// Inline title on iPhone/iPad; no-op elsewhere.
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Sheets: medium/large detents on iPhone, a sensible minimum size on the Mac.
    @ViewBuilder
    func sheetFrame(minWidth: CGFloat = 460, minHeight: CGFloat = 520) -> some View {
        #if os(macOS)
        self.frame(minWidth: minWidth, idealWidth: minWidth + 60, minHeight: minHeight, idealHeight: minHeight + 120)
        #else
        self
        #endif
    }

    /// Hides the tab bar while scrolling down (iPhone).
    @ViewBuilder
    func minimizingTabBar() -> some View {
        #if os(iOS)
        self.tabBarMinimizeBehavior(.onScrollDown)
        #else
        self
        #endif
    }
}

public enum Clipboard {
    public static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    public static var string: String? {
        #if os(iOS)
        UIPasteboard.general.string
        #elseif os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        nil
        #endif
    }
}

public enum PlatformInfo {
    public static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    @MainActor
    public static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    @MainActor
    public static var name: String {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #elseif os(macOS)
        "macOS"
        #elseif os(watchOS)
        "watchOS"
        #else
        "unknown"
        #endif
    }

    /// Hardware model, e.g. "iPhone17,1" or "Mac15,6".
    public static var model: String {
        #if os(macOS)
        let key = "hw.model"
        #else
        let key = "hw.machine"
        #endif
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map { String(cString: $0) } ?? "unknown"
        }
    }
}
