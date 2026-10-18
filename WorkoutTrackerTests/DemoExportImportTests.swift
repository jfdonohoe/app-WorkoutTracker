//
//  DemoExportImportTests.swift
//  WorkoutTrackerTests
//
//  Tests 13–16: demo-data separation/cleanup and safe export/import.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class DemoExportImportTests: XCTestCase {

    // 13. Demo data deletion removes all data that originated as demo data.
    func test13_demoDeletionRemovesDemo() throws {
        let ctx = TestSupport.makeContext()
        SeedDataService(ctx).seed()
        try ctx.save()
        XCTAssertGreaterThan(try ctx.fetchCount(FetchDescriptor<Routine>()), 0)

        // Even if a demo record is EDITED, it remains demo-sourced and is removed.
        let demoRoutine = try ctx.fetch(FetchDescriptor<Routine>()).first { $0.source == .seedDemo }!
        demoRoutine.name = "Edited During QA"
        try ctx.save()

        let deleted = DemoDataManager(ctx).deleteAllDemoData()
        try ctx.save()

        XCTAssertGreaterThan(deleted, 0)
        let remainingDemoRoutines = try ctx.fetch(FetchDescriptor<Routine>()).filter { $0.source == .seedDemo }
        let remainingDemoSessions = try ctx.fetch(FetchDescriptor<WorkoutSession>()).filter { $0.source == .seedDemo }
        XCTAssertTrue(remainingDemoRoutines.isEmpty)
        XCTAssertTrue(remainingDemoSessions.isEmpty)
    }

    // 13b. Demo data comes from the bundled definitions, uses fresh ids every
    // seed, carries no YMCA branding, and is fully removed by demo deletion.
    func test13b_demoSeedsBundledDefinitions() throws {
        let doc = try XCTUnwrap(SeedDataService.loadDemoDefinitions())
        let again = try XCTUnwrap(SeedDataService.loadDemoDefinitions())
        XCTAssertEqual(doc.routines.count, 2)
        XCTAssertTrue(Set(doc.routines.map(\.id)).isDisjoint(with: again.routines.map(\.id)))

        let ctx = TestSupport.makeContext()
        SeedDataService(ctx).seed()
        try ctx.save()
        let routines = try ctx.fetch(FetchDescriptor<Routine>())
        XCTAssertEqual(Set(routines.map(\.name)),
                       ["Strength Workout A (Weeks 1-6)", "Strength Workout B (Weeks 1-6)"])
        XCTAssertTrue(routines.allSatisfy { $0.versions.count == 1 && $0.activeVersion != nil })
        let exercises = try ctx.fetch(FetchDescriptor<Exercise>())
        XCTAssertEqual(exercises.count, doc.exercises.count)
        XCTAssertFalse(exercises.contains { $0.name.localizedCaseInsensitiveContains("YMCA") })
        XCTAssertTrue(exercises.allSatisfy { $0.source == .seedDemo })
        // Every routine exercise resolves to a seeded exercise.
        let exerciseIds = Set(exercises.map(\.id))
        let routineExerciseIds = routines.flatMap { $0.activeVersion?.sections ?? [] }.flatMap(\.exercises).map(\.exerciseId)
        XCTAssertFalse(routineExerciseIds.isEmpty)
        XCTAssertTrue(routineExerciseIds.allSatisfy(exerciseIds.contains))
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<AuditEvent>(predicate: #Predicate { $0.type == "import.performed" })), 0)

        DemoDataManager(ctx).deleteAllDemoData()
        try ctx.save()
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Exercise>()), 0)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Machine>()), 0)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Routine>()), 0)
    }

    // 14. User-created data remains after demo data deletion.
    func test14_userDataRemainsAfterDemoDeletion() throws {
        let ctx = TestSupport.makeContext()
        // Real user data.
        let (userRoutine, _, _) = TestSupport.buildRoutine(ctx, name: "My Routine")
        let workouts = WorkoutRepository(ctx)
        let userSession = workouts.startWorkout(from: userRoutine)
        // One set done: a workout with nothing done is discarded, not kept.
        let userSet = try XCTUnwrap(userSession.exercises.first?.orderedSets.first)
        workouts.completeSet(userSet, in: userSession, actualWeight: 100, actualReps: 10)
        workouts.finishWorkout(userSession)
        // Demo data.
        SeedDataService(ctx).seed()
        try ctx.save()

        DemoDataManager(ctx).deleteAllDemoData()
        try ctx.save()

        let userRoutines = try ctx.fetch(FetchDescriptor<Routine>()).filter { $0.source == .user }
        let userSessions = try ctx.fetch(FetchDescriptor<WorkoutSession>()).filter { $0.source == .user }
        XCTAssertEqual(userRoutines.count, 1)
        XCTAssertEqual(userSessions.count, 1)
        XCTAssertEqual(userRoutines.first?.name, "My Routine")
    }

    // 15. Export includes user workout data.
    func test15_exportIncludesUserData() throws {
        let ctx = TestSupport.makeContext()
        let (routine, _, _) = TestSupport.buildRoutine(ctx, name: "Export Me")
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        workouts.completeSet(session.exercises.flatMap(\.orderedSets).first!, in: session, actualWeight: 100, actualReps: 10)
        workouts.finishWorkout(session)
        try ctx.save()

        let doc = ExportImportService(ctx).makeBackup()
        XCTAssertTrue(doc.routines.contains { $0.name == "Export Me" })
        XCTAssertTrue(doc.sessions.contains { $0.id == session.id })
        XCTAssertFalse(doc.sessionSets.isEmpty)

        // And it encodes to JSON without error.
        let data = try ExportImportService(ctx).exportJSONData()
        XCTAssertGreaterThan(data.count, 0)
    }

    // 16. Import does not destructively overwrite existing data.
    func test16_importIsNonDestructive() throws {
        // Source store with data.
        let ctx1 = TestSupport.makeContext()
        let (routine, _, _) = TestSupport.buildRoutine(ctx1, name: "Source", weight: 100)
        let workouts = WorkoutRepository(ctx1)
        let session = workouts.startWorkout(from: routine)
        // One set done: a workout with nothing done is discarded, not kept.
        let set = try XCTUnwrap(session.exercises.first?.orderedSets.first)
        workouts.completeSet(set, in: session, actualWeight: 100, actualReps: 10)
        workouts.finishWorkout(session)
        try ctx1.save()
        let data = try ExportImportService(ctx1).exportJSONData()

        // Fresh store: importing adds records.
        let ctx2 = TestSupport.makeContext()
        let svc2 = ExportImportService(ctx2)
        let first = try svc2.importJSON(data)
        try ctx2.save()
        XCTAssertGreaterThan(first.added, 0)
        XCTAssertEqual(first.skipped, 0)

        // Importing the SAME backup again must NOT overwrite — all skipped.
        let importedSession = try ctx2.fetch(FetchDescriptor<WorkoutSession>()).first!
        importedSession.note = "user edited locally"
        try ctx2.save()

        let second = try svc2.importJSON(data)
        try ctx2.save()
        XCTAssertEqual(second.added, 0)
        XCTAssertGreaterThan(second.skipped, 0)

        // The locally edited value was preserved, not overwritten by the import.
        let after = try ctx2.fetch(FetchDescriptor<WorkoutSession>()).first { $0.id == importedSession.id }!
        XCTAssertEqual(after.note, "user edited locally")
        // No duplicates created.
        XCTAssertEqual(try ctx2.fetchCount(FetchDescriptor<WorkoutSession>()), 1)
    }
}
