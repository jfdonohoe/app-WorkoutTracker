//
//  WorkoutRepository.swift
//  WorkoutTracker
//
//  All workout-session writes go through here. This is where the immutability
//  contract is enforced.
//
//  Snapshot-on-start (principles #1, #2): startWorkout copies every planned
//  value AND the current machine settings into the session's own child records.
//  The session never reads live routine data afterward.
//
//  Corrections (principle #5): edits to a LOCKED (recorded) session are refused
//  for direct mutation; callers must use CorrectionService (correct /
//  correctActualWeight / correctActualReps), which appends an event and never
//  overwrites the original snapshot.
//

import Foundation
import SwiftData

@MainActor
struct WorkoutRepository {
    let context: ModelContext

    init(_ context: ModelContext) { self.context = context }

    // MARK: - Start

    /// Create a started WorkoutSession by snapshotting the routine's active
    /// version. Called the instant the user taps Start (a real session exists
    /// immediately, principle: "Start creates a WorkoutSession").
    @discardableResult
    func startWorkout(from routine: Routine,
                      scheduledDate: Date? = nil,
                      now: Date = .now) -> WorkoutSession {
        let version = routine.activeVersion
        // Sessions inherit demo/user lineage from the version so demo cleanup
        // can remove QA sessions later.
        let source = version?.source ?? routine.source

        let session = WorkoutSession(routineId: routine.id,
                                     routineVersionId: version?.id,
                                     routineName: routine.name,
                                     status: .started,
                                     source: source,
                                     scheduledDate: scheduledDate,
                                     startedAt: now,
                                     createdAt: now)
        context.insert(session)

        if let version {
            // Seed the session's rests (per exercise type) from the routine.
            session.rests = version.rests

            // Each routine section becomes its own group instance, so a routine
            // with two strength sections keeps two strength groups in the workout.
            var orderCounter = 0
            var groupCounters: [SectionType: Int] = [:]
            for section in version.orderedSections {
                let groupIndex = groupCounters[section.type, default: 0]
                groupCounters[section.type] = groupIndex + 1
                for re in section.orderedExercises {
                    let se = snapshotExercise(re, sectionType: section.type, order: orderCounter, groupIndex: groupIndex)
                    se.session = session
                    session.exercises.append(se)
                    orderCounter += 1
                }
            }
        }

        Audit.log(context, type: "session.started", entity: "WorkoutSession",
                  entityId: session.id,
                  summary: "Started \(routine.name) (v\(version?.versionNumber ?? 0))",
                  source: source)
        return session
    }

    /// Snapshot a single routine exercise into a session exercise, including a
    /// frozen copy of its machine's current settings.
    private func snapshotExercise(_ re: RoutineExercise,
                                  sectionType: SectionType,
                                  order: Int,
                                  groupIndex: Int = 0) -> WorkoutSessionExercise {
        // RoutineExercise is kept as a reconciled mirror of the catalog Exercise
        // (CatalogSyncService) — read the live definition directly here too, as
        // defense-in-depth in case reconciliation hasn't run since the last edit.
        let def = fetchExercise(re.exerciseId)
        // A workout starts on the exercise's default (first) machine; the
        // user switches during the workout if it's taken.
        let machineId = def?.machineId ?? re.machineId

        let se = WorkoutSessionExercise(sourceRoutineExerciseId: re.id,
                                        exerciseId: re.exerciseId,
                                        machineId: machineId,
                                        name: def?.name ?? re.displayName,
                                        sectionType: sectionType,
                                        order: order,
                                        plannedRestBetweenSets: re.restBetweenSets,
                                        notes: def?.notes ?? re.notes)
        se.groupIndex = groupIndex
        context.insert(se)

        // Snapshot the group-specific prescription from the exercise definition
        // (cardio: duration/intensity; stretching: hold/sides/rounds).
        if let def {
            se.snapshotGroupFields(from: def)
            se.snapshotStructure(from: def)
        }

        // Snapshot planned sets — from the catalog definition (for that
        // machine) when available, else the routine's own mirror.
        let plannedSets: [(reps: Int, weight: Double)]
        let fromDefinition = def?.defaultSets(for: machineId) ?? []
        if !fromDefinition.isEmpty {
            plannedSets = fromDefinition
        } else {
            plannedSets = re.effectivePlannedSets
        }
        // A per-side exercise gets a set for each side, cycling within a set.
        for (i, planned) in SidePlan.expand(plannedSets, sides: se.sideLabels).enumerated() {
            let set = WorkoutSessionSet(index: i,
                                        plannedWeight: planned.weight,
                                        plannedReps: planned.reps)
            set.side = planned.side
            set.exercise = se
            se.sets.append(set)
            context.insert(set)
        }

        snapshotMachineSettings(of: machineId, into: se)
        return se
    }

