//
//  DataSafetyCheckTests.swift
//  WorkoutTrackerTests
//
//  Checks 5 and 6 of the Data Safety Check screen must fail when the thing
//  their titles promise is broken: a correction's original value overwritten
//  or detached, and a source marker that is unknown or differs from its parent.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class DataSafetyCheckTests: XCTestCase {

    private func check(_ title: String, _ ctx: ModelContext) throws -> IntegrityCheck {
        try XCTUnwrap(DataIntegrityService(ctx).runAll().first { $0.title == title })
    }

    /// A finished workout with one completed set (100 × 10) and a correction
    /// to its weight.
    private func correctedWorkout(_ ctx: ModelContext) throws -> (session: WorkoutSession, set: WorkoutSessionSet) {
        let built = TestSupport.buildRoutine(ctx, sets: 1)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: built.routine)
        let set = try XCTUnwrap(session.exercises.first?.orderedSets.first)
        workouts.completeSet(set, in: session, actualWeight: 100, actualReps: 10)
        workouts.finishWorkout(session)
        CorrectionService(ctx).correctActualWeight(set, in: session, to: 105)
        try ctx.save()
        return (session, set)
    }

    func testCorrectionWithIntactOriginalPasses() throws {
        let ctx = TestSupport.makeContext()
        _ = try correctedWorkout(ctx)
        XCTAssertTrue(try check("Corrections preserve originals", ctx).passed)
        XCTAssertTrue(try check("Demo/user source markers are intact", ctx).passed)
    }

    /// The bundled demo data must pass every check, or the screen would flag
    /// a fresh install.
    func testSeededDemoDataPassesEveryCheck() throws {
        let ctx = TestSupport.makeContext()
        SeedDataService(ctx).seed()
        try ctx.save()
        for c in DataIntegrityService(ctx).runAll() {
            XCTAssertTrue(c.passed, "\(c.title) — \(c.detail)")
        }
    }

    func testOverwrittenOriginalFails() throws {
        let ctx = TestSupport.makeContext()
        let (_, set) = try correctedWorkout(ctx)
        set.actualWeight = 105   // the original written over instead of layered
        let result = try check("Corrections preserve originals", ctx)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.detail.contains("1 original value(s) overwritten"), result.detail)
    }

    func testCorrectionToMissingSetFails() throws {
        let ctx = TestSupport.makeContext()
        let (session, set) = try correctedWorkout(ctx)
        session.exercises.first?.sets.removeAll { $0.id == set.id }
        ctx.delete(set)
        let result = try check("Corrections preserve originals", ctx)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.detail.contains("1 point at a missing session or set"), result.detail)
    }

    func testUnknownSourceOnLibraryRecordFails() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        built.exercise.sourceRaw = "imported?"
        XCTAssertFalse(try check("Demo/user source markers are intact", ctx).passed)
    }

    func testVersionWithDifferentSourceFromRoutineFails() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        built.routine.activeVersion!.source = .seedDemo
        let result = try check("Demo/user source markers are intact", ctx)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.detail.contains("1 version(s)"), result.detail)
    }

    func testCorrectionWithDifferentSourceFromSessionFails() throws {
        let ctx = TestSupport.makeContext()
        let (session, _) = try correctedWorkout(ctx)
        session.corrections.first?.source = .seedDemo
        XCTAssertFalse(try check("Demo/user source markers are intact", ctx).passed)
    }

    // MARK: - Check 1: mid-workout is not a failure

    func testWorkoutInProgressWithDoneSetIsNotFlaggedAsUnlockedHistory() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx, sets: 2)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: built.routine)
        let set = try XCTUnwrap(session.exercises.first?.orderedSets.first)
        workouts.completeSet(set, in: session, actualWeight: 100, actualReps: 10)
        XCTAssertEqual(session.status, .partial)   // the state that used to trip check 1
        for c in DataIntegrityService(ctx).runAll() {
            XCTAssertTrue(c.passed, "\(c.title) — \(c.detail)")
        }
    }

    /// Resume used to unlock a stopped workout (removed Oct 2026: a locked
    /// workout is never reopened). Stores can still hold workouts it reopened.
    private func unlockAsBeforeOct2026(_ session: WorkoutSession) {
        session.lockedAt = nil
        session.completedAt = nil
        session.endedAt = nil
        WorkoutRepository(session.modelContext!).recomputeStatus(session)
    }

    func testReopenedWorkoutIsNotFlagged() throws {
        let ctx = TestSupport.makeContext()
        let (session, _) = try correctedWorkout(ctx)
        unlockAsBeforeOct2026(session)
        XCTAssertTrue(try check("Recorded sessions are locked", ctx).passed)
        XCTAssertTrue(try check("Workouts in progress are consistent", ctx).passed)
    }

    // MARK: - Check 7: library membership

    func testRoutineWithDeletedExerciseFails() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        built.exercise.deletedAt = .now   // no cascade, as before Aug 2026
        let result = try check("Routines use only library exercises", ctx)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.detail.hasPrefix("1 routine(s)"), result.detail)
    }

    func testWorkoutInProgressWithDeletedExerciseFails() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        _ = WorkoutRepository(ctx).startWorkout(from: built.routine)
        built.exercise.deletedAt = .now
        let result = try check("Routines use only library exercises", ctx)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.detail.contains("1 workout(s) in progress"), result.detail)
    }

    func testFinishedWorkoutWithDeletedExerciseIsHistoryNotAFailure() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        let workouts = WorkoutRepository(ctx)
        workouts.finishWorkout(workouts.startWorkout(from: built.routine))
        RoutineRepository(ctx).removeExerciseFromAllRoutines(exerciseId: built.exercise.id)
        built.exercise.deletedAt = .now
        XCTAssertTrue(try check("Routines use only library exercises", ctx).passed)
    }

    // R-151: deleting an exercise keeps it in a workout that has work logged
    // on it, so that workout isn't a library problem.
    func testExerciseWithLoggedWorkInAnOpenWorkoutPassesLibraryCheck() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: built.routine)
        let set = try XCTUnwrap(session.exercises.first?.orderedSets.first)
        workouts.completeSet(set, in: session, actualWeight: 100, actualReps: 10)
        RoutineRepository(ctx).removeExerciseFromAllRoutines(exerciseId: built.exercise.id)
        workouts.removeExerciseFromActiveSessions(exerciseId: built.exercise.id)
        built.exercise.deletedAt = .now
        XCTAssertEqual(session.exercises.count, 1, "the logged work stays")

        let result = try check("Routines use only library exercises", ctx)
        XCTAssertTrue(result.passed, result.detail)
        XCTAssertTrue(result.issues.isEmpty, "no fix offered for work that is meant to stay")
    }

    func testPruneClearsLibraryCheck() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        built.exercise.deletedAt = .now
        CatalogSyncService(ctx).pruneExercisesMissingFromLibrary()
        XCTAssertTrue(try check("Routines use only library exercises", ctx).passed)
    }

    // MARK: - Check 8: one active version

    func testRoutineWithTwoActiveVersionsFails() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        TestSupport.finishWithOneSetDone(ctx, built.routine)
        let old = built.routine.activeVersion!
        RoutineRepository(ctx).editRoutine(built.routine, note: "fork") { _ in }
        XCTAssertNotEqual(built.routine.activeVersion!.id, old.id)
        XCTAssertTrue(try check("Each routine has one active version", ctx).passed)
        old.isActive = true
        XCTAssertFalse(try check("Each routine has one active version", ctx).passed)
    }

    func testRoutineWithNoActiveVersionFails() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        built.routine.activeVersion!.isActive = false
        XCTAssertFalse(try check("Each routine has one active version", ctx).passed)
    }

    // MARK: - Check 9: machines

    func testDeletedMachineStillReferencedFails() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        XCTAssertTrue(try check("Machine references are valid", ctx).passed)
        RoutineRepository(ctx).softDelete(try XCTUnwrap(built.machine))
        XCTAssertFalse(try check("Machine references are valid", ctx).passed)
    }

    // MARK: - Check 10: workouts in progress

    func testLockedUnfinishedWorkoutFails() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: built.routine)
        workouts.lock(session)   // locked without being finished
        XCTAssertFalse(try check("Workouts in progress are consistent", ctx).passed)
    }

    func testStartedWorkoutWithoutStartTimeFails() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        let session = WorkoutRepository(ctx).startWorkout(from: built.routine)
        session.startedAt = nil
        XCTAssertFalse(try check("Workouts in progress are consistent", ctx).passed)
    }

    // MARK: - Check 11: audit log

    func testFinishedWorkoutMissingFromAuditLogFails() throws {
        let ctx = TestSupport.makeContext()
        _ = try correctedWorkout(ctx)
        XCTAssertTrue(try check("Audit log is intact", ctx).passed)
        for event in try ctx.fetch(FetchDescriptor<AuditEvent>()) where event.type == "session.finished" {
            ctx.delete(event)
        }
        let result = try check("Audit log is intact", ctx)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.detail.contains("1 finished workout(s) missing"), result.detail)
    }

    func testFutureDatedAuditEventFails() throws {
        let ctx = TestSupport.makeContext()
        ctx.insert(AuditEvent(type: "test", entity: "Test", summary: "",
                              timestamp: .now.addingTimeInterval(86_400)))
        XCTAssertFalse(try check("Audit log is intact", ctx).passed)
    }

    // MARK: - Review follow-ups

    /// Reopening a corrected workout and re-logging the set is allowed; it is
    /// not history being overwritten — before or after finishing it again.
    func testReopenedCorrectedWorkoutRelogIsNotOverwrite() throws {
        let ctx = TestSupport.makeContext()
        let (session, set) = try correctedWorkout(ctx)
        let workouts = WorkoutRepository(ctx)
        unlockAsBeforeOct2026(session)
        workouts.editActual(set, in: session, weight: 110)
        XCTAssertTrue(try check("Corrections preserve originals", ctx).passed)
        workouts.finishWorkout(session, now: .now.addingTimeInterval(1))
        XCTAssertTrue(try check("Corrections preserve originals", ctx).passed)
    }

    /// Backups made before the audit log was exported restore workouts with
    /// no events; those are not "missing from the log".
    func testRestoreWithoutAuditLogPasses() throws {
        let src = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(src)
        let workouts = WorkoutRepository(src)
        workouts.finishWorkout(workouts.startWorkout(from: built.routine))
        for event in try src.fetch(FetchDescriptor<AuditEvent>()) { src.delete(event) }
        try src.save()
        let data = try ExportImportService(src).exportJSONData()

        let dst = TestSupport.makeContext()
        _ = try ExportImportService(dst).importJSON(data)
        try dst.save()
        XCTAssertTrue(try check("Audit log is intact", dst).passed)
    }

    /// A session with a completion time but no lock is unlocked history,
    /// whatever its status says.
    func testCompletedButUnlockedSessionFails() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        let session = WorkoutRepository(ctx).startWorkout(from: built.routine)
        session.completedAt = .now   // status still .started, never locked
        XCTAssertFalse(try check("Recorded sessions are locked", ctx).passed)
    }
}
