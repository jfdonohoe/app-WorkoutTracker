//
//  CSVExerciseImporter.swift
//  WorkoutTracker
//
//  Imports the EXERCISE LIBRARY from CSV. Each exercise GROUP has its OWN template
//  and import. A row with a `kind` uses that kind's columns (see
//  CSVExerciseFields); a row without one uses the older columns:
//
//   • strength → exercise, machine, setting1..4_label/value,
//                set1..N_reps/weight (each set its own reps + weight), notes
//   • cardio   → exercise, machine, setting1..4_label/value, duration_min,
//                intensity, notes
//   • stretching → exercise (only the name is required), optional hold_seconds,
//                sides, rounds, notes (no machine)
//
//  Machine settings are split into explicit columns: settingK_label + settingK_value
//  for K = 1...10 (the app caps a machine at Machine.maxSettings). A numeric value 0...15 is a
//  slider pick; anything else is stored as free text.
//
//  Older strength rows read as many setK_reps/setK_weight pairs as the header
//  defines, so an exercise can have any number of sets with independent reps/weight.
//
//  Each new exercise gets its own machine: two exercises can name the same
//  machine, but each keeps its own weight and settings.
//
//  Import is ADDITIVE: an exercise that already exists (same name + group) is
//  ignored, and only new exercises are created. With `replaceExisting` (the
//  Google Sheet and CSV file imports), a row with a kind instead overwrites the existing
//  exercise's definition in place — fields, machines, weights and settings —
//  keeping its id so history and routines still point at it. Machines are
//  matched by name; one no longer listed is unlinked, never deleted.
//
//  `extraMachines` gives a Machine exercise more machines after the row's
//  own (^ rows, from a sheet tab or the file itself). The row's machine is the default. Import is ALL-OR-NOTHING for
//  VALIDATION (any malformed row imports nothing). Shares
//  the CSV parser and CSVImportError / CSVImportReport with CSVRoutineImporter.
//

import Foundation
import SwiftData
import UIKit

/// Live status of the post-import photo downloads, observed by the import screen.
@MainActor
final class PhotoImportStatus: ObservableObject {
    @Published private(set) var total = 0
    /// New photos (the exercise had none).
    @Published private(set) var added = 0
    /// Photos replaced because the image at the link changed.
    @Published private(set) var updated = 0
    /// Re-fetched and the same as before, or set in the app meanwhile.
    @Published private(set) var unchanged = 0
    @Published private(set) var failed = 0

    var pending: Int { max(0, total - added - updated - unchanged - failed) }
    var isDownloading: Bool { total > 0 && pending > 0 }
    var isFinished: Bool { total > 0 && pending == 0 }

    func begin(_ count: Int) { total = count; added = 0; updated = 0; unchanged = 0; failed = 0 }
    func reset() { begin(0) }
    func record(_ result: PhotoRefresh) {
        switch result {
        case .added: added += 1
        case .updated: updated += 1
        case .unchanged: unchanged += 1
        }
    }
    func recordFailure() { failed += 1 }
}

/// What a downloaded photo did to its exercise.
enum PhotoRefresh: Equatable {
    case added, updated, unchanged
}

@MainActor
struct CSVExerciseImporter {
    let context: ModelContext
    let group: SectionType
    let photoStatus: PhotoImportStatus?
    let replaceExisting: Bool
    /// False when the caller saves (or rolls back) several imports together;
    /// photos to fetch are then left in the report for the caller.
    let saves: Bool

    typealias Setting = (label: String, numeric: Int?, other: String?)

    /// One more machine for an exercise: a user label, its weight and settings.
    struct MachineSpec {
        var name: String
        var weight: Double?
        var settings: [Setting] = []
    }

    init(_ context: ModelContext, group: SectionType, photoStatus: PhotoImportStatus? = nil,
         replaceExisting: Bool = false, saves: Bool = true) {
        self.context = context
        self.group = group
        self.photoStatus = photoStatus
        self.replaceExisting = replaceExisting
        self.saves = saves
    }

    // MARK: - Templates

