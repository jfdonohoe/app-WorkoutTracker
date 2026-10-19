//
//  SettingsView.swift
//  WorkoutTracker
//
//  Settings tab. Hosts Routines and the Data tools (import/export, demo data)
//  that previously lived in their own tabs. The Data Safety Check runs as part
//  of Import / Export, the only way its problems can arise.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage(WeightUnit.storageKey) private var weightUnit: WeightUnit = .lb
    @AppStorage(DistanceUnit.storageKey) private var distanceUnit: DistanceUnit = .mi
    @AppStorage(WorkoutSettings.timerSoundsKey) private var timerSounds = true
    @AppStorage(WorkoutSettings.autoProgressStretchesKey) private var autoProgressStretches = true
    var body: some View {
        NavigationStack {
            List {
                Section("Build") {
                    NavigationLink {
                        // Screens below a tab's top level hide the tab bar.
                        RoutineListView(embedded: true).toolbar(.hidden, for: .tabBar)
                    } label: {
                        Label("Routines", systemImage: "list.bullet.rectangle")
                    }
                    NavigationLink {
                        ExerciseLibraryView().toolbar(.hidden, for: .tabBar)
                    } label: {
                        Label("Exercises", systemImage: "dumbbell")
                    }
                }

                Section {
                    Picker("Weight", selection: $weightUnit) {
                        ForEach(WeightUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Distance", selection: $distanceUnit) {
                        ForEach(DistanceUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                } header: {
                    Text("Units")
                } footer: {
                    Text("Changes the label only; numbers you've saved aren't converted.")
                }

                // Approved Figma "Settings: timer sounds and stretch auto-advance".
                Section {
                    Toggle("Timer sounds", isOn: $timerSounds)
                    Toggle("Auto progress through stretches", isOn: $autoProgressStretches)
                } header: {
                    Text("Workout")
                } footer: {
                    Text("Timer sounds: the countdown beeps and chimes (vibrations still play). Auto progress through stretches: when a stretch ends, the next one starts after the workout's Between stretches rest (taken from the routine; 5 seconds unless changed). Off: the timer stops after each stretch.")
                }

                Section("Backup") {
                    NavigationLink { ImportExportView().toolbar(.hidden, for: .tabBar) } label: {
                        Label("Import / Export", systemImage: "arrow.up.arrow.down.circle")
                    }
                }

                Section("Testing") {
                    NavigationLink { DemoDataView().toolbar(.hidden, for: .tabBar) } label: {
                        Label("Demo Data", systemImage: "testtube.2")
                    }
                }

                // Approved Figma "Settings: app version caption".
                Section {
                    Text(versionCaption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Settings")
        }
    }

    /// e.g. "Sets 1.1 (4)": display name, marketing version and build number, read
    /// from the bundle so it always names the build that's actually installed.
    private var versionCaption: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "Sets"
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(name) \(version) (\(build))"
    }
}
