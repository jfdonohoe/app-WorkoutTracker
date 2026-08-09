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

    @State private var showConfirm = false
    @State private var resultMessage: String?

    var body: some View {
        List {
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
                Text("Deletes everything that started as demo data, including demo records you edited. Your own workouts are never touched.")
            }

            #if DEBUG
            Section {
                Button(role: .destructive) {
                    DevTools.resetAndReseed(context)
                    resultMessage = "Dev reset: erased everything and reseeded."
                } label: {
                    Label("DEV: Erase ALL data & reseed", systemImage: "exclamationmark.triangle.fill")
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
