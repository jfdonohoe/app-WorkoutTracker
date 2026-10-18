//
//  GuidedReplanTests.swift
//  WorkoutTrackerTests
//
//  Changing a stretch's reps / sets / timer mid-run re-plans the steps not
//  yet played (GuidedTimerService.replan), keeping what's done; dropping
//  below what's done finishes the stretch. Captions name the set and side.
//

import XCTest
@testable import WorkoutTracker

@MainActor
final class GuidedReplanTests: XCTestCase {

    /// Shoulder Circles from the import sheet: 10 reps, 2 sets, forward/back.
    private func circles(sets: Int = 2, timer: Int = 60) -> WorkoutSessionExercise {
        let se = WorkoutSessionExercise(name: "Shoulder Circles", sectionType: .stretching, order: 0, plannedRestBetweenSets: 0)
        se.kindRaw = ExerciseKind.dynamicStretch.rawValue
        se.reps = 10; se.setCount = sets; se.perSideRaw = PerSide.forwardBack.rawValue; se.countTimerSeconds = timer
        return se
    }

    private func crossovers() -> WorkoutSessionExercise {
        let se = WorkoutSessionExercise(name: "Arm Crossovers", sectionType: .stretching, order: 1, plannedRestBetweenSets: 0)
        se.kindRaw = ExerciseKind.dynamicStretch.rawValue
        se.reps = 15; se.setCount = 1; se.perSideRaw = PerSide.single.rawValue; se.countTimerSeconds = 45
        return se
    }

    func testCaptionsNameTheSetAndSide() {
        let work = GuidedPlan.phases(for: [circles()]).filter { !$0.isTransition }
        XCTAssertEqual(work.map(\.caption), ["Set 1 of 2 · Forward", "Set 1 of 2 · Back",
                                             "Set 2 of 2 · Forward", "Set 2 of 2 · Back"])
        let ready = GuidedPlan.phases(for: [circles()]).filter(\.isTransition)
        XCTAssertEqual(ready[1].caption, "Set 2 of 2 · Forward")   // "Get ready · Set 2 of 2 · Forward"
    }

    func testDroppingToOneSetAfterSetOneFinishesTheStretch() {
        let a = circles(), b = crossovers()
        let timer = GuidedTimerService()
        var finished: [UUID] = []
        timer.onExerciseFinished = { finished.append($0) }
        let t0 = Date()
        timer.start(phases: GuidedPlan.phases(for: [a, b]), finishedTitle: "Stretches complete", now: t0)
        timer.tick(now: t0.addingTimeInterval(70))    // Set 1 · Back playing
        XCTAssertEqual(timer.current?.caption, "Set 1 of 2 · Back")

        a.setCount = 1
        timer.replan(a, now: t0.addingTimeInterval(70))

        XCTAssertEqual(timer.current?.caption, "Back")
        XCTAssertEqual(timer.current?.endsExercise, true)
        XCTAssertEqual(timer.remainingSeconds, 55)        // the playing step keeps its time
        timer.tick(now: t0.addingTimeInterval(126))   // Back ends → Shoulder Circles done
        XCTAssertEqual(finished, [a.id])
        XCTAssertEqual(timer.currentExerciseId, b.id)
        timer.stop()
    }

    func testDroppingSetsDuringTheGetReadyFinishesNow() {
        let a = circles(), b = crossovers()
        let timer = GuidedTimerService()
        var finished: [UUID] = []
        timer.onExerciseFinished = { finished.append($0) }
        let t0 = Date()
        timer.start(phases: GuidedPlan.phases(for: [a, b]), finishedTitle: "Stretches complete", now: t0)
        timer.tick(now: t0.addingTimeInterval(127))   // get ready for Set 2 · Forward
        XCTAssertEqual(timer.current?.isTransition, true)
        XCTAssertEqual(timer.current?.caption, "Set 2 of 2 · Forward")

        a.setCount = 1
        timer.replan(a, now: t0.addingTimeInterval(127))

        XCTAssertEqual(finished, [a.id])
        XCTAssertEqual(timer.currentExerciseId, b.id)   // straight into Arm Crossovers' get-ready
        XCTAssertEqual(timer.current?.isTransition, true)
        XCTAssertEqual(timer.remainingSeconds, StretchTiming.transitionSeconds)
        timer.stop()
    }

