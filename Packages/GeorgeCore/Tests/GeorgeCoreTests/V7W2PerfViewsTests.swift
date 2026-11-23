import XCTest
@testable import GeorgeCore

/// v7 wave 2, lane "perfviews": the faster library search, muscular load and the streak kept for the
/// day must give exactly what the slower code gave.
final class V7W2PerfViewsTests: XCTestCase {
    private let calendar = Calendar.training(timeZone: TimeZone(identifier: "Europe/Vienna")!)

    private func repoFile(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
    }

    /// Deterministic numbers for the synthetic histories.
    private struct Seeded {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
        mutating func unit() -> Double { Double(next() % 10_000) / 10_000 }
    }

    // MARK: Library search

    /// The catalog's search texts as the old search built them (once per catalog).
    private var referenceTexts: [ObjectIdentifier: [String: String]] = [:]

    /// The search as it was before the names were ranked once (fold and localized compare per search).
    private func referenceSearch(_ catalog: ExerciseCatalog, _ query: String, kind: WorkoutKind? = nil, muscle: String? = nil,
                                 equipment: String? = nil, limit: Int = 400) -> [LibraryExercise] {
        let texts: [String: String]
        if let known = referenceTexts[ObjectIdentifier(catalog)] {
            texts = known
        } else {
            var built: [String: String] = [:]
            for exercise in catalog.exercises {
                built[exercise.id] = ExerciseCatalog.fold(([exercise.name] + exercise.aliases + exercise.primary + exercise.tags
                                                           + [exercise.equipment ?? "", exercise.kind.displayName]).joined(separator: " "))
            }
            referenceTexts[ObjectIdentifier(catalog)] = built
            texts = built
        }
        let words = ExerciseCatalog.fold(query).split(separator: " ").map(String.init)
        var scored: [(Int, LibraryExercise)] = []
        for exercise in catalog.exercises {
            if let kind, exercise.kind != kind { continue }
            if let muscle, !exercise.primary.contains(muscle) && !exercise.secondary.contains(muscle) { continue }
            if let equipment, exercise.equipment != equipment { continue }
            if words.isEmpty {
                scored.append((0, exercise))
                continue
            }
            let haystack = texts[exercise.id] ?? ""
            guard words.allSatisfy({ haystack.contains($0) }) else { continue }
            let name = ExerciseCatalog.fold(exercise.name)
            var score = 3
            if name == words.joined(separator: " ") { score = 0 }
            else if name.hasPrefix(words[0]) { score = 1 }
            else if name.contains(words.joined(separator: " ")) { score = 2 }
            scored.append((score, exercise))
        }
        scored.sort { a, b in a.0 != b.0 ? a.0 < b.0 : a.1.name.localizedCaseInsensitiveCompare(b.1.name) == .orderedAscending }
        return Array(scored.prefix(limit).map(\.1))
    }

    func testLibrarySearchOrderIsUnchanged() throws {
        let catalog = try ExerciseCatalog(data: try Data(contentsOf: repoFile("App/Resources/exercises.json")))
        XCTAssertGreaterThan(catalog.exercises.count, 1000)
        let queries = ["", "row", "Row", "bench press", "Barbell Bench Press - Medium Grip", "curl", "squat", "band", "stretch",
                       "yoga", "pull up", "pull-up", "db", "hip", "a", "e", "press", "dumbbell curl", "  plank  ", "down dog",
                       "lunge", "glute", "zzz-no-match", "chest", "Équipement"]
        for query in queries {
            XCTAssertEqual(catalog.search(query).map(\.id), referenceSearch(catalog, query).map(\.id), "query “\(query)”")
        }
        for kind in catalog.kinds {
            for query in ["", "a", "stretch", "row"] {
                XCTAssertEqual(catalog.search(query, kind: kind).map(\.id), referenceSearch(catalog, query, kind: kind).map(\.id),
                               "\(kind.rawValue) “\(query)”")
            }
        }
        for muscle in catalog.allMuscles {
            XCTAssertEqual(catalog.search("", muscle: muscle).map(\.id), referenceSearch(catalog, "", muscle: muscle).map(\.id), muscle)
            XCTAssertEqual(catalog.search("press", kind: .gym, muscle: muscle).map(\.id),
                           referenceSearch(catalog, "press", kind: .gym, muscle: muscle).map(\.id), muscle)
        }
        for equipment in catalog.allEquipment.prefix(6) {
            XCTAssertEqual(catalog.search("", equipment: equipment).map(\.id), referenceSearch(catalog, "", equipment: equipment).map(\.id))
        }
        XCTAssertEqual(catalog.search("", limit: 25).map(\.id), referenceSearch(catalog, "", limit: 25).map(\.id))
    }

