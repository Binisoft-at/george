import XCTest
@testable import GeorgeCore

/// v7 lane "safety": stored workouts are never emptied or stripped (#12), CSV import reads what was
/// meant (#13), full backups round-trip and restore by merging (#45).
final class V7SafetyTests: XCTestCase {
    // MARK: - #12 Blob safety

    private func sampleContent(weight: Double = 60) -> WorkoutContent {
        WorkoutContent(blocks: [
            WorkoutBlock(items: [WorkoutItem(name: "Bench", sets: [WorkoutSet(targetReps: "8", targetWeight: weight),
                                                                   WorkoutSet(targetReps: "8", targetWeight: 62.5)])]),
            WorkoutBlock(items: [WorkoutItem(name: "Row", sets: [WorkoutSet(targetReps: "10")])]),
        ])
    }

    func testNanWeightRejected() throws {
        for text in ["nan", "NaN", "inf", "-inf", "infinity", "1e999", "-1e999"] {
            XCTAssertNil(LooseParse.double(text), text)
        }
        XCTAssertEqual(LooseParse.double("62,5 kg"), 62.5)
        let huge = String(repeating: "9", count: 400)
        XCTAssertNil(NumberParser.double(huge))
        XCTAssertNil(NumberParser.int(huge))
        XCTAssertNil(NumberParser.int("99999999999999999999"))
        XCTAssertEqual(NumberParser.int("12"), 12)
        XCTAssertNil(LooseParse.seconds(huge + "s"))
        XCTAssertNil(LooseParse.seconds("99999999999999999:00"))
        XCTAssertNil(LooseParse.meters(huge))

        let csv = "workout,exercise,sets,reps,weight,rpe\nA,Bench,3,8,nan,8\nA,Row,2,10,1e999,\n"
        let result = try ProgramCSV.parse(csv)
        let content = result.programs[0].workouts[0].content
        XCTAssertEqual(content.exerciseCount, 2)
        XCTAssertTrue(content.allItems.allSatisfy { $0.sets.allSatisfy { $0.targetWeight == nil } })
        XCTAssertEqual(result.warnings.filter { $0.message.contains("Couldn't read weight") }.count, 2)
        // What's left encodes: the template keeps its exercises.
        XCTAssertNotNil(content.encoded())
    }

    func testOutOfRangeWeightAndRPEAreClamped() throws {
        let csv = "workout,exercise,sets,reps,weight,rpe\nA,Sled,1,8,5000,14\nA,Curl,1,8,-5,0\n"
        let result = try ProgramCSV.parse(csv)
        let items = result.programs[0].workouts[0].content.allItems
        XCTAssertEqual(items[0].sets[0].targetWeight, ProgramCSV.maxWeightKg)
        XCTAssertEqual(items[0].sets[0].targetRPE, 10)
        XCTAssertEqual(items[1].sets[0].targetWeight, 0)
        XCTAssertEqual(items[1].sets[0].targetRPE, 1)
        XCTAssertEqual(result.warnings.count, 4, "\(result.warnings)")
    }

    func testEncodedIsNeverEmptyData() {
        var content = sampleContent()
        XCTAssertNotNil(content.encoded())
        content.blocks[0].items[0].sets[0].targetWeight = .nan
        XCTAssertNil(content.encoded(), "no empty Data that would erase the workout")
        XCTAssertThrowsError(try content.encodedData())
    }

    func testEncodeFailureKeepsPreviousData() throws {
        let old = try XCTUnwrap(sampleContent().encoded())
        struct Boom: Error {}
        let decision = StoredContent.write(sampleContent(weight: 70), over: old, encode: { _ in throw Boom() })
        guard case .keep(.encodingFailed) = decision else { return XCTFail("\(decision)") }
    }

    func testNonFiniteNumberIsDroppedNotTheWorkout() throws {
        let old = try XCTUnwrap(sampleContent().encoded())
        var edited = sampleContent()
        edited.blocks[0].items[0].sets[0].targetWeight = .infinity
        edited.blocks[0].items[0].fatigue = .nan
        guard case .repaired(let data, let removed) = StoredContent.write(edited, over: old) else { return XCTFail() }
        XCTAssertEqual(removed, 2)
        let back = try WorkoutContent.decodeStrict(data)
        XCTAssertEqual(back.exerciseCount, 2)
        XCTAssertEqual(back.totalSets, 3)
        XCTAssertNil(back.blocks[0].items[0].sets[0].targetWeight)
        XCTAssertEqual(back.blocks[0].items[0].sets[1].targetWeight, 62.5)
    }

