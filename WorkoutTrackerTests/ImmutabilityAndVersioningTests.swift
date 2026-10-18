//
//  ImmutabilityAndVersioningTests.swift
//  WorkoutTrackerTests
//
//  Tests 1–12: the core data-safety guarantees — versioning, snapshotting,
//  immutability of recorded history, corrections, and soft deletes.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class ImmutabilityAndVersioningTests: XCTestCase {

    // 1. Creating a routine.
    func test01_createRoutine() throws {
        let ctx = TestSupport.makeContext()
        let repo = RoutineRepository(ctx)
        let routine = repo.createRoutine(name: "Gym Full Body A")
        try ctx.save()

        XCTAssertEqual(routine.name, "Gym Full Body A")
        XCTAssertNotNil(routine.activeVersion)
        XCTAssertEqual(routine.activeVersion?.versionNumber, 1)
        XCTAssertEqual(routine.source, .user)
    }

    // 2. Creating a routine version.
    func test02_createRoutineVersion() throws {
        let ctx = TestSupport.makeContext()
        let repo = RoutineRepository(ctx)
        let routine = repo.createRoutine(name: "Upper Body")
        let v1 = routine.activeVersion!
        let v2 = repo.makeNewVersion(of: routine)
        try ctx.save()

        XCTAssertEqual(v2.versionNumber, 2)
        XCTAssertTrue(v2.isActive)
        XCTAssertFalse(v1.isActive)
        XCTAssertEqual(routine.versions.count, 2)
    }

    // 3. Starting a workout creates a WorkoutSession immediately.
    func test03_startCreatesSession() throws {
        let ctx = TestSupport.makeContext()
        let (routine, _, _) = TestSupport.buildRoutine(ctx)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        try ctx.save()

        XCTAssertEqual(session.status, .started)
        let count = try ctx.fetchCount(FetchDescriptor<WorkoutSession>())
        XCTAssertEqual(count, 1)
    }

    // 4. Starting a workout snapshots planned values into the session.
    func test04_snapshotPlannedValues() throws {
        let ctx = TestSupport.makeContext()
        let (routine, _, _) = TestSupport.buildRoutine(ctx, weight: 120, reps: 8, sets: 3)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        try ctx.save()

        let snapshotSets = session.exercises.flatMap(\.sets)
        XCTAssertEqual(snapshotSets.count, 3)
        XCTAssertTrue(snapshotSets.allSatisfy { $0.plannedWeight == 120 && $0.plannedReps == 8 })

        // Mutating the routine afterwards must NOT change the snapshot.
        TestSupport.firstExercise(of: routine).plannedWeight = 999
        try ctx.save()
        XCTAssertTrue(session.exercises.flatMap(\.sets).allSatisfy { $0.plannedWeight == 120 })
    }

    // 5. Completing sets updates session status correctly.
    func test05_completionStatus() throws {
        let ctx = TestSupport.makeContext()
        let (routine, _, _) = TestSupport.buildRoutine(ctx, sets: 2)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        let sets = session.exercises.flatMap(\.orderedSets)

        workouts.completeSet(sets[0], in: session, actualWeight: 100, actualReps: 10)
        XCTAssertEqual(session.status, .partial)

        workouts.completeSet(sets[1], in: session, actualWeight: 100, actualReps: 10)
        XCTAssertEqual(session.status, .completed)
    }

    // 6. Editing weight/reps during a workout changes only the current session.
    func test06_editOnlyAffectsCurrentSession() throws {
        let ctx = TestSupport.makeContext()
        let (routine, _, _) = TestSupport.buildRoutine(ctx, weight: 100)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        let set = session.exercises.flatMap(\.orderedSets).first!

        workouts.editActual(set, in: session, weight: 135)
        try ctx.save()

        XCTAssertEqual(set.actualWeight, 135)
        // Routine prescription untouched; no new version created.
        XCTAssertEqual(TestSupport.firstExercise(of: routine).plannedWeight, 100)
        XCTAssertEqual(routine.versions.count, 1)
    }

    // 7. Editing a catalog Exercise's defaults updates the routine. The
    // version a workout was started from is never changed (a locked workout
    // holds its values forever), so the update lands in a new version.
    func test07_catalogEditUpdatesRoutineInANewVersion() throws {
        let ctx = TestSupport.makeContext()
        let (routine, exercise, _) = TestSupport.buildRoutine(ctx, weight: 100)
        _ = WorkoutRepository(ctx).startWorkout(from: routine)
        try ctx.save()

        XCTAssertEqual(routine.versions.count, 1)
        RoutineRepository(ctx).updateExerciseDefaults(exerciseId: exercise.id, sets: [(reps: 10, weight: 110)])
        CatalogSyncService(ctx).reconcileExercise(exercise.id)
        try ctx.save()

        XCTAssertEqual(routine.versions.count, 2)
        XCTAssertEqual(TestSupport.firstExercise(of: routine).plannedWeight, 110)
        let old = routine.versions.first { !$0.isActive }
        XCTAssertEqual(old?.orderedSections.first?.orderedExercises.first?.plannedWeight, 100)
    }

    // 8. A LOCKED (finished) session's snapshot is unaffected by a later catalog
    // edit — history stays exactly as recorded.
    func test08_lockedSessionUnaffectedByLaterCatalogEdit() throws {
        let ctx = TestSupport.makeContext()
        let (routine, exercise, _) = TestSupport.buildRoutine(ctx, weight: 100, reps: 10, sets: 1)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        let set = session.exercises.flatMap(\.orderedSets).first!
        workouts.completeSet(set, in: session, actualWeight: 100, actualReps: 10)
        workouts.finishWorkout(session)
        try ctx.save()
        XCTAssertTrue(session.isLocked)

        RoutineRepository(ctx).updateExerciseDefaults(exerciseId: exercise.id, sets: [(reps: 5, weight: 200)])
        CatalogSyncService(ctx).reconcileExercise(exercise.id)
        try ctx.save()

        XCTAssertEqual(set.plannedWeight, 100)
        XCTAssertEqual(set.actualWeight, 100)
    }

    // 9. Completed sessions do not change when the routine is edited.
    func test09_completedSessionUnchangedByRoutineEdit() throws {
        let ctx = TestSupport.makeContext()
        let (routine, _, _) = TestSupport.buildRoutine(ctx, weight: 100, reps: 10, sets: 1)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        let set = session.exercises.flatMap(\.orderedSets).first!
        workouts.completeSet(set, in: session, actualWeight: 100, actualReps: 10)
        workouts.finishWorkout(session)
        try ctx.save()

        XCTAssertTrue(session.isLocked)
        XCTAssertEqual(session.status, .completed)

        // Edit the routine heavily.
        let repo = RoutineRepository(ctx)
        let v2 = repo.makeNewVersion(of: routine)
        v2.orderedSections.first?.exercises.first?.plannedWeight = 500
        try ctx.save()

        // Snapshot + actuals unchanged.
        XCTAssertEqual(set.plannedWeight, 100)
        XCTAssertEqual(set.actualWeight, 100)
        XCTAssertEqual(session.status, .completed)
    }

    // 10. Machine settings shared across routines but snapshotted into sessions.
    func test10_machineSettingsSharedButSnapshotted() throws {
        let ctx = TestSupport.makeContext()
        let repo = RoutineRepository(ctx)

        // One machine shared by two routines.
        let machine = Machine(name: "Leg Press", source: .user)
        ctx.insert(machine)
        let def = MachineSettingDefinition(label: "Seat height", order: 0, numericValue: 5, source: .user)
        def.machine = machine; machine.settingDefinitions.append(def); ctx.insert(def)
        let ex = Exercise(name: "Leg Press", machineId: machine.id, source: .user)
        ctx.insert(ex)

        let rA = repo.createRoutine(name: "A")
        repo.addExercise(to: repo.addSection(to: rA.activeVersion!, type: .strength), exercise: ex, plannedWeight: 100)
        let rB = repo.createRoutine(name: "B")
        repo.addExercise(to: repo.addSection(to: rB.activeVersion!, type: .strength), exercise: ex, plannedWeight: 150)
        try ctx.save()

        // Both routines reference the SAME machine id (shared).
        let exA = rA.activeVersion!.orderedSections.first!.orderedExercises.first!
        let exB = rB.activeVersion!.orderedSections.first!.orderedExercises.first!
        XCTAssertEqual(exA.machineId, exB.machineId)

        // Start a workout from A — setting is snapshot at value 5.
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: rA)
        let snap = session.exercises.first!.machineSettings.first!
        XCTAssertEqual(snap.numericValue, 5)

        // Change the shared machine default to 9.
        def.numericValue = 9
        try ctx.save()

        // Past session snapshot stays at 5; machine default is now 9.
        XCTAssertEqual(snap.numericValue, 5)
        XCTAssertEqual(machine.activeSettings.first?.numericValue, 9)
    }

    // 11. Corrections append events and do not overwrite originals.
    func test11_correctionsAppendOnly() throws {
        let ctx = TestSupport.makeContext()
        let (routine, _, _) = TestSupport.buildRoutine(ctx, sets: 1)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        let set = session.exercises.flatMap(\.orderedSets).first!
        workouts.completeSet(set, in: session, actualWeight: 100, actualReps: 10)
        workouts.finishWorkout(session)
        try ctx.save()

        let corrections = CorrectionService(ctx)
        corrections.correctActualWeight(set, in: session, to: 110, note: "logged wrong plate")
        try ctx.save()

        // Original preserved.
        XCTAssertEqual(set.actualWeight, 100)
        // Correction recorded and layered for display.
        XCTAssertEqual(session.corrections.count, 1)
        XCTAssertEqual(CorrectedView.effectiveActualWeight(set, in: session), 110)
    }

    // 12. Soft-deleted routines/exercises remain available to historical sessions.
    func test12_softDeleteKeepsHistory() throws {
        let ctx = TestSupport.makeContext()
        let (routine, exercise, _) = TestSupport.buildRoutine(ctx)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        workouts.finishWorkout(session)
        try ctx.save()

        let repo = RoutineRepository(ctx)
        repo.softDelete(routine)
        repo.softDelete(exercise)
        try ctx.save()

        // Soft-deleted, not destroyed.
        XCTAssertNotNil(routine.deletedAt)
        XCTAssertNotNil(exercise.deletedAt)
        // Still fetchable, and history snapshot name still resolves.
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Exercise>()), 1)
        XCTAssertFalse(session.exercises.first!.name.isEmpty)
    }

    // 18. Per-set planned values snapshot into the session set-by-set. Sets/rest
    // are edited via the catalog Exercise (single source of truth) + reconcile —
    // not by mutating the RoutineExercise mirror directly.
    func test18_perSetPlannedSnapshot() throws {
        let ctx = TestSupport.makeContext()
        let (routine, exercise, _) = TestSupport.buildRoutine(ctx)
        let repo = RoutineRepository(ctx)
        // Define three distinct sets.
        repo.updateExerciseDefaults(exerciseId: exercise.id, sets: [(reps: 12, weight: 100),
                                                                     (reps: 10, weight: 110),
                                                                     (reps: 8, weight: 120)])
        exercise.defaultRest = 75
        CatalogSyncService(ctx).reconcileExercise(exercise.id)
        try ctx.save()

        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        let sets = session.exercises.flatMap(\.orderedSets)
        XCTAssertEqual(sets.count, 3)
        XCTAssertEqual(sets.map { Int($0.plannedWeight) }, [100, 110, 120])
        XCTAssertEqual(sets.map(\.plannedReps), [12, 10, 8])
        XCTAssertEqual(session.exercises.first?.plannedRestBetweenSets, 75)
    }

    // 19. Finishing a workout records start and end timecodes.
    func test19_startAndEndTimecodes() throws {
        let ctx = TestSupport.makeContext()
        let (routine, _, _) = TestSupport.buildRoutine(ctx, sets: 1)
        let workouts = WorkoutRepository(ctx)
        let start = Date()
        let session = workouts.startWorkout(from: routine, now: start)
        XCTAssertNotNil(session.startedAt)
        XCTAssertNil(session.endedAt)

        let end = start.addingTimeInterval(600)
        workouts.completeSet(session.exercises.flatMap(\.orderedSets).first!, in: session, actualWeight: 100, actualReps: 10, now: end)
        workouts.finishWorkout(session, now: end)
        try ctx.save()

        XCTAssertNotNil(session.endedAt)
        XCTAssertEqual(session.duration ?? 0, 600, accuracy: 1)
    }

    // 20. Reconciling a catalog edit for one exercise must not disturb another
    // exercise's independently-reconciled values in the same routine.
    func test20_reconcileAppliesIndependentlyToMultipleExercisesInOneRoutine() throws {
        let ctx = TestSupport.makeContext()
        let repo = RoutineRepository(ctx)
        let sync = CatalogSyncService(ctx)

        let routine = repo.createRoutine(name: "Two Exercise Routine")
        let strength = repo.addSection(to: routine.activeVersion!, type: .strength)
        let exA = Exercise(name: "Bench Press", source: .user)
        ctx.insert(exA)
        repo.addExercise(to: strength, exercise: exA, setCount: 1, plannedWeight: 50, plannedReps: 10)
        let exB = Exercise(name: "Pull Down", source: .user)
        ctx.insert(exB)
        repo.addExercise(to: strength, exercise: exB, setCount: 1, plannedWeight: 0, plannedReps: 10)
        try ctx.save()

        repo.updateExerciseDefaults(exerciseId: exA.id, sets: [(reps: 10, weight: 55)])
        sync.reconcileExercise(exA.id)
        repo.updateExerciseDefaults(exerciseId: exB.id, sets: [(reps: 10, weight: 70)])
        sync.reconcileExercise(exB.id)
        try ctx.save()

        let finalSections = routine.activeVersion!.orderedSections.first!.orderedExercises
        XCTAssertEqual(finalSections.first { $0.displayName == "Bench Press" }?.plannedWeight, 55)
        XCTAssertEqual(finalSections.first { $0.displayName == "Pull Down" }?.plannedWeight, 70)
    }
}