    func testAddingASetAndChangingTheTimerReplansTheRest() {
        let a = circles()
        let timer = GuidedTimerService()
        let t0 = Date()
        timer.start(phases: GuidedPlan.phases(for: [a]), finishedTitle: "Stretches complete", now: t0)
        timer.tick(now: t0.addingTimeInterval(10))

        a.setCount = 3; a.countTimerSeconds = 30
        timer.replan(a, now: t0.addingTimeInterval(10))

        let work = timer.phases.filter { !$0.isTransition }
        XCTAssertEqual(work.count, 6)
        XCTAssertEqual(work.first?.seconds, 60)                         // playing step unchanged
        XCTAssertEqual(work.dropFirst().map(\.seconds), [30, 30, 30, 30, 30])
        XCTAssertEqual(work.filter(\.endsExercise).count, 1)
        XCTAssertEqual(work.last?.caption, "Set 3 of 3 · Back")
        XCTAssertEqual(timer.remainingSeconds, 50)
        timer.stop()
    }

    func testReplanOfAStretchNotYetReachedSwapsItsSteps() {
        let a = circles(), b = crossovers()
        let timer = GuidedTimerService()
        timer.start(phases: GuidedPlan.phases(for: [a, b]), finishedTitle: "Stretches complete")
        b.setCount = 2
        timer.replan(b)
        let bWork = timer.phases.filter { $0.exerciseId == b.id && !$0.isTransition }
        XCTAssertEqual(bWork.map(\.caption), ["Set 1 of 2", "Set 2 of 2"])
        XCTAssertEqual(timer.phases.filter { $0.exerciseId == b.id }.first?.caption, "Next stretch")
        timer.stop()
    }

    func testDroppingSetsOnSetTwoKeepsTheSideAndEndsAfterIt() {
        let a = circles()
        let timer = GuidedTimerService()
        let t0 = Date()
        timer.start(phases: GuidedPlan.phases(for: [a]), finishedTitle: "Stretches complete", now: t0)
        timer.tick(now: t0.addingTimeInterval(135))   // Set 2 · Forward playing
        XCTAssertEqual(timer.current?.caption, "Set 2 of 2 · Forward")

        a.setCount = 1
        timer.replan(a, now: t0.addingTimeInterval(135))

        XCTAssertEqual(timer.current?.caption, "Forward")
        XCTAssertEqual(timer.current?.endsExercise, true)
        XCTAssertNil(timer.next)
        timer.stop()
    }

    func testPlayingStepKeepsItsDetailWhenTheTimerChanges() {
        let a = circles()
        let timer = GuidedTimerService()
        timer.start(phases: GuidedPlan.phases(for: [a]), finishedTitle: "Stretches complete")
        a.reps = 12; a.countTimerSeconds = 30
        timer.replan(a)
        XCTAssertEqual(timer.current?.detail, "10 reps")     // what the running 60 s is for
        XCTAssertEqual(timer.current?.seconds, 60)
        XCTAssertEqual(timer.phases.last?.detail, "12 reps")
        timer.stop()
    }

    func testFinishingTheLastStretchWhilePausedEndsTheRun() {
        let a = circles()
        let timer = GuidedTimerService()
        var finished: [UUID] = []
        var sequenceDone: UUID?
        timer.onExerciseFinished = { finished.append($0) }
        timer.onSequenceFinished = { sequenceDone = $0 }
        let t0 = Date()
        timer.start(phases: GuidedPlan.phases(for: [a]), finishedTitle: "Stretches complete", now: t0)
        timer.tick(now: t0.addingTimeInterval(127))   // get ready for Set 2
        timer.pause(now: t0.addingTimeInterval(127))

        a.setCount = 1
        timer.replan(a, now: t0.addingTimeInterval(127))

        XCTAssertEqual(finished, [a.id])
        XCTAssertEqual(sequenceDone, a.id)
        XCTAssertFalse(timer.isActive)
    }

