//
//  ExerciseStructureMigrationTests.swift
//  WorkoutTrackerTests
//
//  Exercises saved before the exercise structure get a kind and its fields;
//  workout history is untouched.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class ExerciseStructureMigrationTests: XCTestCase {

    private func exercise(_ ctx: ModelContext, _ name: String, _ section: SectionType,
                          machines: [String] = []) -> (Exercise, [Machine]) {
        let ms = machines.map { Machine(name: $0) }
        ms.forEach { ctx.insert($0) }
        let e = Exercise(name: name)
        e.defaultSectionType = section
        e.machineIds = ms.map(\.id)
        ctx.insert(e)
        return (e, ms)
    }

    func testMachineExerciseTakesRepsSetsAndEachMachinesWeight() throws {
        let ctx = TestSupport.makeContext()
        // Shoulder Press: two machines, reps vary on the first.
        let (e, ms) = exercise(ctx, "Shoulder Press", .strength, machines: ["Shoulder Press", "Y Circuit"])
        let repo = RoutineRepository(ctx)
        repo.updateExerciseDefaults(exerciseId: e.id, machineId: ms[0].id, sets: [(12, 40), (10, 40)])
        repo.updateExerciseDefaults(exerciseId: e.id, machineId: ms[1].id, sets: [(12, 45), (12, 45)])

        ExerciseStructureMigration(ctx).run()

        XCTAssertEqual(e.kind, .machine)
        XCTAssertEqual(e.reps, 12)        // first set's reps
        XCTAssertEqual(e.sets, 2)
        XCTAssertEqual(e.perSide, .single)
        XCTAssertEqual(ms[0].weight, 40)
        XCTAssertEqual(ms[1].weight, 45)
    }

    func testStrengthWithoutMachine() throws {
        let ctx = TestSupport.makeContext()
        let (weighted, _) = exercise(ctx, "Goblet Squat", .strength)
        let (plain, _) = exercise(ctx, "Push-up", .strength)
        let (bw, _) = exercise(ctx, "Pull-up", .strength, machines: ["Bodyweight"])
        let repo = RoutineRepository(ctx)
        repo.updateExerciseDefaults(exerciseId: weighted.id, sets: [(10, 25), (10, 25), (10, 25)])
        repo.updateExerciseDefaults(exerciseId: plain.id, sets: [(15, 0)])

        ExerciseStructureMigration(ctx).run()

        XCTAssertEqual(weighted.kind, .freeWeight)
        XCTAssertEqual(weighted.weight, 25)
        XCTAssertEqual(weighted.sets, 3)
        XCTAssertEqual(plain.kind, .bodyweight)
        XCTAssertNil(plain.addedWeight)
        XCTAssertEqual(plain.reps, 15)
        XCTAssertEqual(bw.kind, .bodyweight)
    }

    func testStretches() throws {
        let ctx = TestSupport.makeContext()
        let (calf, _) = exercise(ctx, "Standing Calf Stretch", .stretching)
        calf.holdSeconds = 30; calf.sides = 2; calf.rounds = 1
        let (circles, _) = exercise(ctx, "Shoulder Circles", .stretching)
        circles.holdSeconds = 0; circles.sides = 2; circles.rounds = 15; circles.countTimerSeconds = 30
        let (opener, _) = exercise(ctx, "Chest Opener", .stretching)
        opener.holdSeconds = 30; opener.sides = 1; opener.rounds = 1

        ExerciseStructureMigration(ctx).run()

        XCTAssertEqual(calf.kind, .staticStretch)
        XCTAssertEqual(calf.holdSeconds, 30)
        XCTAssertEqual(calf.reps, 1)
        XCTAssertEqual(calf.sets, 1)
        XCTAssertEqual(calf.perSide, .leftRight)
        XCTAssertEqual(circles.kind, .dynamicStretch)
        XCTAssertEqual(circles.reps, 15)
        XCTAssertEqual(circles.countTimerSeconds, 30)
        XCTAssertEqual(opener.perSide, .single)
    }

    func testCardioBecomesSteadyAndFlagsIntervals() throws {
        let ctx = TestSupport.makeContext()
        let (easy, ms) = exercise(ctx, "Easy Elliptical", .cardio, machines: ["Home Elliptical"])
        easy.intensity = .low; easy.durationMinutes = 35
        let (hiit, _) = exercise(ctx, "Bike Sprints", .cardio)
        hiit.intensity = .high
        hiit.notes = "8 rounds: 30 s work, 30 s recovery"

        let result = ExerciseStructureMigration(ctx).run()

        XCTAssertEqual(easy.kind, .steady)
        XCTAssertEqual(easy.effort, .easy)
        XCTAssertEqual(easy.durationMinutes, 35)
        XCTAssertEqual(easy.machineIds, [ms[0].id])
        XCTAssertEqual(hiit.effort, .hard)
        XCTAssertEqual(result.maybeIntervals, ["Bike Sprints"])
    }

    func testHistoryIsUntouchedAndRunIsRepeatable() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx, weight: 100, reps: 10, sets: 3)
        let finished = TestSupport.finishWithOneSetDone(ctx, built.routine)
        try ctx.save()
        let sessionIds = try ctx.fetch(FetchDescriptor<WorkoutSession>()).map(\.id).sorted { $0.uuidString < $1.uuidString }
        let setSnapshot = try ctx.fetch(FetchDescriptor<WorkoutSessionSet>())
            .map { "\($0.id)|\($0.plannedReps)|\($0.plannedWeight)|\(String(describing: $0.actualWeight))|\($0.isCompleted)" }.sorted()
        let exerciseLinks = finished.exercises.map { "\($0.id)|\(String(describing: $0.exerciseId))|\(String(describing: $0.machineId))" }

        XCTAssertEqual(ExerciseStructureMigration(ctx).run().converted, 1)
        try ctx.save()

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<WorkoutSession>()).map(\.id).sorted { $0.uuidString < $1.uuidString }, sessionIds)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<WorkoutSessionSet>())
            .map { "\($0.id)|\($0.plannedReps)|\($0.plannedWeight)|\(String(describing: $0.actualWeight))|\($0.isCompleted)" }.sorted(), setSnapshot)
        XCTAssertEqual(finished.exercises.map { "\($0.id)|\(String(describing: $0.exerciseId))|\(String(describing: $0.machineId))" }, exerciseLinks)
        XCTAssertEqual(built.exercise.kind, .machine)

        XCTAssertEqual(ExerciseStructureMigration(ctx).run().converted, 0)
    }

    func testRestoringOldBackupConvertsItsExercises() throws {
        let src = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(src, weight: 100, reps: 10, sets: 3)
        try src.save()
        let backup = try ExportImportService(src).exportJSONData()   // no kind in it yet

        let dst = TestSupport.makeContext()
        _ = try ExportImportService(dst).importJSON(backup)
        let restored = try XCTUnwrap(try dst.fetch(FetchDescriptor<Exercise>()).first { $0.id == built.exercise.id })
        XCTAssertEqual(restored.kind, .machine)
        XCTAssertEqual(restored.sets, 3)
    }
}

