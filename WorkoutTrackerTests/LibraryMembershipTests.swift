//
//  LibraryMembershipTests.swift
//  WorkoutTrackerTests
//
//  Routines may only use exercises from the library. Exercises deleted before
//  the delete cascade existed (Aug 2026) stayed in routines — e.g. Hip
//  Abduction, deleted 2026-07-14 but still in Workout A and B — and a backup
//  restore brought them back. CatalogSyncService.pruneExercisesMissingFromLibrary
//  removes them; a deleted exercise can no longer be edited through a routine.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class LibraryMembershipTests: XCTestCase {

    /// Soft-delete WITHOUT the cascade — the pre-Aug-2026 behaviour.
    private func legacyDelete(_ exercise: Exercise) {
        exercise.deletedAt = .now
        exercise.updatedAt = .now
    }

    private func exerciseIds(in routine: Routine) -> [UUID] {
        routine.activeVersion!.sections.flatMap(\.exercises).map(\.exerciseId)
    }

    func testPruneRemovesSoftDeletedExerciseFromEveryRoutine() throws {
        let ctx = TestSupport.makeContext()
        let a = TestSupport.buildRoutine(ctx, name: "A")
        let b = TestSupport.buildRoutine(ctx, name: "B")
        // The same library exercise in both routines.
        let repo = RoutineRepository(ctx)
        let bSection = b.routine.activeVersion!.orderedSections[0]
        repo.addExercise(to: bSection, exercise: a.exercise)
        try ctx.save()

        legacyDelete(a.exercise)
        try ctx.save()
        XCTAssertTrue(exerciseIds(in: a.routine).contains(a.exercise.id))

        let pruned = CatalogSyncService(ctx).pruneExercisesMissingFromLibrary()
        try ctx.save()

        XCTAssertEqual(pruned, [a.exercise.id])
        XCTAssertFalse(exerciseIds(in: a.routine).contains(a.exercise.id))
        XCTAssertFalse(exerciseIds(in: b.routine).contains(a.exercise.id))
        // B's own (live) exercise is untouched.
        XCTAssertEqual(exerciseIds(in: b.routine), [b.exercise.id])
    }

    func testPruneRemovesReferenceToMissingExercise() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        ctx.delete(built.exercise)
        try ctx.save()

        CatalogSyncService(ctx).pruneExercisesMissingFromLibrary()
        try ctx.save()

        XCTAssertTrue(exerciseIds(in: built.routine).isEmpty)
    }

    func testPruneKeepsHistoryAndForksReferencedVersion() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        let finished = TestSupport.finishWithOneSetDone(ctx, built.routine)
        let oldVersion = built.routine.activeVersion!
        try ctx.save()

        legacyDelete(built.exercise)
        CatalogSyncService(ctx).pruneExercisesMissingFromLibrary()
        try ctx.save()

        // The version history points at is unchanged; a new version drops it.
        XCTAssertEqual(oldVersion.sections.flatMap(\.exercises).map(\.exerciseId), [built.exercise.id])
        XCTAssertNotEqual(built.routine.activeVersion!.id, oldVersion.id)
        XCTAssertTrue(exerciseIds(in: built.routine).isEmpty)
        // The finished workout keeps its exercise.
        XCTAssertEqual(finished.exercises.count, 1)
    }

    func testPruneRemovesExerciseFromCurrentWorkout() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        let current = WorkoutRepository(ctx).startWorkout(from: built.routine)
        try ctx.save()

        legacyDelete(built.exercise)
        CatalogSyncService(ctx).pruneExercisesMissingFromLibrary()
        try ctx.save()

        XCTAssertTrue(current.exercises.isEmpty)
    }

    /// A restored backup can leave no version flagged isActive; the app then
    /// uses the newest version, so that is the one pruned.
    func testPruneUsesFallbackActiveVersion() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        built.routine.activeVersion!.isActive = false
        legacyDelete(built.exercise)
        try ctx.save()

        CatalogSyncService(ctx).pruneExercisesMissingFromLibrary()
        try ctx.save()

        XCTAssertTrue(exerciseIds(in: built.routine).isEmpty)
        XCTAssertTrue(built.routine.activeVersion!.sections.allSatisfy { $0.exercises.isEmpty })
    }

    func testPruneIsNoOpWhenEveryExerciseIsInLibrary() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        let versionId = built.routine.activeVersion!.id

        XCTAssertTrue(CatalogSyncService(ctx).pruneExercisesMissingFromLibrary().isEmpty)
        XCTAssertEqual(built.routine.activeVersion!.id, versionId)
        XCTAssertEqual(exerciseIds(in: built.routine), [built.exercise.id])
    }

    func testRestoringBackupDropsDeletedExerciseFromRoutines() throws {
        let src = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(src)
        legacyDelete(built.exercise)
        try src.save()
        let data = try ExportImportService(src).exportJSONData()

        let dst = TestSupport.makeContext()
        _ = try ExportImportService(dst).importJSON(data)
        try dst.save()

        let routine = try XCTUnwrap(try dst.fetch(FetchDescriptor<Routine>()).first)
        XCTAssertTrue(exerciseIds(in: routine).isEmpty)
    }

    func testDeletedExerciseDefaultsCannotBeEdited() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        RoutineRepository(ctx).updateExerciseDefaults(exerciseId: built.exercise.id,
                                                      sets: [(reps: 5, weight: 10)])
        legacyDelete(built.exercise)
        let stamp = built.exercise.updatedAt

        RoutineRepository(ctx).updateExerciseDefaults(exerciseId: built.exercise.id,
                                                      sets: [(reps: 12, weight: 50)])

        XCTAssertEqual(built.exercise.updatedAt, stamp)
        XCTAssertEqual(built.exercise.defaultSets.map(\.reps), [5])
    }
}
