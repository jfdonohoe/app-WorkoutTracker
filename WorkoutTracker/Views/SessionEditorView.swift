//
//  SessionEditorView.swift
//  WorkoutTracker
//
//  Full editor for a workout IN PROGRESS. It deliberately mirrors the routine
//  editor (RoutineEditorView) used when editing a future routine from the
//  Calendar: exercises grouped by type, an "Add exercise" button per grouping
//  (filtered to that grouping's type), tap a strength exercise to edit its sets
//  via the same SetBuilderSheet, swipe / drag to delete and reorder, plus the
//  routine-level cooldowns. The difference is the backing store: this operates
//  on the live WorkoutSession snapshot rather than a RoutineVersion.
//
//  A workout can hold more than one group of the same TYPE (e.g. two strength
//  blocks). The toolbar "+" creates a NEW group of a type; each group's own
//  "Add exercise" button adds into THAT group. Groups are keyed by
//  SessionGroupKey (type + index).
//
//  Presented as a sheet from ActiveWorkoutView's "Edit" button.
//

import SwiftUI
import SwiftData

struct SessionEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: WorkoutSession

    /// What an exercise-picker session should do once an exercise is chosen.
    private enum AddTarget: Identifiable {
        case existing(SessionGroupKey)   // add into this group
        case newGroup(SectionType)       // create a new group of this type
        var id: String {
            switch self {
            case .existing(let k): return "e-\(k.id)"
            case .newGroup(let t): return "n-\(t.rawValue)"
            }
        }
        var type: SectionType {
            switch self {
            case .existing(let k): return k.type
            case .newGroup(let t): return t
            }
        }
    }

    @State private var addTarget: AddTarget?
    @State private var editExercise: WorkoutSessionExercise?

    private var repo: WorkoutRepository { WorkoutRepository(context) }

    var body: some View {
        NavigationStack {
            List {
                cooldownSection

                // One section per group INSTANCE present, in the chosen order. Each
                // has its own "Add exercise" and a header menu to move the whole
                // grouping up/down — like the routine editor.
                ForEach(session.orderedGroupKeys) { key in
                    let exercises = session.exercises(in: key)
                    Section {
                        ForEach(exercises) { ex in exerciseRow(ex) }
                            .onMove { offsets, dest in moveExercises(key, offsets, dest) }
                            .onDelete { removeExercises(exercises, $0) }

                        Button { addTarget = .existing(key) } label: {
                            Label("Add exercise", systemImage: "plus.circle")
                        }
                    } header: {
                        groupHeader(key)
                    }
                }
            }
            .navigationTitle("Edit Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    // Add a NEW grouping of a type (a 2nd strength block, etc.).
                    Menu {
                        ForEach(SectionType.allCases) { type in
                            Button("New \(type.displayName) group") { addTarget = .newGroup(type) }
                        }
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $addTarget) { target in
                // Only exercises of this grouping's type can be added.
                ExercisePickerSheet(group: target.type) { exercise in
                    let groupIndex: Int
                    switch target {
                    case .existing(let key): groupIndex = key.index
                    case .newGroup(let type): groupIndex = session.maxGroupIndex(of: type) + 1
                    }
                    repo.addUnplannedExercise(to: session, from: exercise, groupIndex: groupIndex)
                    try? context.save()
                }
            }
            .sheet(item: $editExercise) { ex in
                SetBuilderSheet(title: ex.name,
                                machineId: ex.machineId,
                                exerciseId: ex.exerciseId,
                                defaultRest: session.restBetweenSets,
                                initialSets: ex.orderedSets.map { ($0.plannedReps, $0.plannedWeight) },
                                initialRest: ex.plannedRestBetweenSets) { sets, rest in
                    repo.setSessionPlannedSets(ex, sets: sets, restBetweenSets: rest, in: session)
                    try? context.save()
                }
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func exerciseRow(_ ex: WorkoutSessionExercise) -> some View {
        if ex.sectionType == .strength {
            // Strength: tap to edit sets/reps/weight (same sheet as the routine editor).
            Button { editExercise = ex } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ex.name).font(.body).foregroundStyle(.primary)
                    Text(subtitle(ex)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .tint(.primary)
        } else {
            // Cardio / stretching: show the snapshot's own characteristics.
            VStack(alignment: .leading, spacing: 2) {
                Text(ex.name).font(.body)
                Text(subtitle(ex)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func subtitle(_ ex: WorkoutSessionExercise) -> String {
        switch ex.sectionType {
        case .strength:
            let n = ex.sets.count
            return "\(n)×\(ex.orderedSets.first?.plannedReps ?? 0) @ \(Int(ex.orderedSets.first?.plannedWeight ?? 0)) lb"
        case .cardio:
            var s = "\(ex.durationMinutes) min"
            if let i = ex.intensity { s += " · \(i.displayName)" }
            return s
        case .stretching:
            return "Hold \(ex.holdSeconds)s · \(ex.rounds) round\(ex.rounds == 1 ? "" : "s")"
        }
    }

    // MARK: - Cooldowns (session-level)

    private var cooldownSection: some View {
        Section("Cooldowns") {
            Stepper("Between exercises: \(session.restBetweenExercises)s",
                    value: Binding(get: { session.restBetweenExercises },
                                   set: { session.restBetweenExercises = $0; try? context.save() }),
                    in: 0...600, step: 15)
            Stepper("Between sets: \(session.restBetweenSets)s",
                    value: Binding(get: { session.restBetweenSets },
                                   set: { session.restBetweenSets = $0; try? context.save() }),
                    in: 0...600, step: 15)
        }
    }

    // MARK: - Group header (title + reorder whole groupings)

    private func groupHeader(_ key: SessionGroupKey) -> some View {
        let groups = session.orderedGroupKeys
        let idx = groups.firstIndex(of: key) ?? 0
        return HStack {
            Text(session.groupTitle(for: key))
            Spacer()
            Menu {
                Button { moveGroup(key, by: -1) } label: {
                    Label("Move grouping up", systemImage: "arrow.up")
                }.disabled(idx == 0)
                Button { moveGroup(key, by: 1) } label: {
                    Label("Move grouping down", systemImage: "arrow.down")
                }.disabled(idx == groups.count - 1)
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Mutations

    private func removeExercises(_ exercises: [WorkoutSessionExercise], _ offsets: IndexSet) {
        let groups = session.orderedGroupKeys
        for i in offsets where exercises.indices.contains(i) {
            context.delete(exercises[i])
        }
        renumber(groups: groups)
        try? context.save()
    }

    private func moveExercises(_ key: SessionGroupKey, _ offsets: IndexSet, _ dest: Int) {
        let groups = session.orderedGroupKeys
        var exercises = session.exercises(in: key)
        exercises.move(fromOffsets: offsets, toOffset: dest)
        renumber(groups: groups, overriding: key, with: exercises)
        try? context.save()
    }

    /// Move an entire grouping up (-1) or down (+1) among the present groups.
    private func moveGroup(_ key: SessionGroupKey, by delta: Int) {
        var groups = session.orderedGroupKeys
        guard let idx = groups.firstIndex(of: key) else { return }
        let target = idx + delta
        guard target >= 0, target < groups.count else { return }
        groups.swapAt(idx, target)
        renumber(groups: groups)
        try? context.save()
    }

    /// Reassign a contiguous global `order`, walking groups in the given order so
    /// both the group order and within-group order stay stable. `overriding`
    /// supplies an already-reordered exercise list for one group.
    private func renumber(groups: [SessionGroupKey],
                          overriding key: SessionGroupKey? = nil,
                          with reordered: [WorkoutSessionExercise] = []) {
        var next = 0
        for g in groups {
            let list = (g == key) ? reordered : session.exercises(in: g)
            for ex in list { ex.order = next; next += 1 }
        }
        session.updatedAt = .now   // notify the workout runner to refresh
    }
}
