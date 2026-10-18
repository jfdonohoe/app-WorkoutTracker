//
//  VaryBySetTests.swift
//  WorkoutTrackerTests
//
//  "Vary by set" (strength only): each set keeps its own weight and reps
//  through saving, routines, workouts, the workout write-back, migration and
//  backups. Off, every set is the same (Sets × Reps @ weight).
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class VaryBySetTests: XCTestCase {

    /// A Machine exercise varying on two machines: 3 sets on one, 1 on the other.
    private func varyingMachineExercise(_ ctx: ModelContext) -> (Exercise, Machine, Machine) {
        let a = Machine(name: "Hammer"); let b = Machine(name: "Cybex")
        ctx.insert(a); ctx.insert(b)
        let e = Exercise(name: "Chest Press"); ctx.insert(e)
        e.kind = .machine; e.reps = 10; e.sets = 3; e.varyBySet = true
        e.machineIds = [a.id, b.id]
        let repo = RoutineRepository(ctx)
        repo.updateExerciseDefaults(exerciseId: e.id, machineId: a.id, sets: [(10, 90), (8, 100), (6, 110)])
        repo.updateExerciseDefaults(exerciseId: e.id, machineId: b.id, sets: [(10, 110)])
        return (e, a, b)
    }

    func testOnlyStrengthKindsVary() {
        XCTAssertEqual(ExerciseKind.allCases.filter(\.supportsVaryBySet), [.machine, .freeWeight, .bodyweight])
    }

    func testWriterKeepsEachSetAndSyncsTheSummaryFields() throws {
        let ctx = TestSupport.makeContext()
        let (e, a, b) = varyingMachineExercise(ctx)

        ExerciseLegacyFields.write(e, machines: [a, b], context: ctx)

        XCTAssertEqual(e.defaultSets(for: a.id).map(\.weight), [90, 100, 110])
        XCTAssertEqual(e.defaultSets(for: a.id).map(\.reps), [10, 8, 6])
        XCTAssertEqual(e.defaultSets(for: b.id).map(\.weight), [110])   // own set count
        XCTAssertEqual(e.sets, 3)
        XCTAssertEqual(e.reps, 10)
        XCTAssertEqual(a.weight, 90)
        XCTAssertEqual(b.weight, 110)
    }

    func testSameEverySetStillRebuildsUniformSets() throws {
        let ctx = TestSupport.makeContext()
        let (e, a, b) = varyingMachineExercise(ctx)
        e.varyBySet = false; e.reps = 10; e.sets = 3; a.weight = 90; b.weight = 110

        ExerciseLegacyFields.write(e, machines: [a, b], context: ctx)

        XCTAssertEqual(e.defaultSets(for: a.id).map(\.weight), [90, 90, 90])
        XCTAssertEqual(e.defaultSets(for: a.id).map(\.reps), [10, 10, 10])
        XCTAssertEqual(e.defaultSets(for: b.id).count, 3)
    }

    /// A non-strength kind left with the flag on is treated as same-every-set.
    func testFlagIgnoredOutsideStrength() throws {
        let ctx = TestSupport.makeContext()
        let e = Exercise(name: "Plank"); ctx.insert(e)
        e.kind = .hold; e.reps = 1; e.sets = 3; e.holdSeconds = 30; e.varyBySet = true
        RoutineRepository(ctx).updateExerciseDefaults(exerciseId: e.id, sets: [(5, 0)])

        ExerciseLegacyFields.write(e, machines: [], context: ctx)

        XCTAssertEqual(e.defaultSets(for: nil).count, 3)
    }

    func testRoutineAndWorkoutGetTheVaryingSets() throws {
        let ctx = TestSupport.makeContext()
        let (e, a, b) = varyingMachineExercise(ctx)
        ExerciseLegacyFields.write(e, machines: [a, b], context: ctx)
        let repo = RoutineRepository(ctx)
        let routine = repo.createRoutine(name: "R")
        let section = repo.addSection(to: routine.activeVersion!, type: .strength)
        repo.addExercise(to: section, exercise: e, plannedSets: e.effectiveDefaultSets, restBetweenSets: 60)
        CatalogSyncService(ctx).reconcileExercise(e.id)

        let session = WorkoutRepository(ctx).startWorkout(from: routine)
        let se = try XCTUnwrap(session.exercises.first)
        XCTAssertEqual(se.orderedSets.map(\.plannedWeight), [90, 100, 110])
        XCTAssertEqual(se.orderedSets.map(\.plannedReps), [10, 8, 6])
        XCTAssertEqual(WorkoutPeekSheet.summary(se), "3 sets · 90–110 lb × 6–10")
    }

    /// Per side: each varying set is done on every side, in order.
    func testPerSideRepeatsEachVaryingSet() throws {
        let ctx = TestSupport.makeContext()
        let e = Exercise(name: "Dumbbell Lunge"); ctx.insert(e)
        e.kind = .freeWeight; e.perSide = .leftRight; e.varyBySet = true
        RoutineRepository(ctx).updateExerciseDefaults(exerciseId: e.id, sets: [(12, 25), (10, 30)])
        ExerciseLegacyFields.write(e, machines: [], context: ctx)
        let repo = RoutineRepository(ctx)
        let routine = repo.createRoutine(name: "R")
        let section = repo.addSection(to: routine.activeVersion!, type: .strength)
        repo.addExercise(to: section, exercise: e, plannedSets: e.effectiveDefaultSets, restBetweenSets: 60)

        let session = WorkoutRepository(ctx).startWorkout(from: routine)
        let sets = try XCTUnwrap(session.exercises.first).orderedSets
        XCTAssertEqual(sets.map(\.side), ["Left", "Right", "Left", "Right"])
        XCTAssertEqual(sets.map(\.plannedWeight), [25, 25, 30, 30])
        XCTAssertEqual(e.weight, 25)
    }

    /// What was done in a workout becomes the exercise's sets (unchanged
    /// behaviour); a varying exercise stays varying.
    func testWorkoutWriteBackKeepsVariation() throws {
        let ctx = TestSupport.makeContext()
        let (e, a, b) = varyingMachineExercise(ctx)
        ExerciseLegacyFields.write(e, machines: [a, b], context: ctx)

        RoutineRepository(ctx).updateExerciseDefaults(exerciseId: e.id, machineId: a.id, sets: [(10, 95), (8, 105), (6, 115)])
        ExerciseLegacyFields.readBackSets(e, machineId: a.id, context: ctx)
        ExerciseLegacyFields.write(e, machines: [a, b], context: ctx)

        XCTAssertTrue(e.varyBySet)
        XCTAssertEqual(e.defaultSets(for: a.id).map(\.weight), [95, 105, 115])
        XCTAssertEqual(e.defaultSets(for: a.id).map(\.reps), [10, 8, 6])
        XCTAssertEqual(e.defaultSets(for: b.id).map(\.weight), [110])
    }

    /// A same-every-set exercise done with different sets in a workout turns
    /// varying, so a later editor save keeps what was done.
    func testWorkoutWithDifferentSetsTurnsVaryOn() throws {
        let ctx = TestSupport.makeContext()
        let m = Machine(name: "Chest Press"); m.weight = 90; ctx.insert(m)
        let e = Exercise(name: "Chest Press"); ctx.insert(e)
        e.kind = .machine; e.reps = 10; e.sets = 3; e.machineIds = [m.id]
        ExerciseLegacyFields.write(e, machines: [m], context: ctx)
        XCTAssertFalse(e.varyBySet)

        RoutineRepository(ctx).updateExerciseDefaults(exerciseId: e.id, machineId: m.id, sets: [(10, 90), (8, 100), (6, 110)])
        ExerciseLegacyFields.readBackSets(e, machineId: m.id, context: ctx)
        ExerciseLegacyFields.write(e, machines: [m], context: ctx)   // e.g. an editor save

        XCTAssertTrue(e.varyBySet)
        XCTAssertEqual(e.defaultSets(for: m.id).map(\.weight), [90, 100, 110])
    }

    func testMigrationVariesWhenMachinesHaveDifferentSetCounts() throws {
        let ctx = TestSupport.makeContext()
        let a = Machine(name: "Hammer"); let b = Machine(name: "Cybex")
        ctx.insert(a); ctx.insert(b)
        let e = Exercise(name: "Chest Press"); e.defaultSectionType = .strength
        e.machineIds = [a.id, b.id]; ctx.insert(e)
        let repo = RoutineRepository(ctx)
        repo.updateExerciseDefaults(exerciseId: e.id, machineId: a.id, sets: [(10, 90), (10, 90), (10, 90)])
        repo.updateExerciseDefaults(exerciseId: e.id, machineId: b.id, sets: [(10, 110), (10, 110)])

        ExerciseStructureMigration(ctx).run()

        XCTAssertTrue(e.varyBySet)
        XCTAssertEqual(e.defaultSets(for: b.id).count, 2)
    }

    func testMigrationTurnsVaryOnOnlyWhereSetsDiffer() throws {
        let ctx = TestSupport.makeContext()
        let m = Machine(name: "Shoulder Press"); ctx.insert(m)
        let press = Exercise(name: "Shoulder Press"); press.defaultSectionType = .strength
        press.machineIds = [m.id]; ctx.insert(press)
        let squat = Exercise(name: "Goblet Squat"); squat.defaultSectionType = .strength; ctx.insert(squat)
        let repo = RoutineRepository(ctx)
        repo.updateExerciseDefaults(exerciseId: press.id, machineId: m.id, sets: [(12, 40), (10, 40)])
        repo.updateExerciseDefaults(exerciseId: squat.id, sets: [(10, 25), (10, 25)])

        ExerciseStructureMigration(ctx).run()

        XCTAssertTrue(press.varyBySet)
        XCTAssertEqual(press.defaultSets(for: m.id).map(\.reps), [12, 10])   // not flattened
        XCTAssertFalse(squat.varyBySet)
    }

    func testSummaryShowsRanges() throws {
        let ctx = TestSupport.makeContext()
        let (e, a, b) = varyingMachineExercise(ctx)
        ExerciseLegacyFields.write(e, machines: [a, b], context: ctx)
        XCTAssertEqual(e.summary, "Machine · 3 sets · 90–110 lb × 6–10")

        XCTAssertEqual(SetRangeText.text([(10, 0), (8, 0)], unit: "lb"), "2 sets · 8–10 reps")
        XCTAssertEqual(SetRangeText.text([(10, 5), (10, 10)], unit: "lb", addedWeight: true), "2 sets · +5–10 lb × 10")
        XCTAssertEqual(SetRangeText.text([(10, 50)], unit: "kg"), "1 set · 50 kg × 10")
    }

    func testBackupRoundTrip() throws {
        let src = TestSupport.makeContext()
        let (e, a, b) = varyingMachineExercise(src)
        ExerciseLegacyFields.write(e, machines: [a, b], context: src)
        let plain = Exercise(name: "Row"); src.insert(plain); plain.kind = .freeWeight
        try src.save()
        let data = try ExportImportService(src).exportJSONData()

        let dst = TestSupport.makeContext()
        _ = try ExportImportService(dst).importJSON(data)
        let all = try dst.fetch(FetchDescriptor<Exercise>())
        let back = try XCTUnwrap(all.first { $0.id == e.id })
        XCTAssertTrue(back.varyBySet)
        XCTAssertEqual(back.defaultSets(for: a.id).map(\.weight), [90, 100, 110])
        XCTAssertEqual(back.defaultSets(for: b.id).map(\.weight), [110])
        XCTAssertFalse(try XCTUnwrap(all.first { $0.id == plain.id }).varyBySet)
    }
}
