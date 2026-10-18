//
//  WorkoutRunnerView.swift
//  WorkoutTracker
//
//  The live workout surface: the session's exercises, grouped by type.
//  Tapping an exercise opens the logging modal. Finish / Stop is below the
//  list, and the rests per exercise type are at the very bottom. Rests run in
//  the exercise card; moving from one type's group to the next has none.
//
//  Embeddable (no NavigationStack of its own): shown inline on the Workout tab.
//

import SwiftUI
import SwiftData

struct WorkoutRunnerView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var restTimer: RestTimerService
    @EnvironmentObject private var guidedTimer: GuidedTimerService

    @Bindable var session: WorkoutSession
    /// Optional content shown above the workout (the Workout tab's title row).
    var listHeader: AnyView? = nil
    /// Sheet presentation: leaving the screen ends the guided run. On the
    /// Workout tab, switching tabs must not, so the tab passes false.
    var stopsGuidedRunOnDisappear: Bool = true
    /// Finishing couldn't be saved. The host shows it: this view goes away
    /// with the finish (the workout is locked in memory).
    var onSaveFailed: (String) -> Void = { _ in }
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
            if let listHeader {
                Section {
                    listHeader
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            // A running cardio/stretch sequence keeps its controls (including
            // the persistent pause) here when the exercise sheet is closed.
            if guidedTimer.isActive {
                Section {
                    GuidedTimerPanel(compact: true).environmentObject(guidedTimer)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            if restTimer.isActive || restTimer.isFinished {
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
                // With nothing logged, stopping discards the workout instead.
                .confirmationDialog(allSetsComplete ? "Finish this workout?"
                                        : (session.hasAnythingDone ? "Stop this workout?" : "Discard this workout?"),
                                    isPresented: $showFinishConfirm, titleVisibility: .visible) {
                    Button(allSetsComplete ? "Finish & lock"
                               : (session.hasAnythingDone ? "Stop & lock" : "Discard Workout"),
                           role: .destructive) { finish() }
                    Button("Keep going", role: .cancel) {}
                } message: {
                    Text(allSetsComplete
                         ? "Completed workouts become permanent history and can only be changed with corrections."
                         : (session.hasAnythingDone
                            ? "This workout isn't finished. Stopping locks it as-is; you can't add to it later."
                            : "Nothing has been logged yet, so this workout won't be saved."))
                }
            }

            // Rests per exercise type, at the very bottom (approved Figma).
            if !session.isLocked {
                RestSettingsSections(
                    rests: Binding(get: { session.rests },
                                   set: { WorkoutRepository(context).setRests(session, $0); try? context.save()
                                          guidedTimer.updateRests($0) }),
                    footer: "Rests apply within each type; moving from one type to the next has no rest. Changes here also update the routine for future workouts.")
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
                .environmentObject(guidedTimer)
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
            guidedTimer.onExerciseFinished = { id in guidedExerciseFinished(id) }
            guidedTimer.onSequenceFinished = { id in guidedSequenceFinished(id) }
        }
        // In a sheet the run belongs to this workout screen: if it goes away
        // (Close, or a swipe-down), stop the run and unhook its callbacks. On
        // the Workout tab the screen merely goes off-screen on a tab switch, so
        // the run (and its callbacks) keep going.
        .onDisappear {
            guard stopsGuidedRunOnDisappear else { return }
            guidedTimer.stop()
            guidedTimer.onExerciseFinished = nil
            guidedTimer.onSequenceFinished = nil
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
        // Exercise structure: the same one-liner as the Up next sheet.
        if ex.kind != nil { return WorkoutPeekSheet.summary(ex) }
        switch ex.sectionType {
        case .strength:
            return "\(ex.sets.count) set\(ex.sets.count == 1 ? "" : "s")"
        case .cardio:
            var s = "\(ex.durationMinutes) min"
            if let i = ex.intensity { s += " · \(i.displayName)" }
            return s
        case .stretching:
            return ex.stretchSummary
        }
    }

    // MARK: - Actions

    /// Called as an exercise's sheet closes after its group's last exercise
    /// was completed. No rest into the next group (moving from one exercise
    /// type to the next has none); if nothing is left, prompt to save and exit.
    private func exerciseCompleted(_ ex: WorkoutSessionExercise) {
        if session.allExercisesComplete {
            restTimer.stop()
            finishPromptPending = true
        }
    }

    private func finish() {
        repo.finishWorkout(session)
        restTimer.stop()
        guidedTimer.stop()
        do {
            try context.save()
        } catch {
            // Not saved: said so by the host, which stays on screen.
            onSaveFailed(error.localizedDescription)
        }
        onFinished()
    }

    // MARK: - Guided cardio / stretch sequence

    /// The guided timer finished an exercise: mark it complete, and if THAT
    /// exercise's sheet is open, move it on to the exercise now being timed.
    /// A sheet the user opened for some other exercise is left alone.
    private func guidedExerciseFinished(_ id: UUID) {
        guard let ex = session.exercises.first(where: { $0.id == id }) else { return }
        if !ex.isFullyCompleted {
            // At the time it actually ended, not when the app caught up.
            repo.markExerciseComplete(ex, in: session, now: guidedTimer.lastExerciseEndedAt ?? .now)
            try? context.save()
        }
        if openExercise?.id == id,
           let nextId = guidedTimer.currentExerciseId, nextId != id,
           let next = session.exercises.first(where: { $0.id == nextId }) {
            openExercise = next
        }
    }

    /// The whole run is done: back to the workout list, and the finish prompt
    /// if nothing is left.
    private func guidedSequenceFinished(_ lastId: UUID) {
        guard session.exercises.contains(where: { $0.id == lastId }) else { return }
        if let open = openExercise, open.id != lastId {
            // The user is working on something else — don't close their sheet.
            return
        }
        // The group is done: no rest into the next group.
        if openExercise != nil {
            if session.allExercisesComplete {
                restTimer.stop()
                finishPromptPending = true   // shown once the sheet is gone
            }
            openExercise = nil
        } else if session.allExercisesComplete {
            restTimer.stop()
            showFinishPrompt = true
        }
    }
}

