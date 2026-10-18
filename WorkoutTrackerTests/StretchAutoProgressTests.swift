//
//  StretchAutoProgressTests.swift
//  WorkoutTrackerTests
//
//  Settings ▸ Auto progress through stretches off: a stretch's run still
//  plays its own sets and sides, but when its timer ends nothing is marked
//  complete — the timer is done and the sheet shows Complete & Next.
//

import XCTest
@testable import WorkoutTracker

@MainActor
final class StretchAutoProgressTests: XCTestCase {

    private func stretch(sides: PerSide = .leftRight) -> WorkoutSessionExercise {
        let se = WorkoutSessionExercise(name: "Quad Stretch", sectionType: .stretching, order: 0, plannedRestBetweenSets: 0)
        se.kindRaw = ExerciseKind.staticStretch.rawValue
        se.holdSeconds = 30; se.reps = 1; se.setCount = 1; se.perSideRaw = sides.rawValue
        return se
    }

    func testOffStillPlaysEverySideThenLeavesCompletingToTheUser() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let ex = stretch()
        let timer = GuidedTimerService()
        var finished: [UUID] = [], sequenceDone: UUID?
        timer.onExerciseFinished = { finished.append($0) }
        timer.onSequenceFinished = { sequenceDone = $0 }
        timer.start(phases: GuidedPlan.phases(for: [ex]), finishedTitle: "Stretches complete",
                    completesExercises: false, now: t0)
        timer.tick(now: t0.addingTimeInterval(31))           // Left done → get ready for Right
        XCTAssertTrue(timer.current?.isTransition ?? false)
        timer.tick(now: t0.addingTimeInterval(66))           // Right done: the run ends
        XCTAssertFalse(timer.isActive)
        XCTAssertTrue(finished.isEmpty, "not completed by the timer")
        XCTAssertNil(sequenceDone)
        XCTAssertEqual(timer.timerDoneExerciseId, ex.id)

        timer.clearTimerDone()
        XCTAssertNil(timer.timerDoneExerciseId)
    }

    func testOnCompletesAsBefore() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let ex = stretch(sides: .single)
        let timer = GuidedTimerService()
        var finished: [UUID] = []
        timer.onExerciseFinished = { finished.append($0) }
        timer.start(phases: GuidedPlan.phases(for: [ex]), finishedTitle: "Stretches complete", now: t0)
        timer.tick(now: t0.addingTimeInterval(31))
        XCTAssertEqual(finished, [ex.id])
        XCTAssertNil(timer.timerDoneExerciseId)
    }

    func testStartingAgainClearsTheDoneTimer() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let ex = stretch(sides: .single)
        let timer = GuidedTimerService()
        timer.start(phases: GuidedPlan.phases(for: [ex]), finishedTitle: "", completesExercises: false, now: t0)
        timer.skipPhase(now: t0.addingTimeInterval(5))
        XCTAssertEqual(timer.timerDoneExerciseId, ex.id)
        timer.start(phases: GuidedPlan.phases(for: [ex]), finishedTitle: "", now: t0)
        XCTAssertNil(timer.timerDoneExerciseId)
        timer.stop()
    }

    func testWorkoutSettingsDefaultToOn() {
        let d = UserDefaults.standard
        let saved = (d.object(forKey: WorkoutSettings.timerSoundsKey), d.object(forKey: WorkoutSettings.autoProgressStretchesKey))
        defer {
            d.set(saved.0, forKey: WorkoutSettings.timerSoundsKey)
            d.set(saved.1, forKey: WorkoutSettings.autoProgressStretchesKey)
        }
        d.removeObject(forKey: WorkoutSettings.timerSoundsKey)
        d.removeObject(forKey: WorkoutSettings.autoProgressStretchesKey)
        XCTAssertTrue(WorkoutSettings.timerSounds)
        XCTAssertTrue(WorkoutSettings.autoProgressStretches)
        d.set(false, forKey: WorkoutSettings.autoProgressStretchesKey)
        XCTAssertFalse(WorkoutSettings.autoProgressStretches)
    }
}
