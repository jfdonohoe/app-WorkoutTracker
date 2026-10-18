//
//  RestoreSetMergeTests.swift
//  WorkoutTrackerTests
//
//  Restoring an older backup over an exercise whose sets were edited since
//  turned 2 sets into 4: saving sets replaces the rows with new ids, and
//  restore merged sets by id, so the backup's older rows were appended
//  alongside the current ones. Sets now follow their parent — when the
//  exercise already exists, the device's sets win.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class RestoreSetMergeTests: XCTestCase {

    private func defaults(_ exercise: Exercise) -> [Int] {
        exercise.defaultSets.sorted { $0.order < $1.order }.map(\.reps)
    }

    func testRestoringOlderBackupKeepsCurrentExerciseSets() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        let repo = RoutineRepository(ctx)
        repo.updateExerciseDefaults(exerciseId: built.exercise.id, sets: [(reps: 10, weight: 50), (reps: 10, weight: 50)])
        try ctx.save()
        let backup = try ExportImportService(ctx).exportJSONData()

        repo.updateExerciseDefaults(exerciseId: built.exercise.id, sets: [(reps: 8, weight: 60), (reps: 8, weight: 60)])
        try ctx.save()
        _ = try ExportImportService(ctx).importJSON(backup)
        try ctx.save()

        XCTAssertEqual(defaults(built.exercise), [8, 8])
    }

    func testRestoringOlderBackupKeepsCurrentRoutinePlannedSets() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx, sets: 2)
        let re = try XCTUnwrap(built.routine.activeVersion?.sections.flatMap(\.exercises).first)
        let repo = RoutineRepository(ctx)
        repo.setPlannedSets(re, sets: [(reps: 10, weight: 50), (reps: 10, weight: 50)], restBetweenSets: 60)
        XCTAssertEqual(re.plannedSets.count, 2)
        try ctx.save()
        let backup = try ExportImportService(ctx).exportJSONData()

        repo.setPlannedSets(re, sets: [(reps: 6, weight: 80), (reps: 6, weight: 80)], restBetweenSets: 60)
        try ctx.save()
        _ = try ExportImportService(ctx).importJSON(backup)
        try ctx.save()

        XCTAssertEqual(re.plannedSets.sorted { $0.order < $1.order }.map(\.plannedReps), [6, 6])
    }

    func testRestoringIntoEmptyStoreBringsSets() throws {
        let src = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(src, sets: 2)
        let repo = RoutineRepository(src)
        repo.updateExerciseDefaults(exerciseId: built.exercise.id, sets: [(reps: 10, weight: 50), (reps: 12, weight: 40)])
        let srcRE = try XCTUnwrap(built.routine.activeVersion?.sections.flatMap(\.exercises).first)
        repo.setPlannedSets(srcRE, sets: [(reps: 10, weight: 50), (reps: 12, weight: 40)], restBetweenSets: 60)
        try src.save()
        let backup = try ExportImportService(src).exportJSONData()

        let dst = TestSupport.makeContext()
        _ = try ExportImportService(dst).importJSON(backup)
        try dst.save()

        let exercise = try XCTUnwrap(try dst.fetch(FetchDescriptor<Exercise>()).first)
        XCTAssertEqual(defaults(exercise), [10, 12])
        let re = try XCTUnwrap(try dst.fetch(FetchDescriptor<RoutineExercise>()).first)
        XCTAssertEqual(re.plannedSets.count, 2)
    }
}
