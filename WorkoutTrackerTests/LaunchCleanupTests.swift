//
//  LaunchCleanupTests.swift
//  WorkoutTrackerTests
//
//  The one-time launch cleanups run once per cleanupVersion, and demo
//  seeding writes no Data Safety repair entries.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class LaunchCleanupTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let name = "LaunchCleanupTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testCleanupsRunOnceThenSkip() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        built.exercise.deletedAt = .now   // old damage: deleted but still planned
        let defaults = freshDefaults()
        let sync = CatalogSyncService(ctx)

        XCTAssertTrue(sync.runOneTimeCleanupsIfNeeded(defaults: defaults))
        XCTAssertEqual(defaults.integer(forKey: CatalogSyncService.cleanupVersionKey), CatalogSyncService.cleanupVersion)
        XCTAssertTrue(built.routine.activeVersion!.sections.flatMap(\.exercises).isEmpty)

        // Later damage is left for the Data Safety Check, not removed silently.
        let other = TestSupport.buildRoutine(ctx, name: "Other")
        other.exercise.deletedAt = .now
        XCTAssertFalse(sync.runOneTimeCleanupsIfNeeded(defaults: defaults))
        XCTAssertFalse(other.routine.activeVersion!.sections.flatMap(\.exercises).isEmpty)
        XCTAssertFalse(try XCTUnwrap(DataIntegrityService(ctx).runAll()
            .first { $0.title == "Routines use only library exercises" }).passed)
    }

    func testCleanupsRunAgainAfterVersionBump() throws {
        let ctx = TestSupport.makeContext()
        let defaults = freshDefaults()
        defaults.set(CatalogSyncService.cleanupVersion - 1, forKey: CatalogSyncService.cleanupVersionKey)
        let built = TestSupport.buildRoutine(ctx)
        built.exercise.deletedAt = .now
        XCTAssertTrue(CatalogSyncService(ctx).runOneTimeCleanupsIfNeeded(defaults: defaults))
    }

    func testDemoSeedingLogsNoRepairs() throws {
        let ctx = TestSupport.makeContext()
        SeedDataService(ctx).seed()
        try ctx.save()
        let repaired = try ctx.fetch(FetchDescriptor<AuditEvent>()).filter { $0.type == "data.repaired" }
        XCTAssertTrue(repaired.isEmpty)
    }
}
