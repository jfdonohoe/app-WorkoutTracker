//
//  SplitAuditFixesTests.swift
//  WorkoutTrackerTests
//
//  Regression tests for the 2026-10-18 split audit fixes
//  (_reports/2026-10-18-split-vs-broad-audit.md; registry rows O-001…O-015).
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class SplitAuditFixesTests: XCTestCase {

    private func startDistance(_ ctx: ModelContext) -> (WorkoutSession, WorkoutSessionExercise) {
        let e = Exercise(name: "Run")
        ctx.insert(e)
        e.kind = .distance
        e.distance = 5
        ExerciseLegacyFields.write(e, machines: [], context: ctx)
        let repo = RoutineRepository(ctx)
        let routine = repo.createRoutine(name: "Run")
        let section = repo.addSection(to: routine.activeVersion!, type: ExerciseKind.distance.section)
        repo.addExercise(to: section, exercise: e, plannedSets: e.effectiveDefaultSets, restBetweenSets: 60)
        let session = WorkoutRepository(ctx).startWorkout(from: routine)
        return (session, session.exercises.first!)
    }

    // O-001: a logged distance, not marked complete, finishes as partial.
    func testDistanceOnlyWorkoutFinishesPartialNotStarted() throws {
        let ctx = TestSupport.makeContext()
        let (session, se) = startDistance(ctx)
        se.actualDistance = 3
        WorkoutRepository(ctx).finishWorkout(session)

        XCTAssertTrue(session.isLocked)
        XCTAssertNil(session.deletedAt, "a logged distance is history, not discarded")
        XCTAssertEqual(session.status, .partial)
    }

    func testDistanceMarkedCompleteFinishesCompleted() throws {
        let ctx = TestSupport.makeContext()
        let (session, se) = startDistance(ctx)
        se.actualDistance = 5
        se.markedCompleteAt = .now
        WorkoutRepository(ctx).finishWorkout(session)

        XCTAssertEqual(session.status, .completed)
    }

    // O-002: restore doesn't bring back a section deleted on the device.
    func testRestoreDoesNotReattachADeletedSection() throws {
        let ctx = TestSupport.makeContext()
        let (routine, _, _) = TestSupport.buildRoutine(ctx)
        let version = try XCTUnwrap(routine.activeVersion)
        RoutineRepository(ctx).addSection(to: version, type: .stretching)
        try ctx.save()
        XCTAssertEqual(version.sections.count, 2)
        let backup = try ExportImportService(ctx).exportJSONData()

        let stretching = try XCTUnwrap(version.sections.first { $0.type == .stretching })
        version.sections.removeAll { $0.id == stretching.id }
        ctx.delete(stretching)
        try ctx.save()
        _ = try ExportImportService(ctx).importJSON(backup)
        try ctx.save()

        XCTAssertEqual(version.sections.map(\.type), [.strength])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<RoutineSection>()), 1)
    }

    func testRestoreIntoEmptyStoreStillBringsSectionsAndExercises() throws {
        let source = TestSupport.makeContext()
        TestSupport.buildRoutine(source)
        let backup = try ExportImportService(source).exportJSONData()

        let ctx = TestSupport.makeContext()
        _ = try ExportImportService(ctx).importJSON(backup)
        try ctx.save()

        let routine = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Routine>()).first)
        let section = try XCTUnwrap(routine.activeVersion?.sections.first)
        XCTAssertEqual(section.exercises.count, 1)
    }

    // O-002: nor a routine exercise deleted on the device.
    func testRestoreDoesNotReattachADeletedRoutineExercise() throws {
        let ctx = TestSupport.makeContext()
        let (routine, _, _) = TestSupport.buildRoutine(ctx)
        let section = try XCTUnwrap(routine.activeVersion?.sections.first)
        let row = Exercise(name: "Row", source: .user)
        ctx.insert(row)
        RoutineRepository(ctx).addExercise(to: section, exercise: row, setCount: 2, plannedWeight: 40, plannedReps: 12)
        try ctx.save()
        XCTAssertEqual(section.exercises.count, 2)
        let backup = try ExportImportService(ctx).exportJSONData()

        let removed = try XCTUnwrap(section.exercises.first { $0.exerciseId == row.id })
        section.exercises.removeAll { $0.id == removed.id }
        ctx.delete(removed)
        try ctx.save()
        _ = try ExportImportService(ctx).importJSON(backup)
        try ctx.save()

        XCTAssertEqual(section.exercises.count, 1)
        XCTAssertFalse(section.exercises.contains { $0.exerciseId == row.id })
    }

    // O-005: Delete Demo Data keeps a kept workout's audit trail.
    func testDemoCleanupKeepsAKeptWorkoutsAuditEvents() throws {
        let ctx = TestSupport.makeContext()
        let routines = RoutineRepository(ctx)
        let routine = routines.createRoutine(name: "Demo Upper", source: .seedDemo)
        let section = routines.addSection(to: try XCTUnwrap(routine.activeVersion), type: .strength)
        let ex = Exercise(name: "Demo Press", source: .seedDemo)
        ctx.insert(ex)
        routines.addExercise(to: section, exercise: ex, setCount: 2, plannedWeight: 50, plannedReps: 10)
        let session = TestSupport.finishWithOneSetDone(ctx, routine)
        XCTAssertEqual(session.source, .seedDemo)
        let set = try XCTUnwrap(session.exercises.flatMap(\.orderedSets).first { $0.isCompleted })
        CorrectionService(ctx).correctActualWeight(set, in: session, to: 55)
        try ctx.save()
        // started and finished are keyed by the workout; the correction by the set.
        let keys: [UUID?] = [session.id, set.id]
        let before = try ctx.fetch(FetchDescriptor<AuditEvent>()).filter { keys.contains($0.entityId) }
        XCTAssertGreaterThanOrEqual(before.count, 3, "started, finished, corrected")

        DemoDataManager(ctx).deleteAllDemoData()
        try ctx.save()

        let after = try ctx.fetch(FetchDescriptor<AuditEvent>()).filter { keys.contains($0.entityId) }
        XCTAssertEqual(Set(after.map(\.id)), Set(before.map(\.id)))
        XCTAssertTrue(after.allSatisfy { $0.source == .user })
    }

    // O-008: once work is logged, a library change doesn't move the exercise
    // to another machine; one not started yet still follows the library.
    func testReconcileKeepsTheMachineOfAnExerciseWithWorkLogged() throws {
        let ctx = TestSupport.makeContext()
        let (routine, exercise, machine) = TestSupport.buildRoutine(ctx, sets: 2)
        let first = try XCTUnwrap(machine)
        let other = Machine(name: "Other", source: .user)
        ctx.insert(other)
        let repo = WorkoutRepository(ctx)
        let started = repo.startWorkout(from: routine)
        let untouched = repo.startWorkout(from: routine)
        let set = try XCTUnwrap(started.exercises.first?.orderedSets.first)
        repo.completeSet(set, in: started, actualWeight: 100, actualReps: 10)
        try ctx.save()

        exercise.machineIds = [other.id]
        CatalogSyncService(ctx).reconcileExercise(exercise.id)

        XCTAssertEqual(started.exercises.first?.machineId, first.id)
        XCTAssertEqual(untouched.exercises.first?.machineId, other.id)
        XCTAssertEqual(set.actualWeight, 100)
    }

    // O-008: nor rewrite the structure (sides, reps) it is being done in.
    func testReconcileKeepsTheStructureOfAnExerciseWithWorkLogged() throws {
        let ctx = TestSupport.makeContext()
        let e = Exercise(name: "Curl")
        ctx.insert(e)
        e.kind = .freeWeight
        e.reps = 10; e.sets = 2; e.weight = 20
        ExerciseLegacyFields.write(e, machines: [], context: ctx)
        let routines = RoutineRepository(ctx)
        let routine = routines.createRoutine(name: "Arms")
        let section = routines.addSection(to: routine.activeVersion!, type: .strength)
        routines.addExercise(to: section, exercise: e, plannedSets: e.effectiveDefaultSets, restBetweenSets: 60)
        let repo = WorkoutRepository(ctx)
        let started = repo.startWorkout(from: routine)
        let untouched = repo.startWorkout(from: routine)
        let set = try XCTUnwrap(started.exercises.first?.orderedSets.first)
        repo.completeSet(set, in: started, actualWeight: 20, actualReps: 10)
        try ctx.save()

        e.perSide = .leftRight
        e.reps = 6
        CatalogSyncService(ctx).reconcileExercise(e.id)

        XCTAssertEqual(started.exercises.first?.reps, 10)
        XCTAssertEqual(started.exercises.first?.perSideRaw, PerSide.single.rawValue)
        XCTAssertEqual(untouched.exercises.first?.reps, 6)
        XCTAssertEqual(untouched.exercises.first?.perSideRaw, PerSide.leftRight.rawValue)
    }

    // O-009: a sheet-imported schedule for a demo routine is demo.
    func testSheetScheduleForADemoRoutineIsDemo() throws {
        let ctx = TestSupport.makeContext()
        let demo = TestSupport.buildRoutine(ctx, name: "Upper").routine
        demo.source = .seedDemo
        let mine = TestSupport.buildRoutine(ctx, name: "Lower").routine
        try ctx.save()
        let days = ["Monday,Upper,Lower", "Tuesday,,", "Wednesday,,", "Thursday,,", "Friday,,", "Saturday,,", "Sunday,,"]
        let text = "start_date,2026-10-19\n\nday,week_1,week_2\n" + days.joined(separator: "\n") + "\n"
        _ = try SheetScheduleImporter(ctx).importText(text, today: SheetScheduleImporter.parseDate("2026-10-19")!)

        let rules = try ctx.fetch(FetchDescriptor<ScheduleRule>()).filter { $0.deletedAt == nil }
        XCTAssertEqual(rules.first { $0.routineId == demo.id }?.source, .seedDemo)
        XCTAssertEqual(rules.first { $0.routineId == mine.id }?.source, .user)
    }

    // O-011: a deleted user routine isn't data of the user's own.
    func testADeletedUserRoutineDoesNotCountAsUserData() throws {
        let ctx = TestSupport.makeContext()
        let routine = RoutineRepository(ctx).createRoutine(name: "New Routine")
        try ctx.save()
        XCTAssertTrue(SeedDataService(ctx).hasExistingUserData())

        RoutineRepository(ctx).softDelete(routine)
        try ctx.save()
        XCTAssertFalse(SeedDataService(ctx).hasExistingUserData())
    }

    // O-015: the weekday header starts where the grid does.
    func testWeekdayHeaderStartsOnTheCalendarsFirstWeekday() {
        var monday = Calendar(identifier: .gregorian)
        monday.locale = Locale(identifier: "en_GB")
        monday.firstWeekday = 2
        XCTAssertEqual(CalendarView.weekdaySymbols(for: monday),
                       ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])

        var sunday = Calendar(identifier: .gregorian)
        sunday.locale = Locale(identifier: "en_US")
        sunday.firstWeekday = 1
        XCTAssertEqual(CalendarView.weekdaySymbols(for: sunday).first, "Sun")
    }

    // O-014: the palette is light-only, so the app is locked to Light appearance.
    func testAppIsLockedToLightAppearance() {
        // The test host is the app, so this reads the built app's Info.plist.
        XCTAssertEqual(Bundle.main.infoDictionary?["UIUserInterfaceStyle"] as? String, "Light")
    }
}
