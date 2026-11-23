import SwiftUI
import BinisoftKit
import GeorgeCore

/// "Still training?" at the top of Today: the running workout has had no sets for three hours
/// (left running after the gym). Finish opens the finish sheet set to end at the last set + rest;
/// Continue keeps it running. Live mode doesn't open by itself for such a workout.
struct StillTrainingBanner: View {
    @Environment(LiveWorkoutController.self) private var live

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let end = live.stillTrainingEnd(at: context.date) {
                banner(end: end)
                    .padding(.bottom, 12)
            } else {
                // Nothing to say: no size (the parent stacks it with spacing 0), but still here, so the
                // clock above keeps checking.
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }

    private func banner(end: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Still training?", systemImage: "clock.badge.questionmark")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    live.finishLeftRunningWorkout()
                } label: {
                    Text("Finish at \(end.formatted(date: .omitted, time: .shortened))")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                Button {
                    live.continueLeftRunningWorkout()
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 0, cornerRadius: 22)
    }

    private var message: String {
        let title = live.session?.title ?? "Your workout"
        return "\u{201C}\(title)\u{201D} is still running, with no sets for hours."
    }
}
