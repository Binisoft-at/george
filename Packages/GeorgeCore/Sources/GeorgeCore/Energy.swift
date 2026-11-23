import Foundation

/// How someone felt: 1 (drained) … 5 (full of energy).
public struct EnergyEntry: Equatable, Sendable {
    public var date: Date
    public var level: Int

    public init(date: Date, level: Int) {
        self.date = date
        self.level = min(5, max(1, level))
    }

    public static let labels = ["Drained", "Low", "Okay", "Good", "Great"]
    public static let symbols = ["battery.0percent", "battery.25percent", "battery.50percent", "battery.75percent", "battery.100percent.bolt"]

    public static func label(for level: Int) -> String { labels[min(5, max(1, level)) - 1] }
    public static func symbol(for level: Int) -> String { symbols[min(5, max(1, level)) - 1] }
}

/// A repeating rhythm in someone's energy (e.g. a 4-week cycle).
public struct EnergyCycle: Equatable, Sendable {
    /// Length of one cycle in days.
    public var periodDays: Int
    /// Autocorrelation at that lag, 0…1: 0.3 weak, 0.5 clear.
    public var strength: Double
    /// When the next low point is expected, from the last low and the period.
    public var nextLow: Date?

    public var strengthText: String { strength >= 0.5 ? "clear" : "weak" }
}

public struct EnergyWeek: Equatable, Sendable, Identifiable {
    public var id: Date { weekStart }
    public var weekStart: Date
    public var average: Double
    public var count: Int
}

public struct EnergyInsights: Equatable, Sendable {
    public var weeks: [EnergyWeek]
    /// Calendar weekday (1 = Sunday) → average level.
    public var weekdayAverages: [Int: Double]
    public var bestWeekday: Int?
    public var lowestWeekday: Int?
    /// Change of the weekly average per week over the last six weeks.
    public var trendPerWeek: Double?
    public var cycle: EnergyCycle?
    /// Pearson correlation of energy with workout performance (−1…1), when there's enough data.
    public var performanceCorrelation: Double?
    /// Days with an entry in the analysed window.
    public var daysLogged: Int
    /// What's still missing before a cycle can be judged (nil when there's enough data).
    public var needMoreData: String?
}

/// Looks for patterns in energy check-ins: weekly averages, the best and worst weekday, a trend, a
/// repeating cycle (autocorrelation of the daily series, 5–40 day lags) and how energy goes with
/// workout performance. Honest about too little data.
public enum EnergyAnalysis {
    public static let minimumDays = 30
    public static let minimumSpanDays = 42

