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

/// The printable routine: a George-blue header band, then numbered exercises with how long or how
/// many, the muscles and the key cues. A4 width, white paper, the same blues as the share picture.
struct RoutineSheetView: View {
    let data: RoutineSheetData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(data.rows.enumerated()), id: \.element.id) { index, row in
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(index + 1)")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(BrandPalette.blue))
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.name)
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(BrandPalette.ink)
                                Spacer(minLength: 8)
                                Text(row.prescription)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(BrandPalette.blue)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(BrandPalette.ice, in: Capsule())
                            }
                            if !row.muscles.isEmpty {
                                Text(row.muscles.uppercased())
                                    .font(.system(size: 10, weight: .heavy))
                                    .tracking(1)
                                    .foregroundStyle(BrandPalette.ink.opacity(0.45))
                            }
                            ForEach(row.steps, id: \.self) { step in
                                HStack(alignment: .top, spacing: 6) {
                                    Circle().fill(BrandPalette.sky).frame(width: 5, height: 5).padding(.top, 6)
                                    Text(step)
                                        .font(.system(size: 13))
                                        .foregroundStyle(BrandPalette.ink.opacity(0.85))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    if index < data.rows.count - 1 {
                        Rectangle().fill(BrandPalette.ink.opacity(0.08)).frame(height: 1).padding(.leading, 44)
                    }
                }
                HStack(spacing: 6) {
                    Image("GeorgeMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text("Made with George – your gym buddy")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(BrandPalette.ink.opacity(0.45))
                .padding(.top, 8)
            }
            .padding(36)
        }
        .frame(width: 595, alignment: .leading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image("GeorgeMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("GEORGE · ROUTINE")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.8))
            }
            Text(data.title)
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            if !data.subtitle.isEmpty {
                Text(data.subtitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BrandPalette.ice)
            }
            Text("\(data.rows.count) exercises · about \(data.minutes) min")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [BrandPalette.navy, BrandPalette.royal, BrandPalette.blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
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