    static func template(for group: SectionType) -> String {
        switch group {
        case .strength:
            // The ^ row gives Leg Press a second machine (the first is the default).
            return """
            exercise,kind,reps,sets,weight,per_side,per_side_custom,implement,added_weight,hold_seconds,machine,setting1_label,setting1_value,setting2_label,setting2_value,setting3_label,setting3_value,setting4_label,setting4_value,setting5_label,setting5_value,setting6_label,setting6_value,notes,photo_url
            Leg Press,machine,10,3,140,single,,,,,Leg Press,Seat height,5,Back angle,3,,,,,,,,,Pyramid up,
            ^,,,,120,,,,,,Leg Press (plate loaded),Seat height,4,Foot plate,High,,,,,,,,,,
            Dumbbell Curl,free_weight,12,3,25,alternating,,dumbbell,,,,,,,,,,,,,,,,Weight is per hand,
            Push-up,bodyweight,15,3,,single,,,,,,,,,,,,,,,,,,,
            Plank,hold,1,3,,single,,,,45,,,,,,,,,,,,,,,
            """
        case .cardio:
            return """
            exercise,kind,duration_min,distance,work_seconds,recovery_seconds,rounds,effort,reps,sets,per_side,machine,setting1_label,setting1_value,setting2_label,setting2_value,setting3_label,setting3_value,setting4_label,setting4_value,setting5_label,setting5_value,setting6_label,setting6_value,notes,photo_url
            Treadmill,steady,20,,,,,moderate,,,,Treadmill,Incline,2,,,,,,,,,,,Steady pace,
            Outdoor Run,distance,,3,,,,moderate,,,,,,,,,,,,,,,,,,
            Bike Sprints,intervals,,,30,60,8,hard,,,,Bike,Resistance,8,,,,,,,,,,,,
            Jumping Jacks,calisthenics,,,,,,,30,3,single,,,,,,,,,,,,,,,
            """
        case .stretching:
            return """
            exercise,kind,hold_seconds,reps,sets,per_side,per_side_custom,prop,timer_seconds,notes,photo_url
            Hamstring Stretch,static,30,2,1,left_right,,strap,,Keep back flat,
            Shoulder Stretch,static,20,1,2,left_right,,,,,
            Leg Swings,dynamic,,10,1,forward_back,,,30,,
            """
        }
    }

