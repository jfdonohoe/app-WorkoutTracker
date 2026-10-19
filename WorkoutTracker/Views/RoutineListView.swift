//
//  RoutineListView.swift
//  WorkoutTracker
//
//  Screen 4. Lists routines, supports creating new ones, and soft-deletes
//  here so historical sessions keep resolving. (Only a scratch routine that
//  no workout ever used is removed outright, from the editor, the Calendar
//  and the schedule sheet.)
//

import SwiftUI
import SwiftData

struct RoutineListView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Routine> { $0.deletedAt == nil }, sort: \Routine.name) private var routines: [Routine]

    /// When embedded inside another NavigationStack (e.g. Settings), don't add a
    /// second stack.
    var embedded: Bool = false

    @State private var newRoutineToEdit: Routine?

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack { content }
            }
        }
    }

    private var content: some View {
        List {
            if routines.isEmpty {
                ContentUnavailableView("No routines yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Tap + to create your first routine."))
            }
            ForEach(routines) { routine in
                NavigationLink {
                    RoutineEditorView(routine: routine).toolbar(.hidden, for: .tabBar)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(routine.name).font(.headline)
                            if routine.source == .seedDemo {
                                Text("DEMO").font(.caption2.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.yellow.opacity(0.3), in: Capsule())
                            }
                        }
                        if let v = routine.activeVersion {
                            Text("v\(v.versionNumber) · \(v.orderedSections.count) section(s)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete(perform: softDelete)
        }
        .navigationTitle("Routines")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { createRoutineAndEdit() } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $newRoutineToEdit) { r in
            NavigationStack {
                RoutineEditorView(routine: r, isCreating: true)
            }
        }
        .onAppear {
            let sync = CatalogSyncService(context)
            for routine in routines { sync.reconcileRoutine(routine) }
            try? context.save()
        }
    }

    /// Create a new (unnamed) routine and open the creation editor with
    /// Cancel/Save; naming is the first step there.
    private func createRoutineAndEdit() {
        let repo = RoutineRepository(context)
        let routine = repo.createRoutine(name: "")
        if let v = routine.activeVersion {
            repo.addSection(to: v, type: .strength)
        }
        try? context.save()
        newRoutineToEdit = routine
    }

    private func softDelete(_ offsets: IndexSet) {
        let repo = RoutineRepository(context)
        for i in offsets { repo.softDelete(routines[i]) }
        try? context.save()
    }
}
