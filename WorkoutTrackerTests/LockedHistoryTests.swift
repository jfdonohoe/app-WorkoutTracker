//
//  LockedHistoryTests.swift
//  WorkoutTrackerTests
//
//  A locked workout holds the values it had when it was locked, forever:
//  library and routine changes, backup restores, demo cleanup and the
//  distance-unit setting never change it.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class LockedHistoryTests: XCTestCase {

    private func snapshot(_ s: WorkoutSession) -> [String] {
        s.orderedExercises.flatMap { ex in
            ["\(ex.name)|\(ex.notes)|\(ex.machineId?.uuidString ?? "-")|\(ex.reps)|\(ex.setCount)"]
                + ex.machineSettings.sorted { $0.order < $1.order }.map { "\($0.label)=\($0.displayValue)" }
                + ex.orderedSets.map { "\($0.plannedReps)x\($0.plannedWeight) \($0.actualReps ?? -1)x\($0.actualWeight ?? -1)" }
        } + [s.status.rawValue, "\(s.endedAt?.timeIntervalSince1970 ?? 0)"]
    }

    /// Stopping is final: a stopped workout is never reopened, so current
    /// definitions can't flow back into it.
    func testStoppedWorkoutIsNeverReopenedOrResynced() throws {
        let ctx = TestSupport.makeContext()
        let (routine, exercise, machine) = TestSupport.buildRoutine(ctx, sets: 3)
        let session = TestSupport.finishWithOneSetDone(ctx, routine)   // partial, locked
        XCTAssertEqual(session.status, .partial)
        let before = snapshot(session)

        exercise.notes = "new notes"
        machine?.activeSettings.first?.numericValue = 9
        RoutineRepository(ctx).updateExerciseDefaults(exerciseId: exercise.id, sets: [(reps: 5, weight: 200)])
        WorkoutRepository(ctx).reopen(session)
        let sync = CatalogSyncService(ctx)
        sync.reconcileExercise(exercise.id)
        if let mid = machine?.id { sync.reconcileMachine(mid) }
        sync.reconcileSession(session)
        try ctx.save()

        XCTAssertTrue(session.isLocked)
        XCTAssertEqual(snapshot(session), before)
    }

    /// Restoring a backup never adds rows to a workout already on the device.
    func testRestoreDoesNotAddRowsToAnExistingWorkout() throws {
        let ctx = TestSupport.makeContext()
        let (routine, _, _) = TestSupport.buildRoutine(ctx, sets: 4)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        try ctx.save()
        let backup = ExportImportService(ctx).makeBackup()

        // Mid-workout the plan drops to three sets; then it's finished.
        let ex = try XCTUnwrap(session.exercises.first)
        let last = try XCTUnwrap(ex.orderedSets.last)
        ex.sets.removeAll { $0.id == last.id }
        ctx.delete(last)
        if let first = ex.orderedSets.first {
            workouts.completeSet(first, in: session, actualWeight: 100, actualReps: 10)
        }
        workouts.finishWorkout(session)
        try ctx.save()
        let before = snapshot(session)

        _ = ExportImportService(ctx).restore(backup)
        try ctx.save()
        XCTAssertEqual(session.orderedExercises.first?.orderedSets.count, 3)
        XCTAssertEqual(snapshot(session), before)
    }

    /// A real workout done on a demo routine survives demo cleanup as the
    /// user's own; seeded demo workouts are still removed.
    func testDemoCleanupKeepsRealWorkoutsOnDemoRoutines() throws {
        let ctx = TestSupport.makeContext()
        SeedDataService(ctx).seed()
        try ctx.save()
        let seeded = try ctx.fetch(FetchDescriptor<WorkoutSession>()).filter { $0.deletedAt == nil }
        XCTAssertFalse(seeded.isEmpty)
        XCTAssertTrue(seeded.allSatisfy { !DemoDataManager.isRealLockedWorkout($0) }, "seeded workouts read as seeded")

        let demoRoutine = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Routine>()).first { $0.source == .seedDemo })
        let workouts = WorkoutRepository(ctx)
        let real = workouts.startWorkout(from: demoRoutine, now: .now.addingTimeInterval(-600))
        let set = try XCTUnwrap(real.exercises.flatMap(\.orderedSets).first)
        workouts.completeSet(set, in: real, actualWeight: set.plannedWeight, actualReps: set.plannedReps)
        workouts.finishWorkout(real)
        XCTAssertEqual(real.source, .seedDemo)
        try ctx.save()
        let before = snapshot(real)

        DemoDataManager(ctx).deleteAllDemoData()
        try ctx.save()

        let left = try ctx.fetch(FetchDescriptor<WorkoutSession>())
        XCTAssertEqual(left.map(\.id), [real.id])
        XCTAssertEqual(real.source, .user)
        XCTAssertEqual(snapshot(real), before)
    }

    /// Distances keep the unit they were recorded in.
    func testDistanceUnitIsFrozenAtLock() throws {
        let key = DistanceUnit.storageKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        let ctx = TestSupport.makeContext()
        UserDefaults.standard.set(DistanceUnit.mi.rawValue, forKey: key)
        let session = TestSupport.finishWithOneSetDone(ctx, TestSupport.buildRoutine(ctx).routine)
        UserDefaults.standard.set(DistanceUnit.km.rawValue, forKey: key)
        XCTAssertEqual(session.distanceUnit, DistanceUnit.mi.rawValue)

        // A workout locked before the unit was recorded gets today's unit once.
        session.distanceUnitRaw = ""
        XCTAssertEqual(WorkoutRepository(ctx).freezeDistanceUnits(), 1)
        UserDefaults.standard.set(DistanceUnit.mi.rawValue, forKey: key)
        XCTAssertEqual(session.distanceUnit, DistanceUnit.km.rawValue)
        XCTAssertEqual(WorkoutRepository(ctx).freezeDistanceUnits(), 0)
    }

    /// Re-locking (Data Safety's finish) keeps the unit already recorded.
    func testRelockKeepsRecordedUnit() throws {
        let key = DistanceUnit.storageKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let ctx = TestSupport.makeContext()
        UserDefaults.standard.set(DistanceUnit.km.rawValue, forKey: key)
        let session = TestSupport.finishWithOneSetDone(ctx, TestSupport.buildRoutine(ctx).routine)
        UserDefaults.standard.set(DistanceUnit.mi.rawValue, forKey: key)
        session.lockedAt = nil
        WorkoutRepository(ctx).lock(session)
        XCTAssertEqual(session.distanceUnit, DistanceUnit.km.rawValue)
    }

    /// Only "both times set and equal" reads as seeded.
    func testWorkoutMissingATimeIsReal() throws {
        let ctx = TestSupport.makeContext()
        let session = TestSupport.finishWithOneSetDone(ctx, TestSupport.buildRoutine(ctx).routine)
        session.endedAt = nil
        XCTAssertTrue(DemoDataManager.isRealLockedWorkout(session))
        session.endedAt = session.startedAt
        XCTAssertFalse(DemoDataManager.isRealLockedWorkout(session))
    }

    /// Session-setting edits are refused on a locked workout.
    func testSessionSettingEditsRefusedWhenLocked() throws {
        let ctx = TestSupport.makeContext()
        let session = TestSupport.finishWithOneSetDone(ctx, TestSupport.buildRoutine(ctx).routine)
        let ex = try XCTUnwrap(session.exercises.first)
        let setting = try XCTUnwrap(ex.machineSettings.first)
        let workouts = WorkoutRepository(ctx)
        let before = snapshot(session)
        workouts.updateSessionSetting(setting, numericValue: 12, otherText: nil)
        workouts.renameSetting(setting, to: "Renamed", in: ex)
        workouts.deleteSetting(setting, from: ex)
        XCTAssertNil(workouts.addSessionSetting(to: ex, label: "New", numericValue: 1, otherText: nil, alsoAddToMachine: false))
        XCTAssertEqual(snapshot(session), before)
    }
}
