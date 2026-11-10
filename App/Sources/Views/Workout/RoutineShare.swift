import SwiftUI
import UniformTypeIdentifiers
import BinisoftKit
import GeorgeCore

extension GeorgeStore {
    /// One template as a George CSV file (anyone with George can import it).
    func exportCSV(for template: WorkoutTemplate) -> String {
        let workout = ProgramCSV.ExportWorkout(
            name: template.name, subtitle: template.subtitle, kind: template.kind, order: 1,
            scheduleDays: template.scheduleDays, notes: template.notes, content: template.content
        )
        return ProgramCSV.export(programName: template.program?.name ?? template.name, workouts: [workout], unit: unit)
    }
}

/// Everything the routine sheet shows – plain data, so it renders off-screen into a PDF.
struct RoutineSheetData {
    struct Row: Identifiable {
        let id: UUID
        let name: String
        let prescription: String
        let steps: [String]
        let muscles: String
    }

    let title: String
    let subtitle: String
    let minutes: Int
    let rows: [Row]

    @MainActor
    static func make(template: WorkoutTemplate, library: ExerciseLibrary, unit: WeightUnit) -> RoutineSheetData {
        let content = template.content
        let rows = content.allItems.map { item in
            let match = library.exercise(for: item)
            return Row(id: item.id, name: item.name, prescription: item.prescription(unit: unit),
                       steps: Array((match?.steps ?? []).prefix(3)),
                       muscles: library.muscles(for: item).prefix(3).joined(separator: ", "))
        }
        return RoutineSheetData(title: template.name, subtitle: template.subtitle,
                                minutes: max(1, Int((Double(content.estimatedSeconds()) / 60).rounded())), rows: rows)
    }

    /// "Morning Stretch (12 min)\n1. Cat-Cow – 2 × 45s …"
    var text: String {
        var lines = ["\(title) (about \(minutes) min)"]
        if !subtitle.isEmpty { lines.append(subtitle) }
        lines.append("")
        for (index, row) in rows.enumerated() {
            lines.append("\(index + 1). \(row.name) – \(row.prescription)")
            for step in row.steps { lines.append("   • \(step)") }
        }
        lines.append("")
        lines.append("Made with George – your gym buddy")
        return lines.joined(separator: "\n")
    }
}

/// The printable routine: one column, numbered exercises with how long or how many, and the key
/// cues. A4 width.
struct RoutineSheetView: View {
    let data: RoutineSheetData

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(data.title)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                if !data.subtitle.isEmpty {
                    Text(data.subtitle).font(.headline).foregroundStyle(.secondary)
                }
                Text("\(data.rows.count) exercises · about \(data.minutes) min")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(data.rows.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.georgeBlue))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.name).font(.headline)
                        Text(row.prescription).font(.subheadline.weight(.semibold)).foregroundStyle(Color.georgeBlue)
                        if !row.muscles.isEmpty {
                            Text(row.muscles.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(row.steps, id: \.self) { step in
                            Text("• \(step)")
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "dumbbell.fill")
                Text("Made with George – your gym buddy")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(width: 595, alignment: .leading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}

/// A rendered PDF of the routine for the share sheet.
struct RoutinePDF: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { pdf in SentTransferredFile(pdf.url) }
    }

    @MainActor
    static func render(_ data: RoutineSheetData) -> RoutinePDF? {
        let safeName = data.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).pdf")
        let renderer = ImageRenderer(content: RoutineSheetView(data: data))
        var ok = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
            ok = true
        }
        return ok ? RoutinePDF(url: url) : nil
    }
}

/// Template → Share: a PDF for anyone, a George file to import, or plain text.
struct RoutineShareSheet: View {
    let template: WorkoutTemplate
    @Environment(GeorgeStore.self) private var store
    @Environment(ExerciseLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var pdf: RoutinePDF?
    @State private var preview: CGImage?
    @State private var copied = false

    var body: some View {
        let data = RoutineSheetData.make(template: template, library: library, unit: store.unit)
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let preview {
                        Image(decorative: preview, scale: 2)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                    } else {
                        ProgressView().frame(height: 200)
                    }
                    VStack(spacing: 10) {
                        if let pdf {
                            ShareLink(item: pdf, preview: SharePreview("\(template.name).pdf")) {
                                Label("Share as PDF", systemImage: "doc.richtext")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .buttonStyle(.glassProminent)
                        }
                        ShareLink(item: CSVDocument(text: store.exportCSV(for: template), name: template.name),
                                  preview: SharePreview("\(template.name).csv")) {
                            Label("Share as George File", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.glass)
                        Button {
                            Clipboard.copy(data.text)
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy as Text", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.glass)
                    }
                    Text("The PDF works for anyone. The George file opens straight in George (iPhone, iPad, Mac) as a template.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("Share Routine")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                pdf = RoutinePDF.render(data)
                let renderer = ImageRenderer(content: RoutineSheetView(data: data))
                renderer.scale = 2
                preview = renderer.cgImage
            }
        }
    }
}
