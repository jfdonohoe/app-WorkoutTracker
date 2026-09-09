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
//  separate "event" (ScheduleRule) created from the Calendar/Today views, so this
//  template has no recurrence columns.
//
//  Expected columns (header row, case-insensitive, any order):
//      routine, group, exercise, machine, machine_settings,
//      set1_reps, set1_weight, set2_reps, set2_weight, … setN_reps, setN_weight,
//      duration_min, intensity, hold_seconds, sides, rounds,
//      set_cooldown, exercise_cooldown, notes
//  Always required: routine, group, exercise.
//  Optional cooldowns (seconds): set_cooldown = rest between sets for THAT
//  exercise (blank → routine default); exercise_cooldown = rest between exercises
//  for the routine (one routine-level value; if rows differ, the largest is used).
//  Required per group:
//      • strength    → per-set columns are OPTIONAL; if blank, the exercise's own
//                       default sets (from the library) are used. Each filled setK
//                       pair is one planned set (sets can differ in reps/weight).
//      • cardio      → duration_min / intensity are OPTIONAL (blank → exercise's
//                       own duration/intensity); validated if present
//      • stretching  → nothing extra (exercise name only; hold_seconds, sides,
//                       rounds are optional and default when blank)
//  In short: a routine row only needs routine + group + exercise; the exercise's
//  saved definition supplies any prescription left blank.
//  Optional everywhere: machine, machine_settings, notes.
//  machine_settings format: "Label=Value; Label2=Value2" (max Machine.maxSettings). A numeric
//  value 1...15 becomes a slider pick; anything else is stored as free text.
//
//  One row = one exercise in a routine. Rows with the same routine name are
//  grouped into one routine; rows with the same exercise name + group share one
//  exercise definition.
//

import Foundation
import SwiftData

struct CSVImportReport {
    var routinesCreated = 0
    var exercisesAdded = 0
    /// Items that already existed and were ignored (import only adds new items).
    var routinesSkipped = 0
    var exercisesSkipped = 0
    /// Always empty on success (import is all-or-nothing); kept for compatibility.
    var rowErrors: [String] = []

