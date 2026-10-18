//
//  CSVRoutineImporter.swift
//  WorkoutTracker
//
//  Imports a CSV file into one or more routines (with their exercises). The CSV
//  mirrors how the app defines routines and exercises: every exercise belongs to
//  a GROUP (strength / cardio / stretching), and each group carries its own
//  attributes — strength = sets/reps/weight, cardio = duration/intensity,
//  stretching = hold/sides/rounds. Machines and their settings are optional.
//
//  Import is ALL-OR-NOTHING. The whole file is validated first; if ANY row is
//  invalid, nothing at all is imported and every problem is reported. This makes
//  it impossible to import incorrect data.
//
//  A routine is a DEFINITION only — it does not carry scheduling. Scheduling is a
//  separate "event" (ScheduleRule) created from the Calendar/Workout views, so this
//  template has no recurrence columns.
//
//  Expected columns (header row, case-insensitive, any order):
//      routine, order, group, exercise, machine, machine_settings,
//      set1_reps, set1_weight, set2_reps, set2_weight, … setN_reps, setN_weight,
//      duration_min, intensity, hold_seconds, sides, rounds,
//      set_cooldown, exercise_cooldown, notes
//  Always required: routine, exercise.
//  group is optional: blank takes the row's kind's group, or the group of the
//  exercise with that name in the library or elsewhere in the file. It's
//  needed only when the name is unknown or is in more than one group.
//  order (optional, whole number ≥ 1) is the row's position in its routine;
//  fill it on every row of a routine or on none (none = file order). The rows
//  of a routine run in that order, and each run of consecutive rows with the
//  same group is one section, so a group can appear more than once (e.g.
//  stretching before and after strength).
//  Optional cooldowns (seconds): set_cooldown = rest between sets for THAT
//  exercise (blank → routine default); exercise_cooldown = rest between exercises
//  for the routine (one routine-level value; if rows differ, the largest is used).
//  Routines follow the library (CatalogSyncService.reconcileRoutineExercises):
//  setK_reps/setK_weight and set_cooldown are written to the routine on import
//  but replaced by the exercise's own sets and rest the next time the Routines,
//  Workout or Calendar tab appears. set_cooldown never reaches the exercise, and
//  setK becomes the exercise's library defaults only on the no-`kind` strength
//  path in exercise(for:). To set them for good, change the exercise.
//  Required per group:
//      • strength    → per-set columns are OPTIONAL; if blank, the exercise's own
//                       default sets (from the library) are used. Each filled setK
//                       pair is one planned set (sets can differ in reps/weight).
//      • cardio      → duration_min / intensity are OPTIONAL (blank → exercise's
//                       own duration/intensity); validated if present
//      • stretching  → nothing extra (exercise name only; hold_seconds, sides,
//                       rounds are optional and default when blank)
//  In short: a routine row only needs routine + exercise; the exercise's
//  saved definition supplies any prescription left blank.
//  Optional everywhere: machine, machine_settings, notes.
//  Optional `kind` plus that kind's columns (see CSVExerciseFields) define a NEW
//  exercise the current way; an exercise already in the library keeps its
//  saved values. setK_reps/setK_weight still plan this routine's sets for any
//  kind with sets, with the caveat above: the library wins on the next sync.
//  Each new exercise gets its own machine.
//  machine_settings format: "Label=Value; Label2=Value2" (max Machine.maxSettings). A numeric
//  value 0...15 becomes a slider pick; anything else is stored as free text.
//
//  One row = one exercise in a routine. Rows with the same routine name are
//  grouped into one routine; rows with the same exercise name + group share one
//  exercise definition.
//
//  A routine that already exists (by name) is skipped. With `updateExisting`
//  (the Google Sheet and CSV file imports) it is compared with the file instead: sections,
//  exercises and their order, plus a cardio length or exercise cooldown the
//  file fills. If anything differs it is rebuilt to match — in a new version
//  when a workout was started from the current one — and otherwise left alone.
//  Sets, set cooldowns and notes aren't compared: the library owns those and
//  CatalogSyncService keeps every routine in step with it.
//

import Foundation
import SwiftData