    public static func analyze(entries: [EnergyEntry], performance: [(date: Date, value: Double)] = [],
                               calendar: Calendar, now: Date = Date(), windowDays: Int = 180) -> EnergyInsights {
        let windowStart = calendar.addingDays(-windowDays, to: calendar.startOfDay(for: now))
        let recent = entries.filter { $0.date >= windowStart && $0.date <= now }.sorted { $0.date < $1.date }

        // One value per day (average of that day's entries).
        var byDay: [Date: [Int]] = [:]
        for entry in recent { byDay[calendar.startOfDay(for: entry.date), default: []].append(entry.level) }
        let days = byDay.keys.sorted()
        let daily = days.map { (day: $0, value: Double(byDay[$0]!.reduce(0, +)) / Double(byDay[$0]!.count)) }

        // Weeks.
        var byWeek: [Date: [Double]] = [:]
        for d in daily { byWeek[calendar.weekStart(for: d.day), default: []].append(d.value) }
        let weeks = byWeek.keys.sorted().map { start in
            EnergyWeek(weekStart: start, average: byWeek[start]!.reduce(0, +) / Double(byWeek[start]!.count), count: byWeek[start]!.count)
        }

        // Weekdays (need at least two entries each).
        var byWeekday: [Int: [Double]] = [:]
        for d in daily { byWeekday[calendar.component(.weekday, from: d.day), default: []].append(d.value) }
        let weekdayAverages = byWeekday.filter { $0.value.count >= 2 }.mapValues { $0.reduce(0, +) / Double($0.count) }
        var best: Int?
        var lowest: Int?
        if weekdayAverages.count >= 3, let max = weekdayAverages.max(by: { $0.value < $1.value }),
           let min = weekdayAverages.min(by: { $0.value < $1.value }), max.value - min.value >= 0.5 {
            best = max.key
            lowest = min.key
        }

        // Trend over the last six weeks.
        let lastWeeks = weeks.suffix(6)
        var trend: Double?
        if lastWeeks.count >= 3 {
            trend = slope(xs: lastWeeks.indices.map { Double($0) }, ys: lastWeeks.map(\.average))
        }

        // Cycle.
        var cycle: EnergyCycle?
        var needMore: String?
        let span = days.count >= 2 ? calendar.daysBetween(days.first!, days.last!) + 1 : days.count
        if daily.count < minimumDays || span < minimumSpanDays {
            let missingDays = max(0, minimumDays - daily.count)
            needMore = missingDays > 0
                ? "\(missingDays) more check-ins (about \(minimumDays) over 6 weeks) before George can look for a rhythm."
                : "A few more weeks of check-ins before George can look for a rhythm."
        } else {
            cycle = findCycle(daily: daily, calendar: calendar)
        }

        // Performance link.
        var correlation: Double?
        let pairs: [(Double, Double)] = performance.compactMap { item in
            byDay[calendar.startOfDay(for: item.date)].map { levels in (Double(levels.reduce(0, +)) / Double(levels.count), item.value) }
        }
        if pairs.count >= 8 { correlation = pearson(pairs.map(\.0), pairs.map(\.1)) }

        return EnergyInsights(weeks: weeks, weekdayAverages: weekdayAverages, bestWeekday: best, lowestWeekday: lowest,
                              trendPerWeek: trend, cycle: cycle, performanceCorrelation: correlation,
                              daysLogged: daily.count, needMoreData: needMore)
    }

    /// Autocorrelation of the daily series (gaps filled linearly) for lags 5…40 days, careful not to
    /// see a rhythm in chance: the series is detrended first (a straight-line fit – a slow decline or
    /// a step is no rhythm), at least 60 % of the days must be real check-ins, what's left after the
    /// trend must vary by more than rounding (half a level), and a lag counts only when the series
    /// covers it at least two and a half times and its correlation is a real peak – the highest
    /// within a quarter of the lag either side, at least max(0.3, 2/√(n − lag)), below zero somewhere
    /// before it (half a cycle) and still positive at twice the lag. The strongest such lag is the cycle.
    static func findCycle(daily: [(day: Date, value: Double)], calendar: Calendar) -> EnergyCycle? {
        guard let first = daily.first?.day, let last = daily.last?.day else { return nil }
        let length = calendar.daysBetween(first, last) + 1
        // The shortest lag, covered two and a half times.
        guard length >= 13 else { return nil }
        var series = [Double?](repeating: nil, count: length)
        for d in daily { series[calendar.daysBetween(first, d.day)] = d.value }
        let realDays = series.filter { $0 != nil }.count
        guard Double(realDays) >= 0.6 * Double(length) else { return nil }
        let detrended = detrend(interpolate(series))
        let variance = detrended.reduce(0) { $0 + $1 * $1 }
        // A decline in whole levels leaves a saw-tooth of ±0.5 around its line: that's rounding, no rhythm.
        guard variance > 1e-9, (variance / Double(length)).squareRoot() >= 0.5 else { return nil }

        // r for every lag (no n/(n − lag) boost: long lags with little overlap aren't inflated).
        let correlation: [Double] = (0..<length).map { lag in
            var sum = 0.0
            for i in 0..<(length - lag) { sum += detrended[i] * detrended[i + lag] }
            return sum / variance
        }
        let maxLag = min(40, length * 2 / 5)
        var bestLag = 0
        var bestR = 0.0
        for lag in 5...max(5, maxLag) where lag <= maxLag {
            let r = correlation[lag]
            guard r >= max(0.3, 2 / Double(length - lag).squareRoot()) else { continue }
            let reach = max(2, lag / 4)
            let isPeak = !((lag - reach)...(lag + reach)).contains { $0 != lag && $0 < length && correlation[$0] > r }
            guard isPeak, (1..<lag).contains(where: { correlation[$0] < 0 }) else { continue }
            if 2 * lag < length && correlation[2 * lag] <= 0 { continue }
            if r > bestR {
                bestR = r
                bestLag = lag
            }
        }
        guard bestLag > 0 else { return nil }

        // Last low point in the most recent cycle, projected forward.
        let recentWindow = detrended.suffix(bestLag)
        var nextLow: Date?
        // Slice indices are positions in `filled`, i.e. days after `first`.
        if let lowIndex = recentWindow.indices.min(by: { recentWindow[$0] < recentWindow[$1] }) {
            nextLow = calendar.addingDays(lowIndex + bestLag, to: first)
        }
        return EnergyCycle(periodDays: bestLag, strength: min(1, bestR), nextLow: nextLow)
    }

