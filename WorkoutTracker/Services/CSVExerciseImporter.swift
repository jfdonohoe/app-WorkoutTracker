//
//  CSVExerciseImporter.swift
//  WorkoutTracker
//
//  Imports the EXERCISE LIBRARY from CSV. Each exercise GROUP has its OWN template
//  and import, with only the columns that group needs:
//
//   • strength → exercise, machine, setting1..4_label/value,
//                set1..N_reps/weight (each set its own reps + weight), notes
//   • cardio   → exercise, machine, setting1..4_label/value, duration_min,
//                intensity, notes
//   • stretching → exercise (only the name is required), optional hold_seconds,
//                sides, rounds, notes (no machine)
//
//  Machine settings are split into explicit columns: settingK_label + settingK_value
//  for K = 1...10 (the app caps a machine at Machine.maxSettings). A numeric value 1...15 is a
//  slider pick; anything else is stored as free text.
//
//  Strength reads as many setK_reps/setK_value pairs as the header defines, so a
//  routine can have any number of sets with independent reps/weight.
//
//  Import is ADDITIVE: an exercise that already exists (same name + group) is
//  ignored, and only new exercises are created. Import is ALL-OR-NOTHING for
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
    @Published private(set) var done = 0
    @Published private(set) var failed = 0

    var pending: Int { max(0, total - done - failed) }
    var isDownloading: Bool { total > 0 && pending > 0 }
    var isFinished: Bool { total > 0 && pending == 0 }

    func begin(_ count: Int) { total = count; done = 0; failed = 0 }
    func reset() { total = 0; done = 0; failed = 0 }
    func recordSuccess() { done += 1 }
    func recordFailure() { failed += 1 }
}

@MainActor
struct CSVExerciseImporter {
    let context: ModelContext
    let group: SectionType
    let photoStatus: PhotoImportStatus?

    init(_ context: ModelContext, group: SectionType, photoStatus: PhotoImportStatus? = nil) {
        self.context = context
        self.group = group
        self.photoStatus = photoStatus
    }

    // MARK: - Templates

