import SwiftUI
import GeorgeCore

extension LiveWorkoutController.StartTarget {
    /// Why this can't start on this device (nil: it can): its stored workout can't be read, or a newer
    /// George wrote it – live mode would run it empty or stripped and save that over the real one.
    var contentRefusal: String? {
        let state: StoredContent.ReadState
        switch self {
        case .template(let template): state = template.contentReadState
        case .session(let session): state = session.contentReadState
        default: return nil // an empty workout has nothing stored yet
        }
        switch state {
        case .readable: return nil
        case .newer: return "Update George on this device to start this workout"
        case .unreadable: return "Can't read this workout, so it can't start"
        }
    }
}

/// Shown instead of the workout editor when the stored workout can't be read on this device, or a
/// newer George wrote it (`StoredContent.ReadState`): why, and – when it can be read – its exercises,
/// read-only. Never an empty editor whose first change would overwrite the real workout.
struct ReadOnlyContentSection: View {
    let state: StoredContent.ReadState
    let content: WorkoutContent
    @Environment(GeorgeStore.self) private var store

    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title)
                        .font(.headline)
                    Text(state.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: state == .unreadable ? "exclamationmark.triangle.fill" : "lock.fill")
                    .foregroundStyle(Tone.cautionText)
            }
            .padding(.vertical, 4)
        }
        if !content.isEmpty {
            Section {
                ForEach(content.allItems) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.body.weight(.semibold))
                        Text(item.prescription(unit: store.unit))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Exercises")
            } footer: {
                Text(content.summary(unit: store.unit))
            }
        }
    }
}
