//
//  MigrationIntegrityTests.swift
//  WorkoutTrackerTests
//
//  Test 17 + data-integrity guarantees that protect immutable workout history,
//  plus assertions on the migration plan's safety posture.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class MigrationIntegrityTests: XCTestCase {

    // 17a. Integrity checks all pass on a healthy store with recorded history.
    func test17_integrityChecksPass() throws {
        let ctx = TestSupport.makeContext()
        let (routine, _, _) = TestSupport.buildRoutine(ctx, sets: 1)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        workouts.completeSet(session.exercises.flatMap(\.orderedSets).first!, in: session, actualWeight: 100, actualReps: 10)
        workouts.finishWorkout(session)
        try ctx.save()

        let checks = DataIntegrityService(ctx).runAll()
        XCTAssertFalse(checks.isEmpty)
        for check in checks {
            XCTAssertTrue(check.passed, "Integrity check failed: \(check.title) — \(check.detail)")
        }
    }

    // 17b. A locked session's snapshot is stable across a routine "migration"
    //      (new version + heavy edits). Proves history is never overwritten.
    func test17_lockedSnapshotStableAcrossRoutineChange() throws {
        let ctx = TestSupport.makeContext()
        let (routine, _, _) = TestSupport.buildRoutine(ctx, weight: 100, reps: 10, sets: 2)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        for set in session.exercises.flatMap(\.orderedSets) {
            workouts.completeSet(set, in: session, actualWeight: 100, actualReps: 10)
        }
        workouts.finishWorkout(session)
        try ctx.save()

        let snapshotBefore = session.exercises.flatMap(\.orderedSets).map { ($0.plannedWeight, $0.plannedReps, $0.actualWeight, $0.actualReps) }
        let lockedVersionId = session.routineVersionId

        // Simulate aggressive future editing of the routine.
        let repo = RoutineRepository(ctx)
        for _ in 0..<3 {
            let v = repo.makeNewVersion(of: routine)
            v.orderedSections.forEach { section in
                section.exercises.forEach { $0.plannedWeight += 50; $0.plannedReps += 2 }
            }
        }
        try ctx.save()

        let snapshotAfter = session.exercises.flatMap(\.orderedSets).map { ($0.plannedWeight, $0.plannedReps, $0.actualWeight, $0.actualReps) }
        XCTAssertEqual(snapshotBefore.map(\.0), snapshotAfter.map(\.0))
        XCTAssertEqual(snapshotBefore.map(\.1), snapshotAfter.map(\.1))
        XCTAssertEqual(snapshotBefore.map(\.2), snapshotAfter.map(\.2))
        XCTAssertEqual(snapshotBefore.map(\.3), snapshotAfter.map(\.3))
        // The session still points at the version it was recorded against.
        XCTAssertEqual(session.routineVersionId, lockedVersionId)
        XCTAssertNotEqual(routine.activeVersion?.id, lockedVersionId)
    }

    // 17c. The migration plan is configured and currently has NO destructive
    //      stages. This guards against someone adding an unsafe migration later
    //      without also updating/justifying this test.
    func test17_migrationPlanIsSafe() {
        XCTAssertTrue(WorkoutMigrationPlan.schemas.contains {
            ObjectIdentifier($0) == ObjectIdentifier(WorkoutSchemaV1.self)
        })
        XCTAssertEqual(WorkoutSchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
        // No migration stages yet — additive-only posture. If you add a stage,
        // it must be reviewed to ensure it never deletes/overwrites history.
        XCTAssertTrue(WorkoutMigrationPlan.stages.isEmpty)
    }

    // 17d. In-memory container builds from the versioned schema + plan.
    func test17_containerBuildsFromVersionedSchema() throws {
        let container = AppContainer.makeInMemory()
        XCTAssertNotNil(container.mainContext)
    }
}
