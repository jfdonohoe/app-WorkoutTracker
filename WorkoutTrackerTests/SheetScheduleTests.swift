//
//  SheetScheduleTests.swift
//  WorkoutTrackerTests
//
//  The Google Sheet's Schedule tab: a two-week cycle (Week 1 = the Monday-to-
//  Sunday week holding start_date) that repeats every two weeks, and that
//  replaces every current and future scheduled workout from today.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class SheetScheduleTests: XCTestCase {

    private let cal = Calendar.current
    private func day(_ s: String) -> Date { SheetScheduleImporter.parseDate(s)! }
    /// Wednesday of Week 1.
    private var today: Date { day("2026-10-21") }

    private func grid(start: String = "2026-10-19", _ rows: [String]) -> String {
        "start_date,\(start)\n\nday,week_1,week_2\n" + rows.joined(separator: "\n") + "\n"
    }

    private let cycle = [
        "Monday,Upper,Lower",
        "Tuesday,,",
        "Wednesday,Lower,Upper",
        "Thursday,,",
        "Friday,,",
        "Saturday,,",
        "Sunday,Mobility,",
    ]

    private func setUpRoutines(_ ctx: ModelContext) -> [String: Routine] {
        var out: [String: Routine] = [:]
        for name in ["Upper", "Lower", "Mobility"] {
            out[name] = TestSupport.buildRoutine(ctx, name: name).routine
        }
        return out
    }

    private func rules(_ ctx: ModelContext) -> [ScheduleRule] {
        ((try? ctx.fetch(FetchDescriptor<ScheduleRule>())) ?? []).filter { $0.deletedAt == nil }
    }

    private func scheduled(_ ctx: ModelContext, on date: String) -> Set<UUID> {
        Set(ScheduleService().scheduledRoutineIds(on: day(date), rules: rules(ctx)))
    }

    func testTheCycleRepeatsEveryTwoWeeksFromToday() throws {
        let ctx = TestSupport.makeContext()
        let r = setUpRoutines(ctx)
        let result = try XCTUnwrap(try SheetScheduleImporter(ctx).importText(grid(cycle), today: today))
        XCTAssertEqual(result.workoutsPerCycle, 5)
        XCTAssertTrue(cal.isDate(result.cycleStart, inSameDayAs: day("2026-10-19")))
        XCTAssertTrue(rules(ctx).allSatisfy { $0.freq == .weekly && $0.interval == 2 })

        // Week 1 (Oct 19–25): Monday is already past, so nothing on it.
        XCTAssertEqual(scheduled(ctx, on: "2026-10-19"), [])
        XCTAssertEqual(scheduled(ctx, on: "2026-10-21"), [r["Lower"]!.id])     // today
        XCTAssertEqual(scheduled(ctx, on: "2026-10-25"), [r["Mobility"]!.id])  // Sunday of Week 1
        // Week 2 (Oct 26–Nov 1).
        XCTAssertEqual(scheduled(ctx, on: "2026-10-26"), [r["Lower"]!.id])
        XCTAssertEqual(scheduled(ctx, on: "2026-10-28"), [r["Upper"]!.id])
        XCTAssertEqual(scheduled(ctx, on: "2026-11-01"), [])                   // Sunday of Week 2
        // Week 1 again (Nov 2–8), and Week 2 again.
        XCTAssertEqual(scheduled(ctx, on: "2026-11-02"), [r["Upper"]!.id])
        XCTAssertEqual(scheduled(ctx, on: "2026-11-04"), [r["Lower"]!.id])
        XCTAssertEqual(scheduled(ctx, on: "2026-11-08"), [r["Mobility"]!.id])
        XCTAssertEqual(scheduled(ctx, on: "2026-11-09"), [r["Lower"]!.id])
        XCTAssertEqual(scheduled(ctx, on: "2026-11-24"), [])                   // a Tuesday
    }

    func testItReplacesCurrentAndFutureSchedulesButNotThePast() throws {
        let ctx = TestSupport.makeContext()
        let r = setUpRoutines(ctx)
        // Made in the app: every Tuesday since October 1, and a one-off next week.
        let weekly = ScheduleRule(routineId: r["Upper"]!.id, freq: .weekly, weekdays: [3], startDate: day("2026-10-01"))
        let oneOff = ScheduleRule(routineId: r["Lower"]!.id, freq: .daily, startDate: day("2026-10-27"), count: 1)
        ctx.insert(weekly); ctx.insert(oneOff)
        try ctx.save()

        let result = try XCTUnwrap(try SheetScheduleImporter(ctx).importText(grid(cycle), today: today))
        XCTAssertEqual(result.replaced, 2)
        XCTAssertTrue(ScheduleService().occurs(weekly, on: day("2026-10-20")), "yesterday stays")
        XCTAssertFalse(ScheduleService().occurs(weekly, on: day("2026-10-27")))
        XCTAssertNotNil(oneOff.deletedAt)
        XCTAssertEqual(scheduled(ctx, on: "2026-10-27"), [], "only the sheet's cycle from today on")
    }

    func testAStartDateInAnyDayOfTheWeekMeansThatWeek() throws {
        let ctx = TestSupport.makeContext()
        let r = setUpRoutines(ctx)
        // Saturday Oct 24 is in the week of Monday Oct 19.
        let result = try XCTUnwrap(try SheetScheduleImporter(ctx).importText(grid(start: "10/24/2026", cycle), today: today))
        XCTAssertTrue(cal.isDate(result.cycleStart, inSameDayAs: day("2026-10-19")))
        XCTAssertEqual(scheduled(ctx, on: "2026-10-28"), [r["Upper"]!.id])
    }

    func testAnEmptyGridChangesNothing() throws {
        let ctx = TestSupport.makeContext()
        let r = setUpRoutines(ctx)
        let keep = ScheduleRule(routineId: r["Upper"]!.id, freq: .weekly, weekdays: [3], startDate: day("2026-10-01"))
        ctx.insert(keep)
        XCTAssertNil(try SheetScheduleImporter(ctx).importText(grid(["Monday,,", "Tuesday,,"]), today: today))
        XCTAssertNil(keep.untilDate)
        XCTAssertEqual(rules(ctx).count, 1)
    }

    func testProblemsAreAllReported() {
        let ctx = TestSupport.makeContext()
        _ = setUpRoutines(ctx)
        let bad = "start_date,someday\n\nday,week_1,week_2\nMonday,Upper,Legs\nFunday,Lower,\n"
        XCTAssertThrowsError(try SheetScheduleImporter(ctx).importText(bad, today: today)) { error in
            guard case CSVImportError.invalidData(let list) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(list.contains { $0.contains("start_date") })
            XCTAssertTrue(list.contains { $0.contains("no routine named \"Legs\"") })
            XCTAssertTrue(list.contains { $0.contains("\"Funday\" isn't a day") })
        }
        XCTAssertTrue(rules(ctx).isEmpty)
    }

    func testOneSheetRunAddsRoutinesThenSchedulesThem() throws {
        let ctx = TestSupport.makeContext()
        let tabs = GoogleSheetImport.Tabs(
            exercises: [("Static", .staticStretch, "exercise,kind,hold_seconds\nHamstring Stretch,static,30\n")],
            routines: "routine,order,exercise\nMobility,1,Hamstring Stretch\n",
            schedule: grid(["Monday,Mobility,", "Tuesday,,Mobility"]))
        let report = try GoogleSheetImport.importAll(tabs, into: ctx)
        XCTAssertTrue(report.hasScheduleTab)
        XCTAssertEqual(report.schedule?.workoutsPerCycle, 2)
        XCTAssertEqual(rules(ctx).count, 2)
    }

    func testAScheduleProblemImportsNothing() {
        let ctx = TestSupport.makeContext()
        let tabs = GoogleSheetImport.Tabs(
            exercises: [("Static", .staticStretch, "exercise,kind,hold_seconds\nHamstring Stretch,static,30\n")],
            routines: "routine,order,exercise\nMobility,1,Hamstring Stretch\n",
            schedule: grid(["Monday,Nope,"]))
        XCTAssertThrowsError(try GoogleSheetImport.importAll(tabs, into: ctx))
        XCTAssertTrue(((try? ctx.fetch(FetchDescriptor<Routine>())) ?? []).isEmpty)
        XCTAssertTrue(rules(ctx).isEmpty)
    }

    func testADuplicateRoutineNameIsAProblemAndUserRoutinesWin() throws {
        let ctx = TestSupport.makeContext()
        let r = setUpRoutines(ctx)
        // A demo routine with the same name as the user's: the user's is used.
        let demo = RoutineRepository(ctx).createRoutine(name: "Upper", source: .seedDemo)
        _ = try XCTUnwrap(try SheetScheduleImporter(ctx).importText(grid(["Monday,Upper,"]), today: today))
        XCTAssertTrue(rules(ctx).allSatisfy { $0.routineId == r["Upper"]!.id && $0.routineId != demo.id })
        // Two of the user's own with one name: reported, nothing changed.
        _ = RoutineRepository(ctx).createRoutine(name: "upper", source: .user)
        let before = rules(ctx).count
        XCTAssertThrowsError(try SheetScheduleImporter(ctx).importText(grid(["Monday,Upper,"]), today: today))
        XCTAssertEqual(rules(ctx).count, before)
    }
}
