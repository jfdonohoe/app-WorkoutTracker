//
//  GoogleSheetImportTests.swift
//  WorkoutTrackerTests
//
//  The Google Sheet import's offline parts: reading the sheet id from a link,
//  the tab names per group, reading tab ids from the htmlview page, and
//  merging a group's tabs into one CSV that the exercise importer accepts.
//  The download itself needs a shared sheet and the network, so it isn't
//  tested here.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class GoogleSheetImportTests: XCTestCase {

    private func merge(_ tabs: [(String, ExerciseKind, String)]) throws -> GoogleSheetImport.MergedTabs {
        try GoogleSheetImport.mergeExerciseTabs(tabs.map { (tab: $0.0, kind: $0.1, csv: $0.2) })
    }

    private func exercises(_ ctx: ModelContext) -> [String: Exercise] {
        let all = (try? ctx.fetch(FetchDescriptor<Exercise>())) ?? []
        return Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Links and tabs

    func testSpreadsheetIDFromLinks() {
        let id = "1ggqTbvE-JBZunxmw4SbXpPsqTJtLeRrmCTL84HoHA1o"
        XCTAssertEqual(GoogleSheetImport.spreadsheetID(from: "https://docs.google.com/spreadsheets/d/\(id)/edit?gid=101#gid=101"), id)
        XCTAssertEqual(GoogleSheetImport.spreadsheetID(from: "  https://docs.google.com/spreadsheets/d/\(id)/edit?usp=sharing\n"), id)
        XCTAssertEqual(GoogleSheetImport.spreadsheetID(from: "https://docs.google.com/spreadsheets/d/\(id)"), id)
        XCTAssertNil(GoogleSheetImport.spreadsheetID(from: "https://docs.google.com/document/d/\(id)/edit"))
        XCTAssertNil(GoogleSheetImport.spreadsheetID(from: ""))
    }

    func testTabNamesPerGroup() {
        XCTAssertEqual(GoogleSheetImport.exerciseTabs(for: .strength).map(\.tab), ["Machine", "Free weight", "Bodyweight", "Hold"])
        XCTAssertEqual(GoogleSheetImport.exerciseTabs(for: .stretching).map(\.tab), ["Static", "Dynamic"])
        XCTAssertEqual(GoogleSheetImport.exerciseTabs(for: .cardio).map(\.tab), ["Steady", "Distance", "Intervals", "Calisthenics"])
    }

    /// The format of the live htmlview page, including its JS escapes.
    func testTabIDsFromHTMLView() {
        let html = #"""
        items.push({name: "Machine", pageUrl: "https:\/\/docs.google.com\/spreadsheets\/d\/X\/htmlview\/sheet?headers\x3dtrue&gid=101", gid: "101",initialSheet: true});
        items.push({name: "Free weight", pageUrl: "https:\/\/docs.google.com\/x?gid=102", gid: "102"});
        items.push({name: "Upper \x26 Lower \"A\"", pageUrl: "u", gid: "7"});
        """#
        XCTAssertEqual(GoogleSheetImport.parseTabIDs(html),
                       ["Machine": "101", "Free weight": "102", "Upper & Lower \"A\"": "7"])
        XCTAssertEqual(GoogleSheetImport.parseTabIDs("<html>sign in</html>"), [:])
    }

    // MARK: - Merge

    func testMergedStrengthTabsImport() throws {
        let machine = """
        exercise,kind,reps,sets,weight,per_side,machine,setting1_label,setting1_value,photo_url
        Chest Press,machine,12,3,95,single,Chest Press,Seat,4,
        Seated Leg Curl,machine,12,3,80,single,Seated Leg Curl,Y Ankle,L,
        """
        let freeWeight = "exercise,kind,reps,sets,weight,implement,per_side,photo_url\n"   // header only
        let hold = "exercise,kind,hold_seconds,reps,sets,per_side,photo_url\nPlank,hold,45,1,3,single,\n,,,,,,\n"
        let merged = try merge([("Machine", .machine, machine), ("Free weight", .freeWeight, freeWeight),
                                ("Bodyweight", .bodyweight, ""), ("Hold", .hold, hold)])

        let ctx = TestSupport.makeContext()
        let report = try CSVExerciseImporter(ctx, group: .strength).importText(merged.csv)
        XCTAssertEqual(report.exercisesAdded, 3)
        let ex = exercises(ctx)
        XCTAssertEqual(ex["Chest Press"]?.kind, .machine)
        XCTAssertEqual(ex["Plank"]?.kind, .hold)
        XCTAssertEqual(ex["Plank"]?.holdSeconds, 45)
    }

    func testBlankKindTakesTheTabsKind() throws {
        let merged = try merge([("Hold", .hold, "exercise,kind,hold_seconds\nWall Sit,,60\n")])
        let ctx = TestSupport.makeContext()
        _ = try CSVExerciseImporter(ctx, group: .strength).importText(merged.csv)
        XCTAssertEqual(exercises(ctx)["Wall Sit"]?.kind, .hold)
        XCTAssertEqual(exercises(ctx)["Wall Sit"]?.holdSeconds, 60)
    }

    func testMergeQuotesValuesWithCommas() throws {
        let merged = try merge([("Static", .staticStretch, "exercise,kind,hold_seconds\n\"Reach, Fold\",static,30\n")])
        XCTAssertEqual(CSVRoutineImporter.parse(merged.csv)[1], ["Reach, Fold", "static", "30"])
    }

    /// A row of another known kind means the wrong tab; it must not import.
    func testOtherKindInTabIsRejected() {
        XCTAssertThrowsError(try merge([("Hold", .hold, "exercise,kind\nChest Press,machine\n")])) { error in
            guard case GoogleSheetImportError.wrongTab("Hold") = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try merge([("Machine", .machine, "routine,order,exercise\nUpper,1,Chest Press\n")]))
    }

    /// A misspelt kind is left for the importer, whose message names the valid kinds.
    func testUnknownKindPassesThroughToImporter() throws {
        let merged = try merge([("Hold", .hold, "exercise,kind\nPlank,holdd\n")])
        XCTAssertThrowsError(try CSVExerciseImporter(TestSupport.makeContext(), group: .strength).importText(merged.csv)) { error in
            XCTAssertFalse(error is GoogleSheetImportError)
        }
    }

    /// Values under unnamed columns don't make a row; it is skipped as blank.
    func testValuesOnlyUnderBlankHeadersAreSkipped() throws {
        let merged = try merge([("Static", .staticStretch, "exercise,kind,hold_seconds,\nHamstring,static,30,\n,,,stray note\n")])
        XCTAssertEqual(merged.origins.count, 1)
        XCTAssertEqual(try CSVExerciseImporter(TestSupport.makeContext(), group: .stretching).importText(merged.csv).exercisesAdded, 1)
    }

    func testAllEmptyTabsGiveEmptyImport() throws {
        let merged = try merge([("Static", .staticStretch, ""), ("Dynamic", .dynamicStretch, "")])
        XCTAssertEqual(merged.csv, "")
        XCTAssertThrowsError(try CSVExerciseImporter(TestSupport.makeContext(), group: .stretching).importText(merged.csv))
    }

    // MARK: - ^ machines

    private let header = "exercise,kind,reps,sets,weight,per_side,machine,setting1_label,setting1_value,setting2_label,setting2_value,setting3_label,setting3_value\n"
    private let legCurl = "Seated Leg Curl,machine,12,3,80,single,Seated Leg Curl,Ankle,1,Back,4,Thigh,3\n"
    private let legCurlY = "^,,,,85,,Seated Leg Curl (Y),Ankle,L,Pitch,1,Back,4\n"

    private func importMachines(_ ctx: ModelContext, _ csv: String) throws -> CSVImportReport {
        let merged = try merge([("Machine", .machine, csv)])
        return try CSVExerciseImporter(ctx, group: .strength, replaceExisting: true)
            .importText(merged.csv, extraMachines: merged.machines)
    }

    private func machines(of e: Exercise?, _ ctx: ModelContext) -> [Machine] {
        let all = (try? ctx.fetch(FetchDescriptor<Machine>())) ?? []
        return (e?.machineIds ?? []).compactMap { id in all.first { $0.id == id } }
    }

    private func settings(_ m: Machine) -> [String] {
        m.activeSettings.map { "\($0.label) \($0.displayValue)" }
    }

    func testCaretRowAddsAMachine() throws {
        let ctx = TestSupport.makeContext()
        let report = try importMachines(ctx, header + legCurl + legCurlY)
        XCTAssertEqual(report.exercisesAdded, 1)
        let ex = exercises(ctx)["Seated Leg Curl"]
        let ms = machines(of: ex, ctx)
        XCTAssertEqual(ms.map(\.name), ["Seated Leg Curl", "Seated Leg Curl (Y)"])
        XCTAssertEqual(ex?.machineId, ms.first?.id, "the exercise row's machine is the default")
        XCTAssertEqual(ms.map(\.weight), [80, 85])
        XCTAssertEqual(settings(ms[0]), ["Ankle 1", "Back 4", "Thigh 3"])
        XCTAssertEqual(settings(ms[1]), ["Ankle L", "Pitch 1", "Back 4"])
        XCTAssertEqual(ex?.defaultSets(for: ms[1].id).map(\.weight), [85, 85, 85])
    }

    func testCaretRowErrorsNameTheirRow() {
        let cases: [(String, String)] = [
            (header + legCurlY, "Machine row 2: ^ adds a machine"),
            (header + legCurl + ",,,,85,,Other,,,,,,\n", "Machine row 3: no exercise name"),
            (header + legCurl + "^,,12,,,,Other,,,,,,\n", "Machine row 3: a ^ row holds only"),
            (header + legCurl + "^,,,,50,,,,,,,,\n", "Machine row 3: a ^ row needs a machine name"),
            (header + legCurl + "^,,,,heavy,,Other,,,,,,\n", "Machine row 3: 'weight'"),
            (header + legCurl + "^,,,,,,Other,,4,,,,\n", "Machine row 3: setting1_value has no setting1_label"),
        ]
        for (csv, prefix) in cases {
            XCTAssertThrowsError(try merge([("Machine", .machine, csv)])) { error in
                guard case CSVImportError.invalidData(let errs) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(errs.contains { $0.hasPrefix(prefix) }, "\(errs) lacks \(prefix)")
            }
        }
    }

    /// ^ rows key to the right exercise across tabs, and never reach back
    /// into the previous tab.
    func testCaretRowsAcrossTabs() throws {
        let merged = try merge([("Machine", .machine, header + legCurl + legCurlY),
                                ("Free weight", .freeWeight, "exercise,kind,weight\nCurl,free_weight,20\n"),
                                ("Hold", .hold, "exercise,kind\nPlank,hold\n")])
        XCTAssertEqual(Array(merged.machines.keys), [2])
        XCTAssertThrowsError(try merge([("Machine", .machine, header + legCurl),
                                        ("Hold", .hold, "exercise,kind,machine\n^,,Bench\n")])) { error in
            guard case CSVImportError.invalidData(let errs) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(errs.first?.hasPrefix("Hold row 2: ^ adds a machine") == true, "\(errs)")
        }

        let twoMachines = header + legCurl + legCurlY
            + "Chest Press,machine,12,3,95,single,Chest Press,Seat,4,,,,\n^,,,,90,,Chest Press (Y),Seat,6,,,,\n"
        let ctx = TestSupport.makeContext()
        _ = try importMachines(ctx, twoMachines)
        XCTAssertEqual(machines(of: exercises(ctx)["Chest Press"], ctx).map(\.name), ["Chest Press", "Chest Press (Y)"])
        XCTAssertEqual(machines(of: exercises(ctx)["Seated Leg Curl"], ctx).count, 2)
    }

    /// Two definitions of one exercise would let row order pick the winner.
    func testRepeatedExerciseIsRejectedWhenReplacing() {
        let merged = try? merge([("Machine", .machine, header + legCurl),
                                 ("Free weight", .freeWeight, "exercise,kind,weight\nseated leg curl,free_weight,20\n")])
        XCTAssertThrowsError(try CSVExerciseImporter(TestSupport.makeContext(), group: .strength, replaceExisting: true)
            .importText(merged?.csv ?? "")) { error in
            guard case CSVImportError.invalidData(let errs) = error else { return XCTFail("\(error)") }
            let labelled = errs.map { GoogleSheetImport.relabel($0, origins: merged?.origins ?? []) }
            XCTAssertTrue(labelled.first?.hasPrefix("Free weight row 2:") == true, "\(labelled)")
            XCTAssertTrue(labelled.first?.contains("already defined") == true, "\(labelled)")
        }
    }

    func testDuplicateMachineNamesAreRejected() {
        let csv = header + legCurl + "^,,,,85,,seated leg curl,,,,,,\n"
        XCTAssertThrowsError(try importMachines(TestSupport.makeContext(), csv)) { error in
            guard case CSVImportError.invalidData(let errs) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(errs.first?.contains("two of this exercise's machines") == true, "\(errs)")
        }
    }

    func testCaretRowOnlyForMachineKind() {
        let csv = "exercise,kind,duration_min,machine\nTreadmill,steady,20,Treadmill\n^,,,Bike\n"
        let ctx = TestSupport.makeContext()
        XCTAssertThrowsError(try {
            let merged = try merge([("Steady", .steady, csv)])
            return try CSVExerciseImporter(ctx, group: .cardio, replaceExisting: true)
                .importText(merged.csv, extraMachines: merged.machines)
        }()) { error in
            guard case CSVImportError.invalidData(let errs) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(errs.first?.contains("only a Machine exercise") == true, "\(errs)")
        }
    }

    // MARK: - Re-import overwrites definitions

    func testReimportUpdatesInPlaceAndKeepsHistory() throws {
        let ctx = TestSupport.makeContext()
        let oldRow = "Seated Leg Curl,machine,12,3,80,single,Seated Leg Curl,Ankle,1,Back,4,Y Ankle,L\n"
        _ = try importMachines(ctx, header + oldRow)
        let ex = try XCTUnwrap(exercises(ctx)["Seated Leg Curl"])
        let firstMachine = try XCTUnwrap(machines(of: ex, ctx).first)
        let ankleId = firstMachine.activeSettings.first?.id

        // A finished workout on the old definition.
        let repo = RoutineRepository(ctx)
        let routine = repo.createRoutine(name: "Legs")
        let section = repo.addSection(to: routine.activeVersion!, type: .strength)
        repo.addExercise(to: section, exercise: ex, setCount: 3, plannedWeight: 80, plannedReps: 12)
        let session = TestSupport.finishWithOneSetDone(ctx, routine)
        let historyBefore = session.exercises.first?.machineSettings.sorted { $0.order < $1.order }
            .map { "\($0.label) \($0.numericValue.map(String.init) ?? $0.otherText ?? "")" }
        XCTAssertEqual(historyBefore, ["Ankle 1", "Back 4", "Y Ankle L"])

        let report = try importMachines(ctx, header + legCurl.replacingOccurrences(of: ",12,3,80,", with: ",10,4,90,") + legCurlY)
        XCTAssertEqual(report.exercisesAdded, 0)
        XCTAssertEqual(report.exercisesUpdated, 1)

        let all = (try? ctx.fetch(FetchDescriptor<Exercise>())) ?? []
        XCTAssertEqual(all.count, 1, "updated in place, not duplicated")
        XCTAssertEqual(all.first?.id, ex.id)
        XCTAssertEqual(ex.reps, 10)
        XCTAssertEqual(ex.sets, 4)
        let ms = machines(of: ex, ctx)
        XCTAssertEqual(ms.first?.id, firstMachine.id, "same-named machine is kept")
        XCTAssertEqual(ms.map(\.name), ["Seated Leg Curl", "Seated Leg Curl (Y)"])
        XCTAssertEqual(ms.first?.weight, 90)
        XCTAssertEqual(settings(firstMachine), ["Ankle 1", "Back 4", "Thigh 3"])
        XCTAssertEqual(firstMachine.activeSettings.first?.id, ankleId, "same label keeps its definition")
        XCTAssertTrue(firstMachine.settingDefinitions.contains { $0.label == "Y Ankle" && $0.deletedAt != nil })

        // The routine picks up the new plan on the default machine.
        let re = TestSupport.firstExercise(of: routine)
        XCTAssertEqual(re.machineId, firstMachine.id)
        XCTAssertEqual(re.effectivePlannedSets.map(\.weight), [90, 90, 90, 90])

        // History is unchanged.
        let historyAfter = session.exercises.first?.machineSettings.sorted { $0.order < $1.order }
            .map { "\($0.label) \($0.numericValue.map(String.init) ?? $0.otherText ?? "")" }
        XCTAssertEqual(historyAfter, historyBefore)
        let sets = session.exercises.first?.orderedSets ?? []
        XCTAssertEqual(sets.count, 3)
        XCTAssertEqual(sets.map(\.plannedWeight), [80, 80, 80])
        XCTAssertEqual(sets.map(\.plannedReps), [12, 12, 12])
        XCTAssertEqual(sets.first?.actualWeight, 80)
        XCTAssertEqual(sets.first?.actualReps, 12)
    }

    /// A machine dropped from the sheet is unlinked, not deleted.
    func testDroppedMachineIsUnlinkedNotDeleted() throws {
        let ctx = TestSupport.makeContext()
        _ = try importMachines(ctx, header + legCurl + legCurlY)
        _ = try importMachines(ctx, header + legCurl)
        let ex = exercises(ctx)["Seated Leg Curl"]
        XCTAssertEqual(machines(of: ex, ctx).map(\.name), ["Seated Leg Curl"])
        let y = ((try? ctx.fetch(FetchDescriptor<Machine>())) ?? []).first { $0.name == "Seated Leg Curl (Y)" }
        XCTAssertNotNil(y)
        XCTAssertNil(y?.deletedAt)
    }

    /// The CSV file import stays additive.
    func testFileImportStillSkipsExisting() throws {
        let ctx = TestSupport.makeContext()
        _ = try CSVExerciseImporter(ctx, group: .strength).importText(header + legCurl)
        let report = try CSVExerciseImporter(ctx, group: .strength)
            .importText(header + legCurl.replacingOccurrences(of: ",12,3,", with: ",8,3,"))
        XCTAssertEqual(report.exercisesSkipped, 1)
        XCTAssertEqual(exercises(ctx)["Seated Leg Curl"]?.reps, 12)
    }

    // MARK: - Error rows

    func testErrorsNameTheTabAndRow() throws {
        let merged = try merge([
            ("Static", .staticStretch, "exercise,kind,hold_seconds\nHamstring,static,30\n\nQuad,static,30\n"),
            ("Dynamic", .dynamicStretch, "exercise,kind,reps,per_side\nLeg Swings,dynamic,10,sideways\n"),
        ])
        XCTAssertEqual(merged.origins.map(\.tab), ["Static", "Static", "Dynamic"])
        XCTAssertEqual(merged.origins.map(\.row), [2, 4, 2])

        var messages: [String] = []
        do {
            _ = try CSVExerciseImporter(TestSupport.makeContext(), group: .stretching).importText(merged.csv)
        } catch CSVImportError.invalidData(let errs) {
            messages = errs.map { GoogleSheetImport.relabel($0, origins: merged.origins) }
        }
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages.first?.hasPrefix("Dynamic row 2:") == true, messages.first ?? "no error")
    }

    func testRelabelLeavesOtherMessagesAlone() {
        let origins = [(tab: "Machine", row: 2)]
        XCTAssertEqual(GoogleSheetImport.relabel("Line 2: bad", origins: origins), "Machine row 2: bad")
        XCTAssertEqual(GoogleSheetImport.relabel("Line 9: bad", origins: origins), "Line 9: bad")
        XCTAssertEqual(GoogleSheetImport.relabel("Duplicate name", origins: origins), "Duplicate name")
    }
}
