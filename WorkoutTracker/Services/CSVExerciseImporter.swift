//
//  CSVExerciseImporter.swift
//  WorkoutTracker
//
//  Imports a CSV file into the EXERCISE LIBRARY (no routines). Each row defines
//  one exercise with its group-specific attributes, an optional machine + shared
//  settings, and notes. Re-importing updates an existing exercise that has the
//  same name + group (so the template is a source of truth you can edit and
//  re-import).
//
//  Import is ALL-OR-NOTHING — the whole file is validated first; if any row is
//  invalid nothing is imported and every problem is reported.
//
//  Columns (header row, case-insensitive, any order):
//      group, exercise, machine, machine_settings,
//      sets, reps, weight, duration_min, intensity,
//      hold_seconds, sides, rounds, notes
//  Always required: group, exercise.
//  Required per group:
//      • strength    → sets (>0), reps (>0), weight (>=0)
//      • cardio      → duration_min (>0), intensity (low|moderate|high)
//      • stretching  → hold_seconds (>0), sides (1 or 2), rounds (>0)
//  Optional: machine, machine_settings, notes. (Stretching has no machine.)
//  Shares the CSV parser, settings parser and group mapping with
//  CSVRoutineImporter, and reuses CSVImportError / CSVImportReport.
//

import Foundation
import SwiftData

@MainActor
struct CSVExerciseImporter {
    let context: ModelContext

    init(_ context: ModelContext) { self.context = context }

    static let exampleCSV = """
    group,exercise,machine,machine_settings,sets,reps,weight,duration_min,intensity,hold_seconds,sides,rounds,notes
    strength,Leg Press,Leg Press,Seat height=5; Back angle=3,3,10,120,,,,,,Push through heels
    strength,Chest Press,Chest Press,Seat height=6,3,10,60,,,,,,
    cardio,Treadmill,,,,,,20,moderate,,,,Steady pace
    cardio,Stationary Bike,,,,,,15,low,,,,Cooldown spin
    stretching,Hamstring Stretch,,,,,,,,30,2,3,Keep back flat
    """

    func importFile(at url: URL) throws -> CSVImportReport {
        guard url.pathExtension.lowercased() == "csv" else { throw CSVImportError.notCSV }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { throw CSVImportError.unreadable }
        return try importText(text)
    }

    private struct Row {
        var group: SectionType
        var name: String
        var machine: String
        var settings: [(label: String, numeric: Int?, other: String?)]
        var notes: String
        var sets = 0, reps = 0
        var weight = 0.0
        var durationMin = 0
        var intensity: CardioIntensity = .moderate
        var holdSeconds = 0
        var sidesCount = 1
        var rounds = 1
    }

