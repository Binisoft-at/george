import Foundation

// MARK: - Imported model

public struct ImportedWorkout: Sendable, Hashable {
    public var name: String
    public var subtitle: String
    public var kind: WorkoutKind
    public var notes: String
    public var order: Int
    /// Calendar weekdays (1 = Sunday ... 7 = Saturday).
    public var scheduleDays: [Int]
    public var estimatedMinutes: Int?
    public var tags: [String]
    public var content: WorkoutContent
}

public struct ImportedProgram: Sendable, Hashable {
    public var name: String
    public var notes: String
    public var colorHex: String?
    public var workouts: [ImportedWorkout]

    public var exerciseCount: Int { workouts.reduce(0) { $0 + $1.content.exerciseCount } }
}

public struct CSVWarning: Sendable, Hashable {
    public var line: Int
    public var message: String
}

public struct CSVImportResult: Sendable {
    public var programs: [ImportedProgram]
    public var warnings: [CSVWarning]
    public var rowCount: Int
}

public enum CSVImportError: Error, LocalizedError, Sendable {
    case empty
    case missingColumn(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "The file is empty."
        case .missingColumn(let name): return "The CSV needs a “\(name)” column. See the George CSV format guide."
        }
    }
}

/// Reads and writes George program CSVs. See docs/CSV_FORMAT.md for the full spec.
public enum ProgramCSV {
    public static let formatVersion = 1

    /// Canonical column -> accepted header spellings.
    static let columnAliases: [String: [String]] = [
        "program": ["program", "project", "plan", "program_name", "programme"],
        "program_notes": ["program_notes", "program_description"],
        "program_color": ["program_color", "color", "colour"],
        "workout": ["workout", "workout_name", "template", "routine", "day_name", "session"],
        "workout_subtitle": ["workout_subtitle", "subtitle", "focus", "description"],
        "workout_type": ["workout_type", "type", "kind", "category"],
        "workout_notes": ["workout_notes"],
        "workout_order": ["workout_order", "order", "day_number"],
        "schedule": ["schedule", "schedule_days", "days", "weekday", "weekdays"],
        "estimated_minutes": ["estimated_minutes", "minutes", "duration_min", "est_minutes"],
        "tags": ["tags", "tag", "labels"],
        "section": ["section", "part", "phase", "segment"],
        "group": ["group", "superset", "block", "superset_group", "group_id"],
        "group_style": ["group_style", "block_style", "style", "group_type"],
        "rounds": ["rounds", "round_count"],
        "rest_after_round": ["rest_after_round", "round_rest", "rest_between_rounds"],
        "exercise": ["exercise", "exercise_name", "name", "movement", "exercise_title"],
        "exercise_id": ["exercise_id", "library_id"],
        "exercise_type": ["exercise_type", "exercise_kind"],
        "mode": ["mode", "measure", "tracking"],
        "sets": ["sets", "set_count"],
        "reps": ["reps", "repetitions", "rep", "target_reps"],
        "weight": ["weight", "weight_kg", "kg", "load_kg"],
        "weight_lb": ["weight_lb", "weight_lbs", "lbs", "lb"],
        "unit": ["unit", "weight_unit", "units"],
        "load": ["load", "band", "resistance", "intensity", "band_color"],
        "duration": ["duration", "time", "hold", "duration_sec", "seconds", "duration_s", "hold_sec"],
        "distance": ["distance", "distance_m", "meters"],
        "rest": ["rest", "rest_sec", "rest_seconds", "rest_s"],
        "tempo": ["tempo"],
        "rpe": ["rpe", "target_rpe", "effort"],
        "per_side": ["per_side", "each_side", "unilateral", "per_leg", "per_arm"],
        "set_type": ["set_type", "settype"],
        "notes": ["notes", "note", "cue", "cues", "comment", "comments", "exercise_notes"],
        "tutorial_url": ["tutorial_url", "tutorial", "video", "video_url", "link", "url", "links", "youtube"],
        "image_url": ["image_url", "image", "gif", "gif_url"],
        "muscles": ["muscles", "primary_muscles", "target", "target_muscles", "muscle"],
        "equipment": ["equipment", "gear"],
    ]

