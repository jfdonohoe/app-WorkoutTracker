//
//  ImportExportView.swift
//  WorkoutTracker
//
//  Screen 9. JSON backup export (via the share sheet) and non-destructive
//  import. Import only ADDS records whose ids don't already exist; it never
//  overwrites existing data.
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

    private var importContentTypes: [UTType] {
        importKind == .backup ? [.json] : [.commaSeparatedText, .plainText, .text, .data]
    }

    private var exGroupFooter: String {
        let photoNote = " An optional photo_url column links a web image (jpg/png/gif) that is downloaded and used as the exercise's photo."
        let base = "Builds your \(exGroup.displayName.lowercased()) exercises. Exercises that already exist are skipped — only new ones are added. A malformed row blocks the whole import. Machine settings use settingK_label/settingK_value columns (K = 1…4). "
        switch exGroup {
        case .strength:
            return base + "Columns: exercise, machine, setting1–4_label/value, set1…set5_reps/weight, notes, photo_url. Each set has its own reps + weight; empty set columns are skipped (only filled sets are created). The template includes 5 sets; the app supports up to 15 (add more setK columns)." + photoNote
        case .cardio:
            return base + "Columns: exercise, machine, setting1–4_label/value, duration_min, intensity (low/moderate/high), notes, photo_url." + photoNote
        case .stretching:
            return "Builds your stretching exercises (no machine). Columns: exercise, hold_seconds, sides (1 or 2), rounds, notes, photo_url. Only the exercise name is required — hold_seconds, sides, and rounds are optional (blank uses defaults). Exercises that already exist are skipped; only new ones are added." + photoNote
        }
    }

    var body: some View {
        List {
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
                    Label(importMessage, systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            } header: {
                Text("Import")
            } footer: {
                Text("Safe import: existing records are kept as-is. Only new records are added — nothing is overwritten.")
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
                    Label(exMessage, systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                if let exError {
                    Label(exError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                // Live status of the linked-photo downloads.
                if photoStatus.isDownloading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Downloading \(photoStatus.pending) photo\(photoStatus.pending == 1 ? "" : "s")…")
                            .foregroundStyle(.secondary)
                    }
                } else if photoStatus.isFinished {
                    if photoStatus.failed > 0 {
                        Label("\(photoStatus.done) photo\(photoStatus.done == 1 ? "" : "s") added · \(photoStatus.failed) couldn't be fetched",
                              systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else if photoStatus.done > 0 {
                        Label("\(photoStatus.done) photo\(photoStatus.done == 1 ? "" : "s") added",
                              systemImage: "photo").foregroundStyle(.green)
                    }
                }
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
                    Label(csvMessage, systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                if let csvError {
                    Label(csvError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            } header: {
                Text("Routines from CSV")
            } footer: {
                Text("Builds routines (and any exercises they reference). Routines that already exist (by name) are skipped, and existing exercises are reused — only new data is added. A routine is just a definition; scheduling is done separately from Calendar/Today, so there are no recurrence columns. Columns: routine, group, exercise, machine, machine_settings, set1_reps, set1_weight, set2_reps, set2_weight, … setN_reps/weight, duration_min, intensity, hold_seconds, sides, rounds, notes. Always required: routine, group, exercise. Strength set columns are optional — if blank, the exercise's saved default sets are used; otherwise each setK pair is one planned set with its own reps/weight (up to 15 sets). Cardio's duration_min/intensity are optional (blank uses the exercise's own); stretching needs only the exercise name. In a routine, every group's prescription columns are optional — a row really only needs routine, group, and exercise. Optional cooldowns (seconds): set_cooldown = rest between sets for that exercise; exercise_cooldown = rest between exercises for the routine (if rows differ, the largest is used). A malformed row blocks the whole import.")
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
    }

    private func prepareExport() {
        errorMessage = nil
        do {
            exportURL = try ExportImportService(context).writeBackupFile(includeDemo: includeDemo)
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
                try? context.save()
                importMessage = outcome.summary
            } catch {
                errorMessage = "Import failed: \(error.localizedDescription)"
            }
        case .failure(let error):
            errorMessage = "Could not open file: \(error.localizedDescription)"
        }
    }

    private func handleCSVImport(_ result: Result<URL, Error>) {
        csvMessage = nil
        csvError = nil
        switch result {
        case .success(let url):
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let report = try CSVRoutineImporter(context).importFile(at: url)
                csvMessage = report.summary
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
                let report = try CSVExerciseImporter(context, group: exGroup, photoStatus: photoStatus).importFile(at: url)
                exMessage = report.summary
            } catch {
                exError = error.localizedDescription
            }
        case .failure(let error):
            exError = "Could not open file: \(error.localizedDescription)"
        }
    }
}
