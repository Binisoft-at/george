import Foundation

/// One day of recovery signals from Apple Health (any may be missing).
public struct DailyHealthSignal: Equatable, Sendable {
    public var day: Date
    /// Heart-rate variability (SDNN), milliseconds – average of the day.
    public var hrvMs: Double?
    /// Resting heart rate, beats per minute.
    public var restingHeartRate: Double?
    /// Sleep that ended on this day, hours.
    public var sleepHours: Double?

    public init(day: Date, hrvMs: Double? = nil, restingHeartRate: Double? = nil, sleepHours: Double? = nil) {
        self.day = day
        self.hrvMs = hrvMs
        self.restingHeartRate = restingHeartRate
        self.sleepHours = sleepHours
    }
}

/// How ready the body looks today compared with its own usual (the last 30 days): lower HRV,
/// higher resting heart rate and short sleep all point to a calmer day. A hint, not a diagnosis.
public struct BodyReadiness: Equatable, Sendable {
    /// Today's HRV against the usual, as a fraction (−0.15 = 15 % below).
    public var hrvChange: Double?
    /// Today's resting heart rate against the usual, in bpm.
    public var restingHeartRateChange: Double?
    /// Last night's sleep in hours.
    public var sleepHours: Double?
    /// −3 (take it easy) … +3 (well recovered).
    public var score: Int

    public var suggestedIntensity: CoachIntensity {
        if score <= -2 { return .calm }
        if score >= 2 { return .hype }
        return .normal
    }

    /// Energy level (1–5) the signals suggest, for prefilling the check-in.
    public var suggestedEnergy: Int { min(5, max(1, 3 + score)) }

    /// "HRV 15 % below your usual · resting HR +6 · 5.8 h sleep"
    public var summary: String {
        var parts: [String] = []
        if let hrvChange {
            let percent = Int((abs(hrvChange) * 100).rounded())
            parts.append(percent < 5 ? "HRV as usual" : "HRV \(percent) % \(hrvChange < 0 ? "below" : "above") your usual")
        }
        if let change = restingHeartRateChange {
            let bpm = Int(change.rounded())
            parts.append(abs(bpm) < 2 ? "resting HR as usual" : "resting HR \(bpm > 0 ? "+" : "")\(bpm)")
        }
        if let sleepHours {
            parts.append("\(Format.number((sleepHours * 10).rounded() / 10)) h sleep")
        }
        return parts.joined(separator: " · ")
    }

    public var headline: String {
        switch score {
        case ...(-2): return "Your body says: take it easy today"
        case -1: return "A little below your usual"
        case 0: return "About your usual"
        case 1: return "Well recovered"
        default: return "Ready to push"
        }
    }

    public static let baselineDays = 30

