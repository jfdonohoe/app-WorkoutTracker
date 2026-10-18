//
//  AuditFixesTests.swift
//  WorkoutTrackerTests
//
//  Regression tests for the 2026-10-17 codebase audit fixes
//  (_reports/2026-10-17-codebase-audit.md).
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class AuditFixesTests: XCTestCase {

    // H4: done sets needn't come first.
    func testMarkingSetOneNotDoneKeepsEverySetInItsPlace() throws {
        let ctx = TestSupport.makeContext()
        let (routine, exercise, _) = TestSupport.buildRoutine(ctx, weight: 100, reps: 10, sets: 3)
        // The library prescription the reconcile re-plans from: 3 × 10 @ 100.
        for i in 0..<3 {
            let d = ExerciseDefaultSet(order: i, reps: 10, weight: 100)
            d.exercise = exercise
            exercise.defaultSets.append(d)
            ctx.insert(d)
        }
        let repo = WorkoutRepository(ctx)
        let session = repo.startWorkout(from: routine)
        let se = try XCTUnwrap(session.exercises.first)
        let sets = se.orderedSets
        repo.completeSet(sets[0], in: session, actualWeight: 100, actualReps: 10)
        repo.completeSet(sets[1], in: session, actualWeight: 105, actualReps: 8)
        repo.uncompleteSet(sets[0], in: session)
        try ctx.save()

        CatalogSyncService(ctx).reconcileExercise(exercise.id)
        CatalogSyncService(ctx).reconcileSession(session)

        let after = se.orderedSets
        XCTAssertEqual(after.map(\.index), [0, 1, 2], "no duplicate or missing set numbers")
        guard after.count == 3 else { return }
        XCTAssertEqual(after.map(\.isCompleted), [false, true, false])
        XCTAssertEqual(after[1].id, sets[1].id, "the done set stays where it was")
        XCTAssertEqual(after[1].actualWeight, 105)
    }

    // H5: an unfinished workout on a demo routine is the user's.
    func testDemoCleanupKeepsAnUnfinishedWorkoutOnADemoRoutine() throws {
        let ctx = TestSupport.makeContext()
        let routine = RoutineRepository(ctx).createRoutine(name: "Demo Upper", source: .seedDemo)
        let version = try XCTUnwrap(routine.activeVersion)
        let section = RoutineRepository(ctx).addSection(to: version, type: .strength)
        let ex = Exercise(name: "Demo Press", source: .seedDemo)
        ctx.insert(ex)
        RoutineRepository(ctx).addExercise(to: section, exercise: ex, setCount: 2, plannedWeight: 50, plannedReps: 10)
        let repo = WorkoutRepository(ctx)
        let session = repo.startWorkout(from: routine)
        XCTAssertEqual(session.source, .seedDemo)
        let set = try XCTUnwrap(session.exercises.first?.orderedSets.first)
        repo.completeSet(set, in: session, actualWeight: 50, actualReps: 10)
        try ctx.save()

        _ = DemoDataManager(ctx).deleteAllDemoData()
        try ctx.save()

        let kept = try ctx.fetch(FetchDescriptor<WorkoutSession>()).first { $0.id == session.id }
        XCTAssertNotNil(kept, "the logged set isn't deleted with the demo data")
        XCTAssertEqual(kept?.source, .user)

        // Its exercise is gone from the library now; a later clean-up of
        // exercises missing from the library mustn't take the logged work.
        _ = CatalogSyncService(ctx).pruneExercisesMissingFromLibrary()
        try ctx.save()
        XCTAssertEqual(kept?.exercises.count, 1)
        XCTAssertTrue(kept?.hasAnythingDone ?? false)
    }

    // M6: an exercise finished while the phone was locked keeps its real end.
    func testGuidedCatchUpReportsWhenTheExerciseActuallyEnded() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let se = WorkoutSessionExercise(name: "Elliptical", sectionType: .cardio, order: 0, plannedRestBetweenSets: 0)
        se.kindRaw = ExerciseKind.steady.rawValue
        se.durationMinutes = 10
        let timer = GuidedTimerService()
        var endedAt: Date?
        timer.onExerciseFinished = { _ in endedAt = timer.lastExerciseEndedAt }
        timer.start(phases: GuidedPlan.phases(for: [se]), finishedTitle: "", now: t0)
        timer.tick(now: t0.addingTimeInterval(3600))     // back an hour later
        XCTAssertEqual(endedAt, t0.addingTimeInterval(600))
    }

    // L9: rests changed mid-run reach the steps not started yet.
    func testChangingRestsMidRunUpdatesTheStepsAhead() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func stretch(_ n: String, _ o: Int) -> WorkoutSessionExercise {
            let se = WorkoutSessionExercise(name: n, sectionType: .stretching, order: o, plannedRestBetweenSets: 0)
            se.kindRaw = ExerciseKind.staticStretch.rawValue
            se.holdSeconds = 30; se.reps = 1; se.setCount = 1; se.perSideRaw = PerSide.leftRight.rawValue
            return se
        }
        let timer = GuidedTimerService()
        timer.start(phases: GuidedPlan.phases(for: [stretch("A", 0), stretch("B", 1)]), finishedTitle: "", now: t0)
        var r = TypeRests.standard; r.stretchWithin = 8; r.stretchBetween = 0
        timer.updateRests(r, now: t0.addingTimeInterval(1))
        XCTAssertEqual(timer.phases.filter(\.isTransition).map(\.seconds), [8, 8], "into B dropped; sides take 8 s")
        timer.stop()
    }

    // M3: restore through the id lookups links children to parents restored earlier.
    func testRestoreLinksRestoredRecordsTogether() throws {
        let ctx = TestSupport.makeContext()
        let routine = TestSupport.buildRoutine(ctx, sets: 4).routine
        for _ in 0..<3 { TestSupport.finishWithOneSetDone(ctx, routine) }
        try ctx.save()
        let data = try ExportImportService(ctx).exportJSONData()
        let restored = TestSupport.makeContext()
        _ = try ExportImportService(restored).importJSON(data)
        let sessions = try restored.fetch(FetchDescriptor<WorkoutSession>())
        XCTAssertEqual(sessions.count, 3)
        XCTAssertTrue(sessions.allSatisfy { !$0.exercises.isEmpty && $0.exercises.allSatisfy { $0.sets.count == 4 } })
        let r = try XCTUnwrap(try restored.fetch(FetchDescriptor<Routine>()).first { $0.id == routine.id })
        XCTAssertEqual(r.versions.count, routine.versions.count)
        XCTAssertFalse(r.activeVersion?.sections.isEmpty ?? true)
    }
}
