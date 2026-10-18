//
//  GoogleSheetImport.swift
//  WorkoutTracker
//
//  Reads import data straight from a Google Sheet link. The sheet must be
//  shared as "Anyone with the link can view": each tab is downloaded as CSV
//  and handed to the same importers the CSV files use.
//
//  Tab names are fixed: one tab per exercise kind, named as the app shows the
//  kind (Machine, Free weight, … Calisthenics), plus Routines and Schedule.
//  One run reads every tab the sheet has: each group's exercise tabs merged
//  into one CSV, then the Routines tab, then the Schedule tab (a two-week
//  cycle that replaces current and future scheduled workouts). The run is all-or-nothing: it is first tried in a
//  scratch context that is never saved, and runs for real only if no row on
//  any tab has a problem.
//
//  An exercise with more than one machine lists the extra machines on the
//  rows under it, each with ^ in the exercise column ("same as above") and
//  only machine, weight and settings filled. The exercise row's own machine
//  is the default. Row order matters, so a sorted tab can misattach ^ rows.
//
//  Sheet imports overwrite the definitions of exercises that already exist
//  (CSVExerciseImporter's `replaceExisting`) and update routines whose rows
//  differ (CSVRoutineImporter's `updateExisting`); history is never changed.
//
//  Tabs are downloaded by id (`export?format=csv&gid=`), which returns cells
//  exactly as typed. The by-name endpoint (`gviz/tq?sheet=`) is not used: it
//  types each column by its majority and blanks the rest (a "L" setting value
//  in a numeric column comes back empty), and an unknown name silently returns
//  the first tab. Tab ids come from the sheet's public `htmlview` page.
//

import Foundation
import SwiftData

enum GoogleSheetImportError: LocalizedError {
    case badLink
    case notShared
    case sheetNotFound
    case noTabList
    case noImportTabs
    case tabUnavailable(String)
    case wrongTab(String)

    var errorDescription: String? {
        switch self {
        case .badLink:
            return "That isn't a Google Sheet link. Copy the link from the sheet's address bar or its Share button."
        case .notShared:
            return "Couldn't read the sheet. In Google Sheets, tap Share and set General access to \"Anyone with the link\" (Viewer), then import again."
        case .sheetNotFound:
            return "No Google Sheet was found at that link. Check the link is complete."
        case .noTabList:
            return "Couldn't read the sheet's list of tabs. Check the link and that the sheet is shared as \"Anyone with the link\"."
        case .noImportTabs:
            let tabs = ExerciseKind.allCases.map(\.displayName) + [GoogleSheetImport.routinesTab, GoogleSheetImport.scheduleTab]
            return "The sheet has none of the import tabs: \(tabs.joined(separator: ", "))."
        case .tabUnavailable(let tab):
            return "Couldn't download the \"\(tab)\" tab. Try again."
        case .wrongTab(let tab):
            return "The \"\(tab)\" tab holds the wrong data. Check its header row and its kind column."
        }
    }
}

@MainActor
enum GoogleSheetImport {
    static let routinesTab = "Routines"
    /// A two-week cycle of routines that repeats (SheetScheduleImporter).
    static let scheduleTab = "Schedule"

    /// The exercise tabs for a group, each named for the kind its rows hold.
    static func exerciseTabs(for group: SectionType) -> [(tab: String, kind: ExerciseKind)] {
        ExerciseKind.allCases.filter { $0.section == group }.map { ($0.displayName, $0) }
    }

