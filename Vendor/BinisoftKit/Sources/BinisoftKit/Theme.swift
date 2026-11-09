import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// Brand theme rules (CONVENTIONS.md → Design):
// - One brand accent colour, taken from the app icon, in the AccentColor asset. It marks primary
//   actions only.
// - Liquid Glass only for floating controls and navigation (bottom accessory, toasts, the tour
//   coach, floating buttons). Content sits on plain cards.
// - Appearance: System / Light / Dark, chosen in Settings.

/// The brand accent (AccentColor asset, the colour of the icon).
public enum Brand {
    public static var accent: Color { Color.accentColor }
}

public enum Appearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public static let storageKey = "binisoft.appearance"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Applies the appearance chosen in Settings.
public struct AppearanceModifier: ViewModifier {
    @AppStorage(Appearance.storageKey) private var raw = Appearance.system.rawValue

    public init() {}

    public func body(content: Content) -> some View {
        content.preferredColorScheme((Appearance(rawValue: raw) ?? .system).colorScheme)
    }
}

public extension View {
    /// System / Light / Dark from Settings. Put it on every window's root (and the Mac Settings scene).
    func appearanceFromSettings() -> some View {
        modifier(AppearanceModifier())
    }

    /// Content card: a plain rounded background, no glass.
    func card(padding: CGFloat = 16, cornerRadius: CGFloat = 22) -> some View {
        self
            .padding(padding)
            .background(Color.cardBackground, in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Liquid Glass for a floating control (toast, bottom bar, coach card). Not for content.
    @ViewBuilder
    func floatingGlass(cornerRadius: CGFloat = 22, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if os(iOS) || os(macOS)
        let glass: Glass = tint.map { Glass.regular.tint($0.opacity(0.35)) } ?? .regular
        self.glassEffect(interactive ? glass.interactive() : glass, in: .rect(cornerRadius: cornerRadius, style: .continuous))
        #else
        self.background(.ultraThinMaterial, in: .rect(cornerRadius: cornerRadius, style: .continuous))
        #endif
    }

    /// The primary action of a screen: prominent, in the brand accent.
    @ViewBuilder
    func primaryActionStyle() -> some View {
        #if os(iOS) || os(macOS)
        self.buttonStyle(.glassProminent).tint(Brand.accent)
        #else
        self.buttonStyle(.borderedProminent).tint(Brand.accent)
        #endif
    }
}

public extension Color {
    /// Grouped screen background on every platform.
    static var groupedBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.black
        #endif
    }

    /// Background of a content card.
    static var cardBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #elseif os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color.gray.opacity(0.2)
        #endif
    }
}

#if os(iOS) || os(macOS)
/// System / Light / Dark picker for Settings.
public struct AppearancePicker: View {
    @AppStorage(Appearance.storageKey) private var raw = Appearance.system.rawValue

    public init() {}

    public var body: some View {
        Picker("Appearance", selection: $raw) {
            ForEach(Appearance.allCases) { appearance in
                Text(appearance.title).tag(appearance.rawValue)
            }
        }
    }
}
#endif
