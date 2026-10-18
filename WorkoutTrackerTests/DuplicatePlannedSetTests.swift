//
//  DuplicatePlannedSetTests.swift
//  WorkoutTrackerTests
//
//  Restores before the 2026-10-16 fix added a backup's older planned sets
//  next to a routine exercise's current ones (2 sets became 4) — seen in
//  Workout A v5 after the Oct 13 restore of the Sept 8 backup.
//  CatalogSyncService.removeDuplicatePlannedSets keeps one row per position.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class DuplicatePlannedSetTests: XCTestCase {

    private func routineExercise(_ routine: Routine) throws -> RoutineExercise {
        try XCTUnwrap(routine.activeVersion?.sections.flatMap(\.exercises).first)
    }

    /// Plan `sets` the way the app does (summary written with the rows), then
    /// add `stale` rows the way an old restore did (rows only).
    private func duplicate(_ ctx: ModelContext, _ re: RoutineExercise,
                           current: [(reps: Int, weight: Double)],
                           stale: [(reps: Int, weight: Double)]) {
        RoutineRepository(ctx).setPlannedSets(re, sets: current, restBetweenSets: 60)
        for (i, s) in stale.enumerated() {
            let row = RoutinePlannedSet(order: i, plannedReps: s.reps, plannedWeight: s.weight)
            row.exercise = re
            re.plannedSets.append(row)
            ctx.insert(row)
        }
    }

    private func planned(_ re: RoutineExercise) -> [String] {
        re.plannedSets.sorted { $0.order < $1.order }.map { "\($0.order):\($0.plannedReps)x\(Int($0.plannedWeight))" }
    }

    /// Back Extension in v5: current 15×115 ×2, Sept 8 rows 15×95 ×2.
    func testKeepsCurrentSetsAndDropsStaleOnes() throws {
        let ctx = TestSupport.makeContext()
        let re = try routineExercise(TestSupport.buildRoutine(ctx).routine)
        duplicate(ctx, re, current: [(15, 115), (15, 115)], stale: [(15, 95), (15, 95)])
        XCTAssertEqual(re.plannedSets.count, 4)

        XCTAssertEqual(CatalogSyncService(ctx).removeDuplicatePlannedSets(), 2)
        try ctx.save()

        XCTAssertEqual(planned(re), ["0:15x115", "1:15x115"])
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<RoutinePlannedSet>()).count, 2)
    }

    /// Seated Leg Curl in v5: both copies 12×80 — one row per position stays.
    func testIdenticalCopiesCollapseToOnePerPosition() throws {
        let ctx = TestSupport.makeContext()
        let re = try routineExercise(TestSupport.buildRoutine(ctx).routine)
        duplicate(ctx, re, current: [(12, 80), (12, 80)], stale: [(12, 80), (12, 80)])

        XCTAssertEqual(CatalogSyncService(ctx).removeDuplicatePlannedSets(), 2)
        XCTAssertEqual(planned(re), ["0:12x80", "1:12x80"])
    }

    /// Old routine versions are cleaned too; finished workouts keep their own
    /// snapshot of what was planned.
    func testCleansOldVersionAndLeavesHistoryAlone() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx, weight: 115, sets: 2)
        let re = try routineExercise(built.routine)
        RoutineRepository(ctx).setPlannedSets(re, sets: [(10, 115), (10, 115)], restBetweenSets: 60)
        let finished = TestSupport.finishWithOneSetDone(ctx, built.routine)
        let oldVersion = built.routine.activeVersion!
        RoutineRepository(ctx).editRoutine(built.routine, note: "fork") { _ in }
        XCTAssertFalse(oldVersion.isActive)
        duplicate(ctx, re, current: [(10, 115), (10, 115)], stale: [(10, 95), (10, 95)])
        let snapshot = finished.exercises.flatMap(\.sets).map(\.plannedWeight)

        CatalogSyncService(ctx).removeDuplicatePlannedSets()

        XCTAssertEqual(planned(re), ["0:10x115", "1:10x115"])
        XCTAssertEqual(finished.exercises.flatMap(\.sets).map(\.plannedWeight), snapshot)
    }

    func testNoOpWithoutDuplicatesAndLogsNothing() throws {
        let ctx = TestSupport.makeContext()
        let re = try routineExercise(TestSupport.buildRoutine(ctx).routine)
        RoutineRepository(ctx).setPlannedSets(re, sets: [(12, 80), (10, 90)], restBetweenSets: 60)
        let auditsBefore = try ctx.fetch(FetchDescriptor<AuditEvent>()).count

        XCTAssertEqual(CatalogSyncService(ctx).removeDuplicatePlannedSets(), 0)
        XCTAssertEqual(planned(re), ["0:12x80", "1:10x90"])
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<AuditEvent>()).count, auditsBefore)
    }

    func testRepeatableAndLogged() throws {
        let ctx = TestSupport.makeContext()
        let re = try routineExercise(TestSupport.buildRoutine(ctx).routine)
        duplicate(ctx, re, current: [(12, 95), (12, 95)], stale: [(12, 80), (12, 80)])
        let sync = CatalogSyncService(ctx)

        XCTAssertEqual(sync.removeDuplicatePlannedSets(), 2)
        XCTAssertEqual(sync.removeDuplicatePlannedSets(), 0)
        let repaired = try ctx.fetch(FetchDescriptor<AuditEvent>()).filter { $0.type == "data.repaired" }
        XCTAssertEqual(repaired.count, 1)
        XCTAssertTrue(DataIntegrityService(ctx).allPassing)
    }

    /// The Oct 16 backup itself carries the duplicates; restoring it into an
    /// empty app must not bring them back.
    func testRestoringBackupWithDuplicatesEndsClean() throws {
        let src = TestSupport.makeContext()
        let re = try routineExercise(TestSupport.buildRoutine(src).routine)
        duplicate(src, re, current: [(12, 110), (12, 110)], stale: [(12, 100), (12, 100)])
        try src.save()
        let backup = try ExportImportService(src).exportJSONData()

        let dst = TestSupport.makeContext()
        _ = try ExportImportService(dst).importJSON(backup)
        try dst.save()

        let restored = try XCTUnwrap(try dst.fetch(FetchDescriptor<RoutineExercise>()).first)
        XCTAssertEqual(planned(restored), ["0:12x110", "1:12x110"])
    }
}
