//
//  MultiMachineAndGuidedTests.swift
//  WorkoutTrackerTests
//
//  Covers the October 2026 changes:
//   • a typed-but-not-yet-saved weight on the active set survives an edit to
//     an earlier set (incomplete sets keep their ids through reconcile);
//   • one exercise, several machines, each with its own default sets and
//     settings — chosen by the routine, switchable mid-workout;
//   • the guided cardio / stretch phase plan and its timer;
//   • setting values start at 0; the demo auto-seed opt-out; backups carry
//     the new fields.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class MultiMachineAndGuidedTests: XCTestCase {

    // MARK: - Helpers

    private func makeMachine(_ ctx: ModelContext, _ name: String, setting: String, value: Int) -> Machine {
        let m = Machine(name: name, source: .user)
        ctx.insert(m)
        let def = MachineSettingDefinition(label: setting, order: 0, numericValue: value, source: .user)
        def.machine = m
        m.settingDefinitions.append(def)
        ctx.insert(def)
        return m
    }

    /// A strength exercise on two machines with different default weights,
    /// in a routine that uses `routineMachine`.
    private func twoMachineSetup(_ ctx: ModelContext, routineUses second: Bool)
        -> (routine: Routine, exercise: Exercise, a: Machine, b: Machine) {
        let a = makeMachine(ctx, "Cable A", setting: "Seat", value: 3)
        let b = makeMachine(ctx, "Cable B", setting: "Arm", value: 7)
        let exercise = Exercise(name: "Row", source: .user)
        ctx.insert(exercise)
        exercise.machineIds = [a.id, b.id]
        let repo = RoutineRepository(ctx)
        repo.updateExerciseDefaults(exerciseId: exercise.id, machineId: a.id,
                                    sets: [(reps: 10, weight: 50), (reps: 10, weight: 50)])
        repo.updateExerciseDefaults(exerciseId: exercise.id, machineId: b.id,
                                    sets: [(reps: 8, weight: 90), (reps: 8, weight: 90), (reps: 8, weight: 90)])
        let routine = repo.createRoutine(name: "Pull")
        let section = repo.addSection(to: routine.activeVersion!, type: .strength)
        let re = repo.addExercise(to: section, exercise: exercise,
                                  plannedSets: exercise.defaultSets(for: a.id), restBetweenSets: 60)
        if second { re.machineId = b.id }
        CatalogSyncService(ctx).reconcileExercise(exercise.id)
        try? ctx.save()
        return (routine, exercise, a, b)
    }

    // MARK: - Bug: editing an earlier set wiped the active set's new weight

    func testEditingEarlierSetKeepsLaterSetIdentity() throws {
        let ctx = TestSupport.makeContext()
        let (routine, exercise, _) = TestSupport.buildRoutine(ctx, weight: 100, reps: 10, sets: 3)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        let se = session.exercises.first!
        let ids = se.orderedSets.map(\.id)
        workouts.completeSet(se.orderedSets[0], in: session, actualWeight: 100, actualReps: 10)

        // The sheet keys the active set's typed weight by its id. Editing the
        // completed first set bakes the sets into the catalog and reconciles —
        // which used to delete and recreate set 2 and 3 under new ids.
        workouts.editActual(se.orderedSets[0], in: session, weight: 110)
        let baked = se.orderedSets.map { (reps: $0.actualReps ?? $0.plannedReps, weight: $0.actualWeight ?? $0.plannedWeight) }
        RoutineRepository(ctx).updateExerciseDefaults(exerciseId: exercise.id, machineId: se.machineId, sets: baked)
        CatalogSyncService(ctx).reconcileExercise(exercise.id)
        try ctx.save()

        XCTAssertEqual(se.orderedSets.map(\.id), ids, "incomplete sets must keep their ids")
        XCTAssertEqual(se.orderedSets[0].actualWeight, 110)
    }

    func testReconcileGrowsAndShrinksTailInPlace() throws {
        let ctx = TestSupport.makeContext()
        let (routine, exercise, _) = TestSupport.buildRoutine(ctx, weight: 100, reps: 10, sets: 3)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        let se = session.exercises.first!
        let secondId = se.orderedSets[1].id
        workouts.completeSet(se.orderedSets[0], in: session, actualWeight: 100, actualReps: 10)

        let repo = RoutineRepository(ctx)
        repo.updateExerciseDefaults(exerciseId: exercise.id, sets: Array(repeating: (reps: 6, weight: 140), count: 5))
        CatalogSyncService(ctx).reconcileExercise(exercise.id)
        XCTAssertEqual(se.orderedSets.count, 5)
        XCTAssertEqual(se.orderedSets[1].id, secondId)
        XCTAssertEqual(se.orderedSets.map(\.index), [0, 1, 2, 3, 4])
        XCTAssertEqual(se.orderedSets[4].plannedWeight, 140)

        repo.updateExerciseDefaults(exerciseId: exercise.id, sets: [(reps: 6, weight: 140), (reps: 6, weight: 150)])
        CatalogSyncService(ctx).reconcileExercise(exercise.id)
        try ctx.save()
        XCTAssertEqual(se.orderedSets.count, 2)
        XCTAssertEqual(se.orderedSets[1].id, secondId)
        XCTAssertEqual(se.orderedSets[1].plannedWeight, 150)
    }

    // MARK: - Multiple machines per exercise

    func testDefaultSetsArePerMachine() {
        let ctx = TestSupport.makeContext()
        let (_, exercise, a, b) = twoMachineSetup(ctx, routineUses: false)
        XCTAssertEqual(exercise.machineId, a.id, "first machine is the primary")
        XCTAssertEqual(exercise.defaultSets(for: a.id).map(\.weight), [50, 50])
        XCTAssertEqual(exercise.defaultSets(for: b.id).map(\.weight), [90, 90, 90])
        XCTAssertEqual(exercise.effectiveDefaultSets.map(\.weight), [50, 50])

        // Updating one machine's sets leaves the other alone.
        RoutineRepository(ctx).updateExerciseDefaults(exerciseId: exercise.id, machineId: b.id, sets: [(reps: 5, weight: 100)])
        XCTAssertEqual(exercise.defaultSets(for: a.id).map(\.weight), [50, 50])
        XCTAssertEqual(exercise.defaultSets(for: b.id).map(\.weight), [100])
    }

    func testLegacySetsBelongToPrimaryAndNewMachineFallsBack() {
        let ctx = TestSupport.makeContext()
        let a = makeMachine(ctx, "A", setting: "Seat", value: 1)
        let exercise = Exercise(name: "Press", machineId: a.id, source: .user)
        ctx.insert(exercise)
        // A row saved before multi-machine support has no machineId.
        let legacy = ExerciseDefaultSet(order: 0, reps: 10, weight: 70)
        legacy.exercise = exercise
        exercise.defaultSets.append(legacy)
        ctx.insert(legacy)
        XCTAssertEqual(exercise.machineIds, [a.id], "empty raw list = just the primary")
        XCTAssertEqual(exercise.effectiveDefaultSets.map(\.weight), [70])

        let b = makeMachine(ctx, "B", setting: "Arm", value: 2)
        exercise.machineIds = [a.id, b.id]
        XCTAssertFalse(exercise.hasOwnDefaultSets(for: b.id))
        XCTAssertEqual(exercise.defaultSets(for: b.id).map(\.weight), [70], "no sets yet → primary's")
    }

    /// A routine doesn't choose a machine: even one saved with the second
    /// machine starts its workouts on the exercise's default (first) machine.
    func testWorkoutStartsOnDefaultMachineWhateverTheRoutineSaved() {
        let ctx = TestSupport.makeContext()
        let (routine, _, a, _) = twoMachineSetup(ctx, routineUses: true)
        let session = WorkoutRepository(ctx).startWorkout(from: routine)
        let se = session.exercises.first!
        XCTAssertEqual(se.machineId, a.id)
        XCTAssertEqual(se.orderedSets.map(\.plannedWeight), [50, 50])
        XCTAssertEqual(se.machineSettings.map(\.label), ["Seat"])
        XCTAssertEqual(TestSupport.firstExercise(of: routine).machineId, a.id)
    }

    func testSwitchMachineMidWorkoutKeepsCompletedSets() throws {
        let ctx = TestSupport.makeContext()
        let (routine, _, a, b) = twoMachineSetup(ctx, routineUses: false)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        let se = session.exercises.first!
        XCTAssertEqual(se.machineId, a.id)
        workouts.completeSet(se.orderedSets[0], in: session, actualWeight: 55, actualReps: 10)

        workouts.switchMachine(se, to: b.id, in: session)
        try ctx.save()

        XCTAssertEqual(se.machineId, b.id)
        let sets = se.orderedSets
        XCTAssertEqual(sets.count, 3, "1 completed + machine B's remaining 2")
        XCTAssertTrue(sets[0].isCompleted)
        XCTAssertEqual(sets[0].actualWeight, 55)
        XCTAssertEqual(sets[1].plannedWeight, 90)
        XCTAssertEqual(se.machineSettings.map(\.label), ["Arm"], "machine A's settings replaced")
        // The routine still uses machine A.
        XCTAssertEqual(TestSupport.firstExercise(of: routine).machineId, a.id)
    }

    func testSwitchToDeletedMachineIsRefused() {
        let ctx = TestSupport.makeContext()
        let (routine, _, a, b) = twoMachineSetup(ctx, routineUses: false)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        let se = session.exercises.first!
        b.deletedAt = .now
        workouts.switchMachine(se, to: b.id, in: session)
        XCTAssertEqual(se.machineId, a.id)
        XCTAssertEqual(se.machineSettings.map(\.label), ["Seat"])
    }

    func testRemovedMachineFallsBackToPrimary() {
        let ctx = TestSupport.makeContext()
        let (routine, exercise, a, _) = twoMachineSetup(ctx, routineUses: true)
        exercise.machineIds = [a.id]          // machine B removed from the exercise
        CatalogSyncService(ctx).reconcileExercise(exercise.id)
        XCTAssertEqual(TestSupport.firstExercise(of: routine).machineId, a.id)
    }

    // MARK: - Guided plan

    private func stretch(_ name: String, hold: Int, sides: Int, rounds: Int, order: Int, timer: Int = 0) -> WorkoutSessionExercise {
        let se = WorkoutSessionExercise(name: name, sectionType: .stretching, order: order, plannedRestBetweenSets: 0)
        se.holdSeconds = hold; se.sides = sides; se.rounds = rounds; se.countTimerSeconds = timer
        return se
    }

    func testTimedStretchPhases() {
        // Standing hamstring stretch: 30 s, one per leg.
        let ham = stretch("Hamstring", hold: 30, sides: 2, rounds: 1, order: 0)
        let phases = GuidedPlan.phases(for: [ham])
        XCTAssertEqual(phases.map(\.seconds), [30, 5, 30])
        XCTAssertEqual(phases.map(\.isTransition), [false, true, false])
        XCTAssertEqual(phases.map(\.endsExercise), [false, false, true])
        XCTAssertEqual(phases[0].detail, "Side 1 of 2")
        // Every stretch phase, transitions included, is flagged (the panel
        // shows no Stop button for them).
        XCTAssertTrue(phases.allSatisfy(\.isStretch))
    }

    func testCountStretchUsesEstimateThenSavedTimer() {
        let circles = stretch("Hip Circles", hold: 0, sides: 2, rounds: 10, order: 0)
        XCTAssertEqual(GuidedPlan.phases(for: [circles]).map(\.seconds), [30, 5, 30], "10 reps × 3 s")
        circles.countTimerSeconds = 45
        XCTAssertEqual(GuidedPlan.phases(for: [circles]).map(\.seconds), [45, 5, 45])
        XCTAssertEqual(StretchTiming.estimate(reps: 2), 10, "floor of 10 s")
    }

    func testTransitionsBetweenStretchesLeadIntoNext() {
        let a = stretch("A", hold: 20, sides: 1, rounds: 2, order: 0)
        let b = stretch("B", hold: 15, sides: 1, rounds: 1, order: 1)
        let phases = GuidedPlan.phases(for: [a, b])
        XCTAssertEqual(phases.map(\.seconds), [20, 5, 20, 5, 15])
        XCTAssertEqual(phases[3].exerciseId, b.id, "transition belongs to the stretch it leads into")
        XCTAssertEqual(phases.filter(\.endsExercise).map(\.exerciseId), [a.id, b.id])
    }

    func testCardioRunsBackToBackWithNoTransitions() {
        let bike = WorkoutSessionExercise(name: "Bike", sectionType: .cardio, order: 0, plannedRestBetweenSets: 0)
        bike.durationMinutes = 10
        let row = WorkoutSessionExercise(name: "Rower", sectionType: .cardio, order: 1, plannedRestBetweenSets: 0)
        row.durationMinutes = 5
        let phases = GuidedPlan.phases(for: [bike, row])
        XCTAssertEqual(phases.map(\.seconds), [600, 300])
        XCTAssertFalse(phases.contains(where: \.isTransition))
        XCTAssertFalse(phases.contains(where: \.isStretch), "cardio keeps its Stop button")
    }

    // MARK: - Guided timer

    func testGuidedTimerAdvancesAndFinishes() {
        let ham = stretch("Hamstring", hold: 30, sides: 2, rounds: 1, order: 0)
        let next = stretch("Calf", hold: 10, sides: 1, rounds: 1, order: 1)
        let timer = GuidedTimerService()
        var finished: [UUID] = []
        var sequenceDone: UUID?
        timer.onExerciseFinished = { finished.append($0) }
        timer.onSequenceFinished = { sequenceDone = $0 }

        let t0 = Date()
        timer.start(phases: GuidedPlan.phases(for: [ham, next]), finishedTitle: "Stretches complete", now: t0)
        timer.tick(now: t0.addingTimeInterval(10))
        XCTAssertEqual(timer.index, 0)
        XCTAssertEqual(timer.remainingSeconds, 20)

        timer.tick(now: t0.addingTimeInterval(31))     // into the transition
        XCTAssertEqual(timer.current?.isTransition, true)
        timer.tick(now: t0.addingTimeInterval(66))     // side 2 done → hamstring complete
        XCTAssertEqual(finished, [ham.id])
        XCTAssertEqual(timer.currentExerciseId, next.id)

        timer.tick(now: t0.addingTimeInterval(500))    // phone was locked: catch up to the end
        XCTAssertEqual(finished, [ham.id, next.id])
        XCTAssertEqual(sequenceDone, next.id)
        XCTAssertFalse(timer.isActive)
    }

    func testGuidedTimerPauseHoldsTime() {
        let ham = stretch("Hamstring", hold: 30, sides: 1, rounds: 1, order: 0)
        let timer = GuidedTimerService()
        let t0 = Date()
        timer.start(phases: GuidedPlan.phases(for: [ham]), finishedTitle: "Stretches complete", now: t0)
        timer.tick(now: t0.addingTimeInterval(10))
        timer.pause(now: t0.addingTimeInterval(10))
        timer.tick(now: t0.addingTimeInterval(100))
        XCTAssertTrue(timer.isActive)
        XCTAssertEqual(timer.remainingSeconds, 20)
        timer.resume(now: t0.addingTimeInterval(100))
        timer.tick(now: t0.addingTimeInterval(115))
        XCTAssertEqual(timer.remainingSeconds, 5)
        timer.stop()
    }

    func testSkipFinishesExercise() {
        let ham = stretch("Hamstring", hold: 30, sides: 1, rounds: 1, order: 0)
        let timer = GuidedTimerService()
        var finished: [UUID] = []
        timer.onExerciseFinished = { finished.append($0) }
        timer.start(phases: GuidedPlan.phases(for: [ham]), finishedTitle: "Stretches complete")
        timer.skipPhase()
        XCTAssertEqual(finished, [ham.id])
        XCTAssertFalse(timer.isActive)
    }

    // MARK: - Settings, demo opt-out, backup

    func testSettingValuesStartAtZero() {
        XCTAssertEqual(MachineSettingDefinition.valueRange.lowerBound, 0)
        XCTAssertEqual(MachineSettingDefinition.valueRange.upperBound, 15)
    }

    func testDemoAutoSeedOptOut() {
        let defaults = UserDefaults.standard
        let keys = [SeedDataService.autoSeedDisabledKey, SeedDataService.hasGraduatedFromDemoKey, SeedDataService.userDeletedDemoKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { defaults.set(v, forKey: k) } }
        defaults.removeObject(forKey: SeedDataService.hasGraduatedFromDemoKey)
        defaults.removeObject(forKey: SeedDataService.userDeletedDemoKey)

        let ctx = TestSupport.makeContext()
        defaults.set(true, forKey: SeedDataService.autoSeedDisabledKey)
        SeedDataService(ctx).reconcileDemoData()
        XCTAssertFalse(DemoDataManager(ctx).hasDemoData(), "opted out → nothing seeded")

        defaults.set(false, forKey: SeedDataService.autoSeedDisabledKey)
        SeedDataService(ctx).reconcileDemoData()
        XCTAssertTrue(DemoDataManager(ctx).hasDemoData(), "default behaviour unchanged")
    }

    func testBackupRoundTripsMachinesAndCountTimer() throws {
        let ctx = TestSupport.makeContext()
        let (_, exercise, a, b) = twoMachineSetup(ctx, routineUses: true)
        exercise.countTimerSeconds = 40
        try ctx.save()
        let data = try ExportImportService(ctx).exportJSONData()

        let fresh = TestSupport.makeContext()
        _ = try ExportImportService(fresh).importJSON(data)
        let restored = try XCTUnwrap(try fresh.fetch(FetchDescriptor<Exercise>()).first { $0.id == exercise.id })
        XCTAssertEqual(restored.machineIds, [a.id, b.id])
        XCTAssertEqual(restored.countTimerSeconds, 40)
        XCTAssertEqual(restored.defaultSets(for: b.id).map(\.weight), [90, 90, 90])
        XCTAssertEqual(restored.defaultSets(for: a.id).map(\.weight), [50, 50])
    }

    /// Per-machine photos: a machine's own photo wins, others fall back to the
    /// exercise photo, and machine photos survive a backup round trip.
    func testMachinePhotoFallbackAndRoundTrip() throws {
        let ctx = TestSupport.makeContext()
        let (_, exercise, a, b) = twoMachineSetup(ctx, routineUses: true)
        let exercisePhoto = Data([1, 2, 3]), machinePhoto = Data([4, 5, 6])
        exercise.photoData = exercisePhoto
        b.photoData = machinePhoto
        try ctx.save()
        XCTAssertEqual(exercise.photo(on: b.id, in: ctx), machinePhoto)
        XCTAssertEqual(exercise.photo(on: a.id, in: ctx), exercisePhoto)
        XCTAssertEqual(exercise.photo(on: nil, in: ctx), exercisePhoto)

        let data = try ExportImportService(ctx).exportJSONData()
        let fresh = TestSupport.makeContext()
        _ = try ExportImportService(fresh).importJSON(data)
        let restoredB = try XCTUnwrap(try fresh.fetch(FetchDescriptor<Machine>()).first { $0.id == b.id })
        XCTAssertEqual(restoredB.photoData, machinePhoto)
    }
}
