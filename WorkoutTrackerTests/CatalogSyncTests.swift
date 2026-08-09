//
//  CatalogSyncTests.swift
//  WorkoutTrackerTests
//
//  Exercise/Machine catalog definitions (Settings) are the single source of
//  truth for exercise settings — sets/reps/weight/rest/notes/photo/rounds/
//  hold/duration/intensity/machine settings — for anything not yet completed.
//  These tests cover CatalogSyncService's reconciliation rules specifically:
//  what it updates, what it freezes, and what it must never touch.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class CatalogSyncTests: XCTestCase {

    // A catalog edit updates a not-yet-completed session's incomplete sets,
    // but leaves the already-completed prefix exactly as recorded.
    func testReconcileUpdatesIncompleteSetsPreservesCompleted() throws {
        let ctx = TestSupport.makeContext()
        let (routine, exercise, _) = TestSupport.buildRoutine(ctx, weight: 100, reps: 10, sets: 3)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        let se = session.exercises.first!
        let sets = se.orderedSets
        workouts.completeSet(sets[0], in: session, actualWeight: 95, actualReps: 10)
        try ctx.save()

        RoutineRepository(ctx).updateExerciseDefaults(
            exerciseId: exercise.id, sets: [(reps: 12, weight: 120), (reps: 12, weight: 120)])
        CatalogSyncService(ctx).reconcileExercise(exercise.id)
        try ctx.save()

        let updated = se.orderedSets
        XCTAssertEqual(updated.count, 2)
        XCTAssertTrue(updated[0].isCompleted)
        XCTAssertEqual(updated[0].actualWeight, 95)
        XCTAssertEqual(updated[0].plannedWeight, 100)   // frozen, not overwritten
        XCTAssertFalse(updated[1].isCompleted)
        XCTAssertEqual(updated[1].plannedWeight, 120)
        XCTAssertEqual(updated[1].plannedReps, 12)
    }

    // A LOCKED (finished) session is never reconciled — history stays exact.
    func testReconcileNeverTouchesLockedSession() throws {
        let ctx = TestSupport.makeContext()
        let (routine, exercise, _) = TestSupport.buildRoutine(ctx, weight: 100, reps: 10, sets: 1)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        let set = session.exercises.flatMap(\.orderedSets).first!
        workouts.completeSet(set, in: session, actualWeight: 100, actualReps: 10)
        workouts.finishWorkout(session)
        try ctx.save()
        XCTAssertTrue(session.isLocked)

        RoutineRepository(ctx).updateExerciseDefaults(exerciseId: exercise.id, sets: [(reps: 5, weight: 500)])
        CatalogSyncService(ctx).reconcileExercise(exercise.id)
        try ctx.save()

        XCTAssertEqual(session.exercises.first!.orderedSets.count, 1)
        XCTAssertEqual(set.plannedWeight, 100)
        XCTAssertEqual(set.actualWeight, 100)
    }

    // If the catalog now prescribes fewer sets than are already completed, the
    // incomplete tail becomes empty and the exercise reads as fully done.
    func testReconcileWithFewerSetsThanCompletedMarksExerciseDone() throws {
        let ctx = TestSupport.makeContext()
        let (routine, exercise, _) = TestSupport.buildRoutine(ctx, weight: 100, reps: 10, sets: 3)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        let se = session.exercises.first!
        let sets = se.orderedSets
        workouts.completeSet(sets[0], in: session, actualWeight: 100, actualReps: 10)
        workouts.completeSet(sets[1], in: session, actualWeight: 100, actualReps: 10)
        try ctx.save()
        XCTAssertFalse(se.isFullyCompleted)

        RoutineRepository(ctx).updateExerciseDefaults(exerciseId: exercise.id, sets: [(reps: 10, weight: 100)])
        CatalogSyncService(ctx).reconcileExercise(exercise.id)
        try ctx.save()

        XCTAssertEqual(se.orderedSets.count, 2)
        XCTAssertTrue(se.isFullyCompleted)
    }

    // Editing a shared Machine's setting propagates into EVERY in-progress
    // session referencing that machine, not just the session it was edited from.
    func testReconcileMachinePropagatesToOtherInProgressSessions() throws {
        let ctx = TestSupport.makeContext()
        let repo = RoutineRepository(ctx)
        let machine = Machine(name: "Leg Press", source: .user)
        ctx.insert(machine)
        let def = MachineSettingDefinition(label: "Seat height", order: 0, numericValue: 5, source: .user)
        def.machine = machine; machine.settingDefinitions.append(def); ctx.insert(def)
        let ex = Exercise(name: "Leg Press", machineId: machine.id, source: .user)
        ctx.insert(ex)

        let rA = repo.createRoutine(name: "A")
        repo.addExercise(to: repo.addSection(to: rA.activeVersion!, type: .strength), exercise: ex, plannedWeight: 100)
        let rB = repo.createRoutine(name: "B")
        repo.addExercise(to: repo.addSection(to: rB.activeVersion!, type: .strength), exercise: ex, plannedWeight: 100)
        try ctx.save()

        let workouts = WorkoutRepository(ctx)
        let sessionA = workouts.startWorkout(from: rA)
        let sessionB = workouts.startWorkout(from: rB)
        try ctx.save()

        def.numericValue = 9
        def.updatedAt = .now
        CatalogSyncService(ctx).reconcileMachine(machine.id)
        try ctx.save()

        XCTAssertEqual(sessionA.exercises.first!.machineSettings.first!.numericValue, 9)
        XCTAssertEqual(sessionB.exercises.first!.machineSettings.first!.numericValue, 9)
    }

    // Cardio/stretching values reconcile while the exercise is still open, but
    // freeze the instant it's marked complete.
    func testReconcileCardioSkipsAlreadyMarkedComplete() throws {
        let ctx = TestSupport.makeContext()
        let repo = RoutineRepository(ctx)
        let cardioEx = Exercise(name: "Treadmill", source: .user)
        cardioEx.defaultSectionType = .cardio
        cardioEx.durationMinutes = 20
        ctx.insert(cardioEx)
        let routine = repo.createRoutine(name: "Cardio Day")
        let section = repo.addSection(to: routine.activeVersion!, type: .cardio)
        repo.addExercise(to: section, exercise: cardioEx)
        try ctx.save()

        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        let se = session.exercises.first!
        XCTAssertEqual(se.durationMinutes, 20)

        workouts.markExerciseComplete(se, in: session)
        try ctx.save()

        cardioEx.durationMinutes = 45
        CatalogSyncService(ctx).reconcileExercise(cardioEx.id)
        try ctx.save()

        XCTAssertEqual(se.durationMinutes, 20)
    }

    // Reconciling a routine's exercises never forks a RoutineVersion — settings
    // are a live mirror, not versioned content.
    func testReconcileRoutineDoesNotForkVersion() throws {
        let ctx = TestSupport.makeContext()
        let (routine, exercise, _) = TestSupport.buildRoutine(ctx, weight: 100)
        _ = WorkoutRepository(ctx).startWorkout(from: routine)
        try ctx.save()
        XCTAssertEqual(routine.versions.count, 1)

        RoutineRepository(ctx).updateExerciseDefaults(exerciseId: exercise.id, sets: [(reps: 8, weight: 135)])
        CatalogSyncService(ctx).reconcileRoutine(routine)
        try ctx.save()

        XCTAssertEqual(routine.versions.count, 1)
        XCTAssertEqual(TestSupport.firstExercise(of: routine).plannedWeight, 135)
    }
}