    /// The spreadsheet id from a sheet link (`…/spreadsheets/d/ID/edit…`).
    static func spreadsheetID(from link: String) -> String? {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = s.range(of: #"/spreadsheets/d/([A-Za-z0-9_-]+)"#, options: .regularExpression) else { return nil }
        let id = s[r].dropFirst("/spreadsheets/d/".count)
        return id.isEmpty ? nil : String(id)
    }

    // MARK: - Import

    /// The sheet's import tabs, downloaded.
    struct Tabs {
        var exercises: [(tab: String, kind: ExerciseKind, csv: String)] = []
        var routines: String?
        var schedule: String?
    }

    /// What one run did.
    struct Report {
        var exercises = CSVImportReport()
        var routines = CSVImportReport()
        var hasRoutinesTab = false
        var hasScheduleTab = false
        /// nil with a Schedule tab = its grid was empty, so nothing changed.
        var schedule: SheetScheduleImporter.Result?
    }

    /// Download every exercise tab and the Routines tab the sheet has.
    static func download(link: String) async throws -> Tabs {
        guard let id = spreadsheetID(from: link) else { throw GoogleSheetImportError.badLink }
        let tabIDs = try await fetchTabIDs(sheetID: id)
        var tabs = Tabs()
        for kind in ExerciseKind.allCases {
            guard let gid = tabIDs[kind.displayName] else { continue }
            tabs.exercises.append((kind.displayName, kind, try await fetchCSV(sheetID: id, gid: gid, tab: kind.displayName)))
        }
        if let gid = tabIDs[routinesTab] {
            tabs.routines = try await fetchCSV(sheetID: id, gid: gid, tab: routinesTab)
        }
        if let gid = tabIDs[scheduleTab] {
            tabs.schedule = try await fetchCSV(sheetID: id, gid: gid, tab: scheduleTab)
        }
        guard !tabs.exercises.isEmpty || tabs.routines != nil || tabs.schedule != nil else {
            throw GoogleSheetImportError.noImportTabs
        }
        return tabs
    }

    /// Import every exercise group, then the routines, saving only if all of
    /// it is valid. The run first goes through a scratch context on the same
    /// store that is never saved; only if that finds no problem does it run
    /// for real. (ModelContext.rollback() doesn't reliably undo changes to
    /// records that already exist, so it is only a last resort.) Photos are
    /// fetched after the save.
    static func importAll(_ tabs: Tabs, into context: ModelContext,
                          photoStatus: PhotoImportStatus? = nil) throws -> Report {
        try context.save()   // the scratch run reads the saved store
        let scratch = ModelContext(context.container)
        scratch.autosaveEnabled = false
        // Settle the scratch run's pending changes (the cascade from deleting
        // a routine's saved sections to their planned sets) before the real
        // run deletes and saves those same records. Left pending, SwiftData
        // processes them on a later run-loop pass, finds the records gone
        // from the store and traps.
        do {
            _ = try run(tabs, in: scratch)
        } catch {
            scratch.processPendingChanges()
            throw error
        }
        scratch.processPendingChanges()

        let (report, photos): (Report, [(id: UUID, raw: String)])
        do {
            (report, photos) = try run(tabs, in: context)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        CSVExerciseImporter(context, group: .strength, photoStatus: photoStatus).downloadPhotos(photos)
        return report
    }

    /// One pass over every tab in `context`, without saving. Throws every
    /// problem found, after trying every tab.
    private static func run(_ tabs: Tabs, in context: ModelContext) throws -> (Report, [(id: UUID, raw: String)]) {
        var report = Report()
        var errors: [String] = []
        var photos: [(id: UUID, raw: String)] = []
        // Routines can name exercises a failed tab would have added; knowing
        // their group keeps those rows from adding errors of their own.
        var known: [String: SectionType] = [:]

        for group in [SectionType.strength, .cardio, .stretching] {
            let groupTabs = tabs.exercises.filter { $0.kind.section == group }
            guard !groupTabs.isEmpty else { continue }
            for t in groupTabs {
                for name in exerciseNames(in: t.csv) { known[name] = group }
            }
            let merged: MergedTabs
            do { merged = try mergeExerciseTabs(groupTabs) } catch {
                errors += messages(error)
                continue
            }
            guard !merged.csv.isEmpty else { continue }
            let importer = CSVExerciseImporter(context, group: group, replaceExisting: true, saves: false)
            do {
                let r = try importer.importText(merged.csv, extraMachines: merged.machines)
                report.exercises.exercisesAdded += r.exercisesAdded
                report.exercises.exercisesUpdated += r.exercisesUpdated
                report.exercises.exercisesUnchanged += r.exercisesUnchanged
                photos += r.photoDownloads
            } catch CSVImportError.empty {
                continue   // header only
            } catch {
                errors += messages(error).map { relabel($0, origins: merged.origins) }
            }
        }

        if let csv = tabs.routines {
            report.hasRoutinesTab = true
            do {
                report.routines = try CSVRoutineImporter(context, updateExisting: true, saves: false,
                                                         knownExercises: known).importText(csv)
            } catch CSVImportError.empty {
                // No routines yet.
            } catch {
                errors += messages(error).map {
                    $0.replacingOccurrences(of: #"^Line (\d+):"#, with: "\(routinesTab) row $1:", options: .regularExpression)
                }
            }
        }

        // The schedule last: it names routines the Routines tab may have just added.
        if let csv = tabs.schedule {
            report.hasScheduleTab = true
            do {
                report.schedule = try SheetScheduleImporter(context).importText(csv)
            } catch {
                errors += messages(error)
            }
        }

        guard errors.isEmpty else { throw CSVImportError.invalidData(errors) }
        ExerciseStructureMigration(context).run()   // new exercises get their type
        return (report, photos)
    }

    private static func messages(_ error: Error) -> [String] {
        if case CSVImportError.invalidData(let list) = error { return list }
        return [error.localizedDescription]
    }

    /// The exercise names a tab defines (not its ^ rows).
    static func exerciseNames(in csv: String) -> [String] {
        let rows = CSVRoutineImporter.parse(csv)
        guard let i = rows.first?.map(normalized).firstIndex(of: "exercise") else { return [] }
        return rows.dropFirst().compactMap { row in
            guard i < row.count else { return nil }
            let name = row[i].trimmingCharacters(in: .whitespaces)
            return name.isEmpty || name == sameAsAbove ? nil : name
        }
    }

    // MARK: - Download

    /// Tab name → gid, read from the sheet's public `htmlview` page. Hidden
    /// tabs aren't listed, which is fine: no import tab is hidden.
    static func fetchTabIDs(sheetID: String) async throws -> [String: String] {
        guard let url = URL(string: "https://docs.google.com/spreadsheets/d/\(sheetID)/htmlview") else {
            throw GoogleSheetImportError.badLink
        }
        let html = try await download(url, failure: .noTabList)
        let ids = parseTabIDs(html)
        guard !ids.isEmpty else { throw GoogleSheetImportError.noTabList }
        return ids
    }

    static func fetchCSV(sheetID: String, gid: String, tab: String) async throws -> String {
        guard let url = URL(string: "https://docs.google.com/spreadsheets/d/\(sheetID)/export?format=csv&gid=\(gid)") else {
            throw GoogleSheetImportError.badLink
        }
        let csv = try await download(url, failure: .tabUnavailable(tab))
        if csv.hasPrefix("<") { throw GoogleSheetImportError.notShared }   // an HTML sign-in page
        return csv
    }

    private static func download(_ url: URL, failure: GoogleSheetImportError) async throws -> String {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 200 {
        case 200...299: break
        case 401, 403: throw GoogleSheetImportError.notShared
        case 404: throw GoogleSheetImportError.sheetNotFound
        default: throw failure
        }
        guard let text = String(data: data, encoding: .utf8) else { throw failure }
        return text
    }

    /// Pull `{name: "…", pageUrl: "…", gid: "…"}` entries out of the htmlview page.
    static func parseTabIDs(_ html: String) -> [String: String] {
        let pattern = #"\{name: "((?:[^"\\]|\\.)*)", pageUrl: "(?:[^"\\]|\\.)*", gid: "(\d+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        var ids: [String: String] = [:]
        let ns = html as NSString
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            ids[unescapeJS(ns.substring(with: m.range(at: 1)))] = ns.substring(with: m.range(at: 2))
        }
        return ids
    }

    /// Undo the page's JavaScript string escapes: \xNN, \uNNNN and \<char>.
    static func unescapeJS(_ s: String) -> String {
        var out = ""
        var chars = s.makeIterator()
        while let c = chars.next() {
            guard c == "\\", let e = chars.next() else { out.append(c); continue }
            let digits = e == "x" ? 2 : e == "u" ? 4 : 0
            guard digits > 0 else { out.append(e); continue }
            var hex = ""
            for _ in 0..<digits { if let h = chars.next() { hex.append(h) } }
            if let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) { out.unicodeScalars.append(scalar) }
        }
        return out
    }

    // MARK: - Merge

    /// One merged CSV, and where each of its data lines came from
    /// (`origins[0]` is line 2, the first line after the header).
    struct MergedTabs {
        var csv: String
        var origins: [(tab: String, row: Int)]
        /// Each exercise's ^ machines, by its line in `csv`.
        var machines: [Int: [CSVExerciseImporter.MachineSpec]] = [:]
    }

    /// The exercise-column marker for another machine of the exercise above.
    static let sameAsAbove = "^"

    /// Columns a ^ row may fill.
    private static func isMachineColumn(_ col: String) -> Bool {
        col == "exercise" || col == "machine" || col == "weight"
            || col.range(of: #"^setting\d+_(label|value)$"#, options: .regularExpression) != nil
    }

    /// One CSV with every column any tab uses; each row keeps its own values.
    /// A blank kind takes the tab's kind. A row of another known kind is
    /// rejected; an unknown kind passes through for the importer to report.
    /// A ^ row becomes another machine of the exercise row above it.
    static func mergeExerciseTabs(_ tabs: [(tab: String, kind: ExerciseKind, csv: String)]) throws -> MergedTabs {
        try merge(tabs.map { ($0.tab, $0.kind, $0.csv) })
    }

    /// A CSV file's ^ rows taken out as machines of the exercise rows above
    /// them. Rows keep their kind as written, and problems are reported by
    /// file line ("Line 4: …").
    static func splitMachineRows(_ csv: String) throws -> MergedTabs {
        try merge([("", nil, csv)])
    }

    /// `kind` nil = a CSV file: no kind is filled in or checked, and an empty
    /// tab name labels rows by file line.
    private static func merge(_ tabs: [(tab: String, kind: ExerciseKind?, csv: String)]) throws -> MergedTabs {
        var columns: [String] = []
        var records: [[String: String]] = []
        var origins: [(tab: String, row: Int)] = []
        var machines: [Int: [CSVExerciseImporter.MachineSpec]] = [:]
        var errors: [String] = []
        for t in tabs {
            var lastExercise: Int?   // index in `records` of this tab's latest exercise row
            let rows = CSVRoutineImporter.parse(t.csv)
            guard let header = rows.first?.map(normalized) else { continue }   // empty tab
            guard header.contains("exercise"), header.contains("kind") else {
                throw GoogleSheetImportError.wrongTab(t.tab)
            }
            for col in header where !col.isEmpty && !columns.contains(col) { columns.append(col) }
            for (offset, row) in rows.dropFirst().enumerated() {
                var record: [String: String] = [:]
                for (i, col) in header.enumerated() where i < row.count && !col.isEmpty {
                    let value = row[i].trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { record[col] = value }
                }
                guard !record.isEmpty else { continue }   // blank row
                let place = t.tab.isEmpty ? "Line \(offset + 2)" : "\(t.tab) row \(offset + 2)"
                if record["exercise"] == sameAsAbove {
                    guard let owner = lastExercise else {
                        errors.append("\(place): ^ adds a machine to the exercise above, but there's no exercise above it.")
                        continue
                    }
                    if let spec = machineSpec(record, place: place, errors: &errors) {
                        machines[owner + 2, default: []].append(spec)
                    }
                    continue
                }
                if record["exercise"] == nil {
                    errors.append("\(place): no exercise name. Put ^ in the exercise column if this row is another machine for the exercise above.")
                    continue
                }
                if let tabKind = t.kind {
                    if let kind = record["kind"] {
                        if let k = CSVExerciseFields.kind(from: kind), k != tabKind {
                            throw GoogleSheetImportError.wrongTab(t.tab)
                        }
                    } else {
                        record["kind"] = CSVExerciseFields.name(of: tabKind)
                    }
                }
                lastExercise = records.count
                records.append(record)
                origins.append((t.tab, offset + 2))
            }
        }
        guard errors.isEmpty else { throw CSVImportError.invalidData(errors) }
        guard !columns.isEmpty else { return MergedTabs(csv: "", origins: []) }
        let lines = [columns.map(escape).joined(separator: ",")]
            + records.map { r in columns.map { escape(r[$0] ?? "") }.joined(separator: ",") }
        return MergedTabs(csv: lines.joined(separator: "\n") + "\n", origins: origins, machines: machines)
    }

    /// A ^ row's machine. It needs a name and holds nothing that belongs on
    /// the exercise row.
    private static func machineSpec(_ record: [String: String], place: String,
                                    errors: inout [String]) -> CSVExerciseImporter.MachineSpec? {
        let before = errors.count
        for col in record.keys.sorted() where !isMachineColumn(col) {
            errors.append("\(place): a ^ row holds only machine, weight and settings; '\(col)' belongs on the exercise row.")
        }
        let name = record["machine"] ?? ""
        if name.isEmpty { errors.append("\(place): a ^ row needs a machine name.") }
        var weight: Double?
        if let w = record["weight"] {
            if let v = Double(w), v.isFinite, v >= 0 { weight = v }
            else { errors.append("\(place): 'weight' must be a number ≥ 0 (got \"\(w)\").") }
        }
        let settings = CSVExerciseImporter.parseMachineSettings({ record[$0] ?? "" }, place: place, into: &errors)
        return errors.count == before ? .init(name: name, weight: weight, settings: settings) : nil
    }

    /// "Line 7: …" in the merged CSV → "Machine row 4: …" in the sheet.
    static func relabel(_ message: String, origins: [(tab: String, row: Int)]) -> String {
        guard let r = message.range(of: #"^Line \d+:"#, options: .regularExpression),
              let line = Int(message[r].dropFirst(5).dropLast()),
              origins.indices.contains(line - 2)
        else { return message }
        func place(_ o: (tab: String, row: Int)) -> String { o.tab.isEmpty ? "line \(o.row)" : "\(o.tab) row \(o.row)" }
        let o = origins[line - 2]
        var rest = String(message[r.upperBound...])
        // "already defined on line 3" → "… on Machine row 2".
        if let m = rest.range(of: #"on line \d+"#, options: .regularExpression),
           let inner = Int(rest[m].dropFirst(8)), origins.indices.contains(inner - 2) {
            rest.replaceSubrange(m, with: "on " + place(origins[inner - 2]))
        }
        let head = place(o)
        return head.prefix(1).uppercased() + head.dropFirst() + ":" + rest
    }

    private static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func escape(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
