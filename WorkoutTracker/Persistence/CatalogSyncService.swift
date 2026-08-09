//
//  CatalogSyncService.swift
//  WorkoutTracker
//
//  The Exercise/Machine catalog (Settings) is the single source of truth for
//  "exercise settings" — sets, reps, weight, rest, notes, photo, rounds, hold
//  time, duration/intensity, and machine settings — for anything not yet
//  completed. This service pushes a catalog change down into every routine
//  and in-progress session that references it, and is also safe to call
//  defensively whenever a routine/session is displayed, so nothing can drift.
//
//  What it deliberately never touches: a LOCKED session (session.isLocked —
//  set the moment a workout is finished, regardless of completed/partial/
//  abandoned). History is frozen; only WorkoutCorrectionEvent may touch it,
//  and only for actuals (see CorrectionService).
//

import Foundation
import SwiftData

@MainActor
struct CatalogSyncService {
    let context: ModelContext

    init(_ context: ModelContext) { self.context = context }

    // MARK: - Exercise

    /// Push the current `Exercise` catalog values into every routine's active
    /// version and every not-yet-locked session that reference it (plus its
    /// linked machine, if any). No-op if the exercise is missing/soft-deleted.
    func reconcileExercise(_ exerciseId: UUID) {
        guard let exercise = fetchExercise(exerciseId), exercise.deletedAt == nil else { return }
        reconcileRoutineExercises(for: exercise)
        reconcileSessionExercises(for: exercise)
        if let machineId = exercise.machineId {
            reconcileMachine(machineId)
        }
    }

    private func reconcileRoutineExercises(for exercise: Exercise) {
        let exerciseId = exercise.id
        let descriptor = FetchDescriptor<RoutineExercise>(
            predicate: #Predicate { $0.exerciseId == exerciseId })
        guard let matches = try? context.fetch(descriptor) else { return }
        let routineRepo = RoutineRepository(context)
        for re in matches {
            // Only the ACTIVE version is ever displayed for "future" use; old
            // versions are frozen bookkeeping for sessions that already
            // snapshotted from them and must not change.
            guard let version = re.section?.version, version.isActive,
                  let routine = version.routine, routine.deletedAt == nil else { continue }
            re.displayName = exercise.name
            re.notes = exercise.notes
            routineRepo.setPlannedSets(re, sets: exercise.effectiveDefaultSets, restBetweenSets: exercise.defaultRest)
        }
    }

    private func reconcileSessionExercises(for exercise: Exercise) {
        let exerciseId: UUID? = exercise.id
        let descriptor = FetchDescriptor<WorkoutSessionExercise>(
            predicate: #Predicate { $0.exerciseId == exerciseId })
        guard let matches = try? context.fetch(descriptor) else { return }
        for se in matches {
            guard let session = se.session, !session.isLocked else { continue }
            se.notes = exercise.notes
            se.plannedRestBetweenSets = exercise.defaultRest
            switch se.sectionType {
            case .strength:
                reconcileStrengthSets(se, target: exercise.effectiveDefaultSets)
            case .cardio:
                guard se.markedCompleteAt == nil else { continue }
                se.durationMinutes = exercise.durationMinutes
                se.intensity = exercise.intensity
            case .stretching:
                guard se.markedCompleteAt == nil else { continue }
                se.holdSeconds = exercise.holdSeconds
                se.sides = exercise.sides
                se.rounds = exercise.rounds
            }
        }
    }

    /// Freeze the already-completed prefix of sets; replace the incomplete
    /// tail with the catalog's current prescription starting at that point.
    /// If the catalog now prescribes fewer sets than are already completed,
    /// the incomplete tail becomes empty — the exercise reads as fully done.
    private func reconcileStrengthSets(_ se: WorkoutSessionExercise, target: [(reps: Int, weight: Double)]) {
        let completed = se.orderedSets.filter(\.isCompleted)
        let incomplete = se.orderedSets.filter { !$0.isCompleted }
        for set in incomplete { context.delete(set) }
        se.sets = completed

        let completedCount = completed.count
        let remaining = target.count > completedCount ? Array(target[completedCount...]) : []
        for (offset, planned) in remaining.enumerated() {
            let set = WorkoutSessionSet(index: completedCount + offset,
                                        plannedWeight: planned.weight,
                                        plannedReps: planned.reps)
            set.exercise = se
            se.sets.append(set)
            context.insert(set)
        }
    }

    // MARK: - Machine

    /// Push a machine's current setting definitions into every not-yet-locked
    /// session exercise that references it. Ad hoc settings added mid-workout
    /// without "also add to machine" (definitionId == nil) are session-local
    /// by design and are never touched here.
    func reconcileMachine(_ machineId: UUID) {
        guard let machine = fetchMachine(machineId), machine.deletedAt == nil else { return }
        let mid: UUID? = machineId
        let descriptor = FetchDescriptor<WorkoutSessionExercise>(
            predicate: #Predicate { $0.machineId == mid })
        guard let matches = try? context.fetch(descriptor) else { return }
        let activeDefs = machine.activeSettings

        for se in matches {
            guard let session = se.session, !session.isLocked else { continue }

            var byDefinition: [UUID: SessionMachineSetting] = [:]
            var adHoc: [SessionMachineSetting] = []
            for s in se.machineSettings {
                if let defId = s.definitionId { byDefinition[defId] = s } else { adHoc.append(s) }
            }

            var rebuilt: [SessionMachineSetting] = []
            for def in activeDefs {
                if let existing = byDefinition.removeValue(forKey: def.id) {
                    existing.label = def.label
                    existing.order = def.order
                    existing.numericValue = def.numericValue
                    existing.otherText = def.otherText
                    rebuilt.append(existing)
                } else {
                    let snap = SessionMachineSetting(definitionId: def.id, label: def.label, order: def.order,
                                                     numericValue: def.numericValue, otherText: def.otherText)
                    snap.exercise = se
                    context.insert(snap)
                    rebuilt.append(snap)
                }
            }
            // Anything left references a definition removed from the machine
            // in Settings.
            for stale in byDefinition.values { context.delete(stale) }
            se.machineSettings = rebuilt + adHoc
        }
    }

    // MARK: - Convenience: reconcile everything currently displayed

    /// Defensive check for view `.onAppear` — reconciles every exercise in a
    /// routine's active version.
    func reconcileRoutine(_ routine: Routine) {
        guard let version = routine.activeVersion else { return }
        var seen = Set<UUID>()
        for section in version.orderedSections {
            for ex in section.orderedExercises where seen.insert(ex.exerciseId).inserted {
                reconcileExercise(ex.exerciseId)
            }
        }
    }

    /// Defensive check for view `.onAppear` — reconciles every exercise in a
    /// not-yet-locked session. No-op for locked (finished) sessions.
    func reconcileSession(_ session: WorkoutSession) {
        guard !session.isLocked else { return }
        var seen = Set<UUID>()
        for ex in session.exercises {
            guard let exId = ex.exerciseId, seen.insert(exId).inserted else { continue }
            reconcileExercise(exId)
        }
    }

    // MARK: - Fetch helpers

    private func fetchExercise(_ id: UUID) -> Exercise? {
        let d = FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(d).first
    }

    private func fetchMachine(_ id: UUID) -> Machine? {
        let d = FetchDescriptor<Machine>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(d).first
    }
}
