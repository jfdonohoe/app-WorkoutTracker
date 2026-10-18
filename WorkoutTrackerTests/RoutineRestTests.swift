//
//  RoutineRestTests.swift
//  WorkoutTrackerTests
//
//  Rest is set per routine. Changing it on the workout screen updates the
//  routine for future workouts; workouts already done keep theirs.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class RoutineRestTests: XCTestCase {

    func testRestChangeDuringWorkoutUpdatesRoutineForFutureWorkouts() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        let workouts = WorkoutRepository(ctx)
        let first = workouts.startWorkout(from: built.routine)
        let startVersion = built.routine.activeVersion!
        let oldRest = startVersion.defaultRestBetweenSets

        workouts.setRest(first, betweenSets: oldRest + 30)

        XCTAssertEqual(first.restBetweenSets, oldRest + 30)
        // The plan this workout started from is kept; a new version carries it.
        XCTAssertEqual(startVersion.defaultRestBetweenSets, oldRest)
        XCTAssertNotEqual(built.routine.activeVersion!.id, startVersion.id)
        XCTAssertEqual(built.routine.activeVersion!.defaultRestBetweenSets, oldRest + 30)

        let next = workouts.startWorkout(from: built.routine)
        XCTAssertEqual(next.restBetweenSets, oldRest + 30)
    }

    func testRepeatedChangesDontPileUpVersions() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        let workouts = WorkoutRepository(ctx)
        let s = workouts.startWorkout(from: built.routine)

        workouts.setRest(s, betweenSets: 75)
        let afterFirst = built.routine.versions.count
        workouts.setRest(s, betweenSets: 90)
        workouts.setRest(s, betweenExercises: 120)

        XCTAssertEqual(built.routine.versions.count, afterFirst)
        XCTAssertEqual(built.routine.activeVersion!.defaultRestBetweenSets, 90)
        XCTAssertEqual(built.routine.activeVersion!.defaultRestBetweenExercises, 120)
    }

    func testFinishedWorkoutCannotChangeRest() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx)
        let finished = TestSupport.finishWithOneSetDone(ctx, built.routine)
        let rest = built.routine.activeVersion!.defaultRestBetweenSets

        WorkoutRepository(ctx).setRest(finished, betweenSets: rest + 60)

        XCTAssertEqual(finished.restBetweenSets, rest)
        XCTAssertEqual(built.routine.activeVersion!.defaultRestBetweenSets, rest)
    }
}