    var summary: String {
        var parts: [String] = []
        if routinesCreated > 0 || routinesSkipped > 0 { parts.append("\(routinesCreated) routine(s)") }
        parts.append("\(exercisesAdded) exercise(s)")
        var s = "Imported " + parts.joined(separator: ", ") + "."
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

    init(_ context: ModelContext) { self.context = context }

    /// The example/template CSV the app can import successfully. One row per
    /// group so users can see exactly which columns each group uses.
    static let exampleCSV = """
    routine,group,exercise,machine,machine_settings,set1_reps,set1_weight,set2_reps,set2_weight,set3_reps,set3_weight,set4_reps,set4_weight,set5_reps,set5_weight,duration_min,intensity,hold_seconds,sides,rounds,set_cooldown,exercise_cooldown,notes
    Gym Full Body A,strength,Leg Press,Leg Press,Seat height=5; Back angle=3,12,100,10,120,10,120,8,140,6,160,,,,,,90,180,Pyramid up
    Gym Full Body A,strength,Chest Press,Chest Press,Seat height=6,10,60,10,60,10,60,,,,,,,,,,60,,
    Gym Full Body A,cardio,Treadmill,,,,,,,,,,,,,20,moderate,,,,,,Steady pace
    Gym Full Body A,stretching,Hamstring Stretch,,,,,,,,,,,,,,,30,2,3,,,Keep back flat
    Gym Full Body B,strength,Seated Row,Seated Row,Chest pad=5; Seat height=6,10,70,10,70,8,80,6,90,,,,,,,,75,120,
    Gym Full Body B,cardio,Stationary Bike,,,,,,,,,,,,,15,low,,,,,,Cooldown spin
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
        var group: SectionType
        var exercise: String
        var machine: String
        var settings: [(label: String, numeric: Int?, other: String?)]
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
        let required = ["routine", "group", "exercise"]
        let missing = required.filter { index[$0] == nil }
        guard missing.isEmpty else { throw CSVImportError.missingColumns(missing) }

        let dataRows = rows.dropFirst().filter { !($0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty) }
        guard !dataRows.isEmpty else { throw CSVImportError.empty }

        func field(_ row: [String], _ key: String) -> String {
            guard let i = index[key], i < row.count else { return "" }
            return row[i].trimmingCharacters(in: .whitespaces)
        }

        // How many setK_reps/setK_weight column pairs the header defines (strength).
        var maxSet = 0
        var sn = 1
        while index["set\(sn)_reps"] != nil || index["set\(sn)_weight"] != nil { maxSet = sn; sn += 1 }

        // ---- PASS 1: validate EVERYTHING. No inserts happen here. ----
        var errors: [String] = []
        var parsedRows: [ParsedRow] = []
        // Routine-level "between exercises" cooldown (one value per routine).
        var exerciseCooldownByRoutine: [String: Int] = [:]

        for (offset, row) in dataRows.enumerated() {
            let lineNo = offset + 2 // header is line 1
            var rowErrors: [String] = []

            let routineName = field(row, "routine")
            let exerciseName = field(row, "exercise")
            if routineName.isEmpty { rowErrors.append("Line \(lineNo): 'routine' is required.") }
            if exerciseName.isEmpty { rowErrors.append("Line \(lineNo): 'exercise' is required.") }

            guard let group = Self.group(from: field(row, "group")) else {
                rowErrors.append("Line \(lineNo): 'group' must be strength, cardio, or stretching (got \"\(field(row, "group"))\").")
                errors.append(contentsOf: rowErrors)
                continue
            }

            // Machine settings (optional). Validate format if present.
            let machineName = field(row, "machine")
            var settings: [(label: String, numeric: Int?, other: String?)] = []
            let settingsStr = field(row, "machine_settings")
            if !settingsStr.isEmpty {
                settings = Self.parseSettings(settingsStr, lineNo: lineNo, into: &rowErrors)
            }

            var parsed = ParsedRow(routine: routineName,
                                   group: group,
                                   exercise: exerciseName,
                                   machine: machineName,
                                   settings: settings,
                                   notes: field(row, "notes"))

            switch group {
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
            } else {
                errors.append(contentsOf: rowErrors)
            }
        }

        // If anything is wrong, import NOTHING.
        guard errors.isEmpty else { throw CSVImportError.invalidData(errors) }

        // ---- PASS 2: create records (now guaranteed valid). ----
        // Additive-only: routines that already exist (by name) are ignored, and
        // exercises that already exist (by name + group) are reused, not duplicated.
        let repo = RoutineRepository(context)
        var report = CSVImportReport()
        var routineByName: [String: Routine] = [:]
        var sectionCache: [String: RoutineSection] = [:]   // key: routineName|group
        var exerciseByKey: [String: Exercise] = [:]        // key: name|group
        var machineByName: [String: Machine] = [:]

        // Existing data to skip/reuse.
        let existingRoutineNames = Set((try? context.fetch(
            FetchDescriptor<Routine>(predicate: #Predicate { $0.deletedAt == nil })
        ))?.map(\.name) ?? [])
        var skippedRoutineNames = Set<String>()
        for e in (try? context.fetch(
            FetchDescriptor<Exercise>(predicate: #Predicate { $0.deletedAt == nil })
        )) ?? [] {
            exerciseByKey["\(e.name)|\(e.defaultSectionType.rawValue)"] = e
        }

        for parsed in parsedRows {
            // Skip rows belonging to a routine that already exists.
            if existingRoutineNames.contains(parsed.routine) {
                if skippedRoutineNames.insert(parsed.routine).inserted { report.routinesSkipped += 1 }
                continue
            }

            // Routine (grouped by name).
            let routine: Routine
            if let existing = routineByName[parsed.routine] {
                routine = existing
            } else {
                routine = repo.createRoutine(name: parsed.routine, source: .user)
                routineByName[parsed.routine] = routine
                report.routinesCreated += 1
                // Routine-level "between exercises" cooldown.
                if let exCd = exerciseCooldownByRoutine[parsed.routine] {
                    routine.activeVersion?.defaultRestBetweenExercises = exCd
                }
            }
            guard let version = routine.activeVersion else { continue }

            // Section per (routine, group).
            let sectionKey = "\(parsed.routine)|\(parsed.group.rawValue)"
            let section: RoutineSection
            if let cached = sectionCache[sectionKey] {
                section = cached
            } else {
                section = repo.addSection(to: version, type: parsed.group,
                                          durationMinutes: (parsed.group == .cardio && parsed.durationMin > 0) ? parsed.durationMin : nil)
                sectionCache[sectionKey] = section
            }

            // Exercise definition, shared by (name, group). Reuse an existing one
            // (from the library or earlier in this import); only create when new —
            // and only then create its machine, so existing data isn't duplicated.
            let exKey = "\(parsed.exercise)|\(parsed.group.rawValue)"
            let exercise: Exercise
            if let e = exerciseByKey[exKey] {
                exercise = e
            } else {
                // Machine (optional; stretching has no machine). Shared by name.
                var machineId: UUID?
                if parsed.group != .stretching, !parsed.machine.isEmpty {
                    if let m = machineByName[parsed.machine] {
                        machineId = m.id
                    } else {
                        let m = Machine(name: parsed.machine, source: .user)
                        context.insert(m)
                        for (i, s) in parsed.settings.prefix(Machine.maxSettings).enumerated() {
                            let def = MachineSettingDefinition(label: s.label, order: i,
                                                               numericValue: s.numeric,
                                                               otherText: s.other, source: .user)
                            def.machine = m
                            m.settingDefinitions.append(def)
                            context.insert(def)
                        }
                        machineByName[parsed.machine] = m
                        machineId = m.id
                    }
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
                exercise = e
            }

            // Add to the routine section. Strength carries per-set planned rows;
            // cardio/stretching are time-based (no planned sets) — their
            // prescription lives on the exercise definition.
            let restBetweenSets = parsed.setCooldown ?? version.defaultRestBetweenSets
            switch parsed.group {
            case .strength:
                // Blank set columns → use the exercise's own default sets; if it
                // has none either, fall back to a single starter set.
                let planned: [(reps: Int, weight: Double)]
                if !parsed.plannedSets.isEmpty {
                    planned = parsed.plannedSets
                } else if !exercise.effectiveDefaultSets.isEmpty {
                    planned = exercise.effectiveDefaultSets
                } else {
                    planned = [(reps: 10, weight: 0)]
                }
                repo.addExercise(to: section, exercise: exercise,
                                 plannedSets: planned,
                                 restBetweenSets: restBetweenSets,
                                 notes: parsed.notes)
            case .cardio, .stretching:
                repo.addExercise(to: section, exercise: exercise,
                                 plannedSets: [],
                                 restBetweenSets: restBetweenSets,
                                 notes: parsed.notes)
            }
            report.exercisesAdded += 1
        }

        Audit.log(context, type: "import.csv", entity: "Routine",
                  summary: report.summary, source: .user)
        try? context.save()
        return report
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
    /// 1...15 value becomes a slider pick; anything else is stored as free text.
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
            if let n = Int(value), (1...15).contains(n) {
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