/// The new fields write the older ones that routines and workouts still read.
@MainActor
final class ExerciseLegacyFieldsTests: XCTestCase {

    func testMachineKindWritesSetsPerMachine() throws {
        let ctx = TestSupport.makeContext()
        let a = Machine(name: "Chest Press"); a.weight = 95
        let b = Machine(name: "Y Circuit"); b.weight = 100
        ctx.insert(a); ctx.insert(b)
        let e = Exercise(name: "Chest Press"); ctx.insert(e)
        e.kind = .machine; e.reps = 12; e.sets = 3
        e.machineIds = [a.id, b.id]

        ExerciseLegacyFields.write(e, machines: [a, b], context: ctx)

        XCTAssertEqual(e.defaultSectionType, .strength)
        XCTAssertEqual(e.defaultSets(for: a.id).map(\.weight), [95, 95, 95])
        XCTAssertEqual(e.defaultSets(for: b.id).map(\.weight), [100, 100, 100])
        XCTAssertEqual(e.defaultSets(for: a.id).map(\.reps), [12, 12, 12])
    }

    func testStretchesWriteHoldSidesAndRounds() throws {
        let ctx = TestSupport.makeContext()
        let stat = Exercise(name: "Calf"); ctx.insert(stat)
        stat.kind = .staticStretch; stat.holdSeconds = 45; stat.reps = 1; stat.sets = 2; stat.perSide = .leftRight
        let dyn = Exercise(name: "Circles"); ctx.insert(dyn)
        dyn.kind = .dynamicStretch; dyn.holdSeconds = 30; dyn.reps = 10; dyn.sets = 1; dyn.perSide = .forwardBack

        ExerciseLegacyFields.write(stat, machines: [], context: ctx)
        ExerciseLegacyFields.write(dyn, machines: [], context: ctx)

        XCTAssertEqual(stat.defaultSectionType, .stretching)
        XCTAssertEqual(stat.holdSeconds, 45)
        XCTAssertEqual(stat.sides, 2)
        XCTAssertEqual(stat.rounds, 2)       // sets repeat the side cycle
        XCTAssertEqual(dyn.holdSeconds, 0)   // count-based
        XCTAssertEqual(dyn.rounds, 10)
    }

