//
//  RoutineEditorSupport.swift
//  WorkoutTracker
//
//  Helper sheet for the Routine Editor: the catalog exercise picker. (An
//  exercise's prescription is edited on the exercise itself.)
//

import SwiftUI
import SwiftData

/// Lists catalog exercises to add to a routine section, with a path to create a
/// new exercise/machine.
struct ExercisePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Exercise> { $0.deletedAt == nil }, sort: \Exercise.name) private var exercises: [Exercise]
    /// When set, only exercises of this group are offered (and a new one is
    /// created locked to it). Nil = show all (e.g. adding an exercise mid-workout).
    var group: SectionType? = nil
    /// Demo and user data never mix: a user routine or workout only offers
    /// user exercises, a demo one only demo exercises, and an exercise
    /// created here takes the same source.
    var source: DataSource = .user
    var onPick: (Exercise) -> Void

    @State private var showNewExercise = false

    private var filtered: [Exercise] { Self.offered(exercises, group: group, source: source) }

    /// The exercises the picker offers: same demo/user source, and the
    /// grouping's type when one is set.
    static func offered(_ exercises: [Exercise], group: SectionType?, source: DataSource) -> [Exercise] {
        exercises.filter { $0.source == source && (group == nil || $0.defaultSectionType == group) }
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
                NavigationStack { ExerciseEditorView(forcedGroup: group, newSource: source) }
            }
        }
    }
}
