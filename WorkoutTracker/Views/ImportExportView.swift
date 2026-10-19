//
//  ImportExportView.swift
//  WorkoutTracker
//
//  Screen 9. JSON backup export (via the share sheet) and non-destructive
//  import. Import adds records whose ids don't already exist and never
//  overwrites an existing one; afterwards the merged store gets the same
//  cleanups as launch (routine rows for exercises not in the library,
//  duplicate planned sets, discarded workouts) and the automatic data-safety
//  repairs (ExportImportService.restore).
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportExportView: View {
    @Environment(\.modelContext) private var context

    @State private var exportURL: URL?
    @State private var includeDemo = true
    @State private var importMessage: String?
    @State private var errorMessage: String?

    // One shared file importer — multiple .fileImporter modifiers on the same
    // view conflict (some never fire). `importKind` selects what to do; it is a
    // plain value (not the presentation trigger) so it survives dismissal.
    private enum ImportKind { case backup, routines, exercises }
    @State private var showFileImporter = false
    @State private var importKind: ImportKind = .backup

    // CSV routine import
    @State private var csvTemplateURL: URL?
    @State private var csvMessage: String?
    @State private var csvError: String?

    // CSV exercise-library import (one template per group)
    @State private var exGroup: SectionType = .strength
    @State private var exTemplateURL: URL?
    @State private var exMessage: String?
    @State private var exError: String?
    @StateObject private var photoStatus = PhotoImportStatus()

    // Google Sheet import: one link, one run for every exercise tab and the routines.
    @AppStorage("googleSheetLink") private var sheetLink = ""
    @State private var isFetchingSheet = false
    @State private var sheetReport: GoogleSheetImport.Report?
    @State private var sheetError: String?
    @StateObject private var sheetPhotoStatus = PhotoImportStatus()
    private var hasSheetLink: Bool { GoogleSheetImport.spreadsheetID(from: sheetLink) != nil }

    /// Set when an import or export finds something that needs the user;
    /// presents the Data Safety Check.
    @State private var safetyReport: SafetyReport?

    private struct SafetyReport: Identifiable {
        let id = UUID()
        let occasion: String
    }

    private var importContentTypes: [UTType] {
        importKind == .backup ? [.json] : [.commaSeparatedText, .plainText, .text, .data]
    }

    private var exGroupFooter: String {
        let photoNote = " An optional photo_url column links a web image (jpg/png/gif) that is downloaded and used as the exercise's photo."
        let base = "Builds your \(exGroup.displayName.lowercased()) exercises from a CSV file. New exercises are added; an existing exercise (same name) is updated from the file, and one whose values already match is left as it is. Finished workouts never change. A malformed row blocks the whole import. The kind column decides which other columns a row uses; blank ones take the kind's defaults. To give a machine exercise another machine, add a row under it with ^ in the exercise column and fill only machine, weight and settings; the first machine is the default. "
        switch exGroup {
        case .strength:
            return base + "Kinds: machine, free_weight, bodyweight, hold. Columns: exercise, kind, reps, sets, weight, per_side, per_side_custom, implement, added_weight, hold_seconds, machine, settingK_label/value (K = 1…\(Machine.maxSettings)), notes, photo_url." + photoNote
        case .cardio:
            return base + "Kinds: steady, distance, intervals, calisthenics. Columns: exercise, kind, duration_min, distance, work_seconds, recovery_seconds, rounds, effort (easy/moderate/hard/max), reps, sets, per_side, per_side_custom, machine, settingK_label/value, notes, photo_url." + photoNote
        case .stretching:
            return base + "Kinds: static, dynamic. Columns: exercise, kind, hold_seconds, reps, sets, per_side, per_side_custom, prop, timer_seconds, notes, photo_url." + photoNote
        }
    }

    var body: some View {
        List {
            Section {
                TextField("Paste the sheet's link", text: $sheetLink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button {
                    importFromSheet()
                } label: {
                    Label(isFetchingSheet ? "Importing…" : "Import from Google Sheet", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        // White icon and title: in a List row the icon otherwise
                        // takes the row tint, the same green as the button.
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.statusGreen)
                .controlSize(.large)
                .disabled(!hasSheetLink || isFetchingSheet)
                if isFetchingSheet {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Downloading from Google Sheets…").foregroundStyle(.secondary)
                    }
                }
                if let sheetReport {
                    sheetResultRow("Exercises", detail: Self.counts(added: sheetReport.exercises.exercisesAdded,
                                                                     updated: sheetReport.exercises.exercisesUpdated,
                                                                     unchanged: sheetReport.exercises.exercisesUnchanged))
                    if sheetReport.hasRoutinesTab {
                        sheetResultRow("Routines", detail: Self.counts(added: sheetReport.routines.routinesCreated,
                                                                        updated: sheetReport.routines.routinesUpdated,
                                                                        unchanged: sheetReport.routines.routinesUnchanged))
                    }
                    if sheetReport.hasScheduleTab {
                        sheetResultRow("Schedule", detail: Self.scheduleSummary(sheetReport.schedule))
                    }
                }
                if let sheetError {
                    Label(sheetError, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.statusRed)
                }
                // Approved "Done" frame: photos as a third result row.
                if sheetPhotoStatus.isFinished && sheetPhotoStatus.failed == 0 {
                    sheetResultRow("Photos", detail: Self.photoSummary(sheetPhotoStatus))
                } else {
                    photoStatusRows(sheetPhotoStatus)
                }
            } header: {
                Text("Google Sheet")
            } footer: {
                Text("Paste the link and tap Import. One run reads every exercise tab (Machine, Free weight, Bodyweight, Hold, Static, Dynamic, Steady, Distance, Intervals, Calisthenics), then the Routines tab, then the Schedule tab. New exercises and routines are added; existing exercises are updated from the sheet, and an existing routine is updated only if its rows differ. Everything is checked before anything is saved — if any row has a problem, nothing is imported. A filled Schedule tab is a two-week cycle that repeats every two weeks from its start_date, and it replaces every current and future scheduled workout (past days stay as they were). Finished workouts never change. Tabs use the same columns as the CSV templates; a blank kind takes the tab's kind. To give an exercise another machine, add a row under it with ^ in the exercise column and fill only machine, weight and settings; the first machine is the default. Share the sheet as \"Anyone with the link\" (Viewer).")
            }

            Section {
                Toggle("Include demo data in export", isOn: $includeDemo)
                if let url = exportURL {
                    ShareLink(item: url) {
                        Label("Share backup file", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    prepareExport()
                } label: {
                    Label("Create backup (JSON)", systemImage: "doc.badge.plus")
                }
            } header: {
                Text("Export")
            } footer: {
                Text("Creates a JSON file with all workout data needed to restore later.")
            }

            Section {
                Button {
                    importKind = .backup; showFileImporter = true
                } label: {
                    Label("Import from backup file", systemImage: "square.and.arrow.down")
                }
                if let importMessage {
                    Label(importMessage, systemImage: "checkmark.circle").foregroundStyle(Theme.statusGreen)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.statusRed)
                }
            } header: {
                Text("Import")
            } footer: {
                Text("Safe import: existing records are kept as-is and only new records are added. Afterwards the usual cleanups and automatic data-safety repairs run on the result.")
            }

            Section {
                Picker("Group", selection: $exGroup) {
                    Text(SectionType.strength.displayName).tag(SectionType.strength)
                    Text(SectionType.cardio.displayName).tag(SectionType.cardio)
                    Text(SectionType.stretching.displayName).tag(SectionType.stretching)
                }
                .onChange(of: exGroup) { _, _ in exTemplateURL = nil; exMessage = nil; exError = nil; photoStatus.reset() }

                if let url = exTemplateURL {
                    ShareLink(item: url) {
                        Label("Share \(exGroup.displayName.lowercased()) template", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        exTemplateURL = try? CSVExerciseImporter.writeTemplate(for: exGroup)
                    } label: {
                        Label("Get \(exGroup.displayName.lowercased()) template", systemImage: "doc.text")
                    }
                }
                Button {
                    importKind = .exercises; showFileImporter = true
                } label: {
                    Label("Import \(exGroup.displayName.lowercased()) exercises", systemImage: "dumbbell")
                }
                if let exMessage {
                    Label(exMessage, systemImage: "checkmark.circle").foregroundStyle(Theme.statusGreen)
                }
                if let exError {
                    Label(exError, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.statusRed)
                }
                photoStatusRows(photoStatus)
            } header: {
                Text("Exercises from CSV")
            } footer: {
                Text(exGroupFooter)
            }

            Section {
                if let url = csvTemplateURL {
                    ShareLink(item: url) {
                        Label("Share routines template", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        csvTemplateURL = try? CSVRoutineImporter.writeExampleFile()
                    } label: {
                        Label("Get routines CSV template", systemImage: "doc.text")
                    }
                }
                Button {
                    importKind = .routines; showFileImporter = true
                } label: {
                    Label("Import routines from CSV", systemImage: "tablecells.badge.ellipsis")
                }
                if let csvMessage {
                    Label(csvMessage, systemImage: "checkmark.circle").foregroundStyle(Theme.statusGreen)
                }
                if let csvError {
                    Label(csvError, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.statusRed)
                }
            } header: {
                Text("Routines from CSV")
            } footer: {
                Text("Builds routines (and any exercises they reference) from a CSV file. A routine that already exists (by name) is updated only if its sections or exercises differ — in a new version if a workout was started from it, so past workouts never change. Routines not in the file are left alone, and existing exercises are reused. A routine is just a definition; scheduling is done separately from the Calendar and Workout tabs. Always required: routine, exercise. group is needed only for an exercise that isn't in your library or given a group or kind elsewhere in this file, or is in more than one group. order (1, 2, 3…) sets each row's place in its routine; fill it on every row of a routine or on none (none keeps file order). Each run of rows in the same group becomes a section, so a group can come more than once (e.g. stretching before and after strength). For a new exercise, kind and its columns (as in the exercise templates) describe it; an exercise already in your library keeps its saved values. machine_settings uses Label=Value; Label2=Value2. setK_reps/setK_weight (as many pairs as the header has) plan this routine's sets on import only: routines follow the library, so the exercise's own sets replace them when the Routines, Workout or Calendar tab next appears. To change them for good, change the exercise. set_cooldown is kept with the row but rest between sets comes from the routine's Rest settings. exercise_cooldown = rest between exercises for the routine (if rows differ, the largest is used). A malformed row blocks the whole import.")
            }
        }
        .navigationTitle("Import / Export")
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: importContentTypes) { result in
            switch importKind {
            case .backup: handleImport(result)
            case .routines: handleCSVImport(result)
            case .exercises: handleExCSVImport(result)
            }
        }
        .sheet(item: $safetyReport) { report in
            NavigationStack { DataSafetyCheckView(occasion: report.occasion) }
        }
    }

    /// Data problems can only arrive with imported data, so the Data Safety
    /// Check runs here: after every import (restore has already made the
    /// repairs that need no decision) and on every export. It opens only when
    /// something needs the user; info-only notes stay quiet.
    private func checkDataSafety(_ occasion: String) {
        if DataIntegrityService(context).runAll().contains(where: \.needsAttention) {
            safetyReport = SafetyReport(occasion: occasion)
        }
    }

    private func prepareExport() {
        errorMessage = nil
        do {
            exportURL = try ExportImportService(context).writeBackupFile(includeDemo: includeDemo)
            // The backup is made either way — it may be the user's safety net.
            checkDataSafety("Your backup was created, but it includes these problems. Fix them, then create a new backup.")
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        importMessage = nil
        errorMessage = nil
        switch result {
        case .success(let url):
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let outcome = try ExportImportService(context).importJSON(data)
                try context.save()   // a failed save is an error, not "Added N"
                importMessage = outcome.summary
                checkDataSafety("Checked after importing your backup.")
            } catch {
                errorMessage = "Import failed: \(error.localizedDescription)"
            }
        case .failure(let error):
            errorMessage = "Could not open file: \(error.localizedDescription)"
        }
    }

    /// One run: download every tab, then import it all or nothing.
    private func importFromSheet() {
        sheetReport = nil
        sheetError = nil
        sheetPhotoStatus.reset()
        let link = sheetLink
        isFetchingSheet = true
        Task {
            defer { isFetchingSheet = false }
            do {
                let tabs = try await GoogleSheetImport.download(link: link)
                sheetReport = try GoogleSheetImport.importAll(tabs, into: context, photoStatus: sheetPhotoStatus)
                checkDataSafety("Checked after importing from your Google Sheet.")
            } catch {
                sheetError = error.localizedDescription
            }
        }
    }

    /// "19 added · 16 updated · 3 unchanged", leaving out zeros.
    static func counts(added: Int, updated: Int, unchanged: Int) -> String {
        let parts = [(added, "added"), (updated, "updated"), (unchanged, "unchanged")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "Nothing to import" : parts.joined(separator: " · ")
    }

    private func sheetResultRow(_ title: String, detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "checkmark.circle").foregroundStyle(Theme.statusGreen)
        }
    }

    /// Live status of the linked-photo downloads.
    @ViewBuilder
    private func photoStatusRows(_ status: PhotoImportStatus) -> some View {
        if status.isDownloading {
            HStack(spacing: 8) {
                ProgressView()
                Text("Downloading \(status.pending) photo\(status.pending == 1 ? "" : "s")…")
                    .foregroundStyle(.secondary)
            }
        } else if status.isFinished {
            if status.failed > 0 {
                Label("Photos: \(Self.photoSummary(status)) · \(status.failed) couldn't be fetched",
                      systemImage: "exclamationmark.triangle").foregroundStyle(Theme.statusOrange)
            } else if status.added + status.updated > 0 {
                Label("Photos: \(Self.photoSummary(status))",
                      systemImage: "photo").foregroundStyle(Theme.statusGreen)
            }
        }
    }

    /// "8 workouts every 2 weeks · from Oct 19", or why nothing changed.
    static func scheduleSummary(_ result: SheetScheduleImporter.Result?) -> String {
        guard let result else { return "Empty — schedule unchanged" }
        let n = result.workoutsPerCycle
        return "\(n) workout\(n == 1 ? "" : "s") every 2 weeks · from \(result.cycleStart.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// "2 added · 3 updated · 11 unchanged", leaving out zero counts.
    static func photoSummary(_ status: PhotoImportStatus) -> String {
        let parts = [(status.added, "added"), (status.updated, "updated"), (status.unchanged, "unchanged")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "none" : parts.joined(separator: " · ")
    }

    private func handleCSVImport(_ result: Result<URL, Error>) {
        csvMessage = nil
        csvError = nil
        switch result {
        case .success(let url):
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let report = try CSVRoutineImporter(context, updateExisting: true).importFile(at: url)
                ExerciseStructureMigration(context).run()   // new exercises get their type
                try context.save()
                csvMessage = report.summary
                checkDataSafety("Checked after importing routines.")
            } catch {
                csvError = error.localizedDescription
            }
        case .failure(let error):
            csvError = "Could not open file: \(error.localizedDescription)"
        }
    }

    private func handleExCSVImport(_ result: Result<URL, Error>) {
        exMessage = nil
        exError = nil
        photoStatus.reset()
        switch result {
        case .success(let url):
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let report = try CSVExerciseImporter(context, group: exGroup, photoStatus: photoStatus,
                                                     replaceExisting: true).importFile(at: url)
                ExerciseStructureMigration(context).run()   // new exercises get their type
                try context.save()
                exMessage = report.summary
                checkDataSafety("Checked after importing exercises.")
            } catch {
                exError = error.localizedDescription
            }
        case .failure(let error):
            exError = "Could not open file: \(error.localizedDescription)"
        }
    }
}
