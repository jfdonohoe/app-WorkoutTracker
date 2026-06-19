//
//  DataHubView.swift
//  WorkoutTracker
//
//  Entry point for data tools: Import/Export (Screen 9), Demo Data (Screen 10),
//  and Data Safety Check (Screen 11).
//

import SwiftUI

struct DataHubView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Backup") {
                    NavigationLink { ImportExportView() } label: {
                        Label("Import / Export", systemImage: "arrow.up.arrow.down.circle")
                    }
                }
                Section("Testing") {
                    NavigationLink { DemoDataView() } label: {
                        Label("Demo Data", systemImage: "testtube.2")
                    }
                    NavigationLink { DataSafetyCheckView() } label: {
                        Label("Data Safety Check", systemImage: "checkmark.shield")
                    }
                }
            }
            .navigationTitle("Data")
        }
    }
}