    func testNewerVersionIsNotOverwritten() throws {
        // A newer George wrote format 3 with a field this build doesn't know.
        let newer = Data(#"{"version":3,"blocks":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","style":"single","items":[{"name":"Bench","futureField":1,"sets":[{"targetReps":"8"}]}]}]}"#.utf8)
        XCTAssertEqual(StoredContent.readState(of: newer), .newer(version: 3))
        XCTAssertFalse(StoredContent.readState(of: newer).isEditable)
        let read = WorkoutContent.decode(newer)
        XCTAssertEqual(read.exerciseCount, 1, "still shown")
        XCTAssertEqual(read.version, 3)
        XCTAssertEqual(StoredContent.write(read, over: newer), .keep(.newerVersion(3)))
        // Content read from a newer format is not written over older data either.
        let older = try XCTUnwrap(sampleContent().encoded())
        XCTAssertEqual(StoredContent.write(read, over: older), .keep(.newerVersion(3)))
        // An explicit replace (import with "Replace templates", restore) may.
        guard case .write = StoredContent.write(sampleContent(), over: newer, force: true) else { return XCTFail() }
        // A newer shape this build can't decode at all is still "newer", not broken – and kept.
        let reshaped = Data(#"{"version":4,"blocks":"a new shape"}"#.utf8)
        XCTAssertEqual(StoredContent.readState(of: reshaped), .newer(version: 4))
        XCTAssertEqual(StoredContent.write(sampleContent(), over: reshaped), .keep(.newerVersion(4)))
    }

    func testOlderFormatIsReadAndWrittenAsCurrent() throws {
        let v1 = Data(#"{"version":1,"blocks":[{"style":"single","items":[{"name":"Row","sets":[{"targetReps":"10"}]}]}]}"#.utf8)
        XCTAssertEqual(StoredContent.readState(of: v1), .readable)
        let content = WorkoutContent.decode(v1)
        XCTAssertEqual(content.version, WorkoutContent.currentVersion)
        guard case .write(let data) = StoredContent.write(content, over: v1) else { return XCTFail() }
        XCTAssertEqual(StoredContent.storedVersion(of: data), WorkoutContent.currentVersion)
        XCTAssertEqual(WorkoutContent(blocks: []).version, 2, "roundOffset is format 2")
    }

    func testUnreadableDataIsKept() throws {
        let garbage = Data("{\"blocks\": [ {\"items\": 7".utf8)
        XCTAssertEqual(StoredContent.readState(of: garbage), .unreadable)
        XCTAssertThrowsError(try WorkoutContent.decodeStrict(garbage))
        XCTAssertTrue(WorkoutContent.decode(garbage).isEmpty, "lists still get an empty workout")
        // The empty workout derived from it (plus an edit) must not replace the stored data.
        var derived = WorkoutContent.decode(garbage)
        derived.append(items: [WorkoutItem(name: "Squat")])
        XCTAssertEqual(StoredContent.write(derived, over: garbage), .keep(.unreadable))
        // Nothing stored yet, or empty data: a normal write.
        XCTAssertEqual(StoredContent.readState(of: nil), .readable)
        XCTAssertEqual(StoredContent.readState(of: Data()), .readable)
        guard case .write = StoredContent.write(derived, over: nil) else { return XCTFail() }
    }

    func testFreshCopyOfNewerContentIsCurrentFormat() {
        var content = sampleContent()
        content.version = 5
        XCTAssertEqual(content.freshCopy().version, WorkoutContent.currentVersion)
    }

    // MARK: - #13 CSV import

    func testSemicolonFileReadsDecimalComma() throws {
        let csv = """
        workout;exercise;sets;reps;weight;distance
        A;Bench;3;8;62,5;
        A;Row;3;10;60/62,5/65;
        A;Press;3;12,10,8;20,22,24;
        A;Run;1;;;1,5km
        """
        let result = try ProgramCSV.parse(csv)
        let items = result.programs[0].workouts[0].content.allItems
        XCTAssertEqual(items[0].sets.map(\.targetWeight), [62.5, 62.5, 62.5])
        XCTAssertEqual(items[1].sets.map(\.targetWeight), [60, 62.5, 65])
        XCTAssertEqual(items[2].sets.map(\.targetWeight), [20, 22, 24], "several commas stay a list")
        XCTAssertEqual(items[2].sets.map(\.targetReps), ["12", "10", "8"])
        XCTAssertEqual(items[3].sets.first?.targetMeters, 1500)
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
    }

    func testCommaFileQuotedDecimalComma() throws {
        let csv = """
        workout,exercise,sets,reps,weight
        A,Bench,3,8,"62,5"
        A,Fly,1,12,"61,25"
        A,Row,3,10,"20,25"
        """
        let result = try ProgramCSV.parse(csv)
        let items = result.programs[0].workouts[0].content.allItems
        XCTAssertEqual(items[0].sets.map(\.targetWeight), [62.5, 62.5, 62.5])
        XCTAssertEqual(items[1].sets.map(\.targetWeight), [61.25])
        XCTAssertEqual(items[2].sets.map(\.targetWeight), [20, 25, 25], "two digits with more sets: a list, as documented")
        let slashes = try ProgramCSV.parse("workout,exercise,sets,reps,weight\nA,Row,3,10,\"60/62,5/65\"\nA,Curl,3,10,20/22.5/25\n")
        XCTAssertEqual(slashes.programs[0].workouts[0].content.allItems.map { $0.sets.map(\.targetWeight) }, [[60, 62.5, 65], [20, 22.5, 25]])
        XCTAssertEqual(LooseParse.decimalCommaFractionDigits("62,5 kg"), 1)
        XCTAssertNil(LooseParse.decimalCommaFractionDigits("15,12,10"))
        XCTAssertNil(LooseParse.decimalCommaFractionDigits("20,22.5"))
    }

    func testListLongerThanSetsWarns() throws {
        let csv = "workout,exercise,sets,reps,weight\nA,Bench,2,\"12,10,8\",40\n"
        let result = try ProgramCSV.parse(csv)
        XCTAssertEqual(result.programs[0].workouts[0].content.allItems[0].sets.count, 3)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].message.contains("3 values for 2 sets"), result.warnings[0].message)
    }

    func testCommentLineDoesNotHideSemicolonHeader() throws {
        let csv = "# my plan, made in Numbers\nworkout;exercise;sets;weight\nA;Bench;2;62,5\n"
        let result = try ProgramCSV.parse(csv)
        XCTAssertEqual(result.programs[0].workouts[0].content.allItems.first?.sets.map(\.targetWeight), [62.5, 62.5])
    }

    func testRoundsKeepWarmupsAndDropSets() throws {
        let csv = """
        workout,group,rounds,exercise,sets,reps,set_type
        A,A,3,Squat,2,5,warmup
        A,A,3,Squat,3,8,
        A,A,3,Squat,1,12,drop
        A,A,3,Lunge,4,10,
        """
        let result = try ProgramCSV.parse(csv)
        let block = result.programs[0].workouts[0].content.blocks[0]
        XCTAssertEqual(block.items.count, 2)
        XCTAssertEqual(block.rounds, 3)
        XCTAssertEqual(block.items[0].sets.map(\.kind), [.warmup, .warmup, .working, .working, .working, .drop])
        XCTAssertEqual(block.items[1].sets.count, 3)
        XCTAssertEqual(result.warnings.count, 1, "\(result.warnings)")
        XCTAssertTrue(result.warnings[0].message.contains("Lunge"))
        XCTAssertEqual(result.warnings[0].line, 5)
    }

    func testSetRoundsPadsWithWorkingSets() {
        var content = WorkoutContent(blocks: [WorkoutBlock(style: .superset, items: [
            WorkoutItem(name: "A", sets: [WorkoutSet(kind: .warmup, targetReps: "5"), WorkoutSet(targetReps: "8")]),
            WorkoutItem(name: "B", sets: [WorkoutSet(targetReps: "10"), WorkoutSet(kind: .drop, targetReps: "6")]),
        ])])
        let removed = content.setRounds(blockID: content.blocks[0].id, to: 3)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(content.blocks[0].rounds, 3)
        XCTAssertEqual(content.blocks[0].items[0].sets.map(\.kind), [.warmup, .working, .working, .working])
        XCTAssertEqual(content.blocks[0].items[1].roundSetCount, 3)
        XCTAssertEqual(content.blocks[0].items[1].sets.filter { $0.kind == .drop }.count, 1)
    }

    func testSameExerciseInANewSectionIsANewExercise() throws {
        let csv = """
        workout,section,exercise,sets,reps,set_type
        A,WARM-UP,Squat,2,5,warmup
        A,,Squat,3,8,
        A,MAIN,Squat,3,5,
        """
        let content = try ProgramCSV.parse(csv).programs[0].workouts[0].content
        XCTAssertEqual(content.sections, ["WARM-UP", "MAIN"])
        XCTAssertEqual(content.exerciseCount, 2)
        XCTAssertEqual(content.blocks[0].items[0].sets.count, 5, "rows of one section still merge")
        XCTAssertEqual(content.blocks[1].section, "MAIN")
        XCTAssertEqual(content.blocks[1].items[0].sets.count, 3)
    }

    private func richWorkout() -> ProgramCSV.ExportWorkout {
        var bench = WorkoutItem(exerciseID: "fedb:Bench", name: "Bench Press", mode: .reps,
                                sets: [WorkoutSet(kind: .warmup, targetReps: "10", targetWeight: 40),
                                       WorkoutSet(targetReps: "8", targetWeight: 60),
                                       WorkoutSet(targetReps: "8", targetWeight: 62.5)],
                                restSeconds: 120, tempo: "3-1-1", notes: "Elbows tucked",
                                links: ["https://example.com/a", "https://example.com/b"], equipment: "barbell",
                                muscles: ["chest", "triceps"], imageURL: "https://example.com/bench.gif")
        bench.sets[1].targetRPE = 8
        let curl = WorkoutItem(name: "Band Curl", sets: [WorkoutSet(targetReps: "15", targetLoad: "red band")], perSide: true)
        let pull = WorkoutItem(name: "Pull-up", sets: [WorkoutSet(kind: .warmup, targetReps: "3"),
                                                       WorkoutSet(targetReps: "6"), WorkoutSet(targetReps: "6"),
                                                       WorkoutSet(kind: .drop, targetReps: "4"), WorkoutSet(targetReps: "6")])
        let dip = WorkoutItem(name: "Dip", sets: [WorkoutSet(targetReps: "10", targetWeight: 10), WorkoutSet(targetReps: "10", targetWeight: 12.5),
                                                  WorkoutSet(targetReps: "8", targetWeight: 15)])
        let plank = WorkoutItem(name: "Plank", mode: .time, sets: [WorkoutSet(targetSeconds: 45), WorkoutSet(targetSeconds: 60)])
        let content = WorkoutContent(blocks: [
            WorkoutBlock(section: "MAIN", items: [bench]),
            WorkoutBlock(section: "MAIN", items: [curl]),
            WorkoutBlock(section: "SUPERSET", style: .superset, rounds: 3, restAfterRoundSeconds: 90, items: [pull, dip]),
            WorkoutBlock(section: "CORE", items: [plank]),
        ])
        return ProgramCSV.ExportWorkout(name: "UPPER", subtitle: "PUSH + PULL", kind: .gym, order: 1, scheduleDays: [2, 5],
                                        notes: "Keep rest short", tags: ["strength", "upper"], content: content)
    }

    func testExtendedRoundTrip() throws {
        for unit in [WeightUnit.kg, .lb] {
            let workout = richWorkout()
            let csv = ProgramCSV.export(programName: "Block", workouts: [workout], unit: unit,
                                        programNotes: "Twelve weeks", programColor: "#FF9500")
            let result = try ProgramCSV.parse(csv)
            XCTAssertTrue(result.warnings.isEmpty, "\(unit): \(result.warnings)")
            let program = result.programs[0]
            XCTAssertEqual(program.notes, "Twelve weeks")
            XCTAssertEqual(program.colorHex, "#FF9500")
            let back = program.workouts[0]
            XCTAssertEqual(back.tags, ["strength", "upper"])
            XCTAssertEqual(back.scheduleDays, [2, 5])
            XCTAssertEqual(back.notes, "Keep rest short")
            XCTAssertEqual(back.content.structureSignature, workout.content.structureSignature, "\(unit)")
            XCTAssertEqual(back.content.sections, workout.content.sections)
            for (a, b) in zip(workout.content.allItems, back.content.allItems) {
                XCTAssertEqual(a.name, b.name)
                XCTAssertEqual(a.exerciseID, b.exerciseID)
                XCTAssertEqual(a.mode, b.mode)
                XCTAssertEqual(a.perSide, b.perSide, a.name)
                XCTAssertEqual(a.restSeconds, b.restSeconds, a.name)
                XCTAssertEqual(a.tempo, b.tempo)
                XCTAssertEqual(a.notes, b.notes)
                XCTAssertEqual(a.links, b.links)
                XCTAssertEqual(a.muscles, b.muscles)
                XCTAssertEqual(a.equipment, b.equipment)
                XCTAssertEqual(a.imageURL, b.imageURL)
                XCTAssertEqual(a.sets.map(\.kind), b.sets.map(\.kind), a.name)
                XCTAssertEqual(a.sets.map(\.targetReps), b.sets.map(\.targetReps), a.name)
                XCTAssertEqual(a.sets.map(\.targetSeconds), b.sets.map(\.targetSeconds), a.name)
                XCTAssertEqual(a.sets.map(\.targetLoad), b.sets.map(\.targetLoad), a.name)
                for (sa, sb) in zip(a.sets, b.sets) {
                    XCTAssertEqual(sa.targetWeight ?? -1, sb.targetWeight ?? -1, accuracy: 0.01, "\(unit) \(a.name)")
                }
            }
            let grouped = back.content.blocks[2]
            XCTAssertEqual(grouped.style, .superset)
            XCTAssertEqual(grouped.rounds, 3)
            XCTAssertEqual(grouped.restAfterRoundSeconds, 90)
            XCTAssertEqual(back.content.blocks[0].items[0].sets[1].targetRPE, 8)
        }
    }

    func testBundledSamplesImportWithoutWarnings() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["gym-strength-block", "elastic-bands-tennis"] {
            let text = try String(contentsOf: root.appendingPathComponent("samples/\(name).csv"), encoding: .utf8)
            let result = try ProgramCSV.parse(text)
            XCTAssertTrue(result.warnings.isEmpty, "\(name): \(result.warnings)")
            // And they survive an export and import.
            let program = result.programs[0]
            let csv = ProgramCSV.export(programName: program.name, workouts: program.workouts.map {
                ProgramCSV.ExportWorkout(name: $0.name, subtitle: $0.subtitle, kind: $0.kind, order: $0.order, scheduleDays: $0.scheduleDays,
                                         notes: $0.notes, tags: $0.tags, content: $0.content)
            }, programNotes: program.notes, programColor: program.colorHex)
            let back = try ProgramCSV.parse(csv)
            XCTAssertTrue(back.warnings.isEmpty, "\(name) round trip: \(back.warnings)")
            XCTAssertEqual(back.programs[0].workouts.map { $0.content.structureSignature }, program.workouts.map { $0.content.structureSignature })
        }
    }

