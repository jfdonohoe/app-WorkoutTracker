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
                if let url = csvTemplateURL {
                    ShareLink(item: url) {
                        Label("Share example CSV", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        csvTemplateURL = try? CSVRoutineImporter.writeExampleFile()
                    } label: {
                        Label("Get example CSV template", systemImage: "doc.text")
                    }
                }
                Button {
                    showCSVImporter = true
                } label: {
                    Label("Import routine from CSV", systemImage: "tablecells.badge.ellipsis")
                }
                if let csvMessage {
                    Label(csvMessage, systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                if let csvError {
                    Label(csvError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            } header: {
                Text("Routine from CSV")
            } footer: {
                Text("Columns: routine, section, exercise, machine, sets, reps, weight. Required: routine, exercise, sets, reps, weight. Bad rows are reported and skipped.")
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
                // Surface the first few row errors so the user can fix the file.
                if !report.rowErrors.isEmpty {
                    csvError = report.rowErrors.prefix(3).joined(separator: "\n")
                        + (report.rowErrors.count > 3 ? "\n…" : "")
                }
            } catch {
                csvError = error.localizedDescription
            }
        case .failure(let error):
            csvError = "Could not open file: \(error.localizedDescription)"
        }
    }
}
