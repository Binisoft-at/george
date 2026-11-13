import Foundation

/// The line on the finish screen – written for George (no borrowed quotes), picked to fit the
/// workout: a record, a low-energy day, a long streak, stopping early, or just a good session.
public enum FinishQuote {
    public struct Context: Sendable {
        public var hasRecord: Bool
        public var energyBefore: Int
        public var streakWeeks: Int
        public var completion: Double
        public var minutes: Int

        public init(hasRecord: Bool = false, energyBefore: Int = 0, streakWeeks: Int = 0, completion: Double = 1, minutes: Int = 45) {
            self.hasRecord = hasRecord
            self.energyBefore = energyBefore
            self.streakWeeks = streakWeeks
            self.completion = completion
            self.minutes = minutes
        }
    }

    static let records = [
        "Records don't happen by accident. You built this one set by set.",
        "Yesterday's limit is today's warm-up.",
        "New best. Remember this feeling next time it gets heavy.",
    ]
    static let lowEnergy = [
        "You showed up on a hard day. Those count double.",
        "Low battery, full effort. That's what discipline looks like.",
        "The days you didn't feel like it are the ones that make you.",
    ]
    static let streak = [
        "Week %d of your streak. Consistency is your superpower.",
        "%d weeks in a row. This isn't motivation any more – it's who you are.",
    ]
    static let partial = [
        "Something beats nothing – every single time.",
        "You kept the habit alive. That's the part that matters.",
    ]
    static let long = [
        "That was serious work. Eat well, sleep well – recovery is where you grow.",
    ]
    static let general = [
        "Strong isn't a feeling. It's a habit – and you just fed it.",
        "One more workout in the bank. Compound interest for your body.",
        "You didn't wait for motivation. You built it.",
        "The weights don't care how you felt. They only know you showed up.",
        "Small steps every week. That's what big changes look like up close.",
        "Today's hard sets are tomorrow's warm-ups.",
        "Done is the best feeling in the gym.",
    ]

    /// A line for this workout; `seed` varies it between workouts (e.g. the session id's hash).
    public static func pick(_ context: Context, seed: Int) -> String {
        let index = abs(seed)
        if context.hasRecord { return records[index % records.count] }
        if (1...2).contains(context.energyBefore) { return lowEnergy[index % lowEnergy.count] }
        if context.completion < 0.75 { return partial[index % partial.count] }
        if context.streakWeeks >= 3 && index % 2 == 0 {
            return String(format: streak[index % streak.count], context.streakWeeks)
        }
        if context.minutes >= 75 { return long[index % long.count] }
        return general[index % general.count]
    }
}
