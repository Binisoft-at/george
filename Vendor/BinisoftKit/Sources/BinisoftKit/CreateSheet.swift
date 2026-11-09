#if os(iOS) || os(macOS)
import SwiftUI

// One central "+" (George): every way to create something – and "Import my data" – lives in one
// sheet. Featured options are big tiles, the rest are rows. Content is on plain cards; glass is
// left to the navigation layer.

public struct CreateOption: Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let symbol: String
    public let tint: Color
    /// Big tile at the top (the two to four most common things); otherwise a row below.
    public let isFeatured: Bool
    /// Runs when chosen. Usually replaces the create sheet with the next sheet
    /// (`app.sheet = .newItem`), so the create sheet doesn't dismiss itself.
    public let action: () -> Void

    public init(id: String, title: String, subtitle: String, symbol: String, tint: Color = Brand.accent,
                isFeatured: Bool = true, action: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.isFeatured = isFeatured
        self.action = action
    }
}

public struct CreateSheet: View {
    let title: String
    let options: [CreateOption]
    let footnote: String?

    @Environment(\.dismiss) private var dismiss

    public init(title: String = "Create", options: [CreateOption], footnote: String? = nil) {
        self.title = title
        self.options = options
        self.footnote = footnote
    }

    private var featured: [CreateOption] { options.filter(\.isFeatured) }
    private var rows: [CreateOption] { options.filter { !$0.isFeatured } }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(featured) { option in
                            CreateTile(option: option)
                        }
                    }
                    if !rows.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(rows) { option in
                                CreateRow(option: option)
                                if option.id != rows.last?.id {
                                    Divider().padding(.leading, 56)
                                }
                            }
                        }
                        .card(padding: 0)
                    }
                    if let footnote {
                        Label(footnote, systemImage: "lightbulb")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                }
                .padding()
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Color.groupedBackground)
            .navigationTitle(title)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .sheetFrame(minWidth: 520, minHeight: 460)
    }
}

private struct CreateTile: View {
    let option: CreateOption

    var body: some View {
        Button(action: option.action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: option.symbol)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(option.tint)
                    .frame(width: 44, height: 44)
                    .background(option.tint.opacity(0.15), in: .rect(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(option.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .card(padding: 14, cornerRadius: 20)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(option.subtitle))
    }
}

private struct CreateRow: View {
    let option: CreateOption

    var body: some View {
        Button(action: option.action) {
            HStack(spacing: 14) {
                Image(systemName: option.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(option.tint)
                    .frame(width: 30, height: 30)
                    .background(option.tint.opacity(0.15), in: .rect(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.title).foregroundStyle(.primary)
                    Text(option.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Every empty screen offers to create something and to import the person's existing data.
public struct EmptyStateView: View {
    let title: String
    let message: String
    let symbol: String
    let createTitle: String?
    let onCreate: (() -> Void)?
    let onImport: () -> Void

    public init(title: String, message: String, symbol: String, createTitle: String? = nil,
                onCreate: (() -> Void)? = nil, onImport: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.symbol = symbol
        self.createTitle = createTitle
        self.onCreate = onCreate
        self.onImport = onImport
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if let onCreate, let createTitle {
                Button(createTitle, systemImage: "plus", action: onCreate)
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.accent)
            }
            Button("Import my data", systemImage: "square.and.arrow.down", action: onImport)
                .buttonStyle(.bordered)
        }
    }
}
#endif