struct CSVImportReport {
    var routinesCreated = 0
    var exercisesAdded = 0
    /// Items that already existed and were ignored (import only adds new items).
    var routinesSkipped = 0
    var exercisesSkipped = 0
    /// Existing exercises whose definition was overwritten (Google Sheet import).
    var exercisesUpdated = 0
    /// Existing exercises the sheet lists with the values they already have.
    var exercisesUnchanged = 0
    /// Existing routines changed to match the file, and ones that already did
    /// (Google Sheet import).
    var routinesUpdated = 0
    var routinesUnchanged = 0
    /// Photos still to fetch, when the caller saves the import itself.
    var photoDownloads: [(id: UUID, raw: String)] = []
    /// Always empty on success (import is all-or-nothing); kept for compatibility.
    var rowErrors: [String] = []

    var summary: String {
        var parts: [String] = []
        if routinesCreated > 0 || routinesSkipped > 0 { parts.append("\(routinesCreated) routine(s)") }
        parts.append("\(exercisesAdded) exercise(s)")
        var s = "Imported " + parts.joined(separator: ", ") + "."
        if exercisesUpdated > 0 { s += " Updated \(exercisesUpdated) existing exercise(s)." }
        if routinesUpdated > 0 { s += " Updated \(routinesUpdated) existing routine(s)." }
        if exercisesUnchanged + routinesUnchanged > 0 {
            var same: [String] = []
            if routinesUnchanged > 0 { same.append("\(routinesUnchanged) routine(s)") }
            if exercisesUnchanged > 0 { same.append("\(exercisesUnchanged) exercise(s)") }
            s += " " + same.joined(separator: ", ") + " already matched."
        }
        let skipped = routinesSkipped + exercisesSkipped
        if skipped > 0 {
            var sk: [String] = []
            if routinesSkipped > 0 { sk.append("\(routinesSkipped) routine(s)") }
            if exercisesSkipped > 0 { sk.append("\(exercisesSkipped) exercise(s)") }
            s += " Skipped " + sk.joined(separator: ", ") + " that already existed."
        }
        return s
    }
}

enum CSVImportError: LocalizedError {
    case notCSV
    case empty
    case missingColumns([String])
    case unreadable
    /// One or more rows failed validation. Nothing was imported.
    case invalidData([String])

    var errorDescription: String? {
        switch self {
        case .notCSV: return "That file isn't a .csv file. Please choose a CSV."
        case .empty: return "The CSV has a header but no data rows to import."
        case .unreadable: return "Couldn't read the file's contents. If it's stored in iCloud or Google Drive, open it once in the Files app so it downloads, then import again."
        case .missingColumns(let cols):
            return "The CSV is missing required column(s): \(cols.joined(separator: ", "))."
        case .invalidData(let errs):
            let shown = errs.prefix(10).joined(separator: "\n")
            let more = errs.count > 10 ? "\n…and \(errs.count - 10) more." : ""
            return "Nothing was imported — fix these and try again:\n\(shown)\(more)"
        }
    }
}

@MainActor
struct CSVRoutineImporter {
    let context: ModelContext
    let updateExisting: Bool
    /// False when the caller saves (or rolls back) several imports together.
    let saves: Bool
    /// Exercise names → group known to the caller (the sheet's exercise tabs),
    /// for rows with no group whose exercise isn't in the library yet.
    let knownExercises: [String: SectionType]

    init(_ context: ModelContext, updateExisting: Bool = false, saves: Bool = true,
         knownExercises: [String: SectionType] = [:]) {
        self.context = context
        self.updateExisting = updateExisting
        self.saves = saves
        self.knownExercises = knownExercises
    }

    /// The example/template CSV the app can import successfully. One row per
    /// group so users can see exactly which columns each group uses.
    static let exampleCSV = """
    routine,group,exercise,kind,reps,sets,weight,per_side,per_side_custom,implement,added_weight,hold_seconds,prop,timer_seconds,duration_min,distance,work_seconds,recovery_seconds,rounds,effort,machine,machine_settings,set1_reps,set1_weight,set2_reps,set2_weight,set3_reps,set3_weight,set4_reps,set4_weight,set5_reps,set5_weight,set_cooldown,exercise_cooldown,notes
    Gym Full Body A,strength,Leg Press,machine,10,3,120,single,,,,,,,,,,,,,Leg Press,Seat height=5; Back angle=3,12,100,10,120,10,120,8,140,6,160,90,180,Pyramid up
    Gym Full Body A,strength,Dumbbell Curl,free_weight,12,3,25,alternating,,dumbbell,,,,,,,,,,,,,,,,,,,,,,,60,,
    Gym Full Body A,cardio,Treadmill,steady,,,,,,,,,,,20,,,,,moderate,,,,,,,,,,,,,,,Steady pace
    Gym Full Body A,stretching,Hamstring Stretch,static,2,1,,left_right,,,,30,strap,,,,,,,,,,,,,,,,,,,,,,Keep back flat
    Gym Full Body B,strength,Plank,hold,1,3,,single,,,,45,,,,,,,,,,,,,,,,,,,,,45,120,
    Gym Full Body B,cardio,Bike Sprints,intervals,,,,,,,,,,,,,30,60,8,hard,Bike,Resistance=8,,,,,,,,,,,,,
    Gym Full Body B,stretching,Leg Swings,dynamic,10,1,,forward_back,,,,,,30,,,,,,,,,,,,,,,,,,,,,
    """