    func testFilterListsAreTheSameAsBefore() throws {
        let catalog = try ExerciseCatalog(data: try Data(contentsOf: repoFile("App/Resources/exercises.json")))
        XCTAssertEqual(catalog.allMuscles, Array(Set(catalog.exercises.flatMap(\.primary))).sorted())
        XCTAssertEqual(catalog.allEquipment, Array(Set(catalog.exercises.compactMap(\.equipment))).sorted())
        XCTAssertEqual(catalog.kinds, Array(Set(catalog.exercises.map(\.kind))).sorted())
        XCTAssertTrue(ExerciseCatalog.empty.kinds.isEmpty)
        XCTAssertTrue(ExerciseCatalog.empty.search("row").isEmpty)
    }

    func testEqualNamesKeepTheFileOrder() {
        // Names that compare the same (case only) keep the order of the file, as the stable sort did.
        let catalog = ExerciseCatalog(file: LibraryFile(exercises: [
            LibraryExercise(id: "b2", name: "plank", kind: .gym),
            LibraryExercise(id: "a1", name: "Arm Circle", kind: .mobility),
            LibraryExercise(id: "b1", name: "Plank", kind: .gym),
            LibraryExercise(id: "c1", name: "Ćurl", kind: .gym),
            LibraryExercise(id: "c2", name: "Curl", kind: .gym),
            LibraryExercise(id: "p3", name: "PLANK", kind: .yoga),
        ]))
        for query in ["", "plank", "curl", "a"] {
            XCTAssertEqual(catalog.search(query).map(\.id), referenceSearch(catalog, query).map(\.id), "“\(query)”")
        }
        XCTAssertEqual(catalog.search("plank").map(\.id), ["b2", "b1", "p3"])
    }

    // MARK: Muscular load

