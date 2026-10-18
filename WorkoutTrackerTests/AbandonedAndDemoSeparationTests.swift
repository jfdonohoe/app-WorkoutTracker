//
//  AbandonedAndDemoSeparationTests.swift
//  WorkoutTrackerTests
//
//  A workout finished with nothing done is discarded, not kept as history.
//  Demo and user data never mix: pickers, CSV imports and the Data Safety
//  Check all keep them apart.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class AbandonedAndDemoSeparationTests: XCTestCase {

    // MARK: - Abandoned workouts

    func testFinishingWithNothingDoneDiscardsTheWorkout() throws {
        let ctx = TestSupport.makeContext()
        let workouts = WorkoutRepository(ctx)
        let s = workouts.startWorkout(from: TestSupport.buildRoutine(ctx).routine)

        workouts.finishWorkout(s)

        XCTAssertNotNil(s.deletedAt)           // hidden at once
        XCTAssertEqual(s.status, .abandoned)
        let events = try ctx.fetch(FetchDescriptor<AuditEvent>()).map(\.type)
        XCTAssertTrue(events.contains("session.discarded"))
        XCTAssertFalse(events.contains("session.finished"))

        // Kept until tomorrow (stops Today auto-starting it again), then gone.
        XCTAssertEqual(workouts.purgeDiscardedWorkouts(), 0)
        XCTAssertEqual(workouts.purgeDiscardedWorkouts(now: .now.addingTimeInterval(86_400)), 1)
        try ctx.save()
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<WorkoutSession>()).isEmpty)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<WorkoutSessionExercise>()).isEmpty)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<WorkoutSessionSet>()).isEmpty)
    }

    func testFinishingWithASetDoneKeepsTheWorkout() throws {
        let ctx = TestSupport.makeContext()
        let workouts = WorkoutRepository(ctx)
        let s = workouts.startWorkout(from: TestSupport.buildRoutine(ctx, sets: 2).routine)
        let set = try XCTUnwrap(s.exercises.first?.orderedSets.first)
        workouts.completeSet(set, in: s, actualWeight: 100, actualReps: 10)

        workouts.finishWorkout(s)

        XCTAssertNil(s.deletedAt)
        XCTAssertEqual(s.status, .partial)
        XCTAssertEqual(workouts.purgeDiscardedWorkouts(), 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<WorkoutSession>()).count, 1)
    }

    func testRestoringBackupWithAbandonedWorkoutDropsIt() throws {
        let src = TestSupport.makeContext()
        let s = WorkoutRepository(src).startWorkout(from: TestSupport.buildRoutine(src).routine)
        s.status = .abandoned          // as saved by earlier versions, on an earlier day
        s.startedAt = .now.addingTimeInterval(-86_400)
        s.completedAt = s.startedAt
        s.lockedAt = s.startedAt
        try src.save()
        let backup = try ExportImportService(src).exportJSONData()

        let dst = TestSupport.makeContext()
        _ = try ExportImportService(dst).importJSON(backup)
        try dst.save()

        XCTAssertTrue(try dst.fetch(FetchDescriptor<WorkoutSession>()).isEmpty)
    }

    // MARK: - Demo / user separation

    func testPickerOffersOnlyExercisesOfTheSameSource() throws {
        let ctx = TestSupport.makeContext()
        let mine = Exercise(name: "Mine", source: .user)
        let demo = Exercise(name: "Demo", source: .seedDemo)
        ctx.insert(mine); ctx.insert(demo)

        XCTAssertEqual(ExercisePickerSheet.offered([mine, demo], group: nil, source: .user).map(\.name), ["Mine"])
        XCTAssertEqual(ExercisePickerSheet.offered([mine, demo], group: nil, source: .seedDemo).map(\.name), ["Demo"])
    }

    func testSeparationCheckFlagsUserRoutineUsingDemoExercise() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx, name: "My Routine")
        XCTAssertTrue(try check(ctx).passed)

        built.exercise.source = .seedDemo   // as if added before the picker filtered
        let result = try check(ctx)
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.issues.first?.title, "My Routine")
    }

    func testSeparationCheckFlagsExerciseUsingOtherSourcesMachine() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        try XCTUnwrap(built.machine).source = .seedDemo
        XCTAssertFalse(try check(ctx).passed)
    }

    func testDemoSeedAlongsideUserDataStaysSeparate() throws {
        let ctx = TestSupport.makeContext()
        TestSupport.buildRoutine(ctx, name: "My Routine")
        SeedDataService(ctx).seed()
        try ctx.save()
        XCTAssertTrue(try check(ctx).passed)
    }

    private func check(_ ctx: ModelContext) throws -> IntegrityCheck {
        try XCTUnwrap(DataIntegrityService(ctx).runAll().first { $0.title == "Demo and your data are separate" })
    }

    // MARK: - Review follow-ups

    func testEmptyWorkoutLeftOpenOnEarlierDayIsPurged() throws {
        let ctx = TestSupport.makeContext()
        let workouts = WorkoutRepository(ctx)
        let s = workouts.startWorkout(from: TestSupport.buildRoutine(ctx).routine,
                                      now: .now.addingTimeInterval(-2 * 86_400))
        XCTAssertNil(s.completedAt)
        XCTAssertEqual(workouts.purgeDiscardedWorkouts(), 1)
    }

    func testOpenWorkoutWithASetDoneIsNeverPurged() throws {
        let ctx = TestSupport.makeContext()
        let workouts = WorkoutRepository(ctx)
        let s = workouts.startWorkout(from: TestSupport.buildRoutine(ctx, sets: 2).routine,
                                      now: .now.addingTimeInterval(-2 * 86_400))
        let set = try XCTUnwrap(s.exercises.first?.orderedSets.first)
        workouts.completeSet(set, in: s, actualWeight: 100, actualReps: 10)
        s.status = .abandoned   // even with the label, something was logged
        XCTAssertEqual(workouts.purgeDiscardedWorkouts(), 0)
    }

    func testTodaysEmptyWorkoutInProgressIsKept() throws {
        let ctx = TestSupport.makeContext()
        _ = WorkoutRepository(ctx).startWorkout(from: TestSupport.buildRoutine(ctx).routine)
        XCTAssertEqual(WorkoutRepository(ctx).purgeDiscardedWorkouts(), 0)
    }

    func testCopyOfDemoRoutineStaysDemo() throws {
        let ctx = TestSupport.makeContext()
        SeedDataService(ctx).seed()
        let demo = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Routine>()).first { $0.source == .seedDemo })
        let copy = RoutineRepository(ctx).cloneRoutine(demo, newName: demo.name + " (edited)")
        XCTAssertEqual(copy.source, .seedDemo)
        XCTAssertEqual(copy.activeVersion?.source, .seedDemo)
        try ctx.save()
        XCTAssertTrue(try XCTUnwrap(DataIntegrityService(ctx).runAll()
            .first { $0.title == "Demo and your data are separate" }).passed)

        DemoDataManager(ctx).deleteAllDemoData()
        try ctx.save()
        XCTAssertFalse(try ctx.fetch(FetchDescriptor<Routine>()).contains { $0.id == copy.id })
    }

    func testScheduleForDemoRoutineIsDemoAndGoesWithIt() throws {
        let ctx = TestSupport.makeContext()
        SeedDataService(ctx).seed()
        let demo = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Routine>()).first { $0.source == .seedDemo })
        let rule = RecurrenceState().buildRule(routineId: demo.id, source: demo.source)
        ctx.insert(rule)
        XCTAssertEqual(rule.source, .seedDemo)
        DemoDataManager(ctx).deleteAllDemoData()
        try ctx.save()
        XCTAssertFalse(try ctx.fetch(FetchDescriptor<ScheduleRule>()).contains { $0.id == rule.id })
    }
}
