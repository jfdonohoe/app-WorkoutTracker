//
//  WorkoutPlaybackTests.swift
//  WorkoutTrackerTests
//
//  How a workout plays each exercise kind: intervals' work and recovery,
//  stretch side cycles, per-side strength sets, and the Up next summary.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class WorkoutPlaybackTests: XCTestCase {

    /// A one-exercise routine for an exercise of `kind`, started as a workout.
    private func start(_ ctx: ModelContext, _ kind: ExerciseKind,
                       configure: (Exercise) -> Void) -> WorkoutSessionExercise {
        let e = Exercise(name: kind.displayName)
        ctx.insert(e)
        e.kind = kind
        configure(e)
        ExerciseLegacyFields.write(e, machines: [], context: ctx)
        let repo = RoutineRepository(ctx)
        let routine = repo.createRoutine(name: "R")
        let section = repo.addSection(to: routine.activeVersion!, type: kind.section)
        repo.addExercise(to: section, exercise: e, plannedSets: e.effectiveDefaultSets, restBetweenSets: 60)
        let session = WorkoutRepository(ctx).startWorkout(from: routine)
        return session.exercises.first!
    }

    func testIntervalsAlternateWorkAndRecovery() {
        let ctx = TestSupport.makeContext()
        let se = start(ctx, .intervals) { $0.rounds = 3; $0.workSeconds = 30; $0.recoverySeconds = 20; $0.effort = .hard }

        let phases = GuidedPlan.phases(for: [se])

        XCTAssertEqual(phases.map(\.seconds), [30, 20, 30, 20, 30])
        XCTAssertEqual(phases.map(\.isRecovery), [false, true, false, true, false])
        XCTAssertEqual(phases.filter(\.endsExercise).count, 1)
        XCTAssertTrue(phases.last!.endsExercise)
        XCTAssertEqual(phases[0].caption, "Work · Round 1 of 3")
        XCTAssertEqual(phases[1].caption, "Round 1 of 3")
    }

    func testStaticStretchCyclesSidesWithinEachSet() {
        let ctx = TestSupport.makeContext()
        let se = start(ctx, .staticStretch) { $0.holdSeconds = 30; $0.reps = 1; $0.sets = 2; $0.perSide = .leftRight }

        let work = GuidedPlan.phases(for: [se]).filter { !$0.isBetween }

        XCTAssertEqual(work.count, 4)   // L, R, L, R
        XCTAssertEqual(work.map(\.caption), ["Set 1 of 2 · Left", "Set 1 of 2 · Right",
                                             "Set 2 of 2 · Left", "Set 2 of 2 · Right"])
        XCTAssertEqual(work.first?.detail, "Hold 30s")
        XCTAssertEqual(GuidedPlan.phases(for: [se]).filter(\.isTransition).count, 3)
    }

    func testDynamicStretchTimesEachSide() {
        let ctx = TestSupport.makeContext()
        let se = start(ctx, .dynamicStretch) { $0.reps = 10; $0.sets = 1; $0.perSide = .forwardBack; $0.countTimerSeconds = 25 }

        let work = GuidedPlan.phases(for: [se]).filter { !$0.isBetween }

        XCTAssertEqual(work.map(\.seconds), [25, 25])
        XCTAssertEqual(work.first?.detail, "10 reps")
        XCTAssertEqual(work.map(\.caption), ["Forward", "Back"])
    }

    func testPerSideStrengthGetsASetForEachSide() {
        let ctx = TestSupport.makeContext()
        let se = start(ctx, .freeWeight) { $0.reps = 8; $0.sets = 2; $0.weight = 20; $0.perSide = .leftRight }

        XCTAssertEqual(se.orderedSets.map(\.side), ["Left", "Right", "Left", "Right"])
        XCTAssertEqual(se.orderedSets.map(\.plannedWeight), [20, 20, 20, 20])
    }

    func testCalisthenicsLogsSetsAndIsNotTimed() {
        let ctx = TestSupport.makeContext()
        let se = start(ctx, .calisthenics) { $0.reps = 15; $0.sets = 3 }

        XCTAssertEqual(se.sets.count, 3)
        XCTAssertTrue(GuidedPlan.phases(for: [se]).isEmpty)
    }

    func testDistanceIsLoggedNotTimed() {
        let ctx = TestSupport.makeContext()
        let se = start(ctx, .distance) { $0.distance = 2.5 }

        XCTAssertEqual(se.plannedDistance, 2.5)
        XCTAssertTrue(GuidedPlan.phases(for: [se]).isEmpty)
    }

    func testUpNextSummaries() {
        let ctx = TestSupport.makeContext()
        XCTAssertEqual(WorkoutPeekSheet.summary(start(ctx, .staticStretch) { $0.holdSeconds = 30; $0.perSide = .leftRight }),
                       "Hold 30s · Left/Right")
        XCTAssertEqual(WorkoutPeekSheet.summary(start(ctx, .intervals) { $0.rounds = 8; $0.effort = .hard }),
                       "8 × 30s / 30s · Hard")
        XCTAssertEqual(WorkoutPeekSheet.summary(start(ctx, .freeWeight) { $0.reps = 10; $0.sets = 3; $0.weight = 25 }),
                       "3 sets · 25 lb × 10")
        XCTAssertEqual(WorkoutPeekSheet.summary(start(ctx, .hold) { $0.reps = 1; $0.sets = 3; $0.holdSeconds = 30 }),
                       "3 × 1 · hold 30s")
    }

    /// A workout's performed sets go back to the exercise once per set, not
    /// once per side.
    func testPerSideSetsReadBackOncePerSet() {
        let ctx = TestSupport.makeContext()
        let e = Exercise(name: "Lunge"); ctx.insert(e)
        e.kind = .freeWeight; e.reps = 8; e.sets = 2; e.weight = 20; e.perSide = .leftRight
        ExerciseLegacyFields.write(e, machines: [], context: ctx)
        RoutineRepository(ctx).updateExerciseDefaults(exerciseId: e.id, sets: [(10, 25), (10, 25)])

        ExerciseLegacyFields.readBackSets(e, machineId: nil, context: ctx)

        XCTAssertEqual(e.sets, 2)
        XCTAssertEqual(e.reps, 10)
        XCTAssertEqual(e.weight, 25)
    }
}
