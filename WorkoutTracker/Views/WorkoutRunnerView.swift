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
    @State private var showFinishConfirm = false
    /// Shown over the lower third once the final exercise is completed.
    @State private var showFinishPrompt = false
    /// Set while the exercise sheet is still on screen; consumed in its
    /// onDismiss. Presenting a second sheet in the same runloop turn as the
    /// first one's dismissal drops the presentation, so we wait for the
    /// dismissal to land.
    @State private var finishPromptPending = false

    private var repo: WorkoutRepository { WorkoutRepository(context) }

    /// True when every exercise is fully done — all strength sets completed AND
    /// every cardio/stretching exercise marked complete.
    private var allSetsComplete: Bool { session.allExercisesComplete }


    var body: some View {
        // Depend on the session's `updatedAt` scalar so the runner reliably
        // re-renders after a presented sheet (exercise sheet / editor) adds,
        // reorders, or completes exercises — SwiftData to-many relationship
        // changes alone don't always notify a parent-held view.
        let _ = session.updatedAt
        return List {
            if restTimer.isRunning || restTimer.isFinished {
                Section {
                    RestTimerBar().environmentObject(restTimer)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            Section { progressRow }

            // One section per group instance present, in the order chosen in the
            // editor. Tapping opens the logging sheet; structural editing is in Edit.
            ForEach(session.orderedGroupKeys) { key in
                Section(session.groupTitle(for: key)) {
                    ForEach(session.exercises(in: key)) { ex in
                        Button { openExercise = ex } label: { exerciseRow(ex) }
                            .tint(.primary)
                    }
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
                    BigActionLabel(title: allSetsComplete ? "Finish Workout" : "Stop Workout",
                                   systemImage: allSetsComplete ? "flag.checkered" : "stop.circle")
                        .foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent)
                // Completed → brand green "Finish Workout"; abandoned/incomplete →
                // black "Stop Workout".
                .tint(allSetsComplete ? Theme.accent : Theme.statusBlack)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                // Stop-and-lock confirmation, attached to the button that triggers it.
                .confirmationDialog(allSetsComplete ? "Finish this workout?" : "Stop this workout?",
                                    isPresented: $showFinishConfirm, titleVisibility: .visible) {
                    Button(allSetsComplete ? "Finish & lock" : "Stop & lock", role: .destructive) { finish() }
                    Button("Keep going", role: .cancel) {}
                } message: {
                    Text(allSetsComplete
                         ? "Completed workouts become permanent history and can only be changed with corrections."
                         : "This workout isn't finished. Stopping locks it as-is; you can't add to it later.")
                }
            }
        }
        .sheet(item: $openExercise, onDismiss: {
            if finishPromptPending {
                finishPromptPending = false
                showFinishPrompt = true
            }
        }) { ex in
            SessionExerciseSheet(session: session, exercise: ex,
                                 onExerciseCompleted: { exerciseCompleted(ex) },
                                 onAdvance: { next in openExercise = next })
                .environmentObject(restTimer)
                .id(ex.id)   // fresh state when auto-advancing to the next exercise
        }
        .sheet(isPresented: $showFinishPrompt) {
            WorkoutCompletePrompt(
                exerciseCount: session.exercises.count,
                duration: session.duration,
                onSaveAndExit: { showFinishPrompt = false; finish() },
                onKeepGoing: { showFinishPrompt = false })
                // Lower third of the screen, per the workout-complete design.
                .presentationDetents([.fraction(0.33)])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            CatalogSyncService(context).reconcileSession(session)
            try? context.save()
        }
    }

    // MARK: - Rows

    private var progressRow: some View {
        let total = session.exercises.count
        let done = session.exercises.filter(\.isFullyCompleted).count
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.status.displayName).font(.headline)
                Spacer()
                Text("\(done)/\(total) exercise\(total == 1 ? "" : "s")").foregroundStyle(.secondary)
            }
            ProgressView(value: total == 0 ? 0 : Double(done) / Double(total))
        }
    }

    private func exerciseRow(_ ex: WorkoutSessionExercise) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ex.isFullyCompleted ? "checkmark.circle.fill"
                  : (ex.isPartiallyIncomplete ? "circle.lefthalf.filled" : "circle"))
                .foregroundStyle(ex.isFullyCompleted ? Theme.statusGreen : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(ex.name).font(.body)
                Text(exerciseSubtitle(ex))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func exerciseSubtitle(_ ex: WorkoutSessionExercise) -> String {
        switch ex.sectionType {
        case .strength:
            return "\(ex.sets.count) set\(ex.sets.count == 1 ? "" : "s")"
        case .cardio:
            var s = "\(ex.durationMinutes) min"
            if let i = ex.intensity { s += " · \(i.displayName)" }
            return s
        case .stretching:
            return "Hold \(ex.holdSeconds)s · \(ex.rounds) round\(ex.rounds == 1 ? "" : "s")"
        }
    }

    // MARK: - Actions

    /// Called as an exercise's sheet closes after that exercise was completed.
    /// If it was the LAST one, prompt to save and exit instead of starting a
    /// cooldown for a workout that has nothing left to do.
    private func exerciseCompleted(_ ex: WorkoutSessionExercise) {
        if session.allExercisesComplete {
            restTimer.stop()
            finishPromptPending = true
        } else {
            startBetweenExercisesRest(after: ex)
        }
    }

    /// Start the between-exercises cooldown after an exercise is completed and
    /// its sheet closes (only if another exercise still needs work).
    private func startBetweenExercisesRest(after ex: WorkoutSessionExercise) {
        guard session.restBetweenExercises > 0 else { return }
        if let next = session.orderedExercises.first(where: { !$0.isFullyCompleted }) {
            restTimer.start(seconds: session.restBetweenExercises, upcoming: "Next: \(next.name)")
        }
    }

    private func finish() {
        repo.finishWorkout(session)
        try? context.save()
        restTimer.stop()
        onFinished()
    }
}