    /// The series minus its straight-line fit.
    static func detrend(_ values: [Double]) -> [Double] {
        guard !values.isEmpty else { return [] }
        let xs = values.indices.map(Double.init)
        let mean = values.reduce(0, +) / Double(values.count)
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let b = slope(xs: xs, ys: values) ?? 0
        return values.enumerated().map { $0.element - (mean + b * (Double($0.offset) - meanX)) }
    }

    static func interpolate(_ series: [Double?]) -> [Double] {
        var result = [Double](repeating: 0, count: series.count)
        let known = series.indices.filter { series[$0] != nil }
        guard let firstKnown = known.first, let lastKnown = known.last else { return result }
        for i in series.indices {
            if let value = series[i] {
                result[i] = value
            } else if i < firstKnown {
                result[i] = series[firstKnown]!
            } else if i > lastKnown {
                result[i] = series[lastKnown]!
            } else {
                let before = known.last { $0 < i }!
                let after = known.first { $0 > i }!
                let t = Double(i - before) / Double(after - before)
                result[i] = series[before]! + (series[after]! - series[before]!) * t
            }
        }
        return result
    }

    static func slope(xs: [Double], ys: [Double]) -> Double? {
        guard xs.count == ys.count, xs.count >= 2 else { return nil }
        let mx = xs.reduce(0, +) / Double(xs.count)
        let my = ys.reduce(0, +) / Double(ys.count)
        let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard sxx > 0 else { return nil }
        let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        return sxy / sxx
    }

    static func pearson(_ xs: [Double], _ ys: [Double]) -> Double? {
        guard xs.count == ys.count, xs.count >= 3 else { return nil }
        let mx = xs.reduce(0, +) / Double(xs.count)
        let my = ys.reduce(0, +) / Double(ys.count)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (x, y) in zip(xs, ys) {
            sxy += (x - mx) * (y - my)
            sxx += (x - mx) * (x - mx)
            syy += (y - my) * (y - my)
        }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }
}

/// How the live workout behaves on a given day: full motivation, or calm on a low-energy day.
public enum CoachIntensity: String, CaseIterable, Sendable, Identifiable {
    case calm, normal, hype
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .calm: return "Low energy"
        case .normal: return "Normal"
        case .hype: return "High energy"
        }
    }

    /// Slack before a gap counts as dawdling.
    public var paceSlack: Double {
        switch self {
        case .calm: return 90
        case .normal: return 30
        case .hype: return 15
        }
    }

    /// From a check-in: 1–2 calm, 3 normal, 4–5 full energy.
    public static func from(energy level: Int) -> CoachIntensity {
        if level <= 2 { return .calm }
        if level >= 4 { return .hype }
        return .normal
    }
}
