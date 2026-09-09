//
//  ExportCompletenessTests.swift
//  WorkoutTrackerTests
//
//  Tests 18–21: a backup must be able to reproduce the store it came from.
//
//  These exist because formatVersion 1 exported only the set-based half of a
//  session. Cardio and stretching exercises have no WorkoutSessionSet rows —
//  their entire result lives in markedCompleteAt / durationMinutes / intensity /
//  holdSeconds / sides / rounds on WorkoutSessionExercise — so a v1 backup
//  restored every one of them as never-performed, including inside locked,
//  completed sessions. The append-only AuditEvent log was dropped wholesale.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class ExportCompletenessTests: XCTestCase {

    /// The backup format encodes dates as ISO-8601 without fractional seconds
    /// (`JSONEncoder.dateEncodingStrategy = .iso8601`), so a round trip is
    /// accurate to the second, not the millisecond. That is a property of the
    /// format, not of the fields under test here.
    private func assertSameInstant(_ lhs: Date?, _ rhs: Date?, _ message: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        switch (lhs, rhs) {
        case (nil, nil):
            break
        case let (l?, r?):
            XCTAssertEqual(l.timeIntervalSince1970, r.timeIntervalSince1970, accuracy: 1.0,
                           message, file: file, line: line)
        default:
            XCTFail("\(message) — one side is nil (\(String(describing: lhs)) vs \(String(describing: rhs)))",
                    file: file, line: line)
        }
    }

    /// A routine with one cardio, one stretching and one strength exercise, run
    /// as a session with every non-set exercise marked complete.
    private func makeMixedSession(_ ctx: ModelContext) -> WorkoutSession {
        let routines = RoutineRepository(ctx)
        let routine = routines.createRoutine(name: "Mixed")
        let version = routine.activeVersion!

        let cardioSection = routines.addSection(to: version, type: .cardio, durationMinutes: 10)
        let cardio = Exercise(name: "Elliptical", source: .user)
        cardio.durationMinutes = 12
        cardio.intensityRaw = CardioIntensity.moderate.rawValue
        ctx.insert(cardio)
        routines.addExercise(to: cardioSection, exercise: cardio)

        let stretchSection = routines.addSection(to: version, type: .stretching)
        let stretch = Exercise(name: "Hamstring Stretch", source: .user)
        stretch.holdSeconds = 30
        stretch.sides = 2
        stretch.rounds = 3
        ctx.insert(stretch)
        routines.addExercise(to: stretchSection, exercise: stretch)

        let strengthSection = routines.addSection(to: version, type: .strength)
        let press = Exercise(name: "Chest Press", source: .user)
        ctx.insert(press)
        routines.addExercise(to: strengthSection, exercise: press, setCount: 2, plannedWeight: 80, plannedReps: 12)
        try? ctx.save()

        let workouts = WorkoutRepository(ctx)
        let session = workouts.startWorkout(from: routine)
        for se in session.exercises where !se.hasSets {
            workouts.markExerciseComplete(se, in: session)
        }
        for set in session.exercises.flatMap(\.orderedSets) {
            workouts.completeSet(set, in: session, actualWeight: 80, actualReps: 12)
        }
        workouts.finishWorkout(session)
        try? ctx.save()
        return session
    }

    // 18. Cardio/stretching results survive a full export → import round trip.
    func test18_nonSetExerciseResultsSurviveRoundTrip() throws {
        let ctx1 = TestSupport.makeContext()
        let original = makeMixedSession(ctx1)
        XCTAssertTrue(original.isLocked, "precondition: the session is finished and locked")

        let expected = Dictionary(uniqueKeysWithValues: original.exercises.map { ($0.id, $0) })
        let data = try ExportImportService(ctx1).exportJSONData()

        let ctx2 = TestSupport.makeContext()
        _ = try ExportImportService(ctx2).importJSON(data)
        try ctx2.save()

        let restored = try ctx2.fetch(FetchDescriptor<WorkoutSessionExercise>())
        XCTAssertEqual(restored.count, expected.count)

        for se in restored {
            let was = try XCTUnwrap(expected[se.id], "restored an exercise that was not exported")
            assertSameInstant(se.markedCompleteAt, was.markedCompleteAt, "\(se.name): completion lost")
            XCTAssertEqual(se.durationMinutes, was.durationMinutes, "\(se.name): duration lost")
            XCTAssertEqual(se.intensityRaw, was.intensityRaw, "\(se.name): intensity lost")
            XCTAssertEqual(se.holdSeconds, was.holdSeconds, "\(se.name): hold lost")
            XCTAssertEqual(se.sides, was.sides, "\(se.name): sides lost")
            XCTAssertEqual(se.rounds, was.rounds, "\(se.name): rounds lost")
            XCTAssertEqual(se.groupIndex, was.groupIndex, "\(se.name): group lost")
            assertSameInstant(se.startedAt, was.startedAt, "\(se.name): startedAt lost")
            assertSameInstant(se.endedAt, was.endedAt, "\(se.name): endedAt lost")

            // Guard against the assertions above passing vacuously: the two
            // non-set exercises must genuinely carry a completion timestamp and
            // their own recorded parameters on BOTH sides.
            if !se.hasSets {
                XCTAssertNotNil(se.markedCompleteAt, "\(se.name): restored without a completion timestamp")
                XCTAssertNotNil(was.markedCompleteAt, "\(se.name): precondition — was never marked complete")
                XCTAssertTrue(se.durationMinutes > 0 || se.holdSeconds > 0,
                              "\(se.name): restored with no duration and no hold time")
            }
        }

        // The headline symptom: a restored completed session must still read as
        // complete, not as one where every stretch was skipped.
        let restoredSession = try XCTUnwrap(try ctx2.fetch(FetchDescriptor<WorkoutSession>()).first)
        XCTAssertTrue(restoredSession.allExercisesComplete)
        XCTAssertFalse(restoredSession.exercises.contains { $0.isSkipped })
    }

    // 19. The append-only audit log is exported and restored.
    func test19_auditLogSurvivesRoundTrip() throws {
        let ctx1 = TestSupport.makeContext()
        _ = makeMixedSession(ctx1)
        let originalEvents = try ctx1.fetch(FetchDescriptor<AuditEvent>())
        XCTAssertFalse(originalEvents.isEmpty, "precondition: running a workout writes audit events")

        let doc = ExportImportService(ctx1).makeBackup()
        XCTAssertEqual((doc.auditEvents ?? []).count, originalEvents.count)

        let data = try ExportImportService(ctx1).exportJSONData()
        let ctx2 = TestSupport.makeContext()
        _ = try ExportImportService(ctx2).importJSON(data)
        try ctx2.save()

        let restored = try ctx2.fetch(FetchDescriptor<AuditEvent>())
        let restoredIds = Set(restored.map(\.id))
        for event in originalEvents {
            XCTAssertTrue(restoredIds.contains(event.id), "audit event '\(event.type)' was not restored")
        }
    }

    // 20. A formatVersion 1 backup — no new keys at all — still imports.
    //     Swift's synthesized Codable throws on a missing key rather than using a
    //     property default, so the v2 fields must stay Optional or every older
    //     backup becomes unreadable.
    func test20_version1BackupStillImports() throws {
        let ctx1 = TestSupport.makeContext()
        let original = makeMixedSession(ctx1)
        let data = try ExportImportService(ctx1).exportJSONData()

        // Strip the v2 additions back out, reproducing a v1 file exactly.
        var raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        raw["formatVersion"] = 1
        raw.removeValue(forKey: "auditEvents")
        let v2Keys = ["groupIndex", "startedAt", "endedAt", "durationMinutes",
                      "intensity", "holdSeconds", "sides", "rounds", "markedCompleteAt"]
        raw["sessionExercises"] = (raw["sessionExercises"] as? [[String: Any]] ?? []).map { dto in
            dto.filter { !v2Keys.contains($0.key) }
        }
        let v1Data = try JSONSerialization.data(withJSONObject: raw)

        let ctx2 = TestSupport.makeContext()
        let result = try ExportImportService(ctx2).importJSON(v1Data)
        try ctx2.save()
        XCTAssertGreaterThan(result.added, 0)

        // It imports, and the dropped fields land on the model's own defaults.
        let restored = try ctx2.fetch(FetchDescriptor<WorkoutSessionExercise>())
        XCTAssertEqual(restored.count, original.exercises.count)
        for se in restored {
            XCTAssertNil(se.markedCompleteAt)
            XCTAssertEqual(se.sides, 1)
            XCTAssertEqual(se.rounds, 1)
            XCTAssertEqual(se.holdSeconds, 0)
            XCTAssertEqual(se.durationMinutes, 0)
        }
        // Strength sets were never affected by the v1 gap and still restore.
        XCTAssertEqual(try ctx2.fetchCount(FetchDescriptor<WorkoutSessionSet>()),
                       original.exercises.flatMap(\.sets).count)
    }

    // 21. Import stays non-destructive for the newly exported entities too:
    //     re-importing the same backup must skip, never duplicate.
    func test21_reimportDoesNotDuplicateAuditEvents() throws {
        let ctx1 = TestSupport.makeContext()
        _ = makeMixedSession(ctx1)
        let data = try ExportImportService(ctx1).exportJSONData()

        let ctx2 = TestSupport.makeContext()
        let svc = ExportImportService(ctx2)
        _ = try svc.importJSON(data)
        try ctx2.save()
        let afterFirst = try ctx2.fetchCount(FetchDescriptor<AuditEvent>())

        _ = try svc.importJSON(data)
        try ctx2.save()
        let afterSecond = try ctx2.fetchCount(FetchDescriptor<AuditEvent>())

        // Only the "import.performed" event each import logs about itself is new.
        XCTAssertEqual(afterSecond, afterFirst + 1)
    }
}
