//
//  RestTimerStateTests.swift
//  WorkoutTrackerTests
//
//  The rest ring sits in the set's action slot while a rest is running OR
//  paused, so `isActive` must clear whenever the rest is stopped or skipped —
//  otherwise a stale paused ring hides Complete Set in the next exercise or
//  workout.
//

import XCTest
@testable import WorkoutTracker

@MainActor
final class RestTimerStateTests: XCTestCase {

    func testPausedRestIsActiveUntilStopped() {
        let timer = RestTimerService()
        timer.start(seconds: 60, title: "Rest between sets")
        timer.pause()
        XCTAssertTrue(timer.isPaused)
        XCTAssertTrue(timer.isActive)

        timer.stop()
        XCTAssertFalse(timer.isPaused)
        XCTAssertFalse(timer.isActive)
    }

    func testSkippingAPausedRestClearsIt() {
        let timer = RestTimerService()
        timer.start(seconds: 60)
        timer.pause()
        timer.reset()
        XCTAssertFalse(timer.isActive)
    }

    func testOverrideKeepsTitleAndPausedLength() {
        let timer = RestTimerService()
        timer.start(seconds: 60, title: "Rest between exercises")
        timer.override(seconds: 90)
        XCTAssertEqual(timer.title, "Rest between exercises")

        timer.pause()
        timer.override(seconds: 120)
        timer.resume()
        XCTAssertTrue(timer.isRunning)
        XCTAssertEqual(timer.remainingSeconds, 120)
        timer.stop()
    }
}