    /// Snapshot a machine's current settings into a workout exercise (shared
    /// on the machine, frozen here).
    private func snapshotMachineSettings(of machineId: UUID?, into se: WorkoutSessionExercise) {
        guard let machineId, let machine = fetchMachine(machineId) else { return }
        for def in machine.activeSettings {
            let snap = SessionMachineSetting(definitionId: def.id, label: def.label, order: def.order,
                                             numericValue: def.numericValue, otherText: def.otherText)
            snap.exercise = se
            se.machineSettings.append(snap)
            context.insert(snap)
        }
    }

    func fetchMachine(_ id: UUID) -> Machine? {
        let d = FetchDescriptor<Machine>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(d).first
    }

    func fetchExercise(_ id: UUID) -> Exercise? {
        let d = FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(d).first
    }

    // MARK: - Exercise start/end timecodes (for the summary)

    /// Record when the user first opened this exercise (idempotent — only sets
    /// it once). Called when the logging sheet appears.
    func recordExerciseStarted(_ exercise: WorkoutSessionExercise, in session: WorkoutSession, now: Date = .now) {
        guard !session.isLocked, exercise.startedAt == nil else { return }
        exercise.startedAt = now
    }

    /// Stamp `endedAt` the moment an exercise becomes fully completed, and
    /// clear it if a completion is undone.
    private func syncExerciseEndTimecode(_ exercise: WorkoutSessionExercise, now: Date) {
        if exercise.isFullyCompleted {
            if exercise.endedAt == nil { exercise.endedAt = now }
        } else {
            exercise.endedAt = nil
        }
    }

    // MARK: - Non-set completion (cardio / stretching)

    /// Mark a cardio/stretching exercise complete (it has no sets to tick off).
    func markExerciseComplete(_ exercise: WorkoutSessionExercise, in session: WorkoutSession, now: Date = .now) {
        guard !session.isLocked else { return }
        exercise.markedCompleteAt = now
        session.updatedAt = now
        syncExerciseEndTimecode(exercise, now: now)
        recomputeStatus(session)
    }

    func unmarkExerciseComplete(_ exercise: WorkoutSessionExercise, in session: WorkoutSession) {
        guard !session.isLocked else { return }
        exercise.markedCompleteAt = nil
        session.updatedAt = .now
        syncExerciseEndTimecode(exercise, now: .now)
        recomputeStatus(session)
    }

    // MARK: - Set completion (active session only)

    /// Mark a set complete with actuals, then recompute session status.
    /// Refuses to mutate a locked session (recorded history is immutable).
    func completeSet(_ set: WorkoutSessionSet,
                     in session: WorkoutSession,
                     actualWeight: Double?,
                     actualReps: Int?,
                     effort: PerceivedEffort? = nil,
                     note: String? = nil,
                     now: Date = .now) {
        guard !session.isLocked else {
            assertionFailure("Refusing to edit a locked session directly; use CorrectionService.")
            return
        }
        set.actualWeight = actualWeight ?? set.actualWeight ?? set.plannedWeight
        set.actualReps = actualReps ?? set.actualReps ?? set.plannedReps
        if let effort { set.perceivedEffort = effort }
        if let note { set.note = note }
        set.isCompleted = true
        set.completedAt = now
        session.updatedAt = now
        if let exercise = set.exercise { syncExerciseEndTimecode(exercise, now: now) }
        recomputeStatus(session)
    }

    func uncompleteSet(_ set: WorkoutSessionSet, in session: WorkoutSession) {
        guard !session.isLocked else { return }
        set.isCompleted = false
        set.completedAt = nil
        session.updatedAt = .now
        if let exercise = set.exercise { syncExerciseEndTimecode(exercise, now: .now) }
        recomputeStatus(session)
    }