    static func template(for group: SectionType) -> String {
        switch group {
        case .strength:
            return """
            exercise,machine,setting1_label,setting1_value,setting2_label,setting2_value,setting3_label,setting3_value,setting4_label,setting4_value,set1_reps,set1_weight,set2_reps,set2_weight,set3_reps,set3_weight,set4_reps,set4_weight,set5_reps,set5_weight,notes,photo_url
            Leg Press,Leg Press,Seat height,5,Back angle,3,,,,,12,100,10,120,10,120,8,140,6,160,Pyramid up,
            Chest Press,Chest Press,Seat height,6,,,,,,,10,60,10,60,10,60,,,,,,
            Lat Pulldown,Lat Pulldown,Seat height,4,Thigh pad,7,,,,,12,80,10,90,10,90,8,100,,,,
            """
        case .cardio:
            return """
            exercise,machine,setting1_label,setting1_value,setting2_label,setting2_value,setting3_label,setting3_value,setting4_label,setting4_value,duration_min,intensity,notes,photo_url
            Treadmill,,,,,,,,,,20,moderate,Steady pace,
            Stationary Bike,,,,,,,,,,15,low,Cooldown spin,
            Rowing Machine,Rower,Resistance,8,,,,,,,12,high,Hard intervals,
            """
        case .stretching:
            return """
            exercise,hold_seconds,sides,rounds,notes,photo_url
            Hamstring Stretch,30,2,3,Keep back flat,
            Shoulder Stretch,20,2,2,,
            Calf Stretch,30,2,3,,
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
        var settings: [(label: String, numeric: Int?, other: String?)] = []
        var notes: String = ""
        var photoURL: String = ""                      // optional web image to fetch
        var sets: [(reps: Int, weight: Double)] = []  // strength
        var durationMin = 0                            // cardio
        var intensity: CardioIntensity = .moderate     // cardio
        var holdSeconds = 0                            // stretching
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

        // Required columns per group.
        let required: [String]
        switch group {
        case .strength: required = ["exercise", "set1_reps", "set1_weight"]
        case .cardio: required = ["exercise", "duration_min", "intensity"]
        case .stretching: required = ["exercise"]
        }
        let missing = required.filter { index[$0] == nil }
        guard missing.isEmpty else { throw CSVImportError.missingColumns(missing) }

        let dataRows = rows.dropFirst().filter { !($0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty) }
        guard !dataRows.isEmpty else { throw CSVImportError.empty }

        func field(_ row: [String], _ key: String) -> String {
            guard let i = index[key], i < row.count else { return "" }
            return row[i].trimmingCharacters(in: .whitespaces)
        }

        // How many setK_reps/setK_weight column pairs the header defines.
        var maxSet = 0
        if group == .strength {
            var n = 1
            while index["set\(n)_reps"] != nil || index["set\(n)_weight"] != nil { maxSet = n; n += 1 }
        }

        // ---- PASS 1: validate everything. ----
        var errors: [String] = []
        var parsed: [Row] = []

        for (offset, rowFields) in dataRows.enumerated() {
            let lineNo = offset + 2
            var rowErrors: [String] = []

            let name = field(rowFields, "exercise")
            if name.isEmpty { rowErrors.append("Line \(lineNo): 'exercise' is required.") }

            var r = Row(name: name, notes: field(rowFields, "notes"))
            r.photoURL = field(rowFields, "photo_url")   // optional; downloaded after import

            if group != .stretching {
                r.machine = field(rowFields, "machine")
                r.settings = parseMachineSettings(rowFields, field: field, lineNo: lineNo, into: &rowErrors)
            }

            switch group {
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
        var machineByName: [String: Machine] = [:]
        var existingByKey: [String: Exercise] = [:]
        for e in (try? context.fetch(
            FetchDescriptor<Exercise>(predicate: #Predicate { $0.deletedAt == nil })
        )) ?? [] {
            existingByKey["\(e.name)|\(e.defaultSectionType.rawValue)"] = e
        }
        var createdKeys = Set<String>()
        var report = CSVImportReport()
        var photoDownloads: [(id: UUID, raw: String)] = []   // exercises to fetch a photo_url for

        for r in parsed {
            let key = "\(r.name)|\(group.rawValue)"
            if let existing = existingByKey[key] {
                report.exercisesSkipped += 1                                          // already in library
                // Re-import backfills a photo onto an existing exercise that has none.
                if existing.photoData == nil, !r.photoURL.isEmpty {
                    photoDownloads.append((existing.id, r.photoURL))
                }
                continue
            }
            if createdKeys.contains(key) { continue }                                // duplicate within this file

            var machineId: UUID?
            if group != .stretching, !r.machine.isEmpty {
                if let m = machineByName[r.machine] {
                    machineId = m.id
                } else {
                    let m = Machine(name: r.machine, source: .user)
                    context.insert(m)
                    for (i, s) in r.settings.prefix(Machine.maxSettings).enumerated() {
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

        Audit.log(context, type: "import.csv", entity: "Exercise",
                  summary: report.summary, source: .user)
        try? context.save()
        downloadPhotos(photoDownloads)   // fire-and-forget; photos appear once fetched
        return report
    }

    /// Download each linked photo off the main thread and store a LOCAL COPY of the
    /// bytes on its exercise (`photoData` = on-device storage). Best-effort: bad
    /// links / non-image responses are skipped. Raw bytes are kept so animated GIFs
    /// stay animated (see AnimatedImageView).
    private func downloadPhotos(_ items: [(id: UUID, raw: String)]) {
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
                    ex.photoData = data        // local copy, independent of the URL afterwards
                    changed = true
                    photoStatus?.recordSuccess()
                } else {
                    photoStatus?.recordFailure()
                }
            }
            if changed { try? context.save() }
        }
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
    private func parseMachineSettings(_ row: [String],
                                      field: ([String], String) -> String,
                                      lineNo: Int,
                                      into errors: inout [String]) -> [(label: String, numeric: Int?, other: String?)] {
        var out: [(label: String, numeric: Int?, other: String?)] = []
        for i in 1...Machine.maxSettings {
            let label = field(row, "setting\(i)_label")
            let value = field(row, "setting\(i)_value")
            if label.isEmpty && value.isEmpty { continue }
            guard !label.isEmpty else {
                errors.append("Line \(lineNo): setting\(i)_value has no setting\(i)_label.")
                continue
            }
            if let n = Int(value), (1...15).contains(n) {
                out.append((label: label, numeric: n, other: nil))
            } else {
                out.append((label: label, numeric: nil, other: value.isEmpty ? nil : value))
            }
        }
        return out
    }
}
