import Foundation
import Observation
import SwiftData
import GeorgeCore

/// The bundled exercise catalog (free-exercise-db + curated band/yoga/mobility moves)
/// plus the user's own exercises from SwiftData.
@MainActor
@Observable
final class ExerciseLibrary {
    private(set) var catalog: ExerciseCatalog = .empty
    private(set) var isLoaded = false

    func load() async {
        guard !isLoaded else { return }
        let loaded = await Task.detached(priority: .userInitiated) { () -> ExerciseCatalog in
            guard let url = Bundle.main.url(forResource: "exercises", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let catalog = try? ExerciseCatalog(data: data) else {
                return ExerciseCatalog.empty
            }
            return catalog
        }.value
        catalog = loaded
        isLoaded = true
    }

    func exercise(for item: WorkoutItem) -> LibraryExercise? {
        catalog.match(for: item)
    }

    func exercise(id: String) -> LibraryExercise? {
        catalog.exercise(id: id)
    }

    /// Which muscles an exercise trains: library primary (1) + secondary (0.5), the item's own
    /// muscle list overriding the library's primary muscles.
    func contributions(for item: WorkoutItem) -> [MuscleContribution] {
        let match = exercise(for: item)
        let primary = item.muscles.isEmpty ? (match?.primary ?? []) : item.muscles
        let secondary = (match?.secondary ?? []).filter { !primary.contains($0) }
        return MuscleResolver.contributions(primary: primary, secondary: secondary, exerciseName: item.name)
    }

    /// Muscles trained by an item: from the item itself, else from the library.
    func muscles(for item: WorkoutItem) -> [String] {
        if !item.muscles.isEmpty { return item.muscles }
        return catalog.match(for: item)?.primary ?? []
    }

    func imageURLs(for item: WorkoutItem) -> [URL] {
        if let raw = item.imageURL, let url = URL(string: raw) { return [url] }
        guard let exercise = catalog.match(for: item) else { return [] }
        return catalog.imageURLs(for: exercise)
    }

    func imageURLs(for exercise: LibraryExercise) -> [URL] {
        catalog.imageURLs(for: exercise)
    }

    /// Library search merged with custom exercises (custom first).
    func search(_ query: String, kind: WorkoutKind?, muscle: String?, equipment: String?, custom: [UserExercise]) -> [LibraryExercise] {
        let folded = query.lowercased().trimmingCharacters(in: .whitespaces)
        let customMatches = custom
            .filter { $0.isCustom }
            .map(\.asLibraryExercise)
            .filter { exercise in
                (kind == nil || exercise.kind == kind) &&
                (muscle == nil || exercise.primary.contains(muscle!)) &&
                (folded.isEmpty || exercise.name.lowercased().contains(folded))
            }
        return customMatches + catalog.search(query, kind: kind, muscle: muscle, equipment: equipment)
    }
}
