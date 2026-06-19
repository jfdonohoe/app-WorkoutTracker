//
//  WorkoutRunnerView.swift
//  WorkoutTracker
//
//  The live workout surface: the session's exercises as a press-and-hold
//  reorderable list. Tapping an exercise opens the logging modal. Below the list
//  are two session cooldown settings (between exercises / between sets). When an
//  exercise's logging sheet closes after the exercise is finished, the
//  between-exercises cooldown timer starts here.
//
//  Embeddable (no NavigationStack of its own).
//

import SwiftUI
import SwiftData

struct WorkoutRunnerView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var restTimer: RestTimerService

    @Bindable var session: WorkoutSession
    var onFinished: () -> Void = {}

    @State private var openExercise: WorkoutSessionExercise?
    @State private var showAddExercise = false
    @State private var showFinishConfirm = false

    private var repo: WorkoutRepository { WorkoutRepository(context) }

    var body: some View {
        List {
            if restTimer.isRunning || restTimer.isFinished {
                Section {
                    RestTimerBar().environmentObject(restTimer)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            Section { progressRow }

            Section("Exercises") {
                ForEach(session.orderedExercises) { ex in
                    Button { openExercise = ex } label: { exerciseRow(ex) }
                        .tint(.primary)
                }
                .onMove(perform: moveExercises) // press-and-hold to reorder

                Button { showAddExercise = true } label: {
                    Label("Add exercise", systemImage: "plus.circle")
                }
            }

            Section("Cooldown timers") {
                Stepper("Between exercises: \(session.restBetweenExercises)s",
                        value: Binding(get: { session.restBetweenExercises },
                                       set: { session.restBetweenExercises = $0; try? context.save() }),
                        in: 0...600, step: 15)
                Stepper("Between sets: \(session.restBetweenSets)s",
                        value: Binding(get: { session.restBetweenSets },
                                       set: { session.restBetweenSets = $0; try? context.save() }),
                        in: 0...600, step: 15)
            }

            Section {
                Button { showFinishConfirm = true } label: {
                    BigActionLabel(title: "Finish workout", systemImage: "flag.checkered")
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .sheet(item: $openExercise) { ex in
            SessionExerciseSheet(session: session, exercise: ex,
                                 onExerciseCompleted: { startBetweenExercisesRest(after: ex) })
                .environmentObject(restTimer)
        }
        .sheet(isPresented: $showAddExercise) {
            ExercisePickerSheet { exercise in
                addFromLibrary(exercise)
            }
        }
        .confirmationDialog("Finish this workout?", isPresented: $showFinishConfirm, titleVisibility: .visible) {
            Button("Finish & lock", role: .destructive) { finish() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("Completed workouts become permanent history and can only be changed with corrections.")
        }
    }

    // MARK: - Rows

    private var progressRow: some View {
        let sets = session.exercises.flatMap(\.sets)
        let done = sets.filter(\.isCompleted).count
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.status.displayName).font(.headline)
                Spacer()
                Text("\(done)/\(sets.count) sets").foregroundStyle(.secondary)
            }
            ProgressView(value: sets.isEmpty ? 0 : Double(done) / Double(sets.count))
        }
    }

    private func exerciseRow(_ ex: WorkoutSessionExercise) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ex.isFullyCompleted ? "checkmark.circle.fill"
                  : (ex.isPartiallyIncomplete ? "circle.lefthalf.filled" : "circle"))
                .foregroundStyle(ex.isFullyCompleted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(ex.name).font(.body)
                Text("\(ex.sets.count) set\(ex.sets.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Actions

    private func moveExercises(_ offsets: IndexSet, _ destination: Int) {
        var ordered = session.orderedExercises
        ordered.move(fromOffsets: offsets, toOffset: destination)
        repo.reorder(session, orderedIds: ordered.map(\.id))
        try? context.save()
    }

    /// Start the between-exercises cooldown after an exercise is completed and
    /// its sheet closes (only if another exercise still needs work).
    private func startBetweenExercisesRest(after ex: WorkoutSessionExercise) {
        guard session.restBetweenExercises > 0 else { return }
        if let next = session.orderedExercises.first(where: { !$0.isFullyCompleted }) {
            restTimer.start(seconds: session.restBetweenExercises, upcoming: "Next: \(next.name)")
        }
    }

    private func addFromLibrary(_ exercise: Exercise) {
        let defaults = exercise.effectiveDefaultSets
        let sets = defaults.isEmpty ? [(reps: 10, weight: 0.0)] : defaults
        let se = repo.addUnplannedExercise(to: session, name: exercise.name, sets: sets,
                                           rest: exercise.defaultRest, machineId: exercise.machineId)
        // Snapshot the machine's current settings into the new session exercise.
        if let machineId = exercise.machineId, let machine = repo.fetchMachine(machineId) {
            for def in machine.activeSettings {
                _ = repo.addSessionSetting(to: se, label: def.label,
                                           numericValue: def.numericValue, otherText: def.otherText,
                                           alsoAddToMachine: false)
            }
        }
        try? context.save()
    }

    private func finish() {
        repo.finishWorkout(session)
        try? context.save()
        restTimer.stop()
        onFinished()
    }
}