    /// Edit a single actual value on an in-progress session (one value at a
    /// time; only the changed value updates).
    func editActual(_ set: WorkoutSessionSet,
                    in session: WorkoutSession,
                    weight: Double? = nil,
                    reps: Int? = nil) {
        guard !session.isLocked else {
            assertionFailure("Locked session — use CorrectionService.")
            return
        }
        if let weight { set.actualWeight = weight }
        if let reps { set.actualReps = reps }
        session.updatedAt = .now
    }

    // MARK: - Status

    /// Recompute status. Counts "units": each strength set, plus each cardio /
    /// stretching exercise (which has no sets) as a single mark-complete unit.
    func recomputeStatus(_ session: WorkoutSession) {
        guard !session.isLocked else { return }
        var total = 0, done = 0
        for ex in session.exercises {
            if ex.hasSets {
                total += ex.sets.count
                done += ex.sets.filter(\.isCompleted).count
            } else {
                total += 1
                if ex.markedCompleteAt != nil { done += 1 }
            }
        }
        if total > 0 && done == total {
            session.status = .completed
        } else if done > 0 || session.hasAnythingDone {
            // hasAnythingDone also counts a logged distance on an exercise not
            // yet marked complete, so finishing it locks history as partial.
            session.status = .partial
        } else {
            // Started but nothing completed yet — stays started until finished.
            session.status = .started
        }
    }

    /// Finish the workout: assign a terminal status and LOCK it as history.
    /// completed / partial become immutable history. A workout with nothing
    /// done is not history at all: it is discarded — hidden at once
    /// (deletedAt, so the screen still showing it can finish tearing down) and
    /// removed for good by purgeDiscardedWorkouts at the next launch.
    func finishWorkout(_ session: WorkoutSession, now: Date = .now) {
        recomputeStatus(session)
        if !session.hasAnythingDone {
            session.status = .abandoned
            session.endedAt = now
            session.completedAt = now
            session.deletedAt = now
            session.updatedAt = now
            lock(session, now: now)
            Audit.log(context, type: "session.discarded", entity: "WorkoutSession",
                      entityId: session.id,
                      summary: "Discarded \(session.routineName): nothing was done",
                      source: session.source)
            return
        }
        session.endedAt = now      // end timecode
        session.completedAt = now
        session.updatedAt = now
        lock(session, now: now)
        Audit.log(context, type: "session.finished", entity: "WorkoutSession",
                  entityId: session.id,
                  summary: "Finished \(session.routineName) as \(session.status.displayName)",
                  source: session.source)
    }

