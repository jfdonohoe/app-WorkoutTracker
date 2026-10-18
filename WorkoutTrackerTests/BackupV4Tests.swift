//
//  BackupV4Tests.swift
//  WorkoutTrackerTests
//
//  Backup formatVersion 4 carries the exercise structure; the bundled demo
//  data is already in it.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class BackupV4Tests: XCTestCase {

    func testStructureSurvivesBackupAndRestore() throws {
        let src = TestSupport.makeContext()
        let m = Machine(name: "Y Circuit"); m.weight = 45; src.insert(m)
        let e = Exercise(name: "Lunge"); src.insert(e)
        e.kind = .freeWeight; e.reps = 8; e.sets = 2; e.weight = 20; e.perSide = .leftRight
        e.implement = .dumbbell; e.effort = .hard
        let iv = Exercise(name: "Bike Sprints"); src.insert(iv)
        iv.kind = .intervals; iv.rounds = 6; iv.workSeconds = 40; iv.recoverySeconds = 20
        ExerciseLegacyFields.write(e, machines: [], context: src)
        ExerciseLegacyFields.write(iv, machines: [], context: src)
        let repo = RoutineRepository(src)
        let routine = repo.createRoutine(name: "R")
        let section = repo.addSection(to: routine.activeVersion!, type: .strength)
        repo.addExercise(to: section, exercise: e, plannedSets: e.effectiveDefaultSets, restBetweenSets: 60)
        let s = WorkoutRepository(src).startWorkout(from: routine)
        let set = s.exercises.first!.orderedSets.first!
        WorkoutRepository(src).completeSet(set, in: s, actualWeight: 20, actualReps: 8)
        try src.save()
        let data = try ExportImportService(src).exportJSONData()

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(BackupDocument.self, from: data)
        XCTAssertEqual(doc.formatVersion, 4)
        XCTAssertNil(doc.exercises.first { $0.id == e.id }?.defaultRest)   // no longer written

        let dst = TestSupport.makeContext()
        _ = try ExportImportService(dst).importJSON(data)
        let back = try XCTUnwrap(try dst.fetch(FetchDescriptor<Exercise>()).first { $0.id == e.id })
        XCTAssertEqual(back.kind, .freeWeight)
        XCTAssertEqual(back.perSide, .leftRight)
        XCTAssertEqual(back.implement, .dumbbell)
        XCTAssertEqual(back.weight, 20)
        let ivBack = try XCTUnwrap(try dst.fetch(FetchDescriptor<Exercise>()).first { $0.id == iv.id })
        XCTAssertEqual([ivBack.rounds, ivBack.workSeconds, ivBack.recoverySeconds], [6, 40, 20])
        XCTAssertEqual(try dst.fetch(FetchDescriptor<Machine>()).first { $0.id == m.id }?.weight, 45)
        let se = try XCTUnwrap(try dst.fetch(FetchDescriptor<WorkoutSessionExercise>()).first)
        XCTAssertEqual(se.kind, .freeWeight)
        XCTAssertEqual(se.orderedSets.map(\.side), ["Left", "Right", "Left", "Right"])
    }

    func testDemoDataArrivesInTheNewStructure() throws {
        let ctx = TestSupport.makeContext()
        SeedDataService(ctx).seed()
        let exercises = try ctx.fetch(FetchDescriptor<Exercise>())
        XCTAssertFalse(exercises.isEmpty)
        XCTAssertTrue(exercises.allSatisfy { $0.kind != nil })
        XCTAssertEqual(exercises.first { $0.name == "Shoulder Circles" }?.kind, .dynamicStretch)
        XCTAssertEqual(exercises.first { $0.name == "Standing Calf Stretch" }?.perSide, .leftRight)
        let press = try XCTUnwrap(exercises.first { $0.name == "Shoulder Press" })
        XCTAssertEqual(press.kind, .machine)
        let machines = try ctx.fetch(FetchDescriptor<Machine>())
        XCTAssertEqual(machines.first { press.machineIds.contains($0.id) }?.weight, 45)
    }
}
