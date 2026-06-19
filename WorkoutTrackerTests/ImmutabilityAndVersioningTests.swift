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
        let routine = repo.createRoutine(name: "YMCA Full Body A")
        try ctx.save()

        XCTAssertEqual(routine.name, "YMCA Full Body A")
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

    // 7. Saving a workout edit as future default creates a new RoutineVersion.
    func test07_futureDefaultCreatesVersion() throws {
        let ctx = TestSupport.makeContext()
        let (routine, _, _) = TestSupport.buildRoutine(ctx, weight: 100)
        let repo = RoutineRepository(ctx)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        let sourceExId = session.exercises.first!.sourceRoutineExerciseId!

        XCTAssertEqual(routine.versions.count, 1)
        repo.updateFutureDefault(routine: routine, sourceRoutineExerciseId: sourceExId) { $0.plannedWeight = 110 }
        try ctx.save()

        XCTAssertEqual(routine.versions.count, 2)
        XCTAssertEqual(routine.activeVersion?.versionNumber, 2)
        // New version reflects the change; only the changed value differs.
        let newEx = routine.activeVersion!.orderedSections.first { $0.type == .strength }!.orderedExercises.first!
        XCTAssertEqual(newEx.plannedWeight, 110)
    }

    // 8. Past sessions continue pointing to the old RoutineVersion.
    func test08_pastSessionKeepsOldVersion() throws {
        let ctx = TestSupport.makeContext()
        let (routine, _, _) = TestSupport.buildRoutine(ctx)
        let repo = RoutineRepository(ctx)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        let oldVersionId = session.routineVersionId
        let sourceExId = session.exercises.first!.sourceRoutineExerciseId!

        repo.updateFutureDefault(routine: routine, sourceRoutineExerciseId: sourceExId) { $0.plannedWeight = 200 }
        try ctx.save()

        XCTAssertEqual(session.routineVersionId, oldVersionId)
        XCTAssertNotEqual(routine.activeVersion?.id, oldVersionId)
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

    // 18. Per-set planned values snapshot into the session set-by-set.
    func test18_perSetPlannedSnapshot() throws {
        let ctx = TestSupport.makeContext()
        let (routine, exercise, _) = TestSupport.buildRoutine(ctx)
        let repo = RoutineRepository(ctx)
        let re = TestSupport.firstExercise(of: routine)
        // Define three distinct sets.
        repo.setPlannedSets(re, sets: [(reps: 12, weight: 100),
                                       (reps: 10, weight: 110),
                                       (reps: 8, weight: 120)], restBetweenSets: 75)
        try ctx.save()
        _ = exercise

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
}
