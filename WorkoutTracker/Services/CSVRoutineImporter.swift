//
//  CSVRoutineImporter.swift
//  WorkoutTracker
//
//  Imports a CSV file into one or more routines (with their exercises). Designed
//  to be forgiving about column order/casing but strict about structure: it
//  reports clear errors for a missing header, missing required columns, or
//  non-numeric set/rep/weight values, and skips bad rows while importing good
//  ones.
//
//  Expected columns (header row, case-insensitive, any order):
//      routine, section, exercise, machine, sets, reps, weight
//  Required: routine, exercise, sets, reps, weight   (section/machine optional)
//  One row = one exercise; `sets` copies of (reps, weight) become its planned
//  sets. Rows with the same routine name are grouped into one routine.
//

import Foundation
import SwiftData

struct CSVImportReport {
    var routinesCreated = 0
    var exercisesAdded = 0
    var rowErrors: [String] = []

    var summary: String {
        var s = "Imported \(routinesCreated) routine(s), \(exercisesAdded) exercise(s)."
        if !rowErrors.isEmpty { s += " \(rowErrors.count) row(s) skipped." }
        return s
    }
}

enum CSVImportError: LocalizedError {
    case notCSV
    case empty
    case missingColumns([String])
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notCSV: return "That file isn't a .csv file. Please choose a CSV."
        case .empty: return "The CSV file is empty."
        case .unreadable: return "The file could not be read as text."
        case .missingColumns(let cols):
            return "The CSV is missing required column(s): \(cols.joined(separator: ", "))."
        }
    }
}

@MainActor
struct CSVRoutineImporter {
    let context: ModelContext

    init(_ context: ModelContext) { self.context = context }

    /// The example/template CSV the app can import successfully.
    static let exampleCSV = """
    routine,section,exercise,machine,sets,reps,weight
    YMCA Full Body A,cardio,Treadmill,,1,1,0
    YMCA Full Body A,strength,Leg Press,Leg Press,3,10,120
    YMCA Full Body A,strength,Chest Press,Chest Press,3,10,60
    YMCA Full Body A,strength,Lat Pulldown,Lat Pulldown,3,10,80
    YMCA Full Body A,stretching,Hamstring Stretch,,1,1,0
    YMCA Full Body B,strength,Seated Row,Seated Row,3,10,70
    YMCA Full Body B,strength,Shoulder Press,Shoulder Press,3,8,40
    """

    /// Validate the picked file is a CSV, then import its text.
    func importFile(at url: URL) throws -> CSVImportReport {
        guard url.pathExtension.lowercased() == "csv" else { throw CSVImportError.notCSV }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { throw CSVImportError.unreadable }
        return try importText(text)
    }

    /// Parse and import CSV text.
    func importText(_ text: String) throws -> CSVImportReport {
        let rows = Self.parse(text)
        guard let header = rows.first, !header.isEmpty else { throw CSVImportError.empty }

        // Map column name -> index (case-insensitive).
        var index: [String: Int] = [:]
        for (i, name) in header.enumerated() {
            index[name.trimmingCharacters(in: .whitespaces).lowercased()] = i
        }
        let required = ["routine", "exercise", "sets", "reps", "weight"]
        let missing = required.filter { index[$0] == nil }
        guard missing.isEmpty else { throw CSVImportError.missingColumns(missing) }

        let dataRows = rows.dropFirst().filter { !($0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty) }
        guard !dataRows.isEmpty else { throw CSVImportError.empty }

        let repo = RoutineRepository(context)
        var report = CSVImportReport()
        var routineByName: [String: Routine] = [:]
        var sectionCache: [String: RoutineSection] = [:]   // key: routineName|sectionType
        var exerciseByName: [String: Exercise] = [:]
        var machineByName: [String: Machine] = [:]

        func field(_ row: [String], _ key: String) -> String {
            guard let i = index[key], i < row.count else { return "" }
            return row[i].trimmingCharacters(in: .whitespaces)
        }

        for (offset, row) in dataRows.enumerated() {
            let lineNo = offset + 2 // header is line 1
            let routineName = field(row, "routine")
            let exerciseName = field(row, "exercise")
            let setsStr = field(row, "sets")
            let repsStr = field(row, "reps")
            let weightStr = field(row, "weight")

            guard !routineName.isEmpty, !exerciseName.isEmpty else {
                report.rowErrors.append("Line \(lineNo): missing routine or exercise name."); continue
            }
            guard let sets = Int(setsStr), sets > 0 else {
                report.rowErrors.append("Line \(lineNo): 'sets' must be a positive whole number (got \"\(setsStr)\")."); continue
            }
            guard let reps = Int(repsStr), reps > 0 else {
                report.rowErrors.append("Line \(lineNo): 'reps' must be a positive whole number (got \"\(repsStr)\")."); continue
            }
            guard let weight = Double(weightStr), weight >= 0 else {
                report.rowErrors.append("Line \(lineNo): 'weight' must be a number (got \"\(weightStr)\")."); continue
            }

            // Routine (grouped by name).
            let routine: Routine
            if let existing = routineByName[routineName] {
                routine = existing
            } else {
                routine = repo.createRoutine(name: routineName, source: .user)
                routineByName[routineName] = routine
                report.routinesCreated += 1
            }
            guard let version = routine.activeVersion else { continue }

            // Section.
            let sectionType = Self.sectionType(from: field(row, "section"))
            let sectionKey = "\(routineName)|\(sectionType.rawValue)"
            let section: RoutineSection
            if let cached = sectionCache[sectionKey] {
                section = cached
            } else {
                section = repo.addSection(to: version, type: sectionType,
                                          durationMinutes: sectionType.isTimeBased ? 10 : nil)
                sectionCache[sectionKey] = section
            }

            // Machine (optional, shared by name).
            var machineId: UUID?
            let machineName = field(row, "machine")
            if !machineName.isEmpty {
                if let m = machineByName[machineName] {
                    machineId = m.id
                } else {
                    let m = Machine(name: machineName, source: .user)
                    context.insert(m)
                    machineByName[machineName] = m
                    machineId = m.id
                }
            }

            // Exercise (catalog, shared by name+machine).
            let exKey = "\(exerciseName)|\(machineName)"
            let exercise: Exercise
            if let e = exerciseByName[exKey] {
                exercise = e
            } else {
                let e = Exercise(name: exerciseName, machineId: machineId, source: .user)
                context.insert(e)
                exerciseByName[exKey] = e
                exercise = e
            }

            let plannedSets = Array(repeating: (reps: reps, weight: weight), count: sets)
            repo.addExercise(to: section, exercise: exercise,
                             plannedSets: plannedSets,
                             restBetweenSets: version.defaultRestBetweenSets)
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

    // MARK: - Parsing

    private static func sectionType(from raw: String) -> SectionType {
        let s = raw.lowercased()
        if s.contains("cardio") { return .cardio }
        if s.contains("stretch") { return .stretching }
        return .strength
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
