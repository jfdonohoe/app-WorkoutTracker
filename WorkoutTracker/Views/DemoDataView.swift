//
//  DemoDataView.swift
//  WorkoutTracker
//
//  Screen 10. One-click demo cleanup. Removes ALL data that originated as demo
//  data — even demo records the user edited during QA — while leaving real user
//  data untouched (principles #6, #7).
//

import SwiftUI
import SwiftData

struct DemoDataView: View {
    @Environment(\.modelContext) private var context

    @Query(filter: #Predicate<Routine> { $0.sourceRaw == "seedDemo" }) private var demoRoutines: [Routine]
    @Query(filter: #Predicate<WorkoutSession> { $0.sourceRaw == "seedDemo" }) private var demoSessions: [WorkoutSession]
    @Query(filter: #Predicate<Routine> { $0.sourceRaw == "user" }) private var userRoutines: [Routine]
    @Query(filter: #Predicate<WorkoutSession> { $0.sourceRaw == "user" }) private var userSessions: [WorkoutSession]

    /// Persistent (UserDefaults) — see SeedDataService.autoSeedDisabledKey.
    @AppStorage(SeedDataService.autoSeedDisabledKey) private var autoSeedDisabled = false
    @State private var showConfirm = false
    @State private var resultMessage: String?
    /// The debug erase asks first: Debug builds run on the phone with real history.
    @State private var showWipeConfirm = false

    var body: some View {
        List {
            Section {
                Toggle("Add demo data on launch", isOn: Binding(get: { !autoSeedDisabled },
                                                                set: { autoSeedDisabled = !$0 }))
            } footer: {
                Text(autoSeedDisabled
                     ? "Demo data will never be added automatically when the app starts. This stays off through app updates and new builds."
                     : "When you have no data of your own, demo data is added automatically when the app starts.")
            }
            Section("Demo data present") {
                row("Demo routines", demoRoutines.count)
                row("Demo sessions", demoSessions.count)
            }
            Section("Your data (kept)") {
                row("Your routines", userRoutines.count)
                row("Your sessions", userSessions.count)
            }
            Section {
                Button(role: .destructive) {
                    showConfirm = true
                } label: {
                    Label("Delete Demo Data", systemImage: "trash")
                }
                .disabled(demoRoutines.isEmpty && demoSessions.isEmpty)
                .confirmationDialog("Delete all demo data?", isPresented: $showConfirm, titleVisibility: .visible) {
                    Button("Delete demo data", role: .destructive) { deleteDemo() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This cannot be undone, but it only removes demo-originated data.")
                }

                Button {
                    SeedDataService(context).seed()
                } label: {
                    Label("Re-seed demo data", systemImage: "arrow.clockwise")
                }
                .disabled(!(demoRoutines.isEmpty && demoSessions.isEmpty))

                if let resultMessage {
                    Label(resultMessage, systemImage: "checkmark.circle").foregroundStyle(Theme.statusGreen)
                }
            } footer: {
                Text("Deletes everything that started as demo data, including demo records you edited. Your own workouts are never touched, and neither are workouts you finished or stopped on a demo routine: they become yours.")
            }

            #if DEBUG
            Section {
                Button(role: .destructive) {
                    showWipeConfirm = true
                } label: {
                    Label("DEV: Erase ALL data & reseed", systemImage: "exclamationmark.triangle.fill")
                }
                .confirmationDialog("Erase ALL data?", isPresented: $showWipeConfirm, titleVisibility: .visible) {
                    Button("Erase everything", role: .destructive) {
                        DevTools.resetAndReseed(context)
                        resultMessage = "Dev reset: erased everything and reseeded."
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every workout, routine, exercise, correction and log on this device is deleted, including your own history. This can't be undone. Make a backup first.")
                }
            } header: {
                Text("Developer (debug builds only)")
            } footer: {
                Text("Wipes the entire local store — user data included — then reseeds demo data. This control is compiled out of release builds.")
            }
            #endif
        }
        .navigationTitle("Demo Data")
    }

    private func row(_ label: String, _ count: Int) -> some View {
        HStack { Text(label); Spacer(); Text("\(count)").foregroundStyle(.secondary) }
    }

    private func deleteDemo() {
        let count = DemoDataManager(context).deleteAllDemoData()
        try? context.save()
        resultMessage = "Deleted \(count) demo record group(s)."
    }
}