    /// Permanently remove abandoned workouts: ones with nothing done that were
    /// discarded (finishWorkout hides them at once), or left unfinished on an
    /// earlier day — e.g. stopped from the Calendar, or a past-day workout
    /// started and never logged. Anything with a set done or an exercise
    /// marked complete is never touched. Today's are kept until tomorrow: a
    /// discarded workout still on record for today is what stops Today from
    /// auto-starting the same scheduled routine again
    /// (TodayWorkoutView.routineToAutoStart). Run at every launch and after
    /// every import. Returns the number removed.
    @discardableResult
    func purgeDiscardedWorkouts(now: Date = .now) -> Int {
        let startOfToday = Calendar.current.startOfDay(for: now)
        let abandoned = SessionStatus.abandoned.rawValue
        // Cheap tests first (in the store, then dates); only the few left get
        // `hasAnythingDone`, which loads their exercises and sets — so a
        // launch doesn't load all of history.
        let candidates = (try? context.fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.completedAt == nil || $0.statusRaw == abandoned }))) ?? []
        let found = candidates.filter { s in
            (s.startedAt ?? s.createdAt) < startOfToday && !s.hasAnythingDone
        }
        for s in found { context.delete(s) }   // cascades to its exercises, sets and corrections
        if !found.isEmpty {
            Audit.log(context, type: "data.repaired", entity: "WorkoutSession",
                      summary: "Removed \(found.count) abandoned workout(s)")
        }
        return found.count
    }

    /// Change a workout's rest from the workout screen. Rest is set per
    /// routine, so the change also updates the routine for every future
    /// workout. The routine's current plan is edited through editRoutine: if
    /// workouts were already done with it, a new version is made so their
    /// record keeps the rest they were done with. Nil leaves a value as is.
    func setRest(_ session: WorkoutSession, betweenSets: Int? = nil, betweenExercises: Int? = nil) {
        var rests = session.rests
        if let betweenSets { rests.strengthSets = betweenSets }
        if let betweenExercises { rests.strengthExercises = betweenExercises }
        setRests(session, rests)
    }

    /// Change the workout's rests; the routine gets them too, for future
    /// workouts (a new version only if something differs).
    func setRests(_ session: WorkoutSession, _ rests: TypeRests) {
        guard !session.isLocked else { return }
        session.rests = rests
        session.updatedAt = .now
        guard let rid = session.routineId,
              let routine = try? context.fetch(FetchDescriptor<Routine>(predicate: #Predicate { $0.id == rid })).first,
              routine.deletedAt == nil, let current = routine.activeVersion,
              current.rests != rests else { return }
        RoutineRepository(context).editRoutine(routine, note: "Rest changed during a workout") { version in
            version.rests = rests
        }
    }

    /// Soft-delete a workout from history (used by the calendar). We keep the
    /// record (deletedAt) rather than destroying it, consistent with the app's
    /// data-safety posture; queries hide deletedAt sessions.
    func softDeleteSession(_ session: WorkoutSession, now: Date = .now) {
        session.deletedAt = now
        session.updatedAt = now
        Audit.log(context, type: "session.softDeleted", entity: "WorkoutSession",
                  entityId: session.id,
                  summary: "Deleted workout \(session.routineName)",
                  source: session.source)
    }

    /// Lock a session as recorded history.
    func lock(_ session: WorkoutSession, now: Date = .now) {
        guard session.lockedAt == nil else { return }
        session.lockedAt = now
        // Keep a unit already recorded (Data Safety's finish re-locks).
        if session.distanceUnitRaw.isEmpty { session.distanceUnitRaw = DistanceUnit.current.rawValue }
    }

    /// Give workouts locked before the distance unit was recorded the unit
    /// they are shown in now, so a later Settings change can't relabel them.
    /// It only records what is already displayed. Run at launch; returns how many.
    @discardableResult
    func freezeDistanceUnits() -> Int {
        let open = (try? context.fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.lockedAt != nil && $0.distanceUnitRaw == "" }))) ?? []
        for s in open { s.distanceUnitRaw = DistanceUnit.current.rawValue }
        return open.count
    }

    /// Reopen an unfinished workout that was marked abandoned while still open
    /// (Data Safety's Resume). A LOCKED workout is never reopened: it keeps
    /// the values it had when it was locked, forever.
    func reopen(_ session: WorkoutSession, now: Date = .now) {
        guard !session.isLocked else { return }
        session.completedAt = nil
        session.endedAt = nil
        session.updatedAt = now
        recomputeStatus(session)
    }

    // MARK: - During-workout structural edits

    /// Add a library exercise to the active session mid-workout, snapshotting its
    /// group-specific prescription (strength sets / cardio duration+intensity /
    /// stretching hold+sides+rounds) and any machine settings. Works for every
    /// exercise type, so cardio and stretching exercises are added correctly
    /// (no spurious sets).
    @discardableResult
    func addUnplannedExercise(to session: WorkoutSession, from exercise: Exercise,
                              groupIndex: Int = 0) -> WorkoutSessionExercise? {
        guard !session.isLocked else { assertionFailure("Locked session."); return nil }
        let group = exercise.defaultSectionType
        let order = (session.exercises.map(\.order).max() ?? -1) + 1
        let se = WorkoutSessionExercise(exerciseId: exercise.id,
                                        machineId: exercise.machineId,
                                        name: exercise.name,
                                        sectionType: group,
                                        order: order,
                                        plannedRestBetweenSets: session.restBetweenSets,
                                        notes: exercise.notes,
                                        isAddedDuringWorkout: true)
        se.groupIndex = groupIndex
        se.session = session
        session.exercises.append(se)
        context.insert(se)
        se.snapshotStructure(from: exercise)

        // Set-based kinds (strength, and cardio Calisthenics) get sets, one
        // per side for a per-side exercise.
        if group == .strength || exercise.kind?.usesSets == true {
            let planned = exercise.effectiveDefaultSets.isEmpty
                ? [(reps: 10, weight: 0.0)] : exercise.effectiveDefaultSets
            for (i, p) in SidePlan.expand(planned, sides: se.sideLabels).enumerated() {
                let set = WorkoutSessionSet(index: i, plannedWeight: p.weight, plannedReps: p.reps)
                set.side = p.side
                set.exercise = se
                se.sets.append(set)
                context.insert(set)
            }
        }
        se.snapshotGroupFields(from: exercise)
        snapshotMachineSettings(of: exercise.machineId, into: se)
        session.updatedAt = .now
        return se
    }

    /// Edit a strength exercise's planned sets on an active session (mirrors the
    /// routine editor's set builder). Existing sets are updated in place by index
    /// so completion/actuals are preserved where they still apply; extra sets are
    /// added or trimmed to match the new plan.
    func setSessionPlannedSets(_ exercise: WorkoutSessionExercise,
                               sets: [(reps: Int, weight: Double)],
                               restBetweenSets: Int? = nil,
                               in session: WorkoutSession) {
        guard !session.isLocked else { return }
        let plan = sets.isEmpty ? [(reps: 10, weight: 0.0)] : sets
        let ordered = exercise.orderedSets
        for (i, p) in plan.enumerated() {
            if i < ordered.count {
                ordered[i].plannedReps = p.reps
                ordered[i].plannedWeight = p.weight
            } else {
                let set = WorkoutSessionSet(index: i, plannedWeight: p.weight, plannedReps: p.reps)
                set.exercise = exercise
                exercise.sets.append(set)
                context.insert(set)
            }
        }
        if plan.count < ordered.count {
            for set in ordered[plan.count...] { context.delete(set) }
        }
        if let restBetweenSets { exercise.plannedRestBetweenSets = restBetweenSets }
        session.updatedAt = .now
        recomputeStatus(session)
    }

    /// Reorder exercises in the active session.
    func reorder(_ session: WorkoutSession, orderedIds: [UUID]) {
        guard !session.isLocked else { return }
        for (idx, id) in orderedIds.enumerated() {
            if let se = session.exercises.first(where: { $0.id == id }) {
                se.order = idx
            }
        }
        session.updatedAt = .now
    }

    // MARK: - Machine settings during a workout

    /// Switch an in-progress exercise to another of its machines, for THIS
    /// workout only (the routine keeps its own choice). Completed sets are
    /// kept; the remaining sets are re-planned from that machine's defaults and
    /// the machine settings are replaced with the new machine's.
    func switchMachine(_ exercise: WorkoutSessionExercise, to machineId: UUID, in session: WorkoutSession) {
        guard !session.isLocked, exercise.machineId != machineId,
              let machine = fetchMachine(machineId), machine.deletedAt == nil else { return }
        exercise.machineId = machineId
        let sync = CatalogSyncService(context)
        if let exerciseId = exercise.exerciseId {
            sync.reconcileExercise(exerciseId)   // re-plans sets + settings for the new machine
        } else {
            sync.reconcileMachine(machineId)
        }
        session.updatedAt = .now
    }

    /// Update a snapshot machine setting for THIS workout only.
    func updateSessionSetting(_ setting: SessionMachineSetting,
                              numericValue: Int?,
                              otherText: String?) {
        guard setting.exercise?.session?.isLocked != true else { return }
        setting.numericValue = numericValue
        setting.otherText = otherText
    }

    /// Rename a machine setting. Like editing its value, a rename applies to the
    /// shared definition when there is one, so the label matches everywhere the
    /// machine is used; `reconcileMachine` pushes it into every other
    /// not-yet-locked session. Locked history keeps the label it was recorded
    /// under, because those snapshots are never revisited.
    func renameSetting(_ setting: SessionMachineSetting,
                       to newLabel: String,
                       in exercise: WorkoutSessionExercise) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, exercise.session?.isLocked != true else { return }
        setting.label = trimmed
        if let defId = setting.definitionId {
            let d = FetchDescriptor<MachineSettingDefinition>(predicate: #Predicate { $0.id == defId })
            if let def = try? context.fetch(d).first {
                def.label = trimmed
                def.updatedAt = .now
            }
            if let machineId = exercise.machineId {
                CatalogSyncService(context).reconcileMachine(machineId)
            }
        }
    }

    /// Save a changed machine setting as the machine's FUTURE default (shared).
    /// This mutates the live Machine's setting value; it does NOT alter any past
    /// session snapshots.
    func saveSettingAsFutureDefault(definitionId: UUID, numericValue: Int?, otherText: String?) {
        let d = FetchDescriptor<MachineSettingDefinition>(predicate: #Predicate { $0.id == definitionId })
        if let def = try? context.fetch(d).first {
            def.numericValue = numericValue
            def.otherText = otherText
            def.updatedAt = .now
        }
    }

    /// Delete a machine setting. If it's linked to a shared machine definition,
    /// soft-delete the definition (settings are shared everywhere, same as
    /// editing one — see `apply` in SessionExerciseSheet) and reconcile every
    /// other in-progress session on the same machine, which also removes this
    /// snapshot. Ad hoc settings (added mid-workout without "also add to
    /// machine") have no shared definition and are simply removed here.
    func deleteSetting(_ setting: SessionMachineSetting, from exercise: WorkoutSessionExercise) {
        guard exercise.session?.isLocked != true else { return }
        if let defId = setting.definitionId,
           let def = try? context.fetch(
             FetchDescriptor<MachineSettingDefinition>(predicate: #Predicate { $0.id == defId })
           ).first {
            def.deletedAt = .now
            def.updatedAt = .now
            if let machineId = exercise.machineId {
                CatalogSyncService(context).reconcileMachine(machineId)
            }
        } else {
            context.delete(setting)
        }
    }

    // MARK: - Catalog exercise deletion cascade

    /// Remove every session exercise referencing `exerciseId` from every
    /// not-yet-locked ("current") workout session. Locked (finished) history is
    /// never touched, and neither is an exercise with work logged on it (a
    /// done set, marked complete, a distance): that work is kept. Called when
    /// an exercise is deleted from the library.
    func removeExerciseFromActiveSessions(exerciseId: UUID) {
        let eid: UUID? = exerciseId
        let descriptor = FetchDescriptor<WorkoutSessionExercise>(predicate: #Predicate { $0.exerciseId == eid })
        guard let matches = try? context.fetch(descriptor) else { return }
        var touchedIds = Set<UUID>()
        var sessions: [WorkoutSession] = []
        for se in matches {
            guard let session = se.session, !session.isLocked, !se.hasWorkDone else { continue }
            if touchedIds.insert(session.id).inserted { sessions.append(session) }
            // Detach before deleting: recomputeStatus below walks session.exercises.
            session.exercises.removeAll { $0.id == se.id }
            context.delete(se)
        }
        for session in sessions {
            session.updatedAt = .now
            recomputeStatus(session)
        }
    }

    /// Add a brand-new machine setting that wasn't originally defined, applied to
    /// the current session exercise (snapshot). Optionally also add to machine —
    /// in that case, reconciling pulls the new definition into THIS exercise
    /// (and every other in-progress session on the same machine) rather than
    /// inserting a second, separately-tracked copy for this exercise.
    /// Nil for a locked workout, which holds its values forever.
    @discardableResult
    func addSessionSetting(to exercise: WorkoutSessionExercise,
                           label: String,
                           numericValue: Int?,
                           otherText: String?,
                           alsoAddToMachine: Bool) -> SessionMachineSetting? {
        guard exercise.session?.isLocked != true else { return nil }
        let order = (exercise.machineSettings.map(\.order).max() ?? -1) + 1
        if alsoAddToMachine, let machineId = exercise.machineId, let machine = fetchMachine(machineId),
           machine.activeSettings.count < Machine.maxSettings {
            let def = MachineSettingDefinition(label: label, order: order,
                                               numericValue: numericValue, otherText: otherText,
                                               source: machine.source)
            def.machine = machine
            machine.settingDefinitions.append(def)
            context.insert(def)
            CatalogSyncService(context).reconcileMachine(machineId)
            if let snap = exercise.machineSettings.first(where: { $0.definitionId == def.id }) {
                return snap
            }
        }
        let snap = SessionMachineSetting(definitionId: nil, label: label, order: order,
                                         numericValue: numericValue, otherText: otherText)
        snap.exercise = exercise
        exercise.machineSettings.append(snap)
        context.insert(snap)
        return snap
    }
}
