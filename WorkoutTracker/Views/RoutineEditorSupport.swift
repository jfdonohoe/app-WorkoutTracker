//
//  RoutineEditorSupport.swift
//  WorkoutTracker
//
//  Helper sheets for the Routine Editor: a catalog exercise picker and a
//  single-exercise prescription editor. Editing happens on a local draft and is
//  only committed via the caller's save closure (which routes through the
//  version-safety guard).
//

import SwiftUI
import SwiftData

/// Plain value type carrying an exercise's editable prescription.
struct RoutineExerciseDraft {
    var setCount: Int
    var plannedWeight: Double
    var plannedReps: Int
    var restBetweenSets: Int
    var notes: String
    var targetEffort: PerceivedEffort?
}

struct RoutineExerciseEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let exercise: RoutineExercise
    var onSave: (RoutineExerciseDraft) -> Void

    @State private var draft: RoutineExerciseDraft

    init(exercise: RoutineExercise, onSave: @escaping (RoutineExerciseDraft) -> Void) {
        self.exercise = exercise
        self.onSave = onSave
        _draft = State(initialValue: RoutineExerciseDraft(
            setCount: exercise.setCount,
            plannedWeight: exercise.plannedWeight,
            plannedReps: exercise.plannedReps,
            restBetweenSets: exercise.restBetweenSets,
            notes: exercise.notes,
            targetEffort: exercise.targetEffort))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(exercise.displayName) {
                    Stepper("Sets: \(draft.setCount)", value: $draft.setCount, in: 1...15)
                    Stepper("Weight: \(Int(draft.plannedWeight)) lb", value: $draft.plannedWeight, in: 0...2000, step: 5)
                    Stepper("Reps: \(draft.plannedReps)", value: $draft.plannedReps, in: 1...100)
                    Stepper("Rest between sets: \(draft.restBetweenSets)s", value: $draft.restBetweenSets, in: 0...600, step: 15)
                }
                Section("Optional") {
                    Picker("Target effort", selection: $draft.targetEffort) {
                        Text("None").tag(PerceivedEffort?.none)
                        ForEach(PerceivedEffort.allCases) { e in
                            Text(e.displayName).tag(PerceivedEffort?.some(e))
                        }
                    }
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                }
            }
            .navigationTitle("Edit Exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(draft); dismiss() }
                }
            }
        }
    }
}

/// Lists catalog exercises to add to a routine section, with a path to create a
/// new exercise/machine.
struct ExercisePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Exercise> { $0.deletedAt == nil }, sort: \Exercise.name) private var exercises: [Exercise]
    /// When set, only exercises of this group are offered (and a new one is
    /// created locked to it). Nil = show all (e.g. adding an exercise mid-workout).
    var group: SectionType? = nil
    var onPick: (Exercise) -> Void

    @State private var showNewExercise = false

    private var filtered: [Exercise] {
        guard let group else { return exercises }
        return exercises.filter { $0.defaultSectionType == group }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showNewExercise = true } label: {
                        Label("Create new exercise", systemImage: "plus.circle")
                    }
                }
                Section(group?.displayName ?? "Exercises") {
                    if filtered.isEmpty {
                        Text(group == nil
                             ? "No exercises yet. Create one above."
                             : "No \(group!.displayName.lowercased()) exercises yet. Create one above.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(filtered) { ex in
                        Button {
                            onPick(ex)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ex.name).foregroundStyle(.primary)
                                Text(ex.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(group == nil ? "Add Exercise" : "Add \(group!.displayName)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showNewExercise) {
                NavigationStack { ExerciseEditorView(forcedGroup: group) }
            }
        }
    }
}