    func testCardioWritesIntensityAndIntervalDuration() throws {
        let ctx = TestSupport.makeContext()
        let e = Exercise(name: "Bike Sprints"); ctx.insert(e)
        e.kind = .intervals; e.workSeconds = 30; e.recoverySeconds = 30; e.rounds = 8; e.effort = .max

        ExerciseLegacyFields.write(e, machines: [], context: ctx)

        XCTAssertEqual(e.defaultSectionType, .cardio)
        XCTAssertEqual(e.intensity, .high)
        XCTAssertEqual(e.durationMinutes, 8)
    }

    /// Editing through the new structure flows into the routines that use it.
    func testRoutineGetsTheNewPrescription() throws {
        let ctx = TestSupport.makeContext()
        let built = TestSupport.buildRoutine(ctx, weight: 100, reps: 10, sets: 3)
        ExerciseStructureMigration(ctx).run()
        let m = try XCTUnwrap(built.machine)
        built.exercise.reps = 8; built.exercise.sets = 4; m.weight = 110

        ExerciseLegacyFields.write(built.exercise, machines: [m], context: ctx)
        CatalogSyncService(ctx).reconcileExercise(built.exercise.id)

        let re = try XCTUnwrap(built.routine.activeVersion?.sections.flatMap(\.exercises).first)
        XCTAssertEqual(re.effectivePlannedSets.map(\.reps), [8, 8, 8, 8])
        XCTAssertEqual(re.effectivePlannedSets.map(\.weight), [110, 110, 110, 110])
    }
}

/// Older CSV imports shared one machine (by name) across exercises; the
/// migration gives each exercise its own.
@MainActor
final class SharedMachineSplitTests: XCTestCase {

    func testSharedMachineIsCopiedForTheSecondExercise() throws {
        let ctx = TestSupport.makeContext()
        let m = Machine(name: "Home Elliptical"); ctx.insert(m)
        let def = MachineSettingDefinition(label: "Resistance", order: 0, numericValue: 10, otherText: nil, source: .user)
        def.machine = m; m.settingDefinitions.append(def); ctx.insert(def)
        let first = Exercise(name: "Steady", createdAt: .now.addingTimeInterval(-60)); ctx.insert(first)
        let second = Exercise(name: "Easy"); ctx.insert(second)
        for e in [first, second] { e.defaultSectionType = .cardio; e.machineIds = [m.id] }

        // A finished workout and one in progress, both on the second exercise.
        let repo = RoutineRepository(ctx)
        let routine = repo.createRoutine(name: "Cardio")
        let section = repo.addSection(to: routine.activeVersion!, type: .cardio)
        repo.addExercise(to: section, exercise: second, plannedSets: [], restBetweenSets: 60)
        let workouts = WorkoutRepository(ctx)
        let done = workouts.startWorkout(from: routine)
        workouts.markExerciseComplete(done.exercises.first!, in: done)
        workouts.finishWorkout(done)
        let open = workouts.startWorkout(from: routine)
        try ctx.save()

        let result = ExerciseStructureMigration(ctx).run()

        XCTAssertEqual(result.splitMachines, 1)
        XCTAssertEqual(first.machineIds, [m.id])                       // oldest keeps it
        let copyId = try XCTUnwrap(second.machineIds.first)
        XCTAssertNotEqual(copyId, m.id)
        let copy = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Machine>()).first { $0.id == copyId })
        XCTAssertEqual(copy.name, "Home Elliptical")
        XCTAssertEqual(copy.activeSettings.map(\.label), ["Resistance"])
        XCTAssertEqual(open.exercises.first?.machineId, copyId)        // in progress moves
        XCTAssertEqual(done.exercises.first?.machineId, m.id)          // history keeps the original
        XCTAssertEqual(ExerciseStructureMigration(ctx).run().splitMachines, 0)   // repeatable
    }
}
