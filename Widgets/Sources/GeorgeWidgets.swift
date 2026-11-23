import WidgetKit
import SwiftUI

/// George's widget extension: Home and Lock Screen widgets (they read the small snapshot the app
/// writes to the shared App Group, see WidgetBridge), the running workout's Live Activity, and
/// the "Start workout" control for Control Center, the Lock Screen and the Action Button.
@main
struct GeorgeWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextWorkoutWidget()
        StreakWidget()
        WorkoutLiveActivity()
        StartWorkoutControl()
    }
}

/// Colours and small pieces every widget shares.
enum WidgetStyle {
    /// The brand blue of the app icon (light and dark variants in the asset catalog).
    static let accent = Color("GeorgeBlue")
}

/// A round badge with the workout kind's symbol.
struct KindBadge: View {
    let symbol: String
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(WidgetStyle.accent.gradient, in: Circle())
            .widgetAccentable()
    }
}

/// This week's days as dots (filled = trained), today ringed.
struct StreakDots: View {
    let streak: WidgetSnapshot.Streak
    let date: Date
    var showsLetters = true
    var dotSize: CGFloat = 10

    var body: some View {
        let dots = streak.dots(on: date)
        let today = streak.todayIndex(on: date)
        let letters = streak.letters()
        HStack(spacing: dotSize * 0.45) {
            ForEach(0..<7, id: \.self) { index in
                let done = index < dots.count && dots[index]
                VStack(spacing: 2) {
                    Circle()
                        .fill(done ? AnyShapeStyle(WidgetStyle.accent) : AnyShapeStyle(.quaternary))
                        .frame(width: dotSize, height: dotSize)
                        .overlay {
                            if today == index {
                                Circle()
                                    .strokeBorder(WidgetStyle.accent, lineWidth: 1.5)
                                    .padding(-3)
                            }
                        }
                        .widgetAccentable(done)
                    if showsLetters {
                        Text(letters[index])
                            .font(.system(size: max(8, dotSize * 0.85), weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(streak.doneDays(on: date)) of \(streak.goal) training days this week")
    }
}
