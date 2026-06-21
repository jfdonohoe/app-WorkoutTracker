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
//  Expected columns (header row, case-insensitive, any order):
//      routine, group, exercise, machine, machine_settings,
//      sets, reps, weight, duration_min, intensity,
//      hold_seconds, sides, rounds, notes,
//      recurrence, interval, weekday, month_day, count, start_date
//  Always required: routine, group, exercise.
//  Required per group:
//      • strength    → sets (>0), reps (>0), weight (>=0)
//      • cardio      → duration_min (>0), intensity (low|moderate|high)
//      • stretching  → hold_seconds (>0), sides (1 or 2), rounds (>0)
//  Optional everywhere: machine, machine_settings, notes.
//  machine_settings format: "Label=Value; Label2=Value2" (max 4). A numeric
//  value 1...15 becomes a slider pick; anything else is stored as free text.
//
//  Optional SCHEDULE (set on any ONE row of a routine; leave blank elsewhere):
//      • recurrence → daily | weekly | monthly  (blank = not scheduled)
//      • interval   → "every N" (positive int, default 1)
//      • weekday    → weekly only; one or more day names separated by space/'|'/'/'
//                     (e.g. "Mon Wed Fri" or "monday"); 1=Sun…7=Sat order
//      • month_day  → monthly only; 1...31 (blank = the start date's day)
//      • count      → optional total number of occurrences (positive int)
//      • start_date → optional anchor "yyyy-MM-dd" (blank = today)
//  If two rows of the same routine give DIFFERENT schedules, the import is
//  rejected (ambiguous). Identical repeats are allowed.
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
    /// Always empty on success (import is all-or-nothing); kept for compatibility.
    var rowErrors: [String] = []

    var summary: String {
        var parts: [String] = []
        if routinesCreated > 0 { parts.append("\(routinesCreated) routine(s)") }
        parts.append("\(exercisesAdded) exercise(s)")
        return "Imported " + parts.joined(separator: ", ") + "."
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
        case .empty: return "The CSV file is empty."
        case .unreadable: return "The file could not be read as text."
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
    routine,group,exercise,machine,machine_settings,sets,reps,weight,duration_min,intensity,hold_seconds,sides,rounds,notes,recurrence,interval,weekday,month_day,count,start_date
    YMCA Full Body A,strength,Leg Press,Leg Press,Seat height=5; Back angle=3,3,10,120,,,,,,Push through heels,weekly,1,Mon,,,
    YMCA Full Body A,strength,Chest Press,Chest Press,Seat height=6,3,10,60,,,,,,,,,,,,
    YMCA Full Body A,cardio,Treadmill,,,,,,20,moderate,,,,Steady pace,,,,,,
    YMCA Full Body A,stretching,Hamstring Stretch,,,,,,,,30,2,3,Keep back flat,,,,,,
    YMCA Full Body B,strength,Seated Row,Seated Row,Chest pad=5; Seat height=6,3,10,70,,,,,,,weekly,1,Thu,,,
    YMCA Full Body B,cardio,Stationary Bike,,,,,,15,low,,,,Cooldown spin,,,,,,
    """

    /// Validate the picked file is a CSV, then import its text.
    func importFile(at url: URL) throws -> CSVImportReport {
        guard url.pathExtension.lowercased() == "csv" else { throw CSVImportError.notCSV }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { throw CSVImportError.unreadable }
        return try importText(text)
    }

    // MARK: - A fully validated row, ready to insert.

    private struct ParsedRow {
        var routine: String
        var group: SectionType
        var exercise: String
        var machine: String
        var settings: [(label: String, numeric: Int?, other: String?)]
        var notes: String
        // strength
        var sets: Int = 0
        var reps: Int = 0
        var weight: Double = 0
        // cardio
        var durationMin: Int = 0
        var intensity: CardioIntensity = .moderate
        // stretching
        var holdSeconds: Int = 0
        var sidesCount: Int = 1
        var rounds: Int = 1
    }

    /// A validated, routine-level schedule parsed from the optional columns.
    private struct ParsedSchedule: Equatable {
        var freq: RecurrenceFrequency
        var interval: Int
        var weekdays: [Int]
        var monthDay: Int?
        var count: Int?
        var startDate: Date

        /// Equality ignores time-of-day on the anchor (we compare whole days).
        static func == (a: ParsedSchedule, b: ParsedSchedule) -> Bool {
            let cal = Calendar.current
            return a.freq == b.freq && a.interval == b.interval
                && a.weekdays.sorted() == b.weekdays.sorted()
                && a.monthDay == b.monthDay && a.count == b.count
                && cal.isDate(a.startDate, inSameDayAs: b.startDate)
        }
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

        // ---- PASS 1: validate EVERYTHING. No inserts happen here. ----
        var errors: [String] = []
        var parsedRows: [ParsedRow] = []
        var scheduleByRoutine: [String: ParsedSchedule] = [:]

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
                let setsStr = field(row, "sets"), repsStr = field(row, "reps"), weightStr = field(row, "weight")
                if let v = Int(setsStr), v > 0 { parsed.sets = v }
                else { rowErrors.append("Line \(lineNo): strength needs 'sets' as a positive whole number (got \"\(setsStr)\").") }
                if let v = Int(repsStr), v > 0 { parsed.reps = v }
                else { rowErrors.append("Line \(lineNo): strength needs 'reps' as a positive whole number (got \"\(repsStr)\").") }
                if let v = Double(weightStr), v >= 0 { parsed.weight = v }
                else { rowErrors.append("Line \(lineNo): strength needs 'weight' as a number ≥ 0 (got \"\(weightStr)\").") }

            case .cardio:
                let durStr = field(row, "duration_min"), intStr = field(row, "intensity")
                if let v = Int(durStr), v > 0 { parsed.durationMin = v }
                else { rowErrors.append("Line \(lineNo): cardio needs 'duration_min' as a positive whole number (got \"\(durStr)\").") }
                if let i = CardioIntensity(rawValue: intStr.lowercased()) { parsed.intensity = i }
                else { rowErrors.append("Line \(lineNo): cardio needs 'intensity' to be low, moderate, or high (got \"\(intStr)\").") }

            case .stretching:
                let holdStr = field(row, "hold_seconds"), sidesStr = field(row, "sides"), roundsStr = field(row, "rounds")
                if let v = Int(holdStr), v > 0 { parsed.holdSeconds = v }
                else { rowErrors.append("Line \(lineNo): stretching needs 'hold_seconds' as a positive whole number (got \"\(holdStr)\").") }
                if let v = Int(sidesStr), v == 1 || v == 2 { parsed.sidesCount = v }
                else { rowErrors.append("Line \(lineNo): stretching needs 'sides' to be 1 or 2 (got \"\(sidesStr)\").") }
                if let v = Int(roundsStr), v > 0 { parsed.rounds = v }
                else { rowErrors.append("Line \(lineNo): stretching needs 'rounds' as a positive whole number (got \"\(roundsStr)\").") }
            }

            // Optional routine-level schedule. Parsed/validated here; checked for
            // consistency across all rows of the same routine.
            if let sched = Self.parseSchedule(recurrence: field(row, "recurrence"),
                                              interval: field(row, "interval"),
                                              weekday: field(row, "weekday"),
                                              monthDay: field(row, "month_day"),
                                              count: field(row, "count"),
                                              startDate: field(row, "start_date"),
                                              lineNo: lineNo, into: &rowErrors),
               !routineName.isEmpty {
                if let existing = scheduleByRoutine[routineName], existing != sched {
                    rowErrors.append("Line \(lineNo): a different schedule was already given for \"\(routineName)\" — use one schedule per routine.")
                } else {
                    scheduleByRoutine[routineName] = sched
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
        let repo = RoutineRepository(context)
        var report = CSVImportReport()
        var routineByName: [String: Routine] = [:]
        var sectionCache: [String: RoutineSection] = [:]   // key: routineName|group
        var exerciseByKey: [String: Exercise] = [:]        // key: name|group
        var machineByName: [String: Machine] = [:]

        for parsed in parsedRows {
            // Routine (grouped by name).
            let routine: Routine
            if let existing = routineByName[parsed.routine] {
                routine = existing
            } else {
                routine = repo.createRoutine(name: parsed.routine, source: .user)
                routineByName[parsed.routine] = routine
                report.routinesCreated += 1
            }
            guard let version = routine.activeVersion else { continue }

            // Section per (routine, group).
            let sectionKey = "\(parsed.routine)|\(parsed.group.rawValue)"
            let section: RoutineSection
            if let cached = sectionCache[sectionKey] {
                section = cached
            } else {
                section = repo.addSection(to: version, type: parsed.group,
                                          durationMinutes: parsed.group == .cardio ? parsed.durationMin : nil)
                sectionCache[sectionKey] = section
            }

            // Machine (optional; stretching has no machine). Shared by name.
            var machineId: UUID?
            if parsed.group != .stretching, !parsed.machine.isEmpty {
                if let m = machineByName[parsed.machine] {
                    machineId = m.id
                } else {
                    let m = Machine(name: parsed.machine, source: .user)
                    context.insert(m)
                    for (i, s) in parsed.settings.prefix(4).enumerated() {
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

            // Exercise definition, shared by (name, group). On first creation we
            // set its group + group-specific defaults from the CSV.
            let exKey = "\(parsed.exercise)|\(parsed.group.rawValue)"
            let exercise: Exercise
            if let e = exerciseByKey[exKey] {
                exercise = e
            } else {
                let e = Exercise(name: parsed.exercise, machineId: machineId,
                                 notes: parsed.notes, source: .user)
                e.defaultSectionType = parsed.group
                switch parsed.group {
                case .strength:
                    let set = ExerciseDefaultSet(order: 0, reps: parsed.reps, weight: parsed.weight)
                    set.exercise = e
                    e.defaultSets.append(set)
                    context.insert(set)
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
            switch parsed.group {
            case .strength:
                let plannedSets = Array(repeating: (reps: parsed.reps, weight: parsed.weight), count: parsed.sets)
                repo.addExercise(to: section, exercise: exercise,
                                 plannedSets: plannedSets,
                                 restBetweenSets: version.defaultRestBetweenSets,
                                 notes: parsed.notes)
            case .cardio, .stretching:
                repo.addExercise(to: section, exercise: exercise,
                                 plannedSets: [],
                                 restBetweenSets: version.defaultRestBetweenSets,
                                 notes: parsed.notes)
            }
            report.exercisesAdded += 1
        }

        // Create routine-level schedules (validated in PASS 1).
        for (routineName, sched) in scheduleByRoutine {
            guard let routine = routineByName[routineName] else { continue }
            let rule = ScheduleRule(routineId: routine.id,
                                    freq: sched.freq,
                                    interval: sched.interval,
                                    weekdays: sched.weekdays,
                                    startDate: sched.startDate,
                                    count: sched.count,
                                    byMonthDay: sched.monthDay,
                                    source: .user)
            context.insert(rule)
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

    /// yyyy-MM-dd parser for the optional start_date column.
    private static let scheduleDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        return f
    }()

    /// Map a weekday name/abbreviation to a Calendar weekday int (1=Sun…7=Sat).
    private static func weekday(from raw: String) -> Int? {
        switch raw.lowercased() {
        case "sun", "sunday", "su": return 1
        case "mon", "monday", "mo": return 2
        case "tue", "tues", "tuesday", "tu": return 3
        case "wed", "weds", "wednesday", "we": return 4
        case "thu", "thur", "thurs", "thursday", "th": return 5
        case "fri", "friday", "fr": return 6
        case "sat", "saturday", "sa": return 7
        default: return nil
        }
    }

    /// Parse the optional schedule columns. Returns nil when no `recurrence` is
    /// given (no schedule). Any validation problems are appended to `errors` and
    /// nil is returned so the row fails the all-or-nothing check.
    private static func parseSchedule(recurrence: String, interval: String, weekday weekdayStr: String,
                                      monthDay: String, count: String, startDate: String,
                                      lineNo: Int, into errors: inout [String]) -> ParsedSchedule? {
        guard !recurrence.isEmpty else { return nil }
        let before = errors.count

        let freq: RecurrenceFrequency
        switch recurrence.lowercased() {
        case "daily": freq = .daily
        case "weekly": freq = .weekly
        case "monthly": freq = .monthly
        default:
            errors.append("Line \(lineNo): 'recurrence' must be daily, weekly, or monthly (got \"\(recurrence)\").")
            return nil
        }

        var intervalVal = 1
        if !interval.isEmpty {
            if let v = Int(interval), v > 0 { intervalVal = v }
            else { errors.append("Line \(lineNo): 'interval' must be a positive whole number (got \"\(interval)\").") }
        }

        var weekdays: [Int] = []
        if freq == .weekly {
            let tokens = weekdayStr.split(whereSeparator: { " |/,".contains($0) }).map(String.init)
            if tokens.isEmpty {
                errors.append("Line \(lineNo): weekly schedules need at least one 'weekday' (e.g. Mon).")
            } else {
                for t in tokens {
                    if let d = Self.weekday(from: t) { weekdays.append(d) }
                    else { errors.append("Line \(lineNo): unrecognized weekday \"\(t)\".") }
                }
            }
        }
        // 'weekday' is ignored for daily/monthly (no error).

        var monthDayVal: Int?
        if freq == .monthly, !monthDay.isEmpty {
            if let v = Int(monthDay), (1...31).contains(v) { monthDayVal = v }
            else { errors.append("Line \(lineNo): 'month_day' must be 1...31 (got \"\(monthDay)\").") }
        }

        var countVal: Int?
        if !count.isEmpty {
            if let v = Int(count), v > 0 { countVal = v }
            else { errors.append("Line \(lineNo): 'count' must be a positive whole number (got \"\(count)\").") }
        }

        var start = Date()
        if !startDate.isEmpty {
            if let d = scheduleDateFormatter.date(from: startDate) { start = d }
            else { errors.append("Line \(lineNo): 'start_date' must be in yyyy-MM-dd format (got \"\(startDate)\").") }
        }

        guard errors.count == before else { return nil }
        return ParsedSchedule(freq: freq, interval: intervalVal, weekdays: weekdays,
                              monthDay: monthDayVal, count: countVal, startDate: start)
    }

    /// Parse "Label=Value; Label2=Value2" into up to 4 setting tuples. A numeric
    /// 1...15 value becomes a slider pick; anything else is stored as free text.
    static func parseSettings(_ raw: String, lineNo: Int,
                              into errors: inout [String]) -> [(label: String, numeric: Int?, other: String?)] {
        var out: [(label: String, numeric: Int?, other: String?)] = []
        let pairs = raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if pairs.count > 4 {
            errors.append("Line \(lineNo): 'machine_settings' has \(pairs.count) entries; the max is 4.")
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
        let scalars = Array(text)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count && scalars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { inQuotes = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\r":
                    break // ignore; handled by \n
                case "\n":
                    row.append(field); field = ""
                    rows.append(row); row = []
                default: field.append(c)
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