    /// Compares the most recent day (today, or yesterday when today has nothing yet) with the
    /// median of the 30 days before it. Needs at least a week of history for HRV or resting HR.
    public static func evaluate(_ signals: [DailyHealthSignal], now: Date = Date(), calendar: Calendar) -> BodyReadiness? {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.addingDays(-1, to: today)
        let sorted = signals.sorted { $0.day < $1.day }
        guard let latest = sorted.last(where: { calendar.startOfDay(for: $0.day) >= yesterday }) else { return nil }
        let latestDay = calendar.startOfDay(for: latest.day)
        let baselineStart = calendar.addingDays(-baselineDays, to: latestDay)
        let history = sorted.filter { $0.day >= baselineStart && calendar.startOfDay(for: $0.day) < latestDay }

        var hrvChange: Double?
        let hrvHistory = history.compactMap(\.hrvMs)
        if let hrv = latest.hrvMs, hrvHistory.count >= 7, let usual = median(hrvHistory), usual > 0 {
            hrvChange = hrv / usual - 1
        }
        var restingChange: Double?
        let restingHistory = history.compactMap(\.restingHeartRate)
        if let resting = latest.restingHeartRate, restingHistory.count >= 7, let usual = median(restingHistory) {
            restingChange = resting - usual
        }
        let sleep = sorted.last(where: { calendar.startOfDay(for: $0.day) == today && $0.sleepHours != nil })?.sleepHours
            ?? latest.sleepHours
        guard hrvChange != nil || restingChange != nil || sleep != nil else { return nil }

        var score = 0
        if let hrvChange {
            if hrvChange <= -0.15 { score -= 1 }
            if hrvChange >= 0.1 { score += 1 }
        }
        if let restingChange {
            if restingChange >= 5 { score -= 1 }
            if restingChange <= -3 { score += 1 }
        }
        if let sleep {
            if sleep < 6 { score -= 1 }
            if sleep >= 7.5 { score += 1 }
        }
        return BodyReadiness(hrvChange: hrvChange, restingHeartRateChange: restingChange, sleepHours: sleep, score: min(3, max(-3, score)))
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

public extension EnergyEntry {
    /// An Apple Health "State of Mind" valence (−1 very unpleasant … 1 very pleasant) as an energy
    /// level 1–5 – a stand-in for history from before George asked.
    static func level(fromValence valence: Double) -> Int {
        min(5, max(1, Int(((valence + 1) * 2).rounded()) + 1))
    }
}

public extension EnergyAnalysis {
    /// Pearson correlation between daily energy and another daily series (e.g. HRV or sleep);
    /// nil with fewer than 8 shared days.
    static func correlation(entries: [EnergyEntry], series: [(date: Date, value: Double)], calendar: Calendar) -> Double? {
        var byDay: [Date: [Int]] = [:]
        for entry in entries { byDay[calendar.startOfDay(for: entry.date), default: []].append(entry.level) }
        var pairs: [(Double, Double)] = []
        for item in series {
            if let levels = byDay[calendar.startOfDay(for: item.date)] {
                pairs.append((Double(levels.reduce(0, +)) / Double(levels.count), item.value))
            }
        }
        guard pairs.count >= 8 else { return nil }
        return pearson(pairs.map(\.0), pairs.map(\.1))
    }

    /// Plain words for a correlation: "strong", "clear", "slight" or nil when there's none.
    static func strengthWord(_ r: Double) -> String? {
        let a = abs(r)
        if a >= 0.6 { return "strong" }
        if a >= 0.35 { return "clear" }
        if a >= 0.2 { return "slight" }
        return nil
    }
}

/// One finished workout, reduced to what's needed to compare performance.
public struct PerformanceSample: Equatable, Sendable {
    public var date: Date
    /// Which workouts are comparable (same template, or same title).
    public var group: String
    public var volumeKg: Double
    /// Done sets / planned sets, 0…1.
    public var completion: Double

    public init(date: Date, group: String, volumeKg: Double, completion: Double) {
        self.date = date
        self.group = group
        self.volumeKg = volumeKg
        self.completion = completion
    }
}

public extension EnergyAnalysis {
    /// How each workout went compared with the usual for the same workout: volume against the
    /// median volume of its group (1.1 = 10 % more than usual), or the share of sets done when
    /// there's no weight. Groups with a single workout are left out.
    static func relativePerformance(_ samples: [PerformanceSample]) -> [(date: Date, value: Double)] {
        let groups = Dictionary(grouping: samples, by: \.group).filter { $0.value.count >= 2 }
        var result: [(date: Date, value: Double)] = []
        for (_, items) in groups {
            let volumes = items.map(\.volumeKg).filter { $0 > 0 }
            if volumes.count >= 2, let usual = BodyReadiness.median(volumes), usual > 0 {
                for item in items where item.volumeKg > 0 { result.append((item.date, item.volumeKg / usual)) }
            } else {
                for item in items { result.append((item.date, item.completion)) }
            }
        }
        return result.sorted { $0.date < $1.date }
    }
}
