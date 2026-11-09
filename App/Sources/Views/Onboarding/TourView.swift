import SwiftUI
import BinisoftKit
import SwiftData
import GeorgeCore

/// Set on the tour's practice page: Start there is only recorded, it never starts a real workout.
@MainActor
@Observable
final class PracticeSession {
    var startTapped = false
}

/// Everything the practice page runs on: its own in-memory store (sample program, never synced),
/// its own router and muscle analytics. The real live workout, Health and Watch stay untouched.
@MainActor
private final class PracticeEnvironment {
    let container: ModelContainer
    let store: GeorgeStore
    let router = Router()
    let muscles: MuscleAnalytics
    let session = PracticeSession()
    let toasts = ToastCenter()
    let templateID: UUID?

    init(library: ExerciseLibrary) {
        container = Persistence.practiceStore()
        store = GeorgeStore(container: container)
        muscles = MuscleAnalytics(store: store, library: library)
        templateID = store.activeProgram?.orderedTemplates.first?.id
    }
}

/// The hands-on tour: the real template screen on a practice copy, with the coach card on top.
/// Each step watches the page and ticks itself off once you've done what it describes.
struct TourView: View {
    let request: TourRequest
    let onFinish: () -> Void

    @Environment(ExerciseLibrary.self) private var library
    @State private var practice: PracticeEnvironment?

    var body: some View {
        Group {
            if let practice {
                PracticePage(steps: request.steps, startAt: request.startAt, templateID: practice.templateID, onFinish: onFinish)
                    .environment(practice.store)
                    .environment(practice.router)
                    .environment(practice.muscles)
                    .environment(practice.session)
                    .environment(practice.toasts)
                    .modelContainer(practice.container)
                    .toasts(practice.toasts, bottomPadding: 90)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            guard practice == nil else { return }
            practice = PracticeEnvironment(library: library)
            AppLog.info("Tour started (\(request.steps.count) steps)", category: "tour")
        }
    }
}

private struct PracticePage: View {
    let steps: [TourStep<GeorgeTourSnapshot>]
    let startAt: String?
    let templateID: UUID?
    let onFinish: () -> Void

    @Environment(GeorgeStore.self) private var store
    @Environment(PracticeSession.self) private var session
    @Query private var templates: [WorkoutTemplate]

    var body: some View {
        NavigationStack {
            Group {
                if let templateID {
                    // Inside the stack, so the coach sits below the navigation bar and the toolbar stays reachable.
                    TemplateDetailView(templateID: templateID)
                } else {
                    MessageView(title: "Practice page unavailable", systemImage: "graduationcap",
                                message: "The practice program couldn't be loaded.")
                }
            }
            .tourCoach(steps: steps, snapshot: snapshot, startAt: startAt, onClose: onFinish)
        }
    }

    private var snapshot: GeorgeTourSnapshot {
        let template = templates.first { $0.id == templateID }
        return GeorgeTourSnapshot(content: template?.content ?? WorkoutContent(), unit: store.unit, startTapped: session.startTapped)
    }
}
