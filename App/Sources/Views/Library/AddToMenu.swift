import SwiftUI
import BinisoftKit
import SwiftData
import GeorgeCore

/// "Add to…" for an exercise from the library: the running workout (while one runs), then the
/// templates by program, active program first. The exercise starts with the same numbers as when
/// it's added from the picker – last time's working sets, else the library's defaults.
struct AddToMenu: View {
    let exercise: LibraryExercise
    var title = "Add to…"

    var body: some View {
        Menu {
            AddToMenuItems(exercise: exercise)
        } label: {
            Label(title, systemImage: "plus.circle")
        }
    }
}

struct AddToMenuItems: View {
    let exercise: LibraryExercise
    @Environment(GeorgeStore.self) private var store
    @Environment(LiveWorkoutController.self) private var live
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        if live.isActive {
            Button {
                addToLiveWorkout()
            } label: {
                Label("Current Workout", systemImage: "waveform.path.ecg")
            }
            Divider()
        }
        ForEach(programs) { program in
            let templates = program.orderedTemplates
            if !templates.isEmpty {
                Menu {
                    ForEach(templates) { template in
                        Button(template.name) { add(to: template) }
                    }
                } label: {
                    Label(program.name, systemImage: program.symbol)
                }
            }
        }
        let loose = store.fetchTemplates().filter { $0.program == nil }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !loose.isEmpty {
            Menu {
                ForEach(loose) { template in
                    Button(template.name) { add(to: template) }
                }
            } label: {
                Label("No Program", systemImage: "square.on.square")
            }
        }
    }

    /// Non-archived programs, the active one first.
    private var programs: [Program] {
        let all = store.fetchPrograms(includeArchived: false)
        guard let active = store.activeProgram else { return all }
        return [active] + all.filter { $0.id != active.id }
    }

    private func item() -> WorkoutItem {
        let key = exercise.id
        let custom = (try? modelContext.fetch(FetchDescriptor<UserExercise>(predicate: #Predicate { $0.key == key })))?.first
        return store.prefilledItem(from: exercise, custom: custom)
    }

    private func addToLiveWorkout() {
        let newItem = item()
        live.edit { $0.append(items: [newItem], asGroup: false) }
        Haptics.success()
        toasts.show("Added \(exercise.name) to the current workout", symbol: "plus.circle.fill")
    }

    private func add(to template: WorkoutTemplate) {
        store.add([item()], to: template)
        Haptics.success()
        toasts.show("Added \(exercise.name) to \(template.name)", symbol: "plus.circle.fill")
    }
}
