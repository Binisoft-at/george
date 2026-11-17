import SwiftUI
import BinisoftKit
import GeorgeCore

/// Plans → Stretch & Yoga Routines: ready-made routines to add as a template (then start, edit or
/// share them like any template).
struct RoutinesView: View {
    @Environment(ExerciseLibrary.self) private var library

    var body: some View {
        List {
            Section {
                ForEach(RoutineLibrary.all) { routine in
                    NavigationLink {
                        RoutineDetailView(routine: routine)
                    } label: {
                        RoutineRow(routine: routine, content: routine.content(using: library.catalog))
                    }
                }
            } footer: {
                Text("Start a routine right away, or add it to your templates (program “Stretch & Yoga”) to change holds and moves, plan it or share it as a PDF or George file. To build your own: + → New Template, then add stretches from the Exercise Library.")
            }
        }
        .groupedList()
        .navigationTitle("Stretch & Yoga")
    }
}

struct RoutineRow: View {
    let routine: Routine
    let content: WorkoutContent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: routine.symbol)
                .font(.title3)
                .foregroundStyle(routine.kind.color)
                .frame(width: 40, height: 40)
                .background(routine.kind.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(routine.name).font(.headline)
                Text("\(routine.subtitle) · \(content.allItems.count) moves · \(Format.minutes(Double(content.estimatedSeconds())))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

struct RoutineDetailView: View {
    let routine: Routine
    @Environment(GeorgeStore.self) private var store
    @Environment(ExerciseLibrary.self) private var library
    @Environment(LiveWorkoutController.self) private var live
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        let content = routine.content(using: library.catalog)
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(routine.subtitle, systemImage: routine.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(routine.kind.color)
                    Text("\(content.allItems.count) moves · about \(Format.minutes(Double(content.estimatedSeconds())))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section("Moves") {
                ForEach(content.allItems) { item in
                    HStack(spacing: 12) {
                        ExerciseThumb(urls: library.imageURLs(for: item), symbol: (item.kind ?? routine.kind).symbol, tint: routine.kind.color, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.subheadline.weight(.semibold))
                            Text(item.prescription(unit: store.unit)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button {
                    let template = add(content)
                    store.requestStart(template, live: live, toasts: toasts)
                } label: {
                    Label("Start Now", systemImage: "play.fill")
                }
                Button {
                    let template = add(content)
                    router.open(.template(template.id))
                } label: {
                    Label("Add to My Templates", systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text("Added to the program “Stretch & Yoga” (created if needed). From the template you can share it as a PDF or George file.")
            }
        }
        .groupedList()
        .navigationTitle(routine.name)
        .inlineTitle()
    }

    /// The routine's template in "Stretch & Yoga" (reused when it was added before).
    private func add(_ content: WorkoutContent) -> WorkoutTemplate {
        let result = store.templateForRoutine(routine, catalog: library.catalog)
        if result.created { toasts.show("Added “\(routine.name)”") }
        return result.template
    }
}
