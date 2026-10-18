//
//  DataSafetyRepairTests.swift
//  WorkoutTrackerTests
//
//  The Data Safety Check's action/info split, the automatic repairs (checks
//  1, 6, 8), the per-record fixes the screen offers, and the restore rule
//  that keeps a routine's current version active.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class DataSafetyRepairTests: XCTestCase {

    private func check(_ title: String, _ ctx: ModelContext) throws -> IntegrityCheck {
        try XCTUnwrap(DataIntegrityService(ctx).runAll().first { $0.title == title })
    }

    /// A finished workout with one set done (one with nothing done is discarded).
    private func finishedWorkout(_ ctx: ModelContext, _ routine: Routine) -> WorkoutSession {
        let workouts = WorkoutRepository(ctx)
        let s = workouts.startWorkout(from: routine)
        if let set = s.exercises.first?.orderedSets.first {
            workouts.completeSet(set, in: s, actualWeight: set.plannedWeight, actualReps: set.plannedReps)
        }
        workouts.finishWorkout(s)
        return s
    }

    // MARK: - Action vs info

    /// Info-only results never open the check after an import or export.
    func testInfoChecksDoNotNeedAttention() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        let s = finishedWorkout(ctx, built.routine)
        s.routineVersionId = UUID()   // check 3: version gone
        ctx.insert(AuditEvent(type: "x", entity: "X", summary: "", timestamp: .now.addingTimeInterval(86_400)))  // check 11

        let checks = DataIntegrityService(ctx).runAll()
        let failing = checks.filter { !$0.passed }
        XCTAssertEqual(Set(failing.map(\.title)), ["Session → routine version references are valid", "Audit log is intact"])
        XCTAssertTrue(failing.allSatisfy { $0.severity == .info })
        XCTAssertFalse(checks.contains(where: \.needsAttention))
    }

    func testActionFailureNeedsAttention() throws {
        let ctx = TestSupport.makeContext()
        TestSupport.buildRoutine(ctx).routine.activeVersion!.isActive = false
        XCTAssertEqual(DataIntegrityService(ctx).runAll().filter(\.needsAttention).count, 1)
    }

    // MARK: - Auto repair (1, 6, 8)

    func testAutoRepairFixesLockSourcesAndActiveVersions() throws {
        let ctx = TestSupport.makeContext()
        let a = TestSupport.buildRoutine(ctx, name: "A")
        let b = TestSupport.buildRoutine(ctx, name: "B")
        let s = finishedWorkout(ctx, a.routine)
        s.lockedAt = nil                                     // 1
        a.exercise.sourceRaw = "imported?"                    // 6 unknown
        b.routine.activeVersion!.source = .seedDemo           // 6 mismatch
        RoutineRepository(ctx).editRoutine(a.routine, note: "fork") { _ in }
        a.routine.versions.forEach { $0.isActive = true }     // 8: two active
        let newest = a.routine.versions.max { $0.versionNumber < $1.versionNumber }!
        b.routine.versions.forEach { $0.isActive = false }    // 8: none active

        XCTAssertGreaterThan(DataSafetyRepair(ctx).autoRepair(), 0)

        XCTAssertEqual(s.lockedAt, s.completedAt)
        XCTAssertEqual(a.exercise.source, .user)
        XCTAssertEqual(b.routine.activeVersion!.source, .user)
        XCTAssertEqual(a.routine.versions.filter(\.isActive).map(\.id), [newest.id])
        XCTAssertEqual(b.routine.versions.filter(\.isActive).count, 1)
        for c in DataIntegrityService(ctx).runAll() { XCTAssertTrue(c.passed, "\(c.title) — \(c.detail)") }
    }

    func testAutoRepairIsRepeatableAndLoggedOnce() throws {
        let ctx = TestSupport.makeContext()
        TestSupport.buildRoutine(ctx).routine.activeVersion!.isActive = false
        let repair = DataSafetyRepair(ctx)
        XCTAssertEqual(repair.autoRepair(), 1)
        XCTAssertEqual(repair.autoRepair(), 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<AuditEvent>()).filter { $0.type == "data.repaired" }.count, 1)
    }

    // MARK: - Restore keeps the device's current version

    func testMergeRestoreKeepsDevicesActiveVersion() throws {
        // Device A: routine v1, backed up.
        let a = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(a)
        try a.save()
        let backupV1 = try ExportImportService(a).exportJSONData()
        // A then forks its own v2 and backs up again.
        _ = finishedWorkout(a, built.routine)
        RoutineRepository(a).editRoutine(built.routine, note: "A's edit") { _ in }
        try a.save()
        let backupA2 = try ExportImportService(a).exportJSONData()

        // Device B restores v1, forks its own v2, then restores A's backup.
        let b = TestSupport.makeContext()
        _ = try ExportImportService(b).importJSON(backupV1)
        let routineB = try XCTUnwrap(try b.fetch(FetchDescriptor<Routine>()).first)
        _ = finishedWorkout(b, routineB)
        RoutineRepository(b).editRoutine(routineB, note: "B's edit") { _ in }
        let bCurrent = routineB.activeVersion!.id
        try b.save()
        _ = try ExportImportService(b).importJSON(backupA2)
        try b.save()

        XCTAssertEqual(routineB.versions.filter(\.isActive).map(\.id), [bCurrent])
        XCTAssertEqual(routineB.versions.count, 3)   // A's v2 kept as history
    }

    // MARK: - Per-record fixes

    func testDeleteWorkoutWithoutSnapshot() throws {
        let ctx = TestSupport.makeContext()
        let s = finishedWorkout(ctx, TestSupport.buildRoutine(ctx).routine)
        s.exercises.removeAll()
        let result = try check("Recorded sessions have snapshot data", ctx)
        XCTAssertEqual(result.issues.first?.fixes, [.deleteWorkout(s.id)])

        DataSafetyRepair(ctx).apply(.deleteWorkout(s.id))
        XCTAssertNotNil(s.deletedAt)
        XCTAssertTrue(try check("Recorded sessions have snapshot data", ctx).passed)
    }

    func testFinishLockedUnfinishedWorkout() throws {
        let ctx = TestSupport.makeContext()
        let workouts = WorkoutRepository(ctx)
        let s = workouts.startWorkout(from: TestSupport.buildRoutine(ctx, sets: 2).routine)
        let set = try XCTUnwrap(s.exercises.first?.orderedSets.first)
        workouts.completeSet(set, in: s, actualWeight: 100, actualReps: 10)
        workouts.lock(s)
        let lockedAt = s.lockedAt
        XCTAssertEqual(try check("Workouts in progress are consistent", ctx).issues.first?.fixes,
                       [.finishWorkout(s.id)])

        DataSafetyRepair(ctx).apply(.finishWorkout(s.id))
        XCTAssertEqual(s.completedAt, lockedAt)
        XCTAssertTrue(try check("Workouts in progress are consistent", ctx).passed)
        XCTAssertTrue(try check("Recorded sessions are locked", ctx).passed)
    }

    /// A locked workout is never reopened, even by a stale Resume fix.
    func testResumeNeverUnlocksALockedWorkout() throws {
        let ctx = TestSupport.makeContext()
        let workouts = WorkoutRepository(ctx)
        let s = workouts.startWorkout(from: TestSupport.buildRoutine(ctx).routine)
        workouts.lock(s)
        DataSafetyRepair(ctx).apply(.resumeWorkout(s.id))
        XCTAssertTrue(s.isLocked)
    }

    func testSetMissingStartTime() throws {
        let ctx = TestSupport.makeContext()
        let s = WorkoutRepository(ctx).startWorkout(from: TestSupport.buildRoutine(ctx).routine)
        s.startedAt = nil
        DataSafetyRepair(ctx).apply(.setStartTime(s.id))
        XCTAssertEqual(s.startedAt, s.createdAt)
        XCTAssertTrue(try check("Workouts in progress are consistent", ctx).passed)
    }

    func testRestoreDeletedExerciseToLibrary() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        built.exercise.deletedAt = .now
        let issue = try XCTUnwrap(try check("Routines use only library exercises", ctx).issues.first)
        XCTAssertEqual(issue.title, built.exercise.name)
        XCTAssertEqual(issue.fixes, [.restoreExercise(built.exercise.id), .removeExerciseEverywhere(built.exercise.id)])

        DataSafetyRepair(ctx).apply(.restoreExercise(built.exercise.id))
        XCTAssertNil(built.exercise.deletedAt)
        XCTAssertTrue(try check("Routines use only library exercises", ctx).passed)
    }

    func testRemoveDeletedExerciseFromRoutines() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        built.exercise.deletedAt = .now
        DataSafetyRepair(ctx).apply(.removeExerciseEverywhere(built.exercise.id))
        XCTAssertTrue(try check("Routines use only library exercises", ctx).passed)
        XCTAssertTrue(built.routine.activeVersion!.sections.flatMap(\.exercises).isEmpty)
    }

    func testRestoreDeletedMachine() throws {
        let ctx = TestSupport.makeContext()
        let machine = try XCTUnwrap(TestSupport.buildRoutine(ctx).machine)
        RoutineRepository(ctx).softDelete(machine)
        XCTAssertEqual(try check("Machine references are valid", ctx).issues.first?.fixes,
                       [.restoreMachine(machine.id), .removeMachineEverywhere(machine.id)])
        DataSafetyRepair(ctx).apply(.restoreMachine(machine.id))
        XCTAssertTrue(try check("Machine references are valid", ctx).passed)
    }

    func testRemoveDeletedMachineEverywhere() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        let machine = try XCTUnwrap(built.machine)
        let open = WorkoutRepository(ctx).startWorkout(from: built.routine)
        RoutineRepository(ctx).softDelete(machine)

        DataSafetyRepair(ctx).apply(.removeMachineEverywhere(machine.id))

        XCTAssertFalse(built.exercise.machineIds.contains(machine.id))
        XCTAssertNil(built.routine.activeVersion!.sections.flatMap(\.exercises).first?.machineId)
        XCTAssertNil(open.exercises.first?.machineId)
        XCTAssertTrue(try check("Machine references are valid", ctx).passed)
    }

    func testEveryFixIsLogged() throws {
        let ctx = TestSupport.makeContext()
        let s = WorkoutRepository(ctx).startWorkout(from: TestSupport.buildRoutine(ctx).routine)
        DataSafetyRepair(ctx).apply(.setStartTime(s.id))
        let logged = try ctx.fetch(FetchDescriptor<AuditEvent>()).filter { $0.type == "data.repaired" }
        XCTAssertEqual(logged.map(\.summary), ["Data Safety: Use Created Time"])
    }

    // MARK: - Review follow-ups

    /// A locked, unfinished workout with sets done finishes as partial, not
    /// with its in-progress status.
    func testFinishLockedWorkoutWithSetsDoneGetsRealStatus() throws {
        let ctx = TestSupport.makeContext()
        let workouts = WorkoutRepository(ctx)
        let s = workouts.startWorkout(from: TestSupport.buildRoutine(ctx, sets: 2).routine)
        let set = try XCTUnwrap(s.exercises.first?.orderedSets.first)
        workouts.completeSet(set, in: s, actualWeight: 100, actualReps: 10)
        workouts.lock(s)
        let lockedAt = s.lockedAt

        DataSafetyRepair(ctx).apply(.finishWorkout(s.id))

        XCTAssertEqual(s.status, .partial)
        XCTAssertEqual(s.lockedAt, lockedAt)
        XCTAssertEqual(s.completedAt, lockedAt)
    }

    /// A fix never changes a finished workout, even one left unlocked.
    func testFixesLeaveFinishedUnlockedWorkoutAlone() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        let finished = finishedWorkout(ctx, built.routine)
        finished.lockedAt = nil
        built.exercise.deletedAt = .now

        DataSafetyRepair(ctx).apply(.removeExerciseEverywhere(built.exercise.id))

        XCTAssertNotNil(finished.lockedAt)
        XCTAssertEqual(finished.exercises.count, 1)
    }

    func testRemoveMachineFromDeletedExerciseStillPlanned() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        let machine = try XCTUnwrap(built.machine)
        built.exercise.deletedAt = .now
        RoutineRepository(ctx).softDelete(machine)

        DataSafetyRepair(ctx).apply(.removeMachineEverywhere(machine.id))

        XCTAssertNil(built.routine.activeVersion!.sections.flatMap(\.exercises).first?.machineId)
        XCTAssertTrue(try check("Machine references are valid", ctx).passed)
    }

    func testRemoveMachineDropsItsDefaultSetsAndOpenSettings() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        let machine = try XCTUnwrap(built.machine)
        RoutineRepository(ctx).updateExerciseDefaults(exerciseId: built.exercise.id, machineId: machine.id,
                                                      sets: [(reps: 10, weight: 50)])
        let open = WorkoutRepository(ctx).startWorkout(from: built.routine)
        RoutineRepository(ctx).softDelete(machine)

        DataSafetyRepair(ctx).apply(.removeMachineEverywhere(machine.id))

        XCTAssertFalse(built.exercise.defaultSets.contains { $0.machineId == machine.id })
        XCTAssertTrue(open.exercises.flatMap(\.machineSettings).allSatisfy { $0.definitionId == nil })
    }

    func testWorkoutWithTwoProblemsHasUniqueIssueIds() throws {
        let ctx = TestSupport.makeContext()
        let workouts = WorkoutRepository(ctx)
        let s = workouts.startWorkout(from: TestSupport.buildRoutine(ctx).routine)
        workouts.lock(s)
        s.startedAt = nil
        let ids = try check("Workouts in progress are consistent", ctx).issues.map(\.id)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 2)
    }

    func testCorrectionWithoutRelationshipTakesSessionSource() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx, sets: 1)
        let workouts = WorkoutRepository(ctx)
        let s = workouts.startWorkout(from: built.routine)
        let set = try XCTUnwrap(s.exercises.first?.orderedSets.first)
        workouts.completeSet(set, in: s, actualWeight: 100, actualReps: 10)
        workouts.finishWorkout(s)
        let c = WorkoutCorrectionEvent(workoutSessionId: s.id, targetEntity: "WorkoutSessionSet", targetEntityId: set.id,
                                       field: "actualWeight", previousValue: "100.0", correctedValue: "105.0",
                                       source: .seedDemo)
        ctx.insert(c)   // no relationship, as after a restore
        XCTAssertFalse(try check("Demo/user source markers are intact", ctx).passed)

        DataSafetyRepair(ctx).autoRepair()

        XCTAssertEqual(c.source, .user)
        XCTAssertTrue(try check("Demo/user source markers are intact", ctx).passed)
    }

    func testRoutineWithNoVersionsOffersDelete() throws {
        let ctx = TestSupport.makeContext()
        let r = Routine(name: "Empty", source: .user)
        ctx.insert(r)
        let result = try check("Each routine has one active version", ctx)
        XCTAssertFalse(result.autoFixable)
        XCTAssertEqual(result.issues.first?.fixes, [.deleteRoutine(r.id)])

        DataSafetyRepair(ctx).apply(.deleteRoutine(r.id))
        XCTAssertTrue(try check("Each routine has one active version", ctx).passed)
    }

    func testBadPlannedValuesFoundByPredicate() throws {
        let ctx = TestSupport.makeContext()
        let s = finishedWorkout(ctx, TestSupport.buildRoutine(ctx, sets: 2).routine)
        s.exercises.first?.sets.first?.plannedReps = -1
        try ctx.save()
        let result = try check("Snapshot sets have valid planned values", ctx)
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.issues.count, 1)
    }

    /// A stuck workout with nothing logged is offered for deletion, not
    /// "Finish" (finishing would discard it anyway).
    func testStuckEmptyWorkoutOffersDelete() throws {
        let ctx = TestSupport.makeContext()
        let workouts = WorkoutRepository(ctx)
        let s = workouts.startWorkout(from: TestSupport.buildRoutine(ctx).routine)
        workouts.lock(s)
        XCTAssertEqual(try check("Workouts in progress are consistent", ctx).issues.first?.fixes,
                       [.deleteWorkout(s.id)])
    }
}
