//
//  ExerciseLibraryView.swift
//  WorkoutTracker
//
//  Settings ▸ Exercises. A library of predefined exercises (with default
//  sets/reps/weight) to build routines from. Includes every exercise already
//  used by existing routines, since those live in the same catalog.
//

import SwiftUI
import SwiftData

struct ExerciseLibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Exercise> { $0.deletedAt == nil }, sort: \Exercise.name) private var exercises: [Exercise]
    @State private var showNewExercise = false
    @State private var editingExercise: Exercise?

    var body: some View {
        List {
            if exercises.isEmpty {
                ContentUnavailableView("No exercises yet", systemImage: "dumbbell",
                                       description: Text("Tap + to define an exercise."))
            }
            // One section per group.
            ForEach(SectionType.allCases) { group in
                let groupExercises = exercises.filter { $0.defaultSectionType == group }
                if !groupExercises.isEmpty {
                    Section(group.displayName) {
                        ForEach(groupExercises) { ex in
                            // Edit in a SHEET (not a push): the editor's per-set
                            // @State ForEach loops if pushed without its own stack.
                            Button { editingExercise = ex } label: {
                                HStack {
                                    row(ex)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.bold()).foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in softDelete(groupExercises, offsets) }
                    }
                }
            }
        }
        .navigationTitle("Exercises")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNewExercise = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showNewExercise) {
            NavigationStack { ExerciseEditorView() }
        }
        .sheet(item: $editingExercise) { ex in
            NavigationStack { ExerciseEditorView(existing: ex) }
        }
    }

    private func row(_ ex: Exercise) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(ex.name).font(.headline)
                if ex.source == .seedDemo {
                    Text("DEMO").font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.yellow.opacity(0.3), in: Capsule())
                }
            }
            Text(ex.summary).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func softDelete(_ list: [Exercise], _ offsets: IndexSet) {
        for i in offsets {
            list[i].deletedAt = .now
            list[i].updatedAt = .now
            RoutineRepository(context).removeExerciseFromAllRoutines(exerciseId: list[i].id)
            WorkoutRepository(context).removeExerciseFromActiveSessions(exerciseId: list[i].id)
        }
        try? context.save()
    }
}
