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
        for machineId in exercise.machineIds {
            reconcileMachine(machineId)
        }
    }

    /// The machine a routine/session exercise should use: its own choice if
    /// that machine is still one of the exercise's machines, else the primary.
    private func validMachine(_ chosen: UUID?, for exercise: Exercise) -> UUID? {
        let ids = exercise.machineIds
        if let chosen, ids.contains(chosen) { return chosen }
        return exercise.machineId
    }

    private func reconcileRoutineExercises(for exercise: Exercise) {
        let exerciseId = exercise.id
        let descriptor = FetchDescriptor<RoutineExercise>(
            predicate: #Predicate { $0.exerciseId == exerciseId })
        guard let matches = try? context.fetch(descriptor) else { return }
        let routineRepo = RoutineRepository(context)
        // Only the ACTIVE version is ever displayed for "future" use; old
        // versions are frozen bookkeeping for sessions that already
        // snapshotted from them and must not change.
        var stale: [UUID: (routine: Routine, version: RoutineVersion)] = [:]
        for re in matches {
            // Active, live routine first: the comparison loads planned sets, and
            // most matches are old versions that would be skipped anyway.
            guard let version = re.section?.version, version.isActive,
                  let routine = version.routine, routine.deletedAt == nil,
                  stale[version.id] == nil, isStale(re, for: exercise) else { continue }
            stale[version.id] = (routine, version)
        }
        for (routine, version) in stale.values {
            // A version a workout was started from is never changed: the
            // update goes into a new version, like an edit in the routine
            // editor (RoutineRepository.editRoutine).
            let target = routineRepo.isReferencedBySession(version)
                ? routineRepo.makeNewVersion(of: routine, note: "Updated \(exercise.name) from the library")
                : version
            for section in target.sections {
                for re in section.exercises where re.exerciseId == exercise.id {
                    re.displayName = exercise.name
                    re.notes = exercise.notes
                    // A routine doesn't choose a machine: every workout starts
                    // on the exercise's default (first) machine, and the user
                    // switches during the workout if it's taken.
                    re.machineId = exercise.machineId
                    // Rest is the routine's (TypeRests), not the exercise's:
                    // the row keeps whatever it has.
                    routineRepo.setPlannedSets(re, sets: exercise.defaultSets(for: re.machineId),
                                               restBetweenSets: re.restBetweenSets)
                }
            }
        }
    }

    /// Whether a routine exercise differs from its library exercise. Reconcile
    /// runs whenever a routine is shown, so an up-to-date one is left alone
    /// (and never forks a version).
    private func isStale(_ re: RoutineExercise, for exercise: Exercise) -> Bool {
        let target = exercise.defaultSets(for: exercise.machineId)
        let planned = re.plannedSets.sorted { $0.order < $1.order }
        return re.displayName != exercise.name
            || re.notes != exercise.notes
            || re.machineId != exercise.machineId
            || re.setCount != target.count
            || planned.count != target.count
            || zip(planned, target).contains { $0.plannedReps != $1.reps || $0.plannedWeight != $1.weight }
    }

    /// Exercises of workouts not yet locked — the only ones a reconcile may
    /// change — reached through those workouts (a handful) instead of fetching
    /// every exercise ever logged and skipping the locked ones.
    private func unlockedSessionExercises(where match: (WorkoutSessionExercise) -> Bool) -> [WorkoutSessionExercise] {
        let open = (try? context.fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.lockedAt == nil }))) ?? []
        return open.flatMap(\.exercises).filter(match)
    }

    private func reconcileSessionExercises(for exercise: Exercise) {
        let exerciseId: UUID? = exercise.id
        for se in unlockedSessionExercises(where: { $0.exerciseId == exerciseId }) {
            guard let session = se.session, !session.isLocked else { continue }
            se.notes = exercise.notes
            // Once work is logged, the machine it was done on and the shape it
            // was done in (kind, sides, reps) are part of the record: only the
            // sets not yet done are re-planned below.
            let started = se.hasWorkDone
            if !started { se.machineId = validMachine(se.machineId, for: exercise) }
            if exercise.kind != nil && !started { se.snapshotStructure(from: exercise) }
            // Set-based kinds — strength, and cardio Calisthenics — re-plan sets.
            if se.sectionType == .strength || se.kind?.usesSets == true {
                reconcileStrengthSets(se, target: SidePlan.expand(exercise.defaultSets(for: se.machineId),
                                                                  sides: se.sideLabels))
                continue
            }
            // Cardio and stretching: the prescription, until it's done.
            if se.sectionType != .strength, !started {
                se.snapshotGroupFields(from: exercise)
            }
        }
    }

    /// Re-plan the sets not yet done from the catalog's current prescription,
    /// position by position: a completed set stays where it is with its values
    /// (done sets needn't come first — "Mark not done" on Set 1 after Set 2);
    /// every other position takes the prescription for that position. Sets
    /// past the new prescription are dropped unless done. With every done set
    /// first this is the same as re-planning the tail after them.
    ///
    /// Incomplete sets are updated IN PLACE (same ids) rather than deleted and
    /// recreated: the logging sheet keys un-saved edits (e.g. a new weight
    /// typed into the active set) by set id, and recreating the rows orphaned
    /// those edits whenever any other set's change triggered a reconcile.
    private func reconcileStrengthSets(_ se: WorkoutSessionExercise, target: [(reps: Int, weight: Double, side: String)]) {
        let ordered = se.orderedSets
        var kept: [WorkoutSessionSet] = []
        for i in 0..<max(target.count, ordered.count) {
            let existing = i < ordered.count ? ordered[i] : nil
            if let existing, existing.isCompleted {
                existing.index = i
                kept.append(existing)
            } else if i < target.count {
                let set: WorkoutSessionSet
                if let existing {
                    set = existing
                } else {
                    set = WorkoutSessionSet(index: 0, plannedWeight: 0, plannedReps: 0)
                    set.exercise = se
                    context.insert(set)
                }
                set.index = i
                set.plannedWeight = target[i].weight
                set.plannedReps = target[i].reps
                set.side = target[i].side
                kept.append(set)
            } else if let existing {
                context.delete(existing)   // not done, past the new prescription
            }
        }
        // No gaps: a done set after dropped ones moves up.
        for (n, set) in kept.enumerated() { set.index = n }
        se.sets = kept
    }

    // MARK: - Machine

    /// Push a machine's current setting definitions into every not-yet-locked
    /// session exercise that references it. Ad hoc settings added mid-workout
    /// without "also add to machine" (definitionId == nil) are session-local
    /// by design and are never touched here.
    func reconcileMachine(_ machineId: UUID) {
        guard let machine = fetchMachine(machineId), machine.deletedAt == nil else { return }
        let mid: UUID? = machineId
        let activeDefs = machine.activeSettings

        for se in unlockedSessionExercises(where: { $0.machineId == mid }) {
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

    // MARK: - Library membership

    /// Every routine and current workout may only use exercises that are in the
    /// library. Remove any reference to an exercise that is soft-deleted or
    /// missing — left behind by deletes made before the delete cascade existed
    /// (Aug 2026), or brought back by a backup restore. Uses the same cascade as
    /// a delete from the library, so routine versions referenced by history are
    /// forked, not edited. Run at launch and after every import; safe to repeat.
    /// Returns the exercise ids that were pruned.
    @discardableResult
    func pruneExercisesMissingFromLibrary() -> Set<UUID> {
        let liveDescriptor = FetchDescriptor<Exercise>(predicate: #Predicate { $0.deletedAt == nil })
        let live = Set(((try? context.fetch(liveDescriptor)) ?? []).map(\.id))
        var orphanIds = Set<UUID>()

        for re in (try? context.fetch(FetchDescriptor<RoutineExercise>())) ?? [] where !live.contains(re.exerciseId) {
            guard let version = re.section?.version,
                  let routine = version.routine, routine.deletedAt == nil,
                  version.id == routine.activeVersion?.id else { continue }
            orphanIds.insert(re.exerciseId)
        }
        for se in unlockedSessionExercises(where: { _ in true }) {
            guard let id = se.exerciseId, !live.contains(id),
                  let session = se.session, !session.isLocked else { continue }
            orphanIds.insert(id)
        }

        let routineRepo = RoutineRepository(context)
        let workoutRepo = WorkoutRepository(context)
        for id in orphanIds {
            routineRepo.removeExerciseFromAllRoutines(exerciseId: id)
            workoutRepo.removeExerciseFromActiveSessions(exerciseId: id)
        }
        return orphanIds
    }

    // MARK: - Duplicate planned sets

    /// Restores before 2026-10-16 merged a backup's planned sets by id into
    /// routine exercises that already had sets. Saving sets gives the rows new
    /// ids (RoutineRepository.setPlannedSets), so the backup's older rows were
    /// added alongside the current ones and every position held two rows —
    /// 2 sets became 4. Keep one row per position and delete the rest.
    ///
    /// The row kept is the one matching the exercise's summary reps/weight,
    /// which setPlannedSets writes together with the rows; if none or several
    /// match, the lowest id is kept so the result is repeatable. The summary
    /// holds the FIRST set's values, so a later set that differs from the
    /// first cannot be told apart and is kept by id. Run at launch and after
    /// every import; safe to repeat. Returns the number of rows removed.
    @discardableResult
    func removeDuplicatePlannedSets() -> Int {
        var removed = 0
        for re in (try? context.fetch(FetchDescriptor<RoutineExercise>())) ?? [] {
            var extras: [RoutinePlannedSet] = []
            for rows in Dictionary(grouping: re.plannedSets, by: \.order).values where rows.count > 1 {
                let matching = rows.filter { $0.plannedReps == re.plannedReps && $0.plannedWeight == re.plannedWeight }
                let pool = matching.isEmpty ? rows : matching
                guard let keep = pool.min(by: { $0.id.uuidString < $1.id.uuidString }) else { continue }
                extras += rows.filter { $0.id != keep.id }
            }
            guard !extras.isEmpty else { continue }
            // Detach before deleting so nothing reads a deleted row through
            // the relationship before the next save.
            let extraIds = Set(extras.map(\.id))
            re.plannedSets.removeAll { extraIds.contains($0.id) }
            for row in extras { context.delete(row) }
            removed += extras.count
        }
        if removed > 0 {
            Audit.log(context, type: "data.repaired", entity: "RoutinePlannedSet",
                      summary: "Removed \(removed) duplicate planned set(s)")
        }
        return removed
    }

    // MARK: - One-time cleanups at launch

    /// Bump when a new one-time cleanup is added below, so it runs once more.
    static let cleanupVersion = 1
    static let cleanupVersionKey = "com.workouttracker.dataCleanupVersion"

    /// Clean-ups for damage whose cause is fixed — exercises deleted before
    /// the delete cascade existed (Aug 2026), planned sets duplicated by
    /// restores before 2026-10-16. They read most of the store (~165 ms on
    /// 30 workouts), so launch runs them once per cleanupVersion instead of
    /// every time; every import still runs them (ExportImportService.restore).
    /// Returns true if anything changed.
    @discardableResult
    func runOneTimeCleanupsIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.integer(forKey: Self.cleanupVersionKey) < Self.cleanupVersion else { return false }
        let pruned = !pruneExercisesMissingFromLibrary().isEmpty
        let deduped = removeDuplicatePlannedSets() > 0
        defaults.set(Self.cleanupVersion, forKey: Self.cleanupVersionKey)
        return pruned || deduped
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