    /// Validate the picked file is a CSV, then import its text.
    func importFile(at url: URL) throws -> CSVImportReport {
        guard url.pathExtension.lowercased() == "csv" else { throw CSVImportError.notCSV }
        let data = Self.readFileData(at: url)
        guard !data.isEmpty else { throw CSVImportError.unreadable } // 0 bytes ≠ "empty CSV"
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { throw CSVImportError.unreadable }
        return try importText(text)
    }

    /// Read a picked file's bytes, coordinating the read so an iCloud/provider
    /// file that hasn't downloaded yet is materialized first (a plain
    /// `Data(contentsOf:)` can otherwise return 0 bytes for such files).
    static func readFileData(at url: URL) -> Data {
        var coordError: NSError?
        var result = Data()
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordError) { u in
            if let d = try? Data(contentsOf: u) { result = d }
        }
        if result.isEmpty, let d = try? Data(contentsOf: url) { result = d } // fallback
        return result
    }

    // MARK: - A fully validated row, ready to insert.

    private struct ParsedRow {
        var routine: String
        /// Position in the routine (the `order` column); nil = file order.
        var order: Int? = nil
        var lineNo: Int
        var group: SectionType
        var exercise: String
        var machine: String
        var settings: [(label: String, numeric: Int?, other: String?)]
        /// Set when the row has a `kind`: defines a new exercise the current way.
        var fields: CSVExerciseFields? = nil
        var notes: String
        /// Per-exercise cooldown between sets (seconds). Nil = routine default.
        var setCooldown: Int? = nil
        // strength — each entry is one planned set (its own reps + weight)
        var plannedSets: [(reps: Int, weight: Double)] = []
        // cardio
        var durationMin: Int = 0
        var intensity: CardioIntensity = .moderate
        // stretching
        var holdSeconds: Int = 0
        var sidesCount: Int = 1
        var rounds: Int = 1
    }

    /// Parse and import CSV text. All-or-nothing.
    func importText(_ text: String) throws -> CSVImportReport {
        let rows = Self.parse(text)
        guard let header = rows.first, !header.isEmpty else { throw CSVImportError.empty }

        // Map column name -> index (case-insensitive).
        var index: [String: Int] = [:]
        for (i, name) in header.enumerated() {
            index[name.trimmingCharacters(in: .whitespaces).lowercased()] = i
        }
        let required = ["routine", "exercise"]
        let missing = required.filter { index[$0] == nil }
        guard missing.isEmpty else { throw CSVImportError.missingColumns(missing) }

        // Blank rows are skipped (a sheet exports one as ",,,"); each row keeps
        // its line number so errors name the right row.
        let dataRows = rows.dropFirst().enumerated()
            .filter { !$0.element.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
            .map { (lineNo: $0.offset + 2, row: $0.element) }   // header is line 1
        guard !dataRows.isEmpty else { throw CSVImportError.empty }

        func field(_ row: [String], _ key: String) -> String {
            guard let i = index[key], i < row.count else { return "" }
            return row[i].trimmingCharacters(in: .whitespaces)
        }

        // How many setK_reps/setK_weight column pairs the header defines (strength).
        var maxSet = 0
        var sn = 1
        while index["set\(sn)_reps"] != nil || index["set\(sn)_weight"] != nil { maxSet = sn; sn += 1 }

        // The user's library exercises, by name|group: a row with a kind must
        // agree with an exercise that already exists (the library wins).
        let user = DataSource.user.rawValue
        var exerciseByKey: [String: Exercise] = [:]        // key: name|group
        for e in (try? context.fetch(
            FetchDescriptor<Exercise>(predicate: #Predicate { $0.deletedAt == nil && $0.sourceRaw == user })
        )) ?? [] {
            exerciseByKey["\(e.name)|\(e.defaultSectionType.rawValue)"] = e
        }

        // The groups each exercise name is known in, for rows with no group:
        // the library, plus rows in this file that give a group or a kind.
        var knownGroups: [String: Set<SectionType>] = [:]
        for e in exerciseByKey.values { knownGroups[e.name, default: []].insert(e.defaultSectionType) }
        for (name, g) in knownExercises { knownGroups[name, default: []].insert(g) }
        for (_, row) in dataRows {
            let name = field(row, "exercise")
            if let g = Self.group(from: field(row, "group")) ?? CSVExerciseFields.kind(from: field(row, "kind"))?.section {
                knownGroups[name, default: []].insert(g)
            }
        }

        // ---- PASS 1: validate EVERYTHING. No inserts happen here. ----
        var errors: [String] = []
        var parsedRows: [ParsedRow] = []
        // Routine-level "between exercises" cooldown (one value per routine).
        var exerciseCooldownByRoutine: [String: Int] = [:]
        // Every row's order cell, including rows that fail other checks, so
        // order problems are all reported at once.
        var orderEntries: [(routine: String, order: Int?, filled: Bool, lineNo: Int)] = []
        // The first row defining each new exercise (name|group) with a kind.
        // A row naming it with no kind uses this row's definition.
        var definingRow: [String: ParsedRow] = [:]

        for (lineNo, row) in dataRows {
            var rowErrors: [String] = []

            let routineName = field(row, "routine")
            let exerciseName = field(row, "exercise")
            if routineName.isEmpty { rowErrors.append("Line \(lineNo): 'routine' is required.") }
            if exerciseName.isEmpty { rowErrors.append("Line \(lineNo): 'exercise' is required.") }

            var order: Int?
            let orderStr = field(row, "order")
            if !orderStr.isEmpty {
                if let v = Int(orderStr), v >= 1 { order = v }
                else { rowErrors.append("Line \(lineNo): 'order' must be a whole number ≥ 1 (got \"\(orderStr)\").") }
            }
            if !routineName.isEmpty {
                orderEntries.append((routineName, order, !orderStr.isEmpty, lineNo))
            }

            let groupStr = field(row, "group"), kindStr = field(row, "kind")
            let group: SectionType
            if !groupStr.isEmpty {
                guard let g = Self.group(from: groupStr) else {
                    rowErrors.append("Line \(lineNo): 'group' must be strength, cardio, or stretching (got \"\(groupStr)\").")
                    errors.append(contentsOf: rowErrors)
                    continue
                }
                group = g
            } else if !kindStr.isEmpty {
                guard let k = CSVExerciseFields.kind(from: kindStr) else {
                    rowErrors.append("Line \(lineNo): 'kind' isn't a known kind (got \"\(kindStr)\").")
                    errors.append(contentsOf: rowErrors)
                    continue
                }
                group = k.section
            } else {
                let groups = knownGroups[exerciseName] ?? []
                guard groups.count == 1, let g = groups.first else {
                    if !exerciseName.isEmpty {
                        rowErrors.append(groups.isEmpty
                            ? "Line \(lineNo): \(exerciseName) isn't in your library or elsewhere in this file. Import it first, or fill 'group' and 'kind'."
                            : "Line \(lineNo): \(exerciseName) is in more than one group (\(groups.map(\.rawValue).sorted().joined(separator: ", "))); fill 'group'.")
                    }
                    errors.append(contentsOf: rowErrors)
                    continue
                }
                group = g
            }

            // Machine settings (optional). Validate format if present.
            let machineName = field(row, "machine")
            var settings: [(label: String, numeric: Int?, other: String?)] = []
            let settingsStr = field(row, "machine_settings")
            if !settingsStr.isEmpty {
                settings = Self.parseSettings(settingsStr, lineNo: lineNo, into: &rowErrors)
            }

            var parsed = ParsedRow(routine: routineName,
                                   order: order,
                                   lineNo: lineNo,
                                   group: group,
                                   exercise: exerciseName,
                                   machine: machineName,
                                   settings: settings,
                                   notes: field(row, "notes"))

            parsed.fields = CSVExerciseFields.parse({ field(row, $0) }, group: group, lineNo: lineNo,
                                                    maxSet: maxSet, allowsSetColumns: true, errors: &rowErrors)
            let usesSets = parsed.fields.map { $0.kind.usesSets } ?? (group == .strength)
            if let f = parsed.fields, let existing = exerciseByKey["\(exerciseName)|\(group.rawValue)"],
               let existingKind = existing.kind, existingKind != f.kind {
                rowErrors.append("Line \(lineNo): \(exerciseName) is already in your library as \(CSVExerciseFields.name(of: existingKind)); use that kind or leave 'kind' blank.")
            }
            if let f = parsed.fields, let def = definingRow["\(exerciseName)|\(group.rawValue)"],
               let defKind = def.fields?.kind, defKind != f.kind {
                rowErrors.append("Line \(lineNo): \(exerciseName) is \(CSVExerciseFields.name(of: defKind)) on line \(def.lineNo); use one kind, or leave 'kind' blank here.")
            }

            switch group {
            case _ where parsed.fields != nil || !field(row, "kind").isEmpty:
                // The kind's own columns were read above; setK pairs plan this
                // routine's sets for a kind with sets.
                if usesSets {
                    for i in stride(from: 1, through: maxSet, by: 1) {
                        let rs = field(row, "set\(i)_reps"), ws = field(row, "set\(i)_weight")
                        if rs.isEmpty && ws.isEmpty { continue }
                        // Blank weight = 0, for kinds with no weight.
                        if let r = Int(rs), r > 0, let w = ws.isEmpty ? 0 : Double(ws), w >= 0 {
                            parsed.plannedSets.append((reps: r, weight: w))
                        } else {
                            rowErrors.append("Line \(lineNo): set \(i) needs whole reps > 0 and weight ≥ 0 (got reps \"\(rs)\", weight \"\(ws)\").")
                        }
                    }
                }
                // Only a filled duration sets the cardio section's length.
                if let f = parsed.fields, f.kind == .steady, !field(row, "duration_min").isEmpty {
                    parsed.durationMin = f.durationMinutes
                }

            case .strength:
                // Per-set columns are OPTIONAL here: if a row leaves them blank,
                // the exercise's own default sets (from the library) are used.
                for i in 1...max(1, maxSet) {
                    let rs = field(row, "set\(i)_reps"), ws = field(row, "set\(i)_weight")
                    if rs.isEmpty && ws.isEmpty { continue }
                    if let r = Int(rs), r > 0, let w = Double(ws), w >= 0 {
                        parsed.plannedSets.append((reps: r, weight: w))
                    } else {
                        rowErrors.append("Line \(lineNo): set \(i) needs whole reps > 0 and weight ≥ 0 (got reps \"\(rs)\", weight \"\(ws)\").")
                    }
                }

            case .cardio:
                // Optional here; blank → the exercise's own duration/intensity.
                let durStr = field(row, "duration_min"), intStr = field(row, "intensity")
                if !durStr.isEmpty {
                    if let v = Int(durStr), v > 0 { parsed.durationMin = v }
                    else { rowErrors.append("Line \(lineNo): 'duration_min' must be a positive whole number (got \"\(durStr)\").") }
                }
                if !intStr.isEmpty {
                    if let i = CardioIntensity(rawValue: intStr.lowercased()) { parsed.intensity = i }
                    else { rowErrors.append("Line \(lineNo): 'intensity' must be low, moderate, or high (got \"\(intStr)\").") }
                }

            case .stretching:
                // Only the exercise name is required; blank hold/sides/rounds use defaults.
                let holdStr = field(row, "hold_seconds"), sidesStr = field(row, "sides"), roundsStr = field(row, "rounds")
                if !holdStr.isEmpty {
                    if let v = Int(holdStr), v >= 0 { parsed.holdSeconds = v }
                    else { rowErrors.append("Line \(lineNo): 'hold_seconds' must be a whole number ≥ 0 (got \"\(holdStr)\").") }
                }
                if !sidesStr.isEmpty {
                    if let v = Int(sidesStr), v == 1 || v == 2 { parsed.sidesCount = v }
                    else { rowErrors.append("Line \(lineNo): 'sides' must be 1 or 2 (got \"\(sidesStr)\").") }
                }
                if !roundsStr.isEmpty {
                    if let v = Int(roundsStr), v > 0 { parsed.rounds = v }
                    else { rowErrors.append("Line \(lineNo): 'rounds' must be a positive whole number (got \"\(roundsStr)\").") }
                }
            }

            // Per-exercise cooldown between sets (optional, seconds ≥ 0).
            let setCdStr = field(row, "set_cooldown")
            if !setCdStr.isEmpty {
                if let v = Int(setCdStr), v >= 0 { parsed.setCooldown = v }
                else { rowErrors.append("Line \(lineNo): 'set_cooldown' must be a whole number of seconds ≥ 0 (got \"\(setCdStr)\").") }
            }

            // Routine-level cooldown between exercises (optional). It's one value
            // per routine, but rows may differ (e.g. 0 on warmups, 60 on strength),
            // so we keep the LARGEST value given rather than treating that as an error.
            let exCdStr = field(row, "exercise_cooldown")
            if !exCdStr.isEmpty, !routineName.isEmpty {
                if let v = Int(exCdStr), v >= 0 {
                    exerciseCooldownByRoutine[routineName] = max(exerciseCooldownByRoutine[routineName] ?? 0, v)
                } else {
                    rowErrors.append("Line \(lineNo): 'exercise_cooldown' must be a whole number of seconds ≥ 0 (got \"\(exCdStr)\").")
                }
            }

            if rowErrors.isEmpty {
                parsedRows.append(parsed)
                let key = "\(exerciseName)|\(group.rawValue)"
                if parsed.fields != nil, definingRow[key] == nil { definingRow[key] = parsed }
            } else {
                errors.append(contentsOf: rowErrors)
            }
        }

        // Each routine's rows, in the order they run: by `order` when the
        // routine fills it (on every row, no repeats), otherwise file order.
        var routineNames: [String] = []
        var rowsByRoutine: [String: [ParsedRow]] = [:]
        for p in parsedRows {
            if rowsByRoutine[p.routine] == nil { routineNames.append(p.routine) }
            rowsByRoutine[p.routine, default: []].append(p)
        }
        var orderRoutines: [String] = []
        var entriesByRoutine: [String: [(routine: String, order: Int?, filled: Bool, lineNo: Int)]] = [:]
        for e in orderEntries {
            if entriesByRoutine[e.routine] == nil { orderRoutines.append(e.routine) }
            entriesByRoutine[e.routine, default: []].append(e)
        }
        for name in orderRoutines {
            let entries = entriesByRoutine[name] ?? []
            let blank = entries.filter { !$0.filled }
            if !blank.isEmpty && blank.count < entries.count {
                errors.append("Routine \(name): 'order' is blank on line(s) \(blank.map { String($0.lineNo) }.joined(separator: ", ")); fill it on every row of the routine or on none.")
                continue
            }
            var seen: [Int: Int] = [:]   // order → first line
            for e in entries {
                guard let o = e.order else { continue }
                if let first = seen[o] {
                    errors.append("Line \(e.lineNo): routine \(name) already has order \(o) (line \(first)).")
                } else { seen[o] = e.lineNo }
            }
        }
        for name in routineNames {
            rowsByRoutine[name]?.sort { ($0.order ?? 0, $0.lineNo) < ($1.order ?? 0, $1.lineNo) }
        }

        // If anything is wrong, import NOTHING.
        guard errors.isEmpty else { throw CSVImportError.invalidData(errors) }

        // ---- PASS 2: create records (now guaranteed valid). ----
        // Routines that already exist (by name) are skipped, or with
        // updateExisting rebuilt when the file differs; exercises that already
        // exist (by name + group) are reused, not duplicated.
        let repo = RoutineRepository(context)
        var report = CSVImportReport()

        // A CSV import is the user's own data, so it only ever matches the
        // user's routines and exercises (exerciseByKey, above) — never demo ones.
        var existingRoutines: [String: Routine] = [:]
        for r in (try? context.fetch(
            FetchDescriptor<Routine>(predicate: #Predicate { $0.deletedAt == nil && $0.sourceRaw == user })
        )) ?? [] where existingRoutines[r.name] == nil {
            existingRoutines[r.name] = r
        }

        // Exercise definition, shared by (name, group). Reuse an existing one
        // (from the library or earlier in this import); only create when new —
        // and only then create its machine, so existing data isn't duplicated.
        func exercise(for parsed: ParsedRow) -> Exercise {
            let exKey = "\(parsed.exercise)|\(parsed.group.rawValue)"
            if let e = exerciseByKey[exKey] { return e }
            if let def = parsed.fields != nil ? parsed : definingRow[exKey], let fields = def.fields {
                // Defined by this row's kind, or by another row's when this
                // row (run earlier) names the exercise without one.
                let e = Exercise(name: def.exercise, notes: def.notes, source: .user)
                fields.apply(to: e)
                var machines: [Machine] = []
                if fields.needsMachine(named: def.machine) {
                    let m = CSVExerciseImporter.makeMachine(
                        named: def.machine.isEmpty ? def.exercise : def.machine,
                        settings: CSVExerciseFields.settingKinds.contains(fields.kind) ? def.settings : [],
                        context: context)
                    m.weight = fields.machineWeight
                    machines.append(m)
                }
                e.machineIds = machines.map(\.id)
                context.insert(e)
                ExerciseLegacyFields.write(e, machines: machines, context: context)
                exerciseByKey[exKey] = e
                return e
            }
            // Machine (optional; stretching has no machine). Shared by name.
            var machineId: UUID?
            if parsed.group != .stretching, !parsed.machine.isEmpty {
                machineId = CSVExerciseImporter.makeMachine(named: parsed.machine,
                                                            settings: parsed.settings,
                                                            context: context).id
            }
            let e = Exercise(name: parsed.exercise, machineId: machineId,
                             notes: parsed.notes, source: .user)
            e.defaultSectionType = parsed.group
            switch parsed.group {
            case .strength:
                for (i, s) in parsed.plannedSets.enumerated() {
                    let set = ExerciseDefaultSet(order: i, reps: s.reps, weight: s.weight)
                    set.exercise = e
                    e.defaultSets.append(set)
                    context.insert(set)
                }
            case .cardio:
                e.durationMinutes = parsed.durationMin
                e.intensity = parsed.intensity
            case .stretching:
                e.sides = parsed.sidesCount
                e.holdSeconds = parsed.holdSeconds
                e.rounds = parsed.rounds
            }
            context.insert(e)
            exerciseByKey[exKey] = e
            return e
        }

        for name in routineNames {
            let rows = rowsByRoutine[name] ?? []
            let version: RoutineVersion
            if let existing = existingRoutines[name] {
                guard updateExisting, let active = existing.activeVersion else {
                    report.routinesSkipped += 1
                    continue
                }
                var plan = Self.plan(rows, exercises: rows.map(exercise(for:)))
                if Self.version(active, matches: plan, exerciseCooldown: exerciseCooldownByRoutine[name]) {
                    report.routinesUnchanged += 1
                    continue
                }
                // A version a workout was started from is never changed.
                version = repo.isReferencedBySession(active)
                    ? repo.makeNewVersion(of: existing, note: "Updated by import")
                    : active
                // A cardio length the file leaves blank keeps the routine's own.
                let lengths = version.orderedSections.map { ($0.type, $0.durationMinutes) }
                for (i, section) in plan.enumerated() where section.durationMinutes == nil
                    && i < lengths.count && lengths[i].0 == section.type {
                    plan[i].durationMinutes = lengths[i].1
                }
                for section in version.sections { context.delete(section) }
                version.sections = []
                existing.updatedAt = .now
                report.routinesUpdated += 1
                build(version, plan: plan, repo: repo, report: &report)
            } else {
                let routine = repo.createRoutine(name: name, source: .user)
                report.routinesCreated += 1
                guard let v = routine.activeVersion else { continue }
                version = v
                build(version, plan: Self.plan(rows, exercises: rows.map(exercise(for:))), repo: repo, report: &report)
            }
            // Routine-level "between exercises" cooldown.
            if let exCd = exerciseCooldownByRoutine[name] {
                version.defaultRestBetweenExercises = exCd
            }
        }

        Audit.log(context, type: "import.csv", entity: "Routine",
                  summary: report.summary, source: .user)
        if saves { try context.save() }   // reported, not swallowed
        return report
    }

    /// One section of a routine as the file describes it.
    private struct PlannedSection {
        var type: SectionType
        var durationMinutes: Int?
        var items: [(row: ParsedRow, exercise: Exercise)] = []
    }

    /// A routine's rows as sections: one per run of consecutive rows in the
    /// same group. A cardio section's length is the first duration its rows give.
    private static func plan(_ rows: [ParsedRow], exercises: [Exercise]) -> [PlannedSection] {
        var sections: [PlannedSection] = []
        for (row, exercise) in zip(rows, exercises) {
            if sections.last?.type != row.group { sections.append(PlannedSection(type: row.group)) }
            let i = sections.count - 1
            if row.group == .cardio, sections[i].durationMinutes == nil, row.durationMin > 0 {
                sections[i].durationMinutes = row.durationMin
            }
            sections[i].items.append((row, exercise))
        }
        return sections
    }

    /// Whether a routine version already holds what the file describes: its
    /// sections and exercises in order, plus a cardio length or exercise
    /// cooldown where the file fills one. Sets, set cooldowns and notes follow
    /// the library (CatalogSyncService), so comparing them would report a
    /// change after every reconcile.
    private static func version(_ v: RoutineVersion, matches plan: [PlannedSection],
                                exerciseCooldown: Int?) -> Bool {
        if let cd = exerciseCooldown, cd != v.defaultRestBetweenExercises { return false }
        let sections = v.orderedSections
        guard sections.count == plan.count else { return false }
        for (section, planned) in zip(sections, plan) {
            let exercises = section.orderedExercises
            guard section.type == planned.type,
                  planned.durationMinutes == nil || section.durationMinutes == planned.durationMinutes,
                  exercises.map(\.exerciseId) == planned.items.map(\.exercise.id) else { return false }
        }
        return true
    }

    /// Add the planned sections and exercises to an empty version.
    private func build(_ version: RoutineVersion, plan: [PlannedSection],
                       repo: RoutineRepository, report: inout CSVImportReport) {
        for planned in plan {
            let section = repo.addSection(to: version, type: planned.type, durationMinutes: planned.durationMinutes)
            for (parsed, exercise) in planned.items {
                // Strength carries per-set planned rows; cardio/stretching are
                // time-based (no planned sets) — their prescription lives on
                // the exercise definition.
                let restBetweenSets = parsed.setCooldown ?? version.defaultRestBetweenSets
                let usesSets = exercise.kind?.usesSets ?? (parsed.group == .strength)
                let planned: [(reps: Int, weight: Double)]
                if !usesSets {
                    planned = []
                } else if !parsed.plannedSets.isEmpty {
                    planned = parsed.plannedSets
                } else if !exercise.effectiveDefaultSets.isEmpty {
                    // Blank set columns → use the exercise's own default sets.
                    planned = exercise.effectiveDefaultSets
                } else {
                    planned = [(reps: 10, weight: 0)]   // a single starter set
                }
                repo.addExercise(to: section, exercise: exercise,
                                 plannedSets: planned,
                                 restBetweenSets: restBetweenSets,
                                 notes: parsed.notes)
                report.exercisesAdded += 1
            }
        }
    }

    /// Write the example CSV to a temp file for sharing.
    static func writeExampleFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutRoutineTemplate.csv")
        try exampleCSV.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Parsing helpers

    static func group(from raw: String) -> SectionType? {
        switch raw.lowercased() {
        case "strength": return .strength
        case "cardio": return .cardio
        case "stretch", "stretching": return .stretching
        default: return nil
        }
    }

    /// Parse "Label=Value; Label2=Value2" into up to Machine.maxSettings setting tuples. A numeric
    /// 0...15 value becomes a slider pick; anything else is stored as free text.
    static func parseSettings(_ raw: String, lineNo: Int,
                              into errors: inout [String]) -> [(label: String, numeric: Int?, other: String?)] {
        var out: [(label: String, numeric: Int?, other: String?)] = []
        let pairs = raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if pairs.count > Machine.maxSettings {
            errors.append("Line \(lineNo): 'machine_settings' has \(pairs.count) entries; the max is \(Machine.maxSettings).")
            return []
        }
        for pair in pairs {
            guard let eq = pair.firstIndex(of: "=") else {
                errors.append("Line \(lineNo): 'machine_settings' entry \"\(pair)\" must be in the form Label=Value.")
                return []
            }
            let label = pair[..<eq].trimmingCharacters(in: .whitespaces)
            let value = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else {
                errors.append("Line \(lineNo): 'machine_settings' entry \"\(pair)\" is missing a label.")
                return []
            }
            if let n = Int(value), MachineSettingDefinition.valueRange.contains(n) {
                out.append((label: label, numeric: n, other: nil))
            } else {
                out.append((label: label, numeric: nil, other: value.isEmpty ? nil : value))
            }
        }
        return out
    }

    /// Minimal RFC 4180-ish CSV parser: handles quoted fields, embedded commas,
    /// escaped quotes ("") and CRLF/LF line endings.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        // Iterate Unicode SCALARS, not Characters: Swift collapses "\r\n" into a
        // single Character grapheme cluster, which would hide CRLF line breaks
        // (the format Google Sheets / Excel export). Scalars keep \r and \n
        // separate, so CRLF, LF, and lone-CR files all split into rows correctly.
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count && scalars[i + 1] == "\"" { field.unicodeScalars.append("\""); i += 1 }
                    else { inQuotes = false }
                } else { field.unicodeScalars.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\r", "\n":
                    row.append(field); field = ""
                    rows.append(row); row = []
                    if c == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 } // CRLF: skip the LF
                default: field.unicodeScalars.append(c)
                }
            }
            i += 1
        }
        // Last field/row (no trailing newline).
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