    /// `loadSummary` as it was before it started at the shown days (it walked every event).
    private func referenceLoadSummary(_ engine: MuscleEngine, group: MuscleGroup?, days: Int, now: Date) -> LoadSummary {
        let calendar = engine.calendar
        let loadBand = engine.loadBand
        let setCeiling = engine.setCeiling
        let end = calendar.addingDays(1, to: calendar.startOfDay(for: now))
        let warmup = 84
        let start = calendar.addingDays(-(days + warmup), to: end)
        let list = engine.eventList(group)
        let firstEvent = list.first?.date
        let series = engine.dailyLoads(group: group, from: start, to: end)
        var prefix: [Double] = [0]
        for entry in series { prefix.append(prefix[prefix.count - 1] + entry.load) }
        func windowSum(endingAt index: Int, days window: Int) -> Double {
            let upper = index + 1
            let lower = max(0, upper - window)
            return prefix[upper] - prefix[lower]
        }
        let dayIndex = Dictionary(uniqueKeysWithValues: series.enumerated().map { ($1.day, $0) })
        var setsPerDay = [Double](repeating: 0, count: series.count)
        var muscleSetsPerDay: [MuscleGroup: [Double]] = [:]
        for event in list where event.sets > 0 {
            guard let i = dayIndex[calendar.startOfDay(for: event.date)] else { continue }
            if group != nil || event.countsOnce { setsPerDay[i] += group == nil ? 1 : event.sets }
            muscleSetsPerDay[event.group, default: [Double](repeating: 0, count: series.count)][i] += event.sets
        }
        func rolling(_ values: [Double], endingAt index: Int, days window: Int) -> Double {
            values[max(0, index - window + 1)...index].reduce(0, +)
        }
        let qualifying = list.filter { $0.load >= 0.5 }
        var windowCounts: [UUID: Int] = [:]
        var head = 0
        var tail = 0
        let minimumSessions = group == nil ? 4 : 3
        var points: [LoadPoint] = []
        var recentRatios: [Double] = []
        for (index, entry) in series.enumerated() {
            let weeklyAcute = windowSum(endingAt: index, days: 7)
            let historyDays: Int
            if let firstEvent {
                historyDays = max(14, min(42, calendar.daysBetween(firstEvent, entry.day) + 1))
            } else {
                historyDays = 42
            }
            let weeklyChronic = windowSum(endingAt: index, days: 42) / (Double(historyDays) / 7)
            let ratio = weeklyChronic > 0.01 ? weeklyAcute / weeklyChronic : 0
            if let firstEvent, calendar.daysBetween(firstEvent, entry.day) >= 14 {
                recentRatios.append(ratio)
                if recentRatios.count > 14 { recentRatios.removeFirst() }
            }
            let dayEnd = calendar.addingDays(1, to: entry.day)
            let windowStart = calendar.addingDays(-42, to: entry.day)
            while head < qualifying.count && qualifying[head].date < dayEnd {
                windowCounts[qualifying[head].sessionID, default: 0] += 1
                head += 1
            }
            while tail < head && qualifying[tail].date < windowStart {
                let id = qualifying[tail].sessionID
                windowCounts[id, default: 1] -= 1
                if windowCounts[id] ?? 0 <= 0 { windowCounts.removeValue(forKey: id) }
                tail += 1
            }
            var status: LoadStatus
            if let firstEvent, calendar.daysBetween(firstEvent, entry.day) >= 14, windowCounts.count >= minimumSessions {
                status = MuscleEngine.classify(ratio: ratio, recentRatios: recentRatios, band: loadBand)
            } else {
                status = .calibrating
            }
            guard index >= series.count - days else { continue }
            let maxMuscle = muscleSetsPerDay.values.map { rolling($0, endingAt: index, days: 7) }.max() ?? 0
            var normal = false
            if (status == .fatigued || status == .overtraining) && maxMuscle <= setCeiling {
                status = .productive
                normal = true
            }
            let acuteSets = rolling(setsPerDay, endingAt: index, days: 7)
            let usualSets = rolling(setsPerDay, endingAt: index, days: 42) / (Double(historyDays) / 7)
            points.append(LoadPoint(day: entry.day, acute: weeklyAcute, chronic: weeklyChronic, status: status,
                                    lowRatio: loadBand.lowerBound, highRatio: loadBand.upperBound,
                                    acuteSets: acuteSets, usualSets: usualSets, maxMuscleSets: maxMuscle,
                                    setCeiling: setCeiling, aboveUsualButNormal: normal))
        }
        let current = points.last ?? LoadPoint(day: calendar.startOfDay(for: now), acute: 0, chronic: 0, status: .calibrating,
                                               lowRatio: loadBand.lowerBound, highRatio: loadBand.upperBound)
        return LoadSummary(current: current, history: points)
    }

