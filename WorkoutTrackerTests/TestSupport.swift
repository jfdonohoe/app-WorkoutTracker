//
//  TestSupport.swift
//  WorkoutTrackerTests
//
//  Shared helpers: an in-memory store and a routine builder so each test starts
//  from a clean, known state.
//

import Foundation
import SwiftData
import XCTest
@testable import WorkoutTracker

@MainActor
enum TestSupport {

    /// A fresh in-memory context per test (no disk, no leakage).
    static func makeContext() -> ModelContext {
        AppContainer.makeInMemory().mainContext
    }

    /// Build a routine with one strength section containing one machine-based
    /// exercise. Returns the routine, its exercise catalog entry, and machine.
    @discardableResult
    static func buildRoutine(_ context: ModelContext,
                             name: String = "Test Routine",
                             weight: Double = 100,
                             reps: Int = 10,
                             sets: Int = 3,
                             withMachine: Bool = true) -> (routine: Routine, exercise: Exercise, machine: Machine?) {
        let repo = RoutineRepository(context)
        let routine = repo.createRoutine(name: name)
        let version = routine.activeVersion!
        let strength = repo.addSection(to: version, type: .strength)

        var machine: Machine?
        var machineId: UUID?
        if withMachine {
            let m = Machine(name: "\(name) Machine", source: .user)
            context.insert(m)
            let def = MachineSettingDefinition(label: "Seat height", order: 0, numericValue: 5, source: .user)
            def.machine = m
            m.settingDefinitions.append(def)
            context.insert(def)
            machine = m
            machineId = m.id
        }
        let exercise = Exercise(name: "\(name) Press", machineId: machineId, source: .user)
        context.insert(exercise)
        repo.addExercise(to: strength, exercise: exercise, setCount: sets,
                         plannedWeight: weight, plannedReps: reps)
        try? context.save()
        return (routine, exercise, machine)
    }

    /// First strength RoutineExercise of a routine's active version.
    static func firstExercise(of routine: Routine) -> RoutineExercise {
        routine.activeVersion!.orderedSections
            .first { $0.type == .strength }!
            .orderedExercises.first!
    }
}
