//
//  TypeRestsTests.swift
//  WorkoutTrackerTests
//
//  Rests per exercise type: set on the routine, copied into each workout,
//  saved back from the workout, kept in backups, and used by the guided run
//  (stretch get-readies, the rest between cardio exercises).
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class TypeRestsTests: XCTestCase {

    private let custom = TypeRests(strengthSets: 45, strengthExercises: 90, stretchWithin: 3,
                                   stretchBetween: 10, cardioSets: 30, cardioExercises: 20)

    func testARoutineSavedBeforeStartsWithTheStandardRests() {
        let ctx = TestSupport.makeContext()
        let v = TestSupport.buildRoutine(ctx).routine.activeVersion!
        XCTAssertEqual(v.rests.stretchWithin, 5)
        XCTAssertEqual(v.rests.stretchBetween, 5)
        XCTAssertEqual(v.rests.cardioExercises, 0)
        v.defaultRestBetweenSets = 75
        XCTAssertEqual(v.rests.cardioSets, 75, "cardio between sets follows strength until set")
    }

    func testAWorkoutCopiesTheRoutinesRestsAndANewVersionKeepsThem() throws {
        let ctx = TestSupport.makeContext()
        let routine = TestSupport.buildRoutine(ctx).routine
        routine.activeVersion!.rests = custom
        let session = WorkoutRepository(ctx).startWorkout(from: routine)
        XCTAssertEqual(session.rests, custom)
        let v2 = RoutineRepository(ctx).makeNewVersion(of: routine, note: "edit")
        XCTAssertEqual(v2.rests, custom)
    }

    func testChangingRestsInAWorkoutUpdatesTheRoutine() throws {
        let ctx = TestSupport.makeContext()
        let routine = TestSupport.buildRoutine(ctx).routine
        let session = WorkoutRepository(ctx).startWorkout(from: routine)
        WorkoutRepository(ctx).setRests(session, custom)
        XCTAssertEqual(session.rests, custom)
        XCTAssertEqual(routine.activeVersion?.rests, custom)
    }

    func testRestsSurviveABackup() throws {
        let ctx = TestSupport.makeContext()
        let routine = TestSupport.buildRoutine(ctx).routine
        routine.activeVersion!.rests = custom
        let session = TestSupport.finishWithOneSetDone(ctx, routine)
        try ctx.save()
        let data = try ExportImportService(ctx).exportJSONData()
        let restored = TestSupport.makeContext()
        _ = try ExportImportService(restored).importJSON(data)
        let r = try XCTUnwrap(try restored.fetch(FetchDescriptor<Routine>()).first { $0.id == routine.id })
        XCTAssertEqual(r.activeVersion?.rests, custom)
        let s = try XCTUnwrap(try restored.fetch(FetchDescriptor<WorkoutSession>()).first { $0.id == session.id })
        XCTAssertEqual(s.rests, custom)
    }

    // MARK: - Guided run

    private func stretch(_ name: String, order: Int) -> WorkoutSessionExercise {
        let se = WorkoutSessionExercise(name: name, sectionType: .stretching, order: order, plannedRestBetweenSets: 0)
        se.kindRaw = ExerciseKind.staticStretch.rawValue
        se.holdSeconds = 30; se.reps = 1; se.setCount = 1; se.perSideRaw = PerSide.leftRight.rawValue
        return se
    }

    private func steady(_ name: String, order: Int, minutes: Int = 10) -> WorkoutSessionExercise {
        let se = WorkoutSessionExercise(name: name, sectionType: .cardio, order: order, plannedRestBetweenSets: 0)
        se.kindRaw = ExerciseKind.steady.rawValue
        se.durationMinutes = minutes
        return se
    }

    func testStretchGetReadiesUseTheRoutinesSeconds() {
        let phases = GuidedPlan.phases(for: [stretch("A", order: 0), stretch("B", order: 1)], rests: custom)
        XCTAssertEqual(phases.filter(\.isTransition).map(\.seconds), [3, 10, 3])   // A side 2, into B, B side 2
    }

    func testZeroMeansNoGetReady() {
        var r = custom; r.stretchWithin = 0; r.stretchBetween = 0
        let phases = GuidedPlan.phases(for: [stretch("A", order: 0), stretch("B", order: 1)], rests: r)
        XCTAssertTrue(phases.allSatisfy { !$0.isTransition })
        XCTAssertEqual(phases.count, 4)
    }

    func testCardioRestBetweenExercisesIsARestRingPhase() {
        let a = steady("Elliptical", order: 0), b = steady("Bike", order: 1)
        let phases = GuidedPlan.phases(for: [a, b], rests: custom)
        XCTAssertEqual(phases.count, 3)
        XCTAssertTrue(phases[1].isRest && phases[1].isBetween)
        XCTAssertEqual(phases[1].seconds, 20)
        XCTAssertEqual(phases[1].exerciseId, b.id, "it leads into the next exercise")
        XCTAssertEqual(GuidedPlan.phases(for: [a, b]).count, 2, "none by default: back to back")
    }

    func testEditingACardioThatHasARestBeforeItStillMovesItsEnd() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let a = steady("Elliptical", order: 0, minutes: 5), b = steady("Bike", order: 1, minutes: 10)
        let timer = GuidedTimerService()
        timer.start(phases: GuidedPlan.phases(for: [a, b], rests: custom), finishedTitle: "Cardio complete",
                    rests: custom, now: t0)
        timer.tick(now: t0.addingTimeInterval(300 + 20 + 60))   // A done, rest done, 1 min into B
        XCTAssertEqual(timer.currentExerciseId, b.id)
        b.durationMinutes = 15
        timer.replan(b, now: t0.addingTimeInterval(380))
        XCTAssertEqual(timer.current?.seconds, 900)
        XCTAssertEqual(timer.remainingSeconds, 840)              // 14 min left
        timer.stop()
    }

    func testCardioNotReachedYetKeepsItsRestWhenEdited() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let a = steady("Elliptical", order: 0), b = steady("Bike", order: 1)
        let timer = GuidedTimerService()
        timer.start(phases: GuidedPlan.phases(for: [a, b], rests: custom), finishedTitle: "", rests: custom, now: t0)
        b.durationMinutes = 20
        timer.replan(b, now: t0.addingTimeInterval(30))
        XCTAssertEqual(timer.phases.map(\.seconds), [600, 20, 1200])
        timer.stop()
    }
}