    func testProgramNotesAreKeptWithoutReplace() {
        XCTAssertEqual(ProgramCSV.notesChange(existing: "", imported: "Plan", replace: false), .set)
        XCTAssertEqual(ProgramCSV.notesChange(existing: "Mine", imported: "", replace: false), .unchanged)
        XCTAssertEqual(ProgramCSV.notesChange(existing: "Mine", imported: "Plan", replace: true), .replace)
        XCTAssertEqual(ProgramCSV.notesChange(existing: "Mine\n\nPlan", imported: "Plan", replace: false), .unchanged, "re-import of an export")
        XCTAssertEqual(ProgramCSV.mergedNotes(existing: "Mine", imported: "Plan", replace: false, dateText: "23 Nov 2026"),
                       "Mine\n\n— Imported 23 Nov 2026 —\nPlan")
        XCTAssertEqual(ProgramCSV.mergedNotes(existing: "Mine", imported: "Plan", replace: true, dateText: "x"), "Plan")
        XCTAssertEqual(ProgramCSV.mergedNotes(existing: "Mine", imported: " ", replace: true, dateText: "x"), "Mine")
    }

    // MARK: - #45 Backup and restore

    private func sampleArchive() -> BackupArchive {
        var archive = BackupArchive()
        archive.reason = BackupReason.weekly.rawValue
        archive.appVersion = "1.0 (1)"
        var program = BackupArchive.Program()
        program.name = "Strength"
        program.notes = "Notes"
        var template = BackupArchive.Template()
        template.name = "UPPER"
        template.programID = program.id
        template.scheduleRaw = "2,5"
        template.content = BackupArchive.Blob.from(sampleContent().encoded())
        var session = BackupArchive.Session()
        session.title = "W47: 1 UPPER"
        session.statusRaw = "completed"
        session.programID = program.id
        session.templateID = template.id
        session.startedAt = Date(timeIntervalSince1970: 1_763_800_000.123)
        session.endedAt = Date(timeIntervalSince1970: 1_763_803_600.5)
        session.effort = 7
        session.energyKcal = 312.4
        session.healthWorkoutID = "HK-1"
        session.content = BackupArchive.Blob(Data([0xFF, 0xFE, 0x00]))
        var energy = BackupArchive.EnergyCheckIn()
        energy.level = 4
        var exercise = BackupArchive.Exercise()
        exercise.key = "custom:1"
        exercise.name = "Band Thing"
        var week = BackupArchive.ExcusedWeek()
        week.weekStart = Date(timeIntervalSince1970: 1_763_334_000)
        var settings = BackupArchive.Settings()
        settings.weeklyGoal = 4
        settings.activeProgramID = program.id
        settings.goalHistory = BackupArchive.Blob(Data(#"[{"daysPerWeek":3}]"#.utf8))
        archive.programs = [program]
        archive.templates = [template]
        archive.sessions = [session]
        archive.energyCheckIns = [energy]
        archive.exercises = [exercise]
        archive.excusedWeeks = [week]
        archive.settings = settings
        return archive
    }

    func testBackupRoundTrip() throws {
        let archive = sampleArchive()
        let data = try archive.encoded()
        let back = try BackupArchive.decode(data)
        XCTAssertEqual(back, archive)
        XCTAssertEqual(back.sessions[0].content?.data, Data([0xFF, 0xFE, 0x00]), "non-UTF-8 bytes survive")
        XCTAssertEqual(WorkoutContent.decode(back.templates[0].content?.data).allItems.map(\.name), ["Bench", "Row"])
        XCTAssertEqual(back.sessions[0].startedAt, archive.sessions[0].startedAt, "dates exact to the last bit")
        // The workout JSON is readable text in the file.
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("Bench"))
        XCTAssertFalse(archive.isEmpty)
        XCTAssertTrue(BackupArchive().isEmpty)
        XCTAssertEqual(archive.summary, "1 program · 1 template · 1 workout · 1 check-in")
    }

    func testBackupFileChecks() throws {
        XCTAssertThrowsError(try BackupArchive.decode(Data("program,workout\n".utf8))) { error in
            XCTAssertEqual(error as? BackupArchive.ReadError, .notABackup)
        }
        XCTAssertThrowsError(try BackupArchive.decode(Data(#"{"format":"something-else","version":1}"#.utf8)))
        var future = sampleArchive()
        future.version = BackupArchive.currentVersion + 1
        XCTAssertThrowsError(try BackupArchive.decode(try future.encoded())) { error in
            XCTAssertEqual(error as? BackupArchive.ReadError, .newerVersion(BackupArchive.currentVersion + 1))
        }
    }

    func testRestorePlanMergesByID() {
        let backup = sampleArchive()
        // Now: the program (and with it its template) was deleted, the workout lost its program and got
        // a new note, a workout was added since, settings are unchanged.
        var current = backup
        current.programs = []
        current.templates = []
        current.sessions[0].programID = nil
        current.sessions[0].notes = "Felt strong"
        var added = BackupArchive.Session()
        added.title = "New since"
        current.sessions.append(added)
        current.settings?.activeProgramID = nil

        let plan = backup.restorePlan(against: current)
        XCTAssertEqual(plan.programs.bringBack, [backup.programs[0].id.uuidString])
        XCTAssertEqual(plan.templates.bringBack, [backup.templates[0].id.uuidString])
        XCTAssertEqual(plan.sessions.changedSince, [backup.sessions[0].id.uuidString])
        XCTAssertEqual(plan.relinkSessions, [backup.sessions[0].id], "linked to its program again")
        XCTAssertEqual(plan.activeProgramID, backup.programs[0].id)
        XCTAssertEqual(plan.energyCheckIns.same, 1)
        XCTAssertEqual(plan.bringBackCount, 2)
        XCTAssertEqual(plan.changedSinceCount, 2, "the workout and the settings")
        XCTAssertFalse(plan.sessions.restores(backup.sessions[0].id.uuidString, includingChanged: false), "a newer note stays")
        XCTAssertTrue(plan.sessions.restores(backup.sessions[0].id.uuidString, includingChanged: true))
        XCTAssertFalse(plan.sessions.restores(added.id.uuidString, includingChanged: true), "added since: never touched")
        XCTAssertTrue(plan.changesSomething(includingChanged: false))
        XCTAssertEqual(plan.describe { $0.bringBack.count }, "1 program, 1 template")

        let nothing = backup.restorePlan(against: backup)
        XCTAssertFalse(nothing.changesSomething(includingChanged: true))
        XCTAssertEqual(nothing.sameCount, 7)
        XCTAssertEqual(nothing.describe { $0.bringBack.count }, "Nothing")
    }

    func testRunningWorkoutComesBackStopped() {
        var session = BackupArchive.Session()
        session.statusRaw = "active"
        session.accumulatedSeconds = 600
        session.resumedAt = Date(timeIntervalSince1970: 1_000)
        let stopped = session.stoppedForRestore(at: Date(timeIntervalSince1970: 1_300), hasDoneSets: true)
        XCTAssertEqual(stopped.statusRaw, "partial")
        XCTAssertNil(stopped.resumedAt)
        XCTAssertEqual(stopped.accumulatedSeconds, 900)
        XCTAssertEqual(stopped.endedAt, Date(timeIntervalSince1970: 1_300))
        XCTAssertEqual(session.stoppedForRestore(at: Date(timeIntervalSince1970: 1_300), hasDoneSets: false).statusRaw, "planned")
    }

    func testRollingBackupNamesAndPruning() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let start = Date(timeIntervalSince1970: 1_763_800_000)
        let names = (0..<10).map { BackupSchedule.fileName(at: start.addingTimeInterval(Double($0) * 86_400), reason: .weekly, timeZone: utc) }
        XCTAssertEqual(names[0], "George Backup 2025-11-22 082640 (weekly).json")
        XCTAssertEqual(BackupSchedule.date(fromFileName: names[0], timeZone: utc), start)
        let foreign = ["My notes.json", "George Backup old.json", "export.csv"]
        let doomed = BackupSchedule.filesToDelete((names + foreign).shuffled(), keep: 8, timeZone: utc)
        XCTAssertEqual(Set(doomed), Set(names.prefix(2)), "the two oldest go; other files are never touched")
        XCTAssertTrue(BackupSchedule.isDue(lastBackup: nil, now: start))
        XCTAssertFalse(BackupSchedule.isDue(lastBackup: start, now: start.addingTimeInterval(6 * 86_400)))
        XCTAssertTrue(BackupSchedule.isDue(lastBackup: start, now: start.addingTimeInterval(7 * 86_400)))
        XCTAssertEqual(BackupArchive.weekKey(Date(timeIntervalSince1970: 1_763_334_000 - 3_600)),
                       BackupArchive.weekKey(Date(timeIntervalSince1970: 1_763_334_000 + 6 * 3_600)), "same day across time zones")
    }
}
