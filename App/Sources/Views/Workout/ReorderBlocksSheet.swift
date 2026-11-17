import SwiftUI
import BinisoftKit
import GeorgeCore

/// Drag exercises (and supersets, as one) into a new order. A moved exercise joins the section it
/// lands in. Used by templates, workouts and live mode: `ReorderBlocksSheet(content: $content)`.
struct ReorderBlocksSheet: View {
    @Binding var content: WorkoutContent
    @Environment(GeorgeStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(content.blocks.enumerated()), id: \.element.id) { index, block in
                        row(block, index: index)
                    }
                    .onMove { source, destination in
                        withAnimation(.snappy) {
                            content.moveBlocksAdoptingSection(fromOffsets: source, toOffset: destination)
                        }
                        Haptics.tap()
                    }
                } footer: {
                    Text("Drag the handles. Supersets and circuits move as one; sets already done stay with their exercise.")
                }
            }
            .groupedList()
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle("Reorder")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func row(_ block: WorkoutBlock, index: Int) -> some View {
        let previous = index > 0 ? content.blocks[index - 1].section : nil
        let showsSection = block.section != nil && block.section != previous
        return VStack(alignment: .leading, spacing: 2) {
            if showsSection, let section = block.section {
                Text(section)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if block.items.count > 1 {
                    Image(systemName: block.style.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Text(block.items.map(\.name).joined(separator: " + "))
                    .font(.body.weight(.medium))
                    .lineLimit(2)
            }
            if block.items.count == 1, let item = block.items.first {
                Text(item.prescription(unit: store.unit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(block.style.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
