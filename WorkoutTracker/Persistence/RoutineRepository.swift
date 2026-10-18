//
//  RoutineRepository.swift
//  WorkoutTracker
//
//  All routine + versioning writes go through here so the immutability /
//  versioning rules live in ONE auditable place.
//
//  Core guarantees:
//   • Editing a routine that any session already references creates a NEW
//     RoutineVersion (deep clone); the old version is left untouched and stays
//     referenced by past sessions (principles #2, #3).
//   • Catalog deletes are SOFT (set deletedAt) so history keeps resolving
//     (principle #4).
//

import Foundation
import SwiftData

@MainActor
struct RoutineRepository {
    let context: ModelContext

    init(_ context: ModelContext) { self.context = context }

    // MARK: - Create

    /// Create a routine with an empty active version (#1).
    @discardableResult
    func createRoutine(name: String, source: DataSource = .user) -> Routine {
        let routine = Routine(name: name, source: source)
        context.insert(routine)
        let version = RoutineVersion(routineId: routine.id,
                                     versionNumber: 1,
                                     isActive: true,
                                     source: source)
        version.routine = routine
        routine.versions.append(version)
        context.insert(version)
        Audit.log(context, type: "routine.created", entity: "Routine",
                  entityId: routine.id, summary: "Created routine \(name)", source: source)
        return routine
    }

    @discardableResult
    func addSection(to version: RoutineVersion,
                    type: SectionType,
                    title: String? = nil,
                    durationMinutes: Int? = nil) -> RoutineSection {
        let order = (version.sections.map(\.order).max() ?? -1) + 1
        let section = RoutineSection(type: type, title: title, order: order, durationMinutes: durationMinutes)
        section.version = version
        version.sections.append(section)
        context.insert(section)
        return section
    }

    @discardableResult
    func addExercise(to section: RoutineSection,
                     exercise: Exercise,
                     setCount: Int = 3,
                     plannedWeight: Double = 0,
                     plannedReps: Int = 10,
                     restBetweenSets: Int = 90,
                     notes: String = "",
                     targetEffort: PerceivedEffort? = nil) -> RoutineExercise {
        let order = (section.exercises.map(\.order).max() ?? -1) + 1
        let re = RoutineExercise(exerciseId: exercise.id,
                                 machineId: exercise.machineId,
                                 displayName: exercise.name,
                                 order: order,
                                 setCount: setCount,
                                 plannedWeight: plannedWeight,
                                 plannedReps: plannedReps,
                                 restBetweenSets: restBetweenSets,
                                 notes: notes,
                                 targetEffort: targetEffort)
        re.section = section
        section.exercises.append(re)
        context.insert(re)
        return re
    }

    /// Add an exercise with explicit per-set planned values (set-by-set builder).
    @discardableResult
    func addExercise(to section: RoutineSection,
                     exercise: Exercise,
                     plannedSets: [(reps: Int, weight: Double)],
                     restBetweenSets: Int,
                     notes: String = "",
                     targetEffort: PerceivedEffort? = nil) -> RoutineExercise {
        let re = addExercise(to: section,
                             exercise: exercise,
                             setCount: plannedSets.count,
                             plannedWeight: plannedSets.first?.weight ?? 0,
                             plannedReps: plannedSets.first?.reps ?? 10,
                             restBetweenSets: restBetweenSets,
                             notes: notes,
                             targetEffort: targetEffort)
        setPlannedSets(re, sets: plannedSets, restBetweenSets: restBetweenSets)
        return re
    }

    /// Replace an exercise's per-set planned rows (and refresh its summary
    /// fields + rest). Used by the set-by-set builder.
    func setPlannedSets(_ exercise: RoutineExercise,
                        sets: [(reps: Int, weight: Double)],
                        restBetweenSets: Int) {
        // Remove existing per-set rows.
        for s in exercise.plannedSets { context.delete(s) }
        exercise.plannedSets = []
        for (i, s) in sets.enumerated() {
            let row = RoutinePlannedSet(order: i, plannedReps: s.reps, plannedWeight: s.weight)
            row.exercise = exercise
            exercise.plannedSets.append(row)
            context.insert(row)
        }
        // Keep summary fields in sync for at-a-glance display + fallback.
        exercise.setCount = sets.count
        exercise.plannedReps = sets.first?.reps ?? exercise.plannedReps
        exercise.plannedWeight = sets.first?.weight ?? exercise.plannedWeight
        exercise.restBetweenSets = restBetweenSets
    }

    // MARK: - Versioning