    func importText(_ text: String) throws -> CSVImportReport {
        let rows = CSVRoutineImporter.parse(text)
        guard let header = rows.first, !header.isEmpty else { throw CSVImportError.empty }

        var index: [String: Int] = [:]
        for (i, name) in header.enumerated() {
            index[name.trimmingCharacters(in: .whitespaces).lowercased()] = i
        }
        let missing = ["group", "exercise"].filter { index[$0] == nil }
        guard missing.isEmpty else { throw CSVImportError.missingColumns(missing) }

        let dataRows = rows.dropFirst().filter { !($0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty) }
        guard !dataRows.isEmpty else { throw CSVImportError.empty }

        func field(_ row: [String], _ key: String) -> String {
            guard let i = index[key], i < row.count else { return "" }
            return row[i].trimmingCharacters(in: .whitespaces)
        }

        // ---- PASS 1: validate everything; no inserts. ----
        var errors: [String] = []
        var parsed: [Row] = []

        for (offset, row) in dataRows.enumerated() {
            let lineNo = offset + 2
            var rowErrors: [String] = []

            let name = field(row, "exercise")
            if name.isEmpty { rowErrors.append("Line \(lineNo): 'exercise' is required.") }

            guard let group = CSVRoutineImporter.group(from: field(row, "group")) else {
                rowErrors.append("Line \(lineNo): 'group' must be strength, cardio, or stretching (got \"\(field(row, "group"))\").")
                errors.append(contentsOf: rowErrors)
                continue
            }

            let machineName = field(row, "machine")
            var settings: [(label: String, numeric: Int?, other: String?)] = []
            let settingsStr = field(row, "machine_settings")
            if !settingsStr.isEmpty {
                settings = CSVRoutineImporter.parseSettings(settingsStr, lineNo: lineNo, into: &rowErrors)
            }

            var r = Row(group: group, name: name, machine: machineName, settings: settings, notes: field(row, "notes"))

            switch group {
            case .strength:
                let setsStr = field(row, "sets"), repsStr = field(row, "reps"), weightStr = field(row, "weight")
                if let v = Int(setsStr), v > 0 { r.sets = v }
                else { rowErrors.append("Line \(lineNo): strength needs 'sets' as a positive whole number (got \"\(setsStr)\").") }
                if let v = Int(repsStr), v > 0 { r.reps = v }
                else { rowErrors.append("Line \(lineNo): strength needs 'reps' as a positive whole number (got \"\(repsStr)\").") }
                if let v = Double(weightStr), v >= 0 { r.weight = v }
                else { rowErrors.append("Line \(lineNo): strength needs 'weight' as a number ≥ 0 (got \"\(weightStr)\").") }
            case .cardio:
                let durStr = field(row, "duration_min"), intStr = field(row, "intensity")
                if let v = Int(durStr), v > 0 { r.durationMin = v }
                else { rowErrors.append("Line \(lineNo): cardio needs 'duration_min' as a positive whole number (got \"\(durStr)\").") }
                if let i = CardioIntensity(rawValue: intStr.lowercased()) { r.intensity = i }
                else { rowErrors.append("Line \(lineNo): cardio needs 'intensity' to be low, moderate, or high (got \"\(intStr)\").") }
            case .stretching:
                let holdStr = field(row, "hold_seconds"), sidesStr = field(row, "sides"), roundsStr = field(row, "rounds")
                if let v = Int(holdStr), v > 0 { r.holdSeconds = v }
                else { rowErrors.append("Line \(lineNo): stretching needs 'hold_seconds' as a positive whole number (got \"\(holdStr)\").") }
                if let v = Int(sidesStr), v == 1 || v == 2 { r.sidesCount = v }
                else { rowErrors.append("Line \(lineNo): stretching needs 'sides' to be 1 or 2 (got \"\(sidesStr)\").") }
                if let v = Int(roundsStr), v > 0 { r.rounds = v }
                else { rowErrors.append("Line \(lineNo): stretching needs 'rounds' as a positive whole number (got \"\(roundsStr)\").") }
            }

            if rowErrors.isEmpty { parsed.append(r) } else { errors.append(contentsOf: rowErrors) }
        }

        guard errors.isEmpty else { throw CSVImportError.invalidData(errors) }

        // ---- PASS 2: create or update exercises. ----
        var machineByName: [String: Machine] = [:]
        let existing = (try? context.fetch(
            FetchDescriptor<Exercise>(predicate: #Predicate { $0.deletedAt == nil })
        )) ?? []
        var exByKey: [String: Exercise] = [:]
        for e in existing { exByKey["\(e.name)|\(e.defaultSectionType.rawValue)"] = e }

        var report = CSVImportReport()

        for r in parsed {
            // Machine (shared by name; not for stretching).
            var machineId: UUID?
            if r.group != .stretching, !r.machine.isEmpty {
                if let m = machineByName[r.machine] {
                    machineId = m.id
                } else {
                    let m = Machine(name: r.machine, source: .user)
                    context.insert(m)
                    for (i, s) in r.settings.prefix(4).enumerated() {
                        let def = MachineSettingDefinition(label: s.label, order: i,
                                                           numericValue: s.numeric, otherText: s.other, source: .user)
                        def.machine = m
                        m.settingDefinitions.append(def)
                        context.insert(def)
                    }
                    machineByName[r.machine] = m
                    machineId = m.id
                }
            }

            // Exercise: update existing (same name + group) or create new.
            let key = "\(r.name)|\(r.group.rawValue)"
            let ex: Exercise
            if let e = exByKey[key] {
                ex = e
            } else {
                let e = Exercise(name: r.name, source: .user)
                context.insert(e)
                exByKey[key] = e
                ex = e
            }
            ex.defaultSectionType = r.group
            ex.notes = r.notes
            if let machineId { ex.machineId = machineId }
            ex.updatedAt = .now

            // Group-specific attributes / default sets.
            for d in ex.defaultSets { context.delete(d) }
            ex.defaultSets = []
            switch r.group {
            case .strength:
                for i in 0..<max(1, r.sets) {
                    let set = ExerciseDefaultSet(order: i, reps: r.reps, weight: r.weight)
                    set.exercise = ex
                    ex.defaultSets.append(set)
                    context.insert(set)
                }
            case .cardio:
                ex.durationMinutes = r.durationMin
                ex.intensity = r.intensity
            case .stretching:
                ex.sides = r.sidesCount
                ex.holdSeconds = r.holdSeconds
                ex.rounds = r.rounds
            }
            report.exercisesAdded += 1
        }

        Audit.log(context, type: "import.csv", entity: "Exercise",
                  summary: report.summary, source: .user)
        try? context.save()
        return report
    }

    static func writeExampleFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutExercisesTemplate.csv")
        try exampleCSV.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}
