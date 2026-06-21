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
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var errorMessage: String?

    // CSV routine import
    @State private var csvTemplateURL: URL?
    @State private var showCSVImporter = false
    @State private var csvMessage: String?
    @State private var csvError: String?

    // CSV exercise-library import
    @State private var exTemplateURL: URL?
    @State private var showExCSVImporter = false
    @State private var exMessage: String?
    @State private var exError: String?

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
                    showImporter = true
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
                if let url = exTemplateURL {
                    ShareLink(item: url) {
                        Label("Share exercises template", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        exTemplateURL = try? CSVExerciseImporter.writeExampleFile()
                    } label: {
                        Label("Get exercises CSV template", systemImage: "doc.text")
                    }
                }
                Button {
                    showExCSVImporter = true
                } label: {
                    Label("Import exercises from CSV", systemImage: "dumbbell")
                }
                if let exMessage {
                    Label(exMessage, systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                if let exError {
                    Label(exError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            } header: {
                Text("Exercises from CSV")
            } footer: {
                Text("Builds your exercise library. Columns: group, exercise, machine, machine_settings, sets, reps, weight, duration_min, intensity, hold_seconds, sides, rounds, notes. Required: group, exercise. Strength needs sets/reps/weight; cardio needs duration_min/intensity; stretching needs hold_seconds/sides/rounds. Re-importing updates an exercise with the same name + group. All-or-nothing: any invalid row blocks the whole import.")
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
                    showCSVImporter = true
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
                Text("Builds routines (and any exercises they reference). Columns: routine, group, exercise, machine, machine_settings, sets, reps, weight, duration_min, intensity, hold_seconds, sides, rounds, notes, recurrence, interval, weekday, month_day, count, start_date. Always required: routine, group, exercise. Strength needs sets/reps/weight; cardio needs duration_min/intensity; stretching needs hold_seconds/sides/rounds. Schedule is optional — set recurrence (daily/weekly/monthly) on one row per routine; weekly also needs weekday. All-or-nothing: any invalid row blocks the whole import.")
            }
        }
        .navigationTitle("Import / Export")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            handleImport(result)
        }
        .fileImporter(isPresented: $showCSVImporter,
                      allowedContentTypes: [.commaSeparatedText, .plainText, .text, .data]) { result in
            handleCSVImport(result)
        }
        .fileImporter(isPresented: $showExCSVImporter,
                      allowedContentTypes: [.commaSeparatedText, .plainText, .text, .data]) { result in
            handleExCSVImport(result)
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
        switch result {
        case .success(let url):
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let report = try CSVExerciseImporter(context).importFile(at: url)
                exMessage = report.summary
            } catch {
                exError = error.localizedDescription
            }
        case .failure(let error):
            exError = "Could not open file: \(error.localizedDescription)"
        }
    }
}