    /// Three years of training with a few weeks off and a long break: sessions every 1–4 days, warm-ups
    /// (load, no sets), hard sets, light days and secondary muscles – across the DST changes.
    private func threeYears(from start: Date) -> (events: [MuscleEvent], breaks: [Date]) {
        var random = Seeded(state: 20_261_123)
        let groups = MuscleGroup.allCases
        let shortBreak = calendar.addingDays(200, to: start)
        let longBreak = calendar.addingDays(500, to: start)
        var events: [MuscleEvent] = []
        var day = start
        let last = calendar.addingDays(3 * 365, to: start)
        while day < last {
            let inShortBreak = day >= shortBreak && day < calendar.addingDays(35, to: shortBreak)
            let inLongBreak = day >= longBreak && day < calendar.addingDays(95, to: longBreak)
            if !inShortBreak && !inLongBreak {
                let sessionID = UUID()
                // Mornings, evenings and the odd late session (23:30) right before midnight.
                let hour = [7, 12, 18, 23][random.int(0...3)]
                var time = calendar.date(bySettingHour: hour, minute: 30, second: 0, of: day) ?? day
                let light = random.unit() < 0.2
                for _ in 0..<random.int(3...7) {
                    let primary = groups[random.int(0...(groups.count - 1))]
                    let secondary = groups[random.int(0...(groups.count - 1))]
                    for set in 0..<random.int(2...4) {
                        let warmup = set == 0 && random.unit() < 0.4
                        let base = warmup ? 0.25 : (light ? 0.15 : 0.6 + random.unit() * 0.5)
                        let countsAsSet = !warmup && !light
                        events.append(MuscleEvent(date: time, sessionID: sessionID, group: primary, load: base,
                                                  sets: countsAsSet ? 1 : 0, volumeKg: 100, exerciseKey: "x", exerciseName: "X",
                                                  countsOnce: countsAsSet))
                        if secondary != primary {
                            events.append(MuscleEvent(date: time, sessionID: sessionID, group: secondary, load: base * 0.5,
                                                      sets: countsAsSet ? 0.5 : 0, volumeKg: 50, exerciseKey: "x", exerciseName: "X"))
                        }
                        time = time.addingTimeInterval(Double(random.int(60...240)))
                    }
                }
            }
            day = calendar.addingDays(random.int(1...4), to: day)
        }
        return (events, [shortBreak, longBreak])
    }

    func testLoadSummaryMatchesTheFullWalkOnThreeYears() {
        let start = calendar.date(from: DateComponents(year: 2023, month: 3, day: 1))!
        let history = threeYears(from: start)
        let engine = MuscleEngine(events: history.events, calendar: calendar, recoveryScale: 1.1, loadBand: 0.8...1.3, setCeiling: 16)
        XCTAssertGreaterThan(engine.events.count, 5_000)
        let first = engine.events.first!.date
        let last = engine.events.last!.date
        let nows = [
            last, last.addingTimeInterval(3 * 86_400), calendar.addingDays(400, to: first), calendar.addingDays(10, to: first),
            first.addingTimeInterval(-5 * 86_400), calendar.addingDays(40, to: history.breaks[1]),
            // The night of a DST change.
            calendar.date(from: DateComponents(year: 2024, month: 3, day: 31, hour: 2, minute: 30))!,
        ]
        // The short windows the cards and live mode ask for, for several muscles; the long ones for the body.
        var cases: [(group: MuscleGroup?, days: Int)] = []
        for group in [nil, .chest, .quads] as [MuscleGroup?] {
            cases += [(group, 1), (group, 14)]
        }
        cases += [(nil, 91), (nil, 365), (.abs, 30)]
        for now in nows {
            for (group, days) in cases {
                let expected = referenceLoadSummary(engine, group: group, days: days, now: now)
                let actual = engine.loadSummary(group: group, days: days, now: now)
                XCTAssertEqual(actual.current, expected.current, "\(group?.rawValue ?? "body") \(days) d at \(now)")
                XCTAssertEqual(actual.history, expected.history, "\(group?.rawValue ?? "body") \(days) d at \(now)")
            }
        }
    }

    func testLoadSummaryWithoutEventsIsCalibrating() {
        let engine = MuscleEngine(events: [], calendar: calendar)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let actual = engine.loadSummary(days: 14, now: now)
        let expected = referenceLoadSummary(engine, group: nil, days: 14, now: now)
        XCTAssertEqual(actual.current, expected.current)
        XCTAssertEqual(actual.history, expected.history)
        XCTAssertEqual(actual.current.status, .calibrating)
    }

    // MARK: Streak kept for the day