    static func writeTemplate(for group: SectionType) throws -> URL {
        let name: String
        switch group {
        case .strength: name = "StrengthExercisesTemplate.csv"
        case .cardio: name = "CardioExercisesTemplate.csv"
        case .stretching: name = "StretchingExercisesTemplate.csv"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try template(for: group).data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    func importFile(at url: URL) throws -> CSVImportReport {
        guard url.pathExtension.lowercased() == "csv" else { throw CSVImportError.notCSV }
        let data = CSVRoutineImporter.readFileData(at: url)
        guard !data.isEmpty else { throw CSVImportError.unreadable } // 0 bytes ≠ "empty CSV"
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { throw CSVImportError.unreadable }
        return try importText(text)
    }

    // MARK: - Parsed row

    private struct Row {
        var name: String
        var machine: String = ""
        var settings: [Setting] = []
        /// Machines after the row's own, from `extraMachines`.
        var extraMachines: [MachineSpec] = []
        /// Set when the row has a `kind`; then the older fields below are unused.
        var fields: CSVExerciseFields?
        var notes: String = ""
        var photoURL: String = ""                      // optional web image to fetch
        var sets: [(reps: Int, weight: Double)] = []  // strength
        var durationMin = 0                            // cardio
        var intensity: CardioIntensity = .moderate     // cardio
        var holdSeconds = 0                            // stretching
        var sidesCount = 1
        var rounds = 1
    }

    /// `extraMachines` is keyed by the exercise row's line number (2 = first data row).
    func importText(_ text: String, extraMachines: [Int: [MachineSpec]] = [:]) throws -> CSVImportReport {
        let rows = CSVRoutineImporter.parse(text)
        guard let header = rows.first, !header.isEmpty else { throw CSVImportError.empty }

        // A file's own ^ rows (more machines for the exercise above), read the
        // same way as the Google Sheet's. Needs the kind column.
        let headerNames = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if extraMachines.isEmpty, headerNames.contains("kind"), let col = headerNames.firstIndex(of: "exercise"),
           rows.dropFirst().contains(where: { col < $0.count && $0[col].trimmingCharacters(in: .whitespaces) == GoogleSheetImport.sameAsAbove }) {
            let split = try GoogleSheetImport.splitMachineRows(text)
            guard !split.csv.isEmpty else { throw CSVImportError.empty }
            do {
                return try importText(split.csv, extraMachines: split.machines)
            } catch CSVImportError.invalidData(let errors) {
                throw CSVImportError.invalidData(errors.map { GoogleSheetImport.relabel($0, origins: split.origins) })
            }
        }

        var index: [String: Int] = [:]
        for (i, name) in header.enumerated() {
            index[name.trimmingCharacters(in: .whitespaces).lowercased()] = i
        }

        // Required columns per group. With a `kind` column, each kind's own
        // fields are optional (blank uses the kind's defaults).
        let required: [String]
        switch group {
        case _ where index["kind"] != nil: required = ["exercise"]
        case .strength: required = ["exercise", "set1_reps", "set1_weight"]
        case .cardio: required = ["exercise", "duration_min", "intensity"]
        case .stretching: required = ["exercise"]
        }
        let missing = required.filter { index[$0] == nil }
        guard missing.isEmpty else { throw CSVImportError.missingColumns(missing) }

        // Blank rows (",,," included) are skipped; each row keeps its file
        // line number so errors name the right row.
        let dataRows = rows.dropFirst().enumerated()
            .filter { !$0.element.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
            .map { (lineNo: $0.offset + 2, row: $0.element) }   // header is line 1
        guard !dataRows.isEmpty else { throw CSVImportError.empty }

        func field(_ row: [String], _ key: String) -> String {
            guard let i = index[key], i < row.count else { return "" }
            return row[i].trimmingCharacters(in: .whitespaces)
        }

        // How many setK_reps/setK_weight column pairs the header defines.
        var maxSet = 0
        var n = 1
        while index["set\(n)_reps"] != nil || index["set\(n)_weight"] != nil { maxSet = n; n += 1 }

        // ---- PASS 1: validate everything. ----
        var errors: [String] = []
        var parsed: [Row] = []
        var firstLine: [String: Int] = [:]   // exercise name → its first line (replace mode)

        for (lineNo, rowFields) in dataRows {
            var rowErrors: [String] = []

            let name = field(rowFields, "exercise")
            if name.isEmpty { rowErrors.append("Line \(lineNo): 'exercise' is required.") }
            if name == GoogleSheetImport.sameAsAbove {
                rowErrors.append("Line \(lineNo): a ^ row (another machine for the exercise above) needs a 'kind' column in the file.")
            }

            var r = Row(name: name, notes: field(rowFields, "notes"))
            r.photoURL = field(rowFields, "photo_url")   // optional; downloaded after import

            r.fields = CSVExerciseFields.parse({ field(rowFields, $0) }, group: group, lineNo: lineNo,
                                               maxSet: maxSet, allowsSetColumns: false, errors: &rowErrors)
            if group != .stretching {
                r.machine = field(rowFields, "machine")
                r.settings = Self.parseMachineSettings({ field(rowFields, $0) }, place: "Line \(lineNo)", into: &rowErrors)
            }
            // Overwriting with two definitions of one exercise would let row
            // order pick the winner, so a repeat is an error. Only rows with a
            // kind overwrite; older rows without one are still just skipped.
            if replaceExisting, r.fields != nil, !name.isEmpty {
                if let first = firstLine[name.lowercased()] {
                    rowErrors.append("Line \(lineNo): \"\(name)\" is already defined on line \(first); each exercise needs one row.")
                } else {
                    firstLine[name.lowercased()] = lineNo
                }
            }
            r.extraMachines = extraMachines[lineNo] ?? []
            if !r.extraMachines.isEmpty {
                if r.fields?.kind != .machine {
                    rowErrors.append("Line \(lineNo): only a Machine exercise can have more than one machine.")
                } else {
                    let names = [r.machine.isEmpty ? r.name : r.machine] + r.extraMachines.map(\.name)
                    var seen = Set<String>()
                    for n in names where !seen.insert(n.lowercased()).inserted {
                        rowErrors.append("Line \(lineNo): two of this exercise's machines are named \"\(n)\"; give each its own name.")
                    }
                }
            }

            switch group {
            case _ where r.fields != nil || !field(rowFields, "kind").isEmpty:
                break   // the kind's own columns were read above
            case .strength:
                for i in 1...max(1, maxSet) {
                    let rs = field(rowFields, "set\(i)_reps"), ws = field(rowFields, "set\(i)_weight")
                    if rs.isEmpty && ws.isEmpty { continue }
                    let reps = Int(rs), weight = Double(ws)
                    if let reps, reps > 0, let weight, weight >= 0 {
                        r.sets.append((reps: reps, weight: weight))
                    } else {
                        rowErrors.append("Line \(lineNo): set \(i) needs whole reps > 0 and weight ≥ 0 (got reps \"\(rs)\", weight \"\(ws)\").")
                    }
                }
                if r.sets.isEmpty {
                    rowErrors.append("Line \(lineNo): strength needs at least set1_reps and set1_weight.")
                }
            case .cardio:
                let durStr = field(rowFields, "duration_min"), intStr = field(rowFields, "intensity")
                if let v = Int(durStr), v > 0 { r.durationMin = v }
                else { rowErrors.append("Line \(lineNo): 'duration_min' must be a positive whole number (got \"\(durStr)\").") }
                if let i = CardioIntensity(rawValue: intStr.lowercased()) { r.intensity = i }
                else { rowErrors.append("Line \(lineNo): 'intensity' must be low, moderate, or high (got \"\(intStr)\").") }
            case .stretching:
                // Only the exercise name is required; blank hold/sides/rounds use defaults.
                let holdStr = field(rowFields, "hold_seconds"), sidesStr = field(rowFields, "sides"), roundsStr = field(rowFields, "rounds")
                if !holdStr.isEmpty {
                    if let v = Int(holdStr), v >= 0 { r.holdSeconds = v }
                    else { rowErrors.append("Line \(lineNo): 'hold_seconds' must be a whole number ≥ 0 (got \"\(holdStr)\").") }
                }
                if !sidesStr.isEmpty {
                    if let v = Int(sidesStr), v == 1 || v == 2 { r.sidesCount = v }
                    else { rowErrors.append("Line \(lineNo): 'sides' must be 1 or 2 (got \"\(sidesStr)\").") }
                }
                if !roundsStr.isEmpty {
                    if let v = Int(roundsStr), v > 0 { r.rounds = v }
                    else { rowErrors.append("Line \(lineNo): 'rounds' must be a positive whole number (got \"\(roundsStr)\").") }
                }
            }

            if rowErrors.isEmpty { parsed.append(r) } else { errors.append(contentsOf: rowErrors) }
        }

        guard errors.isEmpty else { throw CSVImportError.invalidData(errors) }

        // ---- PASS 2: create only NEW exercises; skip ones that already exist. ----
        var existingByKey: [String: Exercise] = [:]
        // A CSV import is the user's own data: a demo exercise with the same
        // name is not a match, so the user gets their own copy.
        let user = DataSource.user.rawValue
        for e in (try? context.fetch(
            FetchDescriptor<Exercise>(predicate: #Predicate { $0.deletedAt == nil && $0.sourceRaw == user })
        )) ?? [] {
            existingByKey["\(e.name)|\(e.defaultSectionType.rawValue)"] = e
        }
        var createdKeys = Set<String>()
        var report = CSVImportReport()
        var photoDownloads: [(id: UUID, raw: String)] = []   // exercises to fetch a photo_url for
        var updated: [UUID] = []

        for r in parsed {
            let key = "\(r.name)|\(group.rawValue)"
            if createdKeys.contains(key) { continue }                                // duplicate within this file
            if let existing = existingByKey[key] {
                createdKeys.insert(key)
                if replaceExisting, let fields = r.fields {
                    let before = definitionSignature(existing), stamp = existing.updatedAt
                    replaceDefinition(of: existing, with: fields, row: r, hasNotesColumn: index["notes"] != nil)
                    if definitionSignature(existing) == before {
                        existing.updatedAt = stamp
                        report.exercisesUnchanged += 1
                    } else {
                        updated.append(existing.id)
                        report.exercisesUpdated += 1
                    }
                } else {
                    report.exercisesSkipped += 1                                      // already in library
                }
                // Re-import fetches the row's photo again: it fills in a missing
                // photo and replaces one whose image at the link has changed
                // (downloadPhotos compares). A photo set in the app is left
                // alone, as is a Machine exercise whose photo is on its machines.
                if !r.photoURL.isEmpty, !existing.photoSetInApp,
                   existing.photoData != nil || !hasMachinePhoto(existing) {
                    photoDownloads.append((existing.id, r.photoURL))
                }
                continue
            }

            if let fields = r.fields {
                // A row with a kind: the kind's fields, its own machine, then the
                // older fields routines and workouts still read.
                let ex = Exercise(name: r.name, notes: r.notes, source: .user)
                fields.apply(to: ex)
                var machines: [Machine] = []
                for spec in Self.machineSpecs(for: r, fields: fields) {
                    let m = Self.makeMachine(named: spec.name, settings: spec.settings, context: context)
                    m.weight = spec.weight
                    machines.append(m)
                }
                ex.machineIds = machines.map(\.id)
                context.insert(ex)
                ExerciseLegacyFields.write(ex, machines: machines, context: context)
                createdKeys.insert(key)
                report.exercisesAdded += 1
                if !r.photoURL.isEmpty { photoDownloads.append((ex.id, r.photoURL)) }
                continue
            }

            var machineId: UUID?
            if group != .stretching, !r.machine.isEmpty {
                machineId = Self.makeMachine(named: r.machine, settings: r.settings, context: context).id
            }

            let ex = Exercise(name: r.name, machineId: machineId, notes: r.notes, source: .user)
            ex.defaultSectionType = group
            switch group {
            case .strength:
                for (i, s) in r.sets.enumerated() {
                    let set = ExerciseDefaultSet(order: i, reps: s.reps, weight: s.weight)
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
            context.insert(ex)
            createdKeys.insert(key)
            report.exercisesAdded += 1

            // Queue a web photo fetch for this new exercise.
            if !r.photoURL.isEmpty { photoDownloads.append((ex.id, r.photoURL)) }
        }

        // Push replaced definitions into routines and workouts in progress
        // (never into finished workouts).
        let sync = CatalogSyncService(context)
        for id in updated { sync.reconcileExercise(id) }

        Audit.log(context, type: "import.csv", entity: "Exercise",
                  summary: report.summary, source: .user)
        if saves {
            try context.save()   // reported, not swallowed
            downloadPhotos(photoDownloads)   // fire-and-forget; photos appear once fetched
        } else {
            report.photoDownloads = photoDownloads
        }
        return report
    }

    /// Everything a sheet row sets on an exercise, so re-importing the same
    /// values counts as unchanged rather than updated.
    private func definitionSignature(_ e: Exercise) -> String {
        let machines = e.machineIds.compactMap { id in
            try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == id })).first
        }
        let machineIndex = Dictionary(machines.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var parts: [String] = [
            e.kindRaw, e.notes, "\(e.reps)", "\(e.sets)", "\(e.perSide)", e.perSideCustom,
            "\(e.weight as Any)", "\(e.implement as Any)", "\(e.addedWeight as Any)", e.prop,
            "\(e.distance as Any)", "\(e.holdSeconds)", "\(e.countTimerSeconds)", "\(e.durationMinutes)",
            "\(e.effort)", "\(e.workSeconds)", "\(e.recoverySeconds)", "\(e.rounds)", "\(e.varyBySet)"
        ]
        for m in machines {
            parts.append("m:\(m.name)|\(m.weight as Any)|\(m.deletedAt == nil)")
            for d in m.activeSettings.sorted(by: { $0.order < $1.order }) {
                parts.append("s:\(d.label)|\(d.numericValue as Any)|\(d.otherText as Any)")
            }
        }
        // Each machine numbers its own sets from 0, so sort by machine first.
        let sets = e.defaultSets.map { (machine: $0.machineId.flatMap { machineIndex[$0] } ?? -1, set: $0) }
            .sorted { ($0.machine, $0.set.order) < ($1.machine, $1.set.order) }
        for (machine, d) in sets {
            parts.append("d:\(machine)|\(d.order)|\(d.reps)|\(d.weight)")
        }
        return parts.joined(separator: "\u{1F}")
    }

    private func hasMachinePhoto(_ e: Exercise) -> Bool {
        e.machineIds.contains { id in
            (try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == id })).first?.photoData) != nil
        }
    }

    /// The machines a kind row describes, default first: the row's own (named
    /// after the exercise if it names none), then its extra machines.
    private static func machineSpecs(for r: Row, fields: CSVExerciseFields) -> [MachineSpec] {
        guard fields.needsMachine(named: r.machine) else { return [] }
        let own = MachineSpec(name: r.machine.isEmpty ? r.name : r.machine,
                              weight: fields.machineWeight,
                              settings: CSVExerciseFields.settingKinds.contains(fields.kind) ? r.settings : [])
        return [own] + (fields.kind == .machine ? r.extraMachines : [])
    }

    /// Overwrite an existing exercise's definition in place (same id, so
    /// routines and history keep pointing at it). Its machines are matched by
    /// name and updated; new names get new machines; machines no longer listed
    /// are unlinked but kept, as history may reference them. Notes change only
    /// when the import has a notes column. A photo is fetched only if it has none.
    private func replaceDefinition(of ex: Exercise, with fields: CSVExerciseFields,
                                   row r: Row, hasNotesColumn: Bool) {
        fields.apply(to: ex)
        if hasNotesColumn { ex.notes = r.notes }
        ex.varyBySet = false   // the sheet's reps × sets replace any per-set plan
        ex.updatedAt = .now

        let current = ex.machineIds.compactMap { id in
            try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == id })).first
        }.filter { $0.deletedAt == nil }
        var unused = current
        var machines: [Machine] = []
        for spec in Self.machineSpecs(for: r, fields: fields) {
            let machine: Machine
            if let i = unused.firstIndex(where: { $0.name.lowercased() == spec.name.lowercased() }) {
                machine = unused.remove(at: i)
                machine.name = spec.name
                // Distance shows only the machine's name: its settings stay
                // as they are, as the exercise editor does.
                if fields.kind != .distance { Self.replaceSettings(of: machine, with: spec.settings, context: context) }
            } else {
                machine = Self.makeMachine(named: spec.name, settings: spec.settings, context: context)
            }
            machine.weight = spec.weight
            machine.updatedAt = .now
            machines.append(machine)
        }
        ex.machineIds = machines.map(\.id)
        ExerciseLegacyFields.write(ex, machines: machines, context: context)
    }

    /// Set a machine's settings to `settings`. A definition with the same
    /// label is updated in place (workouts in progress match settings by
    /// definition id); new labels are added; the rest are soft-deleted.
    static func replaceSettings(of machine: Machine, with settings: [Setting], context: ModelContext) {
        var unused = machine.activeSettings
        var kept = Set<UUID>()
        for (i, s) in settings.prefix(Machine.maxSettings).enumerated() {
            let def: MachineSettingDefinition
            if let j = unused.firstIndex(where: { $0.label.lowercased() == s.label.lowercased() }) {
                def = unused.remove(at: j)
                def.label = s.label
            } else {
                def = MachineSettingDefinition(label: s.label, order: i, source: machine.source)
                def.machine = machine
                machine.settingDefinitions.append(def)
                context.insert(def)
            }
            def.order = i
            def.numericValue = s.numeric
            def.otherText = s.other
            def.updatedAt = .now
            kept.insert(def.id)
        }
        for def in machine.settingDefinitions where def.deletedAt == nil && !kept.contains(def.id) {
            def.deletedAt = .now
            def.updatedAt = .now
        }
    }

    /// A new machine with its settings. Each exercise gets its own (a machine
    /// belongs to one exercise, even when two share a name).
    static func makeMachine(named name: String,
                            settings: [Setting],
                            context: ModelContext) -> Machine {
        let m = Machine(name: name, source: .user)
        context.insert(m)
        for (i, s) in settings.prefix(Machine.maxSettings).enumerated() {
            let def = MachineSettingDefinition(label: s.label, order: i,
                                               numericValue: s.numeric, otherText: s.other, source: .user)
            def.machine = m
            m.settingDefinitions.append(def)
            context.insert(def)
        }
        return m
    }

    /// Download each linked photo off the main thread and store a LOCAL COPY of the
    /// bytes on its exercise (`photoData` = on-device storage). Best-effort: bad
    /// links / non-image responses are skipped. Raw bytes are kept so animated GIFs
    /// stay animated (see AnimatedImageView).
    func downloadPhotos(_ items: [(id: UUID, raw: String)]) {
        guard !items.isEmpty else { return }
        photoStatus?.begin(items.count)
        Task { @MainActor in
            var changed = false
            for item in items {
                guard let data = await Self.fetchImageData(from: item.raw) else {
                    photoStatus?.recordFailure(); continue
                }
                let id = item.id
                if let ex = try? context.fetch(
                    FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == id })
                ).first {
                    let result = Self.applyDownloadedPhoto(data, to: ex)
                    if result != .unchanged { changed = true }
                    photoStatus?.record(result)
                } else {
                    photoStatus?.recordFailure()
                }
            }
            if changed { try? context.save() }
        }
    }

    /// Store a downloaded photo on its exercise unless it's the same image it
    /// already has, or the user set a photo in the app while it downloaded.
    static func applyDownloadedPhoto(_ data: Data, to ex: Exercise) -> PhotoRefresh {
        if ex.photoSetInApp || ex.photoData == data { return .unchanged }
        let result: PhotoRefresh = ex.photoData == nil ? .added : .updated
        ex.photoData = data            // local copy, independent of the URL afterwards
        ex.updatedAt = .now
        return result
    }

    /// Try each candidate direct-image URL until one returns valid image bytes.
    static func fetchImageData(from raw: String) async -> Data? {
        for url in imageCandidates(raw) {
            guard let (data, response) = try? await URLSession.shared.data(from: url) else { continue }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
            if UIImage(data: data) != nil { return data }   // a real image (incl. GIF)
        }
        return nil
    }

    /// Direct-image URL candidates for a raw cell value. A Google Drive / Docs
    /// "share" link opens an HTML viewer rather than the file, so it is rewritten
    /// to direct-download + thumbnail endpoints (the file must be shared so that
    /// "Anyone with the link" can view it). Other links are used as-is.
    static func imageCandidates(_ raw: String) -> [URL] {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard let base = URL(string: s), let scheme = base.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return [] }
        let host = base.host?.lowercased() ?? ""

        if host.contains("google.com"), let id = driveFileID(s) {
            let direct = "https://drive.usercontent.google.com/download?id=\(id)&export=download&confirm=t"
            let thumb  = "https://drive.google.com/thumbnail?id=\(id)&sz=w2000"   // static fallback
            return [direct, thumb].compactMap { URL(string: $0) }
        }
        return [base]
    }

    /// Extract a Google Drive file id from `/file/d/ID/…`, `/d/ID`, or `?id=ID`.
    static func driveFileID(_ s: String) -> String? {
        if let r = s.range(of: #"/d/[A-Za-z0-9_-]+"#, options: .regularExpression) {
            return String(s[r]).replacingOccurrences(of: "/d/", with: "")
        }
        if let items = URLComponents(string: s)?.queryItems,
           let id = items.first(where: { $0.name == "id" })?.value, !id.isEmpty {
            return id
        }
        return nil
    }

    /// Read settingK_label + settingK_value columns (K = 1...Machine.maxSettings) into settings.
    /// `place` starts each error ("Line 4", "Machine row 14").
    static func parseMachineSettings(_ field: (String) -> String,
                                     place: String,
                                     into errors: inout [String]) -> [Setting] {
        var out: [Setting] = []
        for i in 1...Machine.maxSettings {
            let label = field("setting\(i)_label")
            let value = field("setting\(i)_value")
            if label.isEmpty && value.isEmpty { continue }
            guard !label.isEmpty else {
                errors.append("\(place): setting\(i)_value has no setting\(i)_label.")
                continue
            }
            if let n = Int(value), MachineSettingDefinition.valueRange.contains(n) {
                out.append((label: label, numeric: n, other: nil))
            } else {
                out.append((label: label, numeric: nil, other: value.isEmpty ? nil : value))
            }
        }
        return out
    }
}