    /// True if any session was created from this version (so it must not be
    /// mutated in place).
    func isReferencedBySession(_ version: RoutineVersion) -> Bool {
        // Capture as optional so the predicate compares UUID? == UUID? cleanly.
        let vid: UUID? = version.id
        // Deleted and discarded workouts don't count: nothing shows them, and
        // each keeps its own snapshot anyway.
        let descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.routineVersionId == vid && $0.deletedAt == nil }
        )
        let count = (try? context.fetchCount(descriptor)) ?? 0
        return count > 0
    }

    /// Deep-clone the active version into a new version and make it active.
    /// Returns the new version for the caller to mutate. The old version is
    /// preserved unchanged (so any session pointing at it stays accurate).
    @discardableResult
    func makeNewVersion(of routine: Routine, note: String = "") -> RoutineVersion {
        guard let current = routine.activeVersion else {
            // No version yet — create v1.
            let v = RoutineVersion(routineId: routine.id, versionNumber: 1, isActive: true, source: routine.source)
            v.routine = routine
            routine.versions.append(v)
            context.insert(v)
            return v
        }

        current.isActive = false

        let newVersion = RoutineVersion(routineId: routine.id,
                                        versionNumber: routine.nextVersionNumber,
                                        isActive: true,
                                        defaultRestBetweenExercises: current.defaultRestBetweenExercises,
                                        defaultRestBetweenSets: current.defaultRestBetweenSets,
                                        note: note,
                                        source: routine.source) // inherit demo/user lineage
        newVersion.rests = current.rests
        newVersion.routine = routine
        routine.versions.append(newVersion)
        context.insert(newVersion)

        // Deep copy sections & exercises with fresh ids.
        copySections(from: current, to: newVersion)

        routine.updatedAt = .now
        Audit.log(context, type: "routine.versioned", entity: "RoutineVersion",
                  entityId: newVersion.id,
                  summary: "New version v\(newVersion.versionNumber) of \(routine.name)",
                  source: routine.source)
        return newVersion
    }

    /// Editor save: mutate the active version in place ONLY if it is not yet
    /// referenced by any session; otherwise create a new version first, then
    /// apply the edits to the new version. The `apply` closure receives the
    /// version that is safe to mutate.
    func editRoutine(_ routine: Routine, note: String = "", apply: (RoutineVersion) -> Void) {
        guard let active = routine.activeVersion else { return }
        let target: RoutineVersion
        if isReferencedBySession(active) {
            target = makeNewVersion(of: routine, note: note)
        } else {
            target = active
        }
        apply(target)
        routine.updatedAt = .now
    }

    /// Deep-copy a version's sections, exercises and per-set planned rows into
    /// another version, with fresh ids, so the copy is independent. The one
    /// place this copy is written (new version, clone, calendar replace).
    private func copySections(from src: RoutineVersion, to dst: RoutineVersion) {
        for section in src.orderedSections {
            let newSection = RoutineSection(type: section.type, title: section.title,
                                            order: section.order, durationMinutes: section.durationMinutes)
            newSection.version = dst
            dst.sections.append(newSection)
            context.insert(newSection)
            for ex in section.orderedExercises {
                let newEx = RoutineExercise(exerciseId: ex.exerciseId, machineId: ex.machineId,
                                            displayName: ex.displayName, order: ex.order,
                                            setCount: ex.setCount, plannedWeight: ex.plannedWeight,
                                            plannedReps: ex.plannedReps, restBetweenSets: ex.restBetweenSets,
                                            notes: ex.notes, targetEffort: ex.targetEffort)
                newEx.section = newSection
                newSection.exercises.append(newEx)
                context.insert(newEx)
                for ps in ex.plannedSets.sorted(by: { $0.order < $1.order }) {
                    let newPs = RoutinePlannedSet(order: ps.order, plannedReps: ps.plannedReps,
                                                  plannedWeight: ps.plannedWeight)
                    newPs.exercise = newEx
                    newEx.plannedSets.append(newPs)
                    context.insert(newPs)
                }
            }
        }
    }

    /// Duplicate a routine (its active version) into a brand-new routine. Used by
    /// "save as a new routine".
    @discardableResult
    func cloneRoutine(_ source: Routine, newName: String) -> Routine {
        // A copy stays on its original's side: a demo routine's copy is demo,
        // since it uses demo exercises. Demo and user data never mix.
        let clone = createRoutine(name: newName, source: source.source)
        guard let src = source.activeVersion, let dst = clone.activeVersion else { return clone }
        dst.rests = src.rests
        copySections(from: src, to: dst)
        return clone
    }

    /// Replace `target`'s content with a copy of `source`'s active version, as a
    /// NEW version (so past sessions keep their old version). Used when a future
    /// scheduled routine is edited and the change should apply to all recurrences.
    func replaceContent(of target: Routine, with source: Routine) {
        guard let src = source.activeVersion else { return }
        // Start a fresh version (deep-copies target's CURRENT content), then wipe
        // it and copy the source content in.
        let newVersion = makeNewVersion(of: target, note: "Edited from calendar")
        for s in newVersion.sections { context.delete(s) }
        newVersion.sections = []
        newVersion.rests = src.rests
        copySections(from: src, to: newVersion)
        target.updatedAt = .now
    }

    /// Update a library Exercise's default prescription for one of its
    /// machines (nil = the primary machine). Used when baking in workout edits
    /// and by the set builder. Other machines' sets are left alone. A deleted
    /// exercise is never edited.
    func updateExerciseDefaults(exerciseId: UUID, machineId: UUID? = nil, sets: [(reps: Int, weight: Double)]) {
        let d = FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exerciseId })
        guard let exercise = try? context.fetch(d).first, exercise.deletedAt == nil else { return }
        let target = machineId ?? exercise.machineId
        let stale = exercise.defaultSets.filter { ($0.machineId ?? exercise.machineId) == target }
        let staleIds = Set(stale.map(\.id))
        exercise.defaultSets.removeAll { staleIds.contains($0.id) }
        for s in stale { context.delete(s) }
        for (i, s) in sets.enumerated() {
            let ds = ExerciseDefaultSet(order: i, reps: s.reps, weight: s.weight, machineId: target)
            ds.exercise = exercise
            exercise.defaultSets.append(ds)
            context.insert(ds)
        }
        exercise.updatedAt = .now
    }

    // MARK: - Soft delete

    /// Soft-delete a routine: hide it but keep all versions for history.
    func softDelete(_ routine: Routine) {
        routine.deletedAt = .now
        routine.updatedAt = .now
        Audit.log(context, type: "routine.softDeleted", entity: "Routine",
                  entityId: routine.id, summary: "Soft-deleted \(routine.name)", source: routine.source)
    }

    func softDelete(_ exercise: Exercise) {
        exercise.deletedAt = .now
        exercise.updatedAt = .now
    }

    /// Remove every RoutineExercise referencing `exerciseId` from every
    /// non-deleted routine's active version — forking a new version first if
    /// the active version is already referenced by a recorded session, same as
    /// any other structural routine edit (see RoutineEditorView.ensureEditable-
    /// Version). Future and current scheduled workouts read a routine's active
    /// version live (see CalendarView / WorkoutRepository.startWorkout), so this
    /// alone clears the exercise from every one of them; only already-started
    /// sessions need separate handling (WorkoutRepository.removeExerciseFrom-
    /// ActiveSessions). Called when an exercise is deleted from the library.
    func removeExerciseFromAllRoutines(exerciseId: UUID) {
        let descriptor = FetchDescriptor<RoutineExercise>(predicate: #Predicate { $0.exerciseId == exerciseId })
        guard let matches = try? context.fetch(descriptor) else { return }
        var affected: [UUID: Routine] = [:]
        for re in matches {
            guard let version = re.section?.version,
                  let routine = version.routine, routine.deletedAt == nil,
                  version.id == routine.activeVersion?.id else { continue }
            affected[routine.id] = routine
        }
        for routine in affected.values {
            editRoutine(routine, note: "Exercise removed from library") { version in
                for section in version.sections {
                    let toRemove = section.exercises.filter { $0.exerciseId == exerciseId }
                    // Detach before deleting so nothing reads a deleted row
                    // through the relationship before the next save.
                    section.exercises.removeAll { $0.exerciseId == exerciseId }
                    for ex in toRemove { context.delete(ex) }
                }
            }
        }
    }

    func softDelete(_ machine: Machine) {
        machine.deletedAt = .now
        machine.updatedAt = .now
    }
}

/// Tiny helper to append audit events from anywhere.
enum Audit {
    @MainActor
    static func log(_ context: ModelContext,
                    type: String,
                    entity: String,
                    entityId: UUID? = nil,
                    summary: String,
                    source: DataSource = .user) {
        let event = AuditEvent(type: type, entity: entity, entityId: entityId, summary: summary, source: source)
        context.insert(event)
    }
}