    private func assertSame(_ a: StreakSummary, _ b: StreakSummary, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.currentWeeks, b.currentWeeks, file: file, line: line)
        XCTAssertEqual(a.bestWeeks, b.bestWeeks, file: file, line: line)
        XCTAssertEqual(a.streakWorkoutDays, b.streakWorkoutDays, file: file, line: line)
        XCTAssertEqual(a.totalWorkoutDays, b.totalWorkoutDays, file: file, line: line)
        XCTAssertEqual(a.credits, b.credits, file: file, line: line)
        XCTAssertEqual(a.weeksUntilNextCredit, b.weeksUntilNextCredit, file: file, line: line)
        XCTAssertEqual(a.history, b.history, file: file, line: line)
        XCTAssertEqual(a.thisWeek.status, b.thisWeek.status, file: file, line: line)
        XCTAssertEqual(a.thisWeek.effectiveDays, b.thisWeek.effectiveDays, file: file, line: line)
        XCTAssertEqual(a.thisWeek.neededDays, b.thisWeek.neededDays, file: file, line: line)
        XCTAssertEqual(a.thisWeek.workedOutToday, b.thisWeek.workedOutToday, file: file, line: line)
        XCTAssertEqual(a.thisWeek.dots, b.thisWeek.dots, file: file, line: line)
    }

    func testStreakIsKeptForTheDayUntilALaterWorkoutCounts() {
        let engine = StreakEngine(calendar: calendar)
        let config = StreakConfig(defaultGoal: 3)
        let monday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16))!
        var entries: [ActivityEntry] = []
        for week in 0..<6 {
            for day in [0, 2, 4] {
                entries.append(ActivityEntry(date: calendar.date(byAdding: .hour, value: 18, to: calendar.addingDays(week * 7 + day - 42, to: monday))!, minutes: 45))
            }
        }
        let wednesday = calendar.addingDays(2, to: monday)
        let morning = calendar.date(byAdding: .hour, value: 8, to: wednesday)!
        let evening = calendar.date(byAdding: .hour, value: 21, to: wednesday)!

        // Nothing dated in between: the morning's streak is the evening's.
        XCTAssertTrue(engine.evaluatesAlike(entries: entries, at: morning, and: evening))
        assertSame(engine.evaluate(entries: entries, config: config, now: morning),
                   engine.evaluate(entries: entries, config: config, now: evening))

        // A workout at noon counts in the evening, not in the morning.
        let noon = entries + [ActivityEntry(date: calendar.date(byAdding: .hour, value: 12, to: wednesday)!, minutes: 40)]
        XCTAssertFalse(engine.evaluatesAlike(entries: noon, at: morning, and: evening))
        XCTAssertFalse(engine.evaluatesAlike(entries: noon, at: evening, and: morning))
        XCTAssertFalse(engine.evaluate(entries: noon, config: config, now: morning).thisWeek.workedOutToday)
        XCTAssertTrue(engine.evaluate(entries: noon, config: config, now: evening).thisWeek.workedOutToday)
        // Both moments after it: alike again.
        let later = calendar.date(byAdding: .hour, value: 13, to: wednesday)!
        XCTAssertTrue(engine.evaluatesAlike(entries: noon, at: later, and: evening))
        assertSame(engine.evaluate(entries: noon, config: config, now: later), engine.evaluate(entries: noon, config: config, now: evening))

        // Within the minute `evaluate` allows: a workout 30 s ahead already counts at both moments.
        let justAhead = entries + [ActivityEntry(date: morning.addingTimeInterval(30), minutes: 40)]
        XCTAssertTrue(engine.evaluatesAlike(entries: justAhead, at: morning, and: evening))

        // Another day is never alike (the week dots move on).
        XCTAssertFalse(engine.evaluatesAlike(entries: entries, at: morning, and: calendar.addingDays(1, to: morning)))
        XCTAssertTrue(engine.evaluatesAlike(entries: entries, at: morning, and: morning))
    }
}
