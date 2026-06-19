//
//  SettingsView.swift
//  WorkoutTracker
//
//  Settings tab. Hosts Routines and the Data tools (import/export, demo data,
//  data safety check) that previously lived in their own tabs.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Build") {
                    NavigationLink {
                        RoutineListView(embedded: true)
                    } label: {
                        Label("Routines", systemImage: "list.bullet.rectangle")
                    }
                    NavigationLink {
                        ExerciseLibraryView()
                    } label: {
                        Label("Exercises", systemImage: "dumbbell")
                    }
                }

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
            .navigationTitle("Settings")
        }
    }
}
