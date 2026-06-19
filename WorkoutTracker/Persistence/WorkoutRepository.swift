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
//  for direct mutation; callers must use applyCorrection, which appends an event
//  and never overwrites the original snapshot.
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
            // Seed the session-level cooldown defaults from the routine.
            session.restBetweenExercises = version.defaultRestBetweenExercises
            session.restBetweenSets = version.defaultRestBetweenSets

            var orderCounter = 0
            for section in version.orderedSections {
                for re in section.orderedExercises {
                    let se = snapshotExercise(re, sectionType: section.type, order: orderCounter)
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
                                  order: Int) -> WorkoutSessionExercise {
        let se = WorkoutSessionExercise(sourceRoutineExerciseId: re.id,
                                        exerciseId: re.exerciseId,
                                        machineId: re.machineId,
                                        name: re.displayName,
                                        sectionType: sectionType,
                                        order: order,
                                        plannedRestBetweenSets: re.restBetweenSets,
                                        notes: re.notes)
        context.insert(se)

        // Snapshot planned sets — per-set values when defined, else synthesized.
        for (i, planned) in re.effectivePlannedSets.enumerated() {
            let set = WorkoutSessionSet(index: i,
                                        plannedWeight: planned.weight,
                                        plannedReps: planned.reps)
            set.exercise = se
            se.sets.append(set)
            context.insert(set)
        }

        // Snapshot machine settings (shared on the machine, frozen here).
        if let machineId = re.machineId, let machine = fetchMachine(machineId) {
            for def in machine.activeSettings {
                let snap = SessionMachineSetting(definitionId: def.id,
                                                 label: def.label,
                                                 order: def.order,
                                                 numericValue: def.numericValue,
                                                 otherText: def.otherText)
                snap.exercise = se
                se.machineSettings.append(snap)
                context.insert(snap)
            }
        }
        return se
    }

    func fetchMachine(_ id: UUID) -> Machine? {
        let d = FetchDescriptor<Machine>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(d).first
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
            assertionFailure("Refusing to edit a locked session directly; use applyCorrection.")
            return
        }
        set.actualWeight = actualWeight ?? set.actualWeight ?? set.plannedWeight
        set.actualReps = actualReps ?? set.actualReps ?? set.plannedReps
        if let effort { set.perceivedEffort = effort }
        if let note { set.note = note }
        set.isCompleted = true
        set.completedAt = now
        session.updatedAt = now
        recomputeStatus(session)
    }

    func uncompleteSet(_ set: WorkoutSessionSet, in session: WorkoutSession) {
        guard !session.isLocked else { return }
        set.isCompleted = false
        set.completedAt = nil
        session.updatedAt = .now
        recomputeStatus(session)
    }

    /// Edit a single actual value on an in-progress session (one value at a
    /// time; only the changed value updates).
    func editActual(_ set: WorkoutSessionSet,
                    in session: WorkoutSession,
                    weight: Double? = nil,
                    reps: Int? = nil) {
        guard !session.isLocked else {
            assertionFailure("Locked session — use applyCorrection.")
            return
        }
        if let weight { set.actualWeight = weight }
        if let reps { set.actualReps = reps }
        session.updatedAt = .now
    }

    // MARK: - Status

    /// Recompute status from the set/exercise completion rules.
    func recomputeStatus(_ session: WorkoutSession) {
        guard !session.isLocked else { return }
        let allSets = session.exercises.flatMap(\.sets)
        let total = allSets.count
        let done = allSets.filter(\.isCompleted).count

        if total > 0 && done == total {
            session.status = .completed
        } else if done > 0 {
            session.status = .partial
        } else {
            // Started but nothing completed yet — stays started until finished.
            session.status = .started
        }
    }

    /// Finish the workout: assign a terminal status and LOCK it as history.
    /// completed / partial / abandoned all become immutable.
    func finishWorkout(_ session: WorkoutSession, now: Date = .now) {
        recomputeStatus(session)
        let anyDone = session.exercises.flatMap(\.sets).contains(where: \.isCompleted)
        if !anyDone {
            session.status = .abandoned
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
    }

    /// Reopen a finished-but-incomplete (partial/abandoned) workout so the user
    /// can return to it. Clears the lock + end timecodes and recomputes status.
    func reopen(_ session: WorkoutSession, now: Date = .now) {
        session.lockedAt = nil
        session.completedAt = nil
        session.endedAt = nil
        session.updatedAt = now
        recomputeStatus(session)
    }

    // MARK: - During-workout structural edits

    /// Add an unplanned exercise to the active session (does not touch routine).
    /// Accepts per-set planned values built with the set-by-set editor.
    @discardableResult
    func addUnplannedExercise(to session: WorkoutSession,
                              name: String,
                              sets: [(reps: Int, weight: Double)],
                              rest: Int = 90,
                              machineId: UUID? = nil) -> WorkoutSessionExercise {
        guard !session.isLocked else {
            assertionFailure("Locked session.")
            return WorkoutSessionExercise(name: name, sectionType: .strength, order: 0, plannedRestBetweenSets: rest)
        }
        let order = (session.exercises.map(\.order).max() ?? -1) + 1
        let se = WorkoutSessionExercise(exerciseId: nil,
                                        machineId: machineId,
                                        name: name,
                                        sectionType: .strength,
                                        order: order,
                                        plannedRestBetweenSets: rest,
                                        isAddedDuringWorkout: true)
        se.session = session
        session.exercises.append(se)
        context.insert(se)
        let planned = sets.isEmpty ? [(reps: 10, weight: 0.0)] : sets
        for (i, p) in planned.enumerated() {
            let set = WorkoutSessionSet(index: i, plannedWeight: p.weight, plannedReps: p.reps)
            set.exercise = se
            se.sets.append(set)
            context.insert(set)
        }
        session.updatedAt = .now
        return se
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

    /// Update a snapshot machine setting for THIS workout only.
    func updateSessionSetting(_ setting: SessionMachineSetting,
                              numericValue: Int?,
                              otherText: String?) {
        setting.numericValue = numericValue
        setting.otherText = otherText
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

    /// Add a brand-new machine setting that wasn't originally defined, applied to
    /// the current session exercise (snapshot). Optionally also add to machine.
    @discardableResult
    func addSessionSetting(to exercise: WorkoutSessionExercise,
                           label: String,
                           numericValue: Int?,
                           otherText: String?,
                           alsoAddToMachine: Bool) -> SessionMachineSetting {
        let order = (exercise.machineSettings.map(\.order).max() ?? -1) + 1
        var defId: UUID? = nil
        if alsoAddToMachine, let machineId = exercise.machineId, let machine = fetchMachine(machineId),
           machine.activeSettings.count < 4 {
            let def = MachineSettingDefinition(label: label, order: order,
                                               numericValue: numericValue, otherText: otherText,
                                               source: machine.source)
            def.machine = machine
            machine.settingDefinitions.append(def)
            context.insert(def)
            defId = def.id
        }
        let snap = SessionMachineSetting(definitionId: defId, label: label, order: order,
                                         numericValue: numericValue, otherText: otherText)
        snap.exercise = exercise
        exercise.machineSettings.append(snap)
        context.insert(snap)
        return snap
    }
}
