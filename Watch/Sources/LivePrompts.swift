import SwiftUI
import GeorgeCore

/// The coach's question and the energy check-in, when the phone asks for them.
struct LivePrompts: View {
    let live: WatchLiveState

    var body: some View {
        if live.hasPrompt {
            VStack(alignment: .leading, spacing: 6) {
                if let question = live.openQuestion {
                    CoachQuestionCard(question: question)
                }
                if live.showsEnergyCheckIn {
                    EnergyCheckInRow()
                }
            }
        }
    }
}

/// "Bench Press done": muscle fatigue (25–100 %) and reps left (0–3+), one tap each.
private struct CoachQuestionCard: View {
    let question: WatchQuestion
    @Environment(WatchConnector.self) private var connector

    private static let fatigueWords = ["Fresh", "Worked", "Tired", "Spent"]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(question.exerciseName) done")
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if question.asksFatigue {
                Text(question.muscles.isEmpty ? "How fatigued are the muscles?" : "How fatigued are your \(question.muscles)?")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    ForEach(1...4, id: \.self) { quarter in
                        Button {
                            connector.perform(.answerFeedback(setID: question.setID, repsInReserve: nil, fatigue: Double(quarter) / 4))
                        } label: {
                            Text(verbatim: "\(quarter * 25)%")
                        }
                        .buttonStyle(ChipButtonStyle())
                        .accessibilityLabel(Text("\(quarter * 25) percent, \(Self.fatigueWords[quarter - 1])"))
                    }
                }
            }
            if question.asksReps {
                Text("Reps left in the tank?")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(0...3, id: \.self) { reps in
                        Button {
                            connector.perform(.answerFeedback(setID: question.setID, repsInReserve: reps, fatigue: nil))
                        } label: {
                            Text(verbatim: reps == 3 ? "3+" : "\(reps)")
                        }
                        .buttonStyle(ChipButtonStyle())
                        .accessibilityLabel(Text(reps == 3 ? "3 or more reps left" : "\(reps) reps left"))
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.12))
        )
    }
}

/// Energy before the first set, 1 (drained) to 5 (great).
private struct EnergyCheckInRow: View {
    @Environment(WatchConnector.self) private var connector

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How's your energy today?")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { level in
                    Button {
                        connector.perform(.recordEnergy(level))
                    } label: {
                        Text(verbatim: "\(level)")
                    }
                    .buttonStyle(ChipButtonStyle())
                    .accessibilityLabel(Text("Energy \(level) of 5, \(EnergyEntry.label(for: level))"))
                }
            }
            HStack {
                Text(EnergyEntry.label(for: 1))
                Spacer(minLength: 4)
                Text(EnergyEntry.label(for: 5))
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }
}