    static func normalizeHeader(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
    }

    static func mapHeaders(_ headers: [String]) -> [String: Int] {
        var lookup: [String: String] = [:]
        for (canonical, spellings) in columnAliases {
            for spelling in spellings { lookup[spelling] = canonical }
        }
        var result: [String: Int] = [:]
        for (index, header) in headers.enumerated() {
            let key = normalizeHeader(header)
            if let canonical = lookup[key], result[canonical] == nil {
                result[canonical] = index
            }
        }
        return result
    }

    static func weekdays(from raw: String) -> [Int] {
        let map: [String: Int] = [
            "sun": 1, "sunday": 1, "so": 1, "mon": 2, "monday": 2, "mo": 2, "tue": 3, "tues": 3, "tuesday": 3, "di": 3,
            "wed": 4, "wednesday": 4, "mi": 4, "thu": 5, "thur": 5, "thurs": 5, "thursday": 5, "do": 5,
            "fri": 6, "friday": 6, "fr": 6, "sat": 7, "saturday": 7, "sa": 7,
        ]
        let parts = raw.lowercased().components(separatedBy: CharacterSet(charactersIn: ",;/| +&"))
        var days: [Int] = []
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if let day = map[trimmed], !days.contains(day) { days.append(day) }
        }
        return days.sorted()
    }

    // MARK: Import

    public static func parse(_ text: String, defaultProgramName: String = "Imported Program") throws -> CSVImportResult {
        let allRows = CSVReader.parse(text)
        // Drop comment lines.
        let rows = allRows.filter { row in
            !(row.fields.first?.trimmingCharacters(in: .whitespaces).hasPrefix("#") ?? false)
        }
        guard let header = rows.first else { throw CSVImportError.empty }
        let columns = mapHeaders(header.fields)
        guard columns["exercise"] != nil else { throw CSVImportError.missingColumn("exercise") }

        var warnings: [CSVWarning] = []

        struct ItemKey: Equatable {
            var group: String
            var name: String
        }

        // Program name -> builder
        final class WorkoutBuilder {
            var name: String
            var subtitle = ""
            var kind: WorkoutKind = .gym
            var kindSet = false
            var notes = ""
            var order: Int
            var schedule: [Int] = []
            var minutes: Int?
            var tags: [String] = []
            var blocks: [WorkoutBlock] = []
            var currentGroup: String? = nil
            var lastItemKey: ItemKey? = nil
            init(name: String, order: Int) {
                self.name = name
                self.order = order
            }
        }
        final class ProgramBuilder {
            var name: String
            var notes = ""
            var color: String?
            var workouts: [WorkoutBuilder] = []
            init(name: String) { self.name = name }
            func workout(named name: String) -> WorkoutBuilder {
                if let existing = workouts.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    return existing
                }
                let w = WorkoutBuilder(name: name, order: workouts.count + 1)
                workouts.append(w)
                return w
            }
        }

        var programs: [ProgramBuilder] = []
        func program(named name: String) -> ProgramBuilder {
            if let existing = programs.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return existing }
            let p = ProgramBuilder(name: name)
            programs.append(p)
            return p
        }

        var lastProgramName = defaultProgramName
        var lastWorkoutName = "Workout"
        var dataRowCount = 0

        for row in rows.dropFirst() {
            func value(_ key: String) -> String {
                guard let index = columns[key], index < row.fields.count else { return "" }
                return row.fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            dataRowCount += 1

            let programName = value("program").isEmpty ? lastProgramName : value("program")
            lastProgramName = programName
            let workoutName = value("workout").isEmpty ? lastWorkoutName : value("workout")
            lastWorkoutName = workoutName

            let p = program(named: programName)
            if !value("program_notes").isEmpty { p.notes = value("program_notes") }
            if !value("program_color").isEmpty { p.color = value("program_color") }

            let w = p.workout(named: workoutName)
            if !value("workout_subtitle").isEmpty { w.subtitle = value("workout_subtitle") }
            if !value("workout_type").isEmpty, !w.kindSet {
                w.kind = WorkoutKind(value("workout_type"))
                w.kindSet = true
            }
            if !value("workout_notes").isEmpty { w.notes = value("workout_notes") }
            if let order = Int(value("workout_order")) { w.order = order }
            if !value("schedule").isEmpty { w.schedule = weekdays(from: value("schedule")) }
            if let minutes = Int(value("estimated_minutes")) { w.minutes = minutes }
            if !value("tags").isEmpty {
                for tag in LooseParse.list(value("tags")) where !w.tags.contains(tag) { w.tags.append(tag) }
            }

            let exerciseName = value("exercise")
            guard !exerciseName.isEmpty else { continue }

            // Units
            let unitRaw = value("unit").lowercased()
            let unit: WeightUnit = (unitRaw.hasPrefix("lb") || unitRaw.hasPrefix("pound")) ? .lb : .kg

            // Exercise kind
            let exerciseKind: WorkoutKind? = value("exercise_type").isEmpty ? nil : WorkoutKind(value("exercise_type"))
            let kindForDefaults = exerciseKind ?? (w.kindSet ? w.kind : WorkoutKind(value("workout_type").isEmpty ? "gym" : value("workout_type")))

            // Per-set lists
            let repsList = LooseParse.list(value("reps"))
            var weightList = LooseParse.list(value("weight")).compactMap { LooseParse.double($0) }.map { unit.toKilograms($0) }
            if weightList.isEmpty {
                weightList = LooseParse.list(value("weight_lb")).compactMap { LooseParse.double($0) }.map { WeightUnit.lb.toKilograms($0) }
            }
            let durationList = LooseParse.list(value("duration")).compactMap { LooseParse.seconds($0) }
            let distanceList = LooseParse.list(value("distance")).compactMap { LooseParse.meters($0) }
            if !value("duration").isEmpty && durationList.isEmpty {
                warnings.append(CSVWarning(line: row.line, message: "Couldn't read duration “\(value("duration"))” for \(exerciseName)."))
            }

            var setCount = Int(value("sets")) ?? 0
            if value("sets").isEmpty == false && Int(value("sets")) == nil {
                // "3-4" -> 3
                setCount = Int(value("sets").prefix { $0.isNumber }) ?? 0
                if setCount == 0 {
                    warnings.append(CSVWarning(line: row.line, message: "Couldn't read sets “\(value("sets"))” for \(exerciseName); using 1."))
                }
            }
            setCount = max(setCount, repsList.count, weightList.count, durationList.count, distanceList.count, 1)
            if setCount > 50 {
                warnings.append(CSVWarning(line: row.line, message: "Capped \(setCount) sets to 50 for \(exerciseName)."))
                setCount = 50
            }

            // Mode
            let mode: ExerciseMode
            switch value("mode").lowercased() {
            case "time", "timed", "duration", "hold", "seconds": mode = .time
            case "distance", "dist", "meters": mode = .distance
            case "reps", "rep", "repetitions": mode = .reps
            default:
                if !distanceList.isEmpty { mode = .distance }
                else if !durationList.isEmpty && repsList.isEmpty { mode = .time }
                else if repsList.isEmpty && durationList.isEmpty && kindForDefaults.defaultMode == .time { mode = .time }
                else { mode = .reps }
            }

            let setKind = SetKind(loose: value("set_type"))
            let load = value("load").isEmpty ? nil : value("load")
            let rpe = LooseParse.double(value("rpe"))

            var sets: [WorkoutSet] = []
            for i in 0..<setCount {
                func pick<T>(_ list: [T]) -> T? { list.isEmpty ? nil : list[min(i, list.count - 1)] }
                var set = WorkoutSet(kind: setKind)
                set.targetLoad = load
                set.targetRPE = rpe
                switch mode {
                case .reps:
                    set.targetReps = pick(repsList) ?? "10"
                    set.targetWeight = pick(weightList)
                    set.targetSeconds = pick(durationList)
                case .time:
                    set.targetSeconds = pick(durationList) ?? 30
                    set.targetWeight = pick(weightList)
                    if let reps = pick(repsList) { set.targetReps = reps }
                case .distance:
                    set.targetMeters = pick(distanceList) ?? 400
                    set.targetSeconds = pick(durationList)
                }
                sets.append(set)
            }

            let links = value("tutorial_url")
                .components(separatedBy: CharacterSet(charactersIn: " |\n"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.lowercased().hasPrefix("http") }

            let item = WorkoutItem(
                exerciseID: value("exercise_id").isEmpty ? nil : value("exercise_id"),
                name: exerciseName,
                kind: exerciseKind,
                mode: mode,
                sets: sets,
                perSide: LooseParse.bool(value("per_side")),
                restSeconds: LooseParse.seconds(value("rest")),
                tempo: value("tempo").isEmpty ? nil : value("tempo"),
                notes: value("notes").isEmpty ? nil : value("notes"),
                links: links,
                equipment: value("equipment").isEmpty ? nil : value("equipment"),
                muscles: LooseParse.list(value("muscles")).map { $0.lowercased() },
                imageURL: value("image_url").isEmpty ? nil : value("image_url")
            )

            // Group handling: "A1"/"A2" -> "A"
            var groupKey = value("group").uppercased()
            while let last = groupKey.last, last.isNumber, groupKey.count > 1 { groupKey.removeLast() }
            let section = value("section").isEmpty ? nil : value("section")
            let key = ItemKey(group: groupKey, name: exerciseName.lowercased())

            // Same exercise on consecutive rows (e.g. warm-up row + working row) -> merge sets.
            if let lastKey = w.lastItemKey, lastKey == key, let lastBlock = w.blocks.indices.last,
               let lastItem = w.blocks[lastBlock].items.indices.last,
               w.blocks[lastBlock].items[lastItem].name.lowercased() == key.name {
                w.blocks[lastBlock].items[lastItem].sets.append(contentsOf: item.sets)
                continue
            }

            if !groupKey.isEmpty, let current = w.currentGroup, current == groupKey, let lastBlock = w.blocks.indices.last {
                w.blocks[lastBlock].items.append(item)
                let count = w.blocks[lastBlock].items.count
                if !value("group_style").isEmpty {
                    w.blocks[lastBlock].style = BlockStyle(loose: value("group_style"), itemCount: count)
                } else if w.blocks[lastBlock].style == .single || w.blocks[lastBlock].style == .superset {
                    w.blocks[lastBlock].style = BlockStyle(loose: "", itemCount: count)
                }
                if let rounds = Int(value("rounds")) { w.blocks[lastBlock].rounds = rounds }
                if let rest = LooseParse.seconds(value("rest_after_round")) { w.blocks[lastBlock].restAfterRoundSeconds = rest }
            } else {
                var block = WorkoutBlock(section: section ?? w.blocks.last?.section, style: .single, items: [item])
                if !value("group_style").isEmpty && !groupKey.isEmpty {
                    block.style = BlockStyle(loose: value("group_style"), itemCount: 1)
                    if block.style == .superset { block.style = .single }
                }
                if let rounds = Int(value("rounds")) { block.rounds = rounds }
                if let rest = LooseParse.seconds(value("rest_after_round")) { block.restAfterRoundSeconds = rest }
                if let section, section != w.blocks.last?.section { block.section = section }
                w.blocks.append(block)
                w.currentGroup = groupKey.isEmpty ? nil : groupKey
            }
            w.lastItemKey = key
        }

        // Grouped blocks: align set counts with rounds where provided.
        var result: [ImportedProgram] = []
        for p in programs {
            var workouts: [ImportedWorkout] = []
            for w in p.workouts.sorted(by: { $0.order < $1.order }) {
                var content = WorkoutContent(blocks: w.blocks)
                for b in content.blocks.indices where content.blocks[b].style.isGrouped {
                    if let rounds = content.blocks[b].rounds, rounds > 0 {
                        for i in content.blocks[b].items.indices {
                            var sets = content.blocks[b].items[i].sets
                            if sets.count < rounds, let last = sets.last {
                                while sets.count < rounds { sets.append(last.clearedCopy()) }
                            } else if sets.count > rounds {
                                sets = Array(sets.prefix(rounds))
                            }
                            content.blocks[b].items[i].sets = sets
                        }
                    }
                }
                content.normalizeBlocks()
                if content.isEmpty {
                    warnings.append(CSVWarning(line: 0, message: "Workout “\(w.name)” has no exercises."))
                }
                workouts.append(ImportedWorkout(
                    name: w.name, subtitle: w.subtitle, kind: w.kind, notes: w.notes, order: w.order,
                    scheduleDays: w.schedule, estimatedMinutes: w.minutes, tags: w.tags, content: content
                ))
            }
            result.append(ImportedProgram(name: p.name, notes: p.notes, colorHex: p.color, workouts: workouts))
        }
        return CSVImportResult(programs: result, warnings: warnings, rowCount: dataRowCount)
    }

    // MARK: Export

    public static let exportHeader = [
        "program", "workout", "workout_subtitle", "workout_type", "workout_order", "schedule", "workout_notes",
        "section", "group", "group_style", "rounds", "rest_after_round",
        "exercise", "exercise_id", "exercise_type", "mode", "sets", "reps", "weight", "unit", "load",
        "duration", "distance", "rest", "tempo", "rpe", "per_side", "set_type", "notes", "tutorial_url", "muscles", "equipment",
    ]

    public struct ExportWorkout: Sendable {
        public var name: String
        public var subtitle: String
        public var kind: WorkoutKind
        public var order: Int
        public var scheduleDays: [Int]
        public var notes: String
        public var content: WorkoutContent
        public init(name: String, subtitle: String, kind: WorkoutKind, order: Int, scheduleDays: [Int], notes: String, content: WorkoutContent) {
            self.name = name
            self.subtitle = subtitle
            self.kind = kind
            self.order = order
            self.scheduleDays = scheduleDays
            self.notes = notes
            self.content = content
        }
    }

    public static func export(programName: String, workouts: [ExportWorkout], unit: WeightUnit = .kg) -> String {
        let dayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var rows: [[String]] = [exportHeader]
        for workout in workouts {
            var groupLetter = 0
            let schedule = workout.scheduleDays.compactMap { (1...7).contains($0) ? dayNames[$0] : nil }.joined(separator: ";")
            var first = true
            for block in workout.content.blocks {
                var groupLabel = ""
                if block.items.count > 1 || block.style.isGrouped {
                    let scalar = UnicodeScalar(65 + (groupLetter % 26)) ?? "A"
                    groupLabel = String(Character(scalar))
                    groupLetter += 1
                }
                for item in block.items {
                    // Split runs of identical set kinds into separate rows.
                    var runs: [[WorkoutSet]] = []
                    for set in item.sets {
                        if let last = runs.last?.last, last.kind == set.kind {
                            runs[runs.count - 1].append(set)
                        } else {
                            runs.append([set])
                        }
                    }
                    if runs.isEmpty { runs = [[]] }
                    for run in runs {
                        func joined(_ values: [String]) -> String {
                            let nonEmpty = values.filter { !$0.isEmpty }
                            guard !nonEmpty.isEmpty else { return "" }
                            if Set(values).count == 1 { return values[0] }
                            return values.joined(separator: ",")
                        }
                        let reps = joined(run.map { $0.targetReps ?? "" })
                        let weights = joined(run.map { $0.targetWeight.map { Format.number(unit.fromKilograms($0)) } ?? "" })
                        let durations = joined(run.map { $0.targetSeconds.map(String.init) ?? "" })
                        let distances = joined(run.map { $0.targetMeters.map { Format.number($0) } ?? "" })
                        let load = run.first?.targetLoad ?? ""
                        let rpe = run.first?.targetRPE.map { Format.number($0) } ?? ""
                        rows.append([
                            programName,
                            workout.name,
                            first ? workout.subtitle : "",
                            first ? workout.kind.rawValue : "",
                            first ? String(workout.order) : "",
                            first ? schedule : "",
                            first ? workout.notes : "",
                            block.section ?? "",
                            groupLabel,
                            groupLabel.isEmpty ? "" : block.style.rawValue,
                            groupLabel.isEmpty ? "" : (block.rounds.map(String.init) ?? ""),
                            groupLabel.isEmpty ? "" : (block.restAfterRoundSeconds.map(String.init) ?? ""),
                            item.name,
                            item.exerciseID ?? "",
                            item.kind?.rawValue ?? "",
                            item.mode.rawValue,
                            String(run.count),
                            reps,
                            weights,
                            weights.isEmpty ? "" : unit.rawValue,
                            load,
                            durations,
                            distances,
                            item.restSeconds.map(String.init) ?? "",
                            item.tempo ?? "",
                            rpe,
                            item.perSide ? "yes" : "",
                            run.first?.kind == .working || run.isEmpty ? "" : (run.first?.kind.rawValue ?? ""),
                            item.notes ?? "",
                            item.links.joined(separator: " "),
                            item.muscles.joined(separator: ";"),
                            item.equipment ?? "",
                        ])
                        first = false
                    }
                }
            }
        }
        return CSVReader.write(rows: rows)
    }

    // MARK: Session log export

    public struct LogSession: Sendable {
        public var date: Date
        public var title: String
        public var program: String
        public var kind: WorkoutKind
        public var durationSeconds: Double
        public var status: String
        public var content: WorkoutContent
        public init(date: Date, title: String, program: String, kind: WorkoutKind, durationSeconds: Double, status: String, content: WorkoutContent) {
            self.date = date
            self.title = title
            self.program = program
            self.kind = kind
            self.durationSeconds = durationSeconds
            self.status = status
            self.content = content
        }
    }

    /// One row per set — handy for spreadsheets or another AI to analyse progress.
    public static func exportLog(_ sessions: [LogSession], unit: WeightUnit = .kg) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        var rows: [[String]] = [["date", "session", "program", "type", "duration_min", "status", "exercise", "set", "set_type", "done", "reps", "weight", "unit", "duration", "distance", "rpe", "target_reps", "target_weight"]]
        for session in sessions.sorted(by: { $0.date < $1.date }) {
            for item in session.content.allItems {
                for (index, set) in item.sets.enumerated() {
                    rows.append([
                        formatter.string(from: session.date),
                        session.title,
                        session.program,
                        session.kind.rawValue,
                        String(Int((session.durationSeconds / 60).rounded())),
                        session.status,
                        item.name,
                        String(index + 1),
                        set.kind.rawValue,
                        set.isDone ? "yes" : "no",
                        set.reps.map(String.init) ?? "",
                        set.weight.map { Format.number(unit.fromKilograms($0)) } ?? "",
                        unit.rawValue,
                        set.seconds.map(String.init) ?? "",
                        set.meters.map { Format.number($0) } ?? "",
                        set.rpe.map { Format.number($0) } ?? "",
                        set.targetReps ?? "",
                        set.targetWeight.map { Format.number(unit.fromKilograms($0)) } ?? "",
                    ])
                }
            }
        }
        return CSVReader.write(rows: rows)
    }
}
