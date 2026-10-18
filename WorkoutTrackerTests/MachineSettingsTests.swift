//
//  MachineSettingsTests.swift
//  WorkoutTrackerTests
//
//  Tests 22–25: renaming, deleting and the per-machine setting cap.
//
//  Machine settings are SHARED by every routine using the machine but are
//  SNAPSHOT into each session when a workout starts. So the rule under test
//  throughout is the same one: a rename or delete reaches the live machine and
//  every not-yet-locked session, and never reaches locked history.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class MachineSettingsTests: XCTestCase {

    /// A machine-based routine, one finished (locked) session, and one still
    /// in progress — the two states a change has to tell apart.
    private func makeLockedAndOpenSessions(_ ctx: ModelContext)
        -> (machine: Machine, locked: WorkoutSession, open: WorkoutSession) {
        let (routine, _, machine) = TestSupport.buildRoutine(ctx, name: "Settings")
        let workouts = WorkoutRepository(ctx)

        let locked = workouts.startWorkout(from: routine)
        workouts.finishWorkout(locked)
        let open = workouts.startWorkout(from: routine)
        try? ctx.save()

        XCTAssertTrue(locked.isLocked)
        XCTAssertFalse(open.isLocked)
        return (machine!, locked, open)
    }

    private func settings(of session: WorkoutSession) -> [SessionMachineSetting] {
        session.exercises.flatMap(\.machineSettings).sorted { $0.order < $1.order }
    }

    // 22. Renaming reaches the shared definition and every open session, and
    //     leaves locked history reading as it was recorded.
    func test22_renamePropagatesButSpareLockedHistory() throws {
        let ctx = TestSupport.makeContext()
        let (machine, locked, open) = makeLockedAndOpenSessions(ctx)
        XCTAssertEqual(machine.activeSettings.first?.label, "Seat height")

        let target = try XCTUnwrap(settings(of: open).first)
        let exercise = try XCTUnwrap(open.exercises.first)
        WorkoutRepository(ctx).renameSetting(target, to: "  Seat position  ", in: exercise)
        try ctx.save()

        XCTAssertEqual(machine.activeSettings.first?.label, "Seat position", "shared definition not renamed")
        XCTAssertEqual(settings(of: open).first?.label, "Seat position", "open session not updated")
        XCTAssertEqual(settings(of: locked).first?.label, "Seat height", "locked history was rewritten")
    }

    // 23. An empty or whitespace-only name is refused rather than blanking the
    //     setting — the in-workout sheet saves on every keystroke.
    func test23_renameRejectsBlankLabel() throws {
        let ctx = TestSupport.makeContext()
        let (machine, _, open) = makeLockedAndOpenSessions(ctx)
        let target = try XCTUnwrap(settings(of: open).first)
        let exercise = try XCTUnwrap(open.exercises.first)

        WorkoutRepository(ctx).renameSetting(target, to: "   ", in: exercise)
        try ctx.save()

        XCTAssertEqual(target.label, "Seat height")
        XCTAssertEqual(machine.activeSettings.first?.label, "Seat height")
    }

    // 24. Deleting SOFT-deletes the shared definition — sessions reference it by
    //     id, so the row has to stay resolvable — and locked history keeps its
    //     own snapshot of the value.
    func test24_deleteIsSoftAndSparesLockedHistory() throws {
        let ctx = TestSupport.makeContext()
        let (machine, locked, open) = makeLockedAndOpenSessions(ctx)
        let definitionId = try XCTUnwrap(machine.activeSettings.first?.id)

        let target = try XCTUnwrap(settings(of: open).first)
        let exercise = try XCTUnwrap(open.exercises.first)
        WorkoutRepository(ctx).deleteSetting(target, from: exercise)
        try ctx.save()

        // Soft, not hard: the definition row still exists and still resolves.
        let stored = try ctx.fetch(FetchDescriptor<MachineSettingDefinition>())
            .first { $0.id == definitionId }
        XCTAssertNotNil(stored, "definition was hard-deleted; session snapshots would dangle")
        XCTAssertNotNil(stored?.deletedAt, "definition was not soft-deleted")
        XCTAssertTrue(machine.activeSettings.isEmpty, "deleted setting still shows as active")

        XCTAssertTrue(settings(of: open).isEmpty, "open session kept a removed setting")
        XCTAssertEqual(settings(of: locked).count, 1, "locked history lost its snapshot")
        XCTAssertEqual(settings(of: locked).first?.label, "Seat height")
    }

    // 25. A machine accepts up to Machine.maxSettings shared settings; past that
    //     the setting is kept for this workout only rather than being dropped.
    func test25_machineSettingCap() throws {
        let ctx = TestSupport.makeContext()
        let (routine, _, builtMachine) = TestSupport.buildRoutine(ctx, name: "Cap")
        let machine = try XCTUnwrap(builtMachine)
        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        let exercise = try XCTUnwrap(session.exercises.first { $0.machineId == machine.id })
        XCTAssertEqual(machine.activeSettings.count, 1, "precondition: the builder adds one setting")

        // Fill the machine to the cap.
        for i in machine.activeSettings.count..<Machine.maxSettings {
            workouts.addSessionSetting(to: exercise, label: "Setting \(i)", numericValue: i,
                                       otherText: nil, alsoAddToMachine: true)
        }
        try ctx.save()
        XCTAssertEqual(machine.activeSettings.count, Machine.maxSettings)
        XCTAssertGreaterThan(Machine.maxSettings, 4, "the cap should have been raised past the old limit of 4")

        // One more: the machine stays at the cap, but the value is still recorded
        // against this workout so the user's entry isn't silently lost.
        let overflow = try XCTUnwrap(workouts.addSessionSetting(to: exercise, label: "One too many", numericValue: 3,
                                                                otherText: nil, alsoAddToMachine: true))
        try ctx.save()
        XCTAssertEqual(machine.activeSettings.count, Machine.maxSettings, "cap exceeded")
        XCTAssertNil(overflow.definitionId, "overflow setting should be session-local")
        XCTAssertTrue(exercise.machineSettings.contains { $0.id == overflow.id })
    }
}