    func testFinishingWhilePausedHoldsTheNextStretchPaused() {
        let a = circles(), b = crossovers()
        let timer = GuidedTimerService()
        let t0 = Date()
        timer.start(phases: GuidedPlan.phases(for: [a, b]), finishedTitle: "Stretches complete", now: t0)
        timer.tick(now: t0.addingTimeInterval(127))
        timer.pause(now: t0.addingTimeInterval(127))

        a.setCount = 1
        timer.replan(a, now: t0.addingTimeInterval(127))

        XCTAssertEqual(timer.currentExerciseId, b.id)
        XCTAssertFalse(timer.isRunning)
        timer.resume(now: t0.addingTimeInterval(200))
        timer.tick(now: t0.addingTimeInterval(203))
        XCTAssertEqual(timer.remainingSeconds, 2)            // the full 5 s get-ready, from resume
        timer.stop()
    }

    // MARK: - Steady cardio (duration / intensity editable mid-run)

    private func elliptical(minutes: Int = 10) -> WorkoutSessionExercise {
        let se = WorkoutSessionExercise(name: "Elliptical", sectionType: .cardio, order: 0, plannedRestBetweenSets: 0)
        se.kindRaw = ExerciseKind.steady.rawValue
        se.durationMinutes = minutes
        se.effortRaw = Intensity.moderate.rawValue
        return se
    }

    func testLongerCardioMovesTheEndAndKeepsTheTimeDone() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let ex = elliptical()
        let timer = GuidedTimerService()
        timer.start(phases: GuidedPlan.phases(for: [ex]), finishedTitle: "Cardio complete", now: t0)
        timer.tick(now: t0.addingTimeInterval(120))          // 2 of 10 min done
        ex.durationMinutes = 15
        timer.replan(ex, now: t0.addingTimeInterval(120))
        XCTAssertEqual(timer.current?.seconds, 900)
        XCTAssertEqual(timer.remainingSeconds, 780)          // 13 min left
        XCTAssertEqual(timer.current?.detail, "15 min · Moderate")
        timer.stop()
    }

    func testShorterCardioThanTheTimeDoneFinishesIt() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let ex = elliptical()
        let timer = GuidedTimerService()
        var finished: [UUID] = []
        timer.onExerciseFinished = { finished.append($0) }
        timer.start(phases: GuidedPlan.phases(for: [ex]), finishedTitle: "Cardio complete", now: t0)
        timer.tick(now: t0.addingTimeInterval(400))          // 6:40 done
        ex.durationMinutes = 5
        timer.replan(ex, now: t0.addingTimeInterval(400))
        XCTAssertEqual(finished, [ex.id])
        XCTAssertFalse(timer.isActive)
    }

    func testIntensityChangeKeepsTheTime() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let ex = elliptical()
        let timer = GuidedTimerService()
        timer.start(phases: GuidedPlan.phases(for: [ex]), finishedTitle: "Cardio complete", now: t0)
        timer.tick(now: t0.addingTimeInterval(60))
        ex.effortRaw = Intensity.hard.rawValue
        timer.replan(ex, now: t0.addingTimeInterval(60))
        XCTAssertEqual(timer.remainingSeconds, 540)
        XCTAssertEqual(timer.current?.detail, "10 min · \(Intensity.hard.displayName)")
        timer.stop()
    }

    func testShorterCardioWhilePausedStaysPaused() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let ex = elliptical()
        let timer = GuidedTimerService()
        timer.start(phases: GuidedPlan.phases(for: [ex]), finishedTitle: "Cardio complete", now: t0)
        timer.tick(now: t0.addingTimeInterval(120))
        timer.pause(now: t0.addingTimeInterval(120))         // 8 min left
        ex.durationMinutes = 5
        timer.replan(ex, now: t0.addingTimeInterval(300))
        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(timer.remainingSeconds, 180)          // 3 min left
        timer.resume(now: t0.addingTimeInterval(400))
        timer.tick(now: t0.addingTimeInterval(450))
        XCTAssertEqual(timer.remainingSeconds, 130)
        timer.stop()
    }
}
