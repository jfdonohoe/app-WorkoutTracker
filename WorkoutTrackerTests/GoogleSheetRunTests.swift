//
//  GoogleSheetRunTests.swift
//  WorkoutTrackerTests
//
//  One Google Sheet run (GoogleSheetImport.importAll): every exercise tab,
//  then the Routines tab, saved together or not at all. Existing routines
//  change only when their rows differ, and never in a version a workout used.
//  Tabs are given as CSV text; the download isn't tested here.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class GoogleSheetRunTests: XCTestCase {

    private let machineTab = """
    exercise,kind,reps,sets,weight,per_side,machine,setting1_label,setting1_value
    Chest Press,machine,12,3,95,single,Chest Press,Seat,4
    Seated Row,machine,12,3,80,single,Seated Row,Chest,6
    """
    private let staticTab = """
    exercise,kind,hold_seconds
    Hamstring Stretch,static,30
    """
    private let steadyTab = """
    exercise,kind,duration_min
    Elliptical Warm-Up,steady,10
    """
    private let routinesTab = """
    routine,order,exercise
    Upper,1,Elliptical Warm-Up
    Upper,2,Chest Press
    Upper,3,Seated Row
    Upper,4,Hamstring Stretch
    """

    private func tabs(machine: String? = nil, routines: String? = nil) -> GoogleSheetImport.Tabs {
        GoogleSheetImport.Tabs(exercises: [("Machine", .machine, machine ?? machineTab),
                                           ("Static", .staticStretch, staticTab),
                                           ("Steady", .steady, steadyTab)],
                               routines: routines ?? routinesTab)
    }

    private func routine(_ ctx: ModelContext, _ name: String) throws -> Routine {
        try XCTUnwrap(((try? ctx.fetch(FetchDescriptor<Routine>())) ?? []).first { $0.name == name })
    }

    private func names(_ version: RoutineVersion?) -> [String] {
        (version?.orderedSections ?? []).flatMap { $0.orderedExercises.map(\.displayName) }
    }

    func testOneRunImportsEveryGroupThenRoutines() throws {
        let ctx = TestSupport.makeContext()
        let report = try GoogleSheetImport.importAll(tabs(), into: ctx)

        XCTAssertEqual(report.exercises.exercisesAdded, 4)
        XCTAssertEqual(report.routines.routinesCreated, 1)
        let upper = try routine(ctx, "Upper")
        XCTAssertEqual(names(upper.activeVersion), ["Elliptical Warm-Up", "Chest Press", "Seated Row", "Hamstring Stretch"])
        XCTAssertEqual(upper.activeVersion?.orderedSections.map(\.type), [.cardio, .strength, .stretching])
    }

    func testAProblemOnAnyTabImportsNothing() throws {
        let ctx = TestSupport.makeContext()
        let bad = routinesTab + "\nUpper,5,Shoulder Pres"
        XCTAssertThrowsError(try GoogleSheetImport.importAll(tabs(routines: bad), into: ctx)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Routines row 6: Shoulder Pres"), message)
        }
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Exercise>()), 0, "the valid exercise tabs were rolled back")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Routine>()), 0)
    }

    func testAnExerciseProblemDoesNotAlsoFailItsRoutineRows() throws {
        let ctx = TestSupport.makeContext()
        let bad = machineTab + "\n^,,,,95,single,Y Circuit,Seat,6"
        XCTAssertThrowsError(try GoogleSheetImport.importAll(tabs(machine: bad), into: ctx)) { error in
            guard case CSVImportError.invalidData(let errors) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(errors, ["Machine row 4: a ^ row holds only machine, weight and settings; 'per_side' belongs on the exercise row."])
        }
    }

    func testRunningTheSameSheetAgainChangesNothing() throws {
        let ctx = TestSupport.makeContext()
        _ = try GoogleSheetImport.importAll(tabs(), into: ctx)
        let upper = try routine(ctx, "Upper")
        let versionBefore = upper.activeVersion?.id

        let report = try GoogleSheetImport.importAll(tabs(), into: ctx)
        XCTAssertEqual(report.exercises.exercisesAdded, 0)
        XCTAssertEqual(report.exercises.exercisesUpdated, 0)
        XCTAssertEqual(report.exercises.exercisesUnchanged, 4)
        XCTAssertEqual(report.routines.routinesCreated, 0)
        XCTAssertEqual(report.routines.routinesUpdated, 0)
        XCTAssertEqual(report.routines.routinesUnchanged, 1)
        XCTAssertEqual(upper.versions.count, 1)
        XCTAssertEqual(upper.activeVersion?.id, versionBefore)
    }

    func testAMultiMachineExerciseReimportedUnchangedIsUnchanged() throws {
        let ctx = TestSupport.makeContext()
        let twoMachines = machineTab + "\n^,,,,40,,Y Circuit,Seat,7"
        _ = try GoogleSheetImport.importAll(tabs(machine: twoMachines), into: ctx)
        // Several runs, since the bug this guards (sets of two machines
        // compared in an unstable order) only showed some of the time.
        for _ in 0..<5 {
            let report = try GoogleSheetImport.importAll(tabs(machine: twoMachines), into: ctx)
            XCTAssertEqual(report.exercises.exercisesUpdated, 0)
            XCTAssertEqual(report.exercises.exercisesUnchanged, 4)
        }
    }

    func testAnEditedExerciseCountsAsUpdated() throws {
        let ctx = TestSupport.makeContext()
        _ = try GoogleSheetImport.importAll(tabs(), into: ctx)
        let edited = machineTab.replacingOccurrences(of: "Chest Press,machine,12,3,95", with: "Chest Press,machine,10,3,100")
        let report = try GoogleSheetImport.importAll(tabs(machine: edited), into: ctx)
        XCTAssertEqual(report.exercises.exercisesUpdated, 1)
        XCTAssertEqual(report.exercises.exercisesUnchanged, 3)
    }

    func testAnEditedRoutineIsUpdatedInPlaceWhenNoWorkoutUsedIt() throws {
        let ctx = TestSupport.makeContext()
        _ = try GoogleSheetImport.importAll(tabs(), into: ctx)
        let swapped = routinesTab.replacingOccurrences(of: "Upper,2,Chest Press", with: "Upper,2,Seated Row_")
            .replacingOccurrences(of: "Upper,3,Seated Row", with: "Upper,3,Chest Press")
            .replacingOccurrences(of: "Seated Row_", with: "Seated Row")

        let report = try GoogleSheetImport.importAll(tabs(routines: swapped), into: ctx)
        XCTAssertEqual(report.routines.routinesUpdated, 1)
        let upper = try routine(ctx, "Upper")
        XCTAssertEqual(upper.versions.count, 1)
        XCTAssertEqual(names(upper.activeVersion), ["Elliptical Warm-Up", "Seated Row", "Chest Press", "Hamstring Stretch"])
    }

    func testAnEditedRoutineGetsANewVersionWhenAWorkoutUsedIt() throws {
        let ctx = TestSupport.makeContext()
        _ = try GoogleSheetImport.importAll(tabs(), into: ctx)
        let upper = try routine(ctx, "Upper")
        let used = try XCTUnwrap(upper.activeVersion)
        let session = TestSupport.finishWithOneSetDone(ctx, upper)
        XCTAssertEqual(session.routineVersionId, used.id)

        let shorter = routinesTab.replacingOccurrences(of: "\nUpper,4,Hamstring Stretch", with: "")
        let report = try GoogleSheetImport.importAll(tabs(routines: shorter), into: ctx)
        XCTAssertEqual(report.routines.routinesUpdated, 1)
        XCTAssertEqual(upper.versions.count, 2)
        XCTAssertNotEqual(upper.activeVersion?.id, used.id)
        XCTAssertEqual(names(upper.activeVersion), ["Elliptical Warm-Up", "Chest Press", "Seated Row"])
        XCTAssertEqual(names(used), ["Elliptical Warm-Up", "Chest Press", "Seated Row", "Hamstring Stretch"],
                       "the version the workout used is unchanged")
    }

    func testARoutineMissingFromTheSheetIsLeftAlone() throws {
        let ctx = TestSupport.makeContext()
        _ = try GoogleSheetImport.importAll(tabs(), into: ctx)
        _ = RoutineRepository(ctx).createRoutine(name: "Mine")
        _ = try GoogleSheetImport.importAll(tabs(), into: ctx)
        XCTAssertNoThrow(try routine(ctx, "Mine"))
    }

    func testRoutineCSVFileImportStillSkipsExistingRoutines() throws {
        let ctx = TestSupport.makeContext()
        _ = try GoogleSheetImport.importAll(tabs(), into: ctx)
        let report = try CSVRoutineImporter(ctx).importText("routine,exercise\nUpper,Chest Press\n")
        XCTAssertEqual(report.routinesSkipped, 1)
        XCTAssertEqual(names(try routine(ctx, "Upper").activeVersion).count, 4)
    }

    // MARK: - Review follow-ups

    func testARollbackRestoresExistingExercisesAndRoutines() throws {
        let ctx = TestSupport.makeContext()
        _ = try GoogleSheetImport.importAll(tabs(), into: ctx)
        let upper = try routine(ctx, "Upper")
        TestSupport.finishWithOneSetDone(ctx, upper)   // so a library change would fork a version
        let chest = try XCTUnwrap(((try? ctx.fetch(FetchDescriptor<Exercise>())) ?? []).first { $0.name == "Chest Press" })
        let setsBefore = chest.effectiveDefaultSets.map(\.weight)

        let edited = machineTab.replacingOccurrences(of: "Chest Press,machine,12,3,95", with: "Chest Press,machine,12,3,150")
        let reordered = routinesTab.replacingOccurrences(of: "\nUpper,4,Hamstring Stretch", with: "")
        XCTAssertThrowsError(try GoogleSheetImport.importAll(tabs(machine: edited, routines: reordered + "\nUpper,4,Nope"), into: ctx))

        XCTAssertEqual(chest.reps, 12)
        XCTAssertEqual(chest.effectiveDefaultSets.map(\.weight), setsBefore)
        XCTAssertEqual(upper.versions.count, 1, "no version left behind by the rolled-back run")
        XCTAssertEqual(names(upper.activeVersion), ["Elliptical Warm-Up", "Chest Press", "Seated Row", "Hamstring Stretch"])
    }

    func testRoutineSetsFromTheSheetDontCountAsAnEditAfterReconcile() throws {
        let ctx = TestSupport.makeContext()
        let withSets = "routine,order,exercise,set1_reps,set1_weight,notes\nUpper,1,Chest Press,8,200,Heavy\n"
        _ = try GoogleSheetImport.importAll(tabs(routines: withSets), into: ctx)
        let upper = try routine(ctx, "Upper")
        TestSupport.finishWithOneSetDone(ctx, upper)
        CatalogSyncService(ctx).reconcileRoutine(upper)   // what opening the Routines tab does
        let versions = upper.versions.count

        let report = try GoogleSheetImport.importAll(tabs(routines: withSets), into: ctx)
        XCTAssertEqual(report.routines.routinesUnchanged, 1)
        XCTAssertEqual(upper.versions.count, versions)
    }

    func testABlankCardioLengthKeepsTheRoutinesOwn() throws {
        let ctx = TestSupport.makeContext()
        _ = try GoogleSheetImport.importAll(tabs(), into: ctx)
        let upper = try routine(ctx, "Upper")
        upper.activeVersion?.orderedSections.first?.durationMinutes = 20   // set in the app
        let report = try GoogleSheetImport.importAll(tabs(), into: ctx)
        XCTAssertEqual(report.routines.routinesUnchanged, 1)

        // A real edit rebuilds the routine but keeps the length.
        let shorter = routinesTab.replacingOccurrences(of: "\nUpper,4,Hamstring Stretch", with: "")
        _ = try GoogleSheetImport.importAll(tabs(routines: shorter), into: ctx)
        XCTAssertEqual(upper.activeVersion?.orderedSections.first?.durationMinutes, 20)
    }

    func testBlankRowsInTheRoutinesTabAreSkippedAndRowNumbersStayRight() throws {
        let ctx = TestSupport.makeContext()
        let gappy = "routine,order,exercise\nUpper,1,Chest Press\n,,\nUpper,2,Nope\n"
        XCTAssertThrowsError(try GoogleSheetImport.importAll(tabs(routines: gappy), into: ctx)) { error in
            guard case CSVImportError.invalidData(let errors) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(errors.count, 1, "\(errors)")
            XCTAssertTrue(errors.first?.hasPrefix("Routines row 4: Nope") == true, "\(errors)")
        }
        XCTAssertNoThrow(try GoogleSheetImport.importAll(tabs(routines: "routine,order,exercise\nUpper,1,Chest Press\n,,\n"), into: ctx))
    }

    func testARepeatedExerciseNamesBothSheetRows() throws {
        let ctx = TestSupport.makeContext()
        let repeated = machineTab + "\nChest Press,machine,10,3,90,single,Chest Press,Seat,4"
        XCTAssertThrowsError(try GoogleSheetImport.importAll(tabs(machine: repeated), into: ctx)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Machine row 4: \"Chest Press\" is already defined on Machine row 2"),
                          error.localizedDescription)
        }
    }

    func testANewVersionKeepsTheRestBetweenSets() throws {
        let ctx = TestSupport.makeContext()
        let repo = RoutineRepository(ctx)
        let r = repo.createRoutine(name: "R")
        r.activeVersion?.defaultRestBetweenSets = 120
        XCTAssertEqual(repo.makeNewVersion(of: r).defaultRestBetweenSets, 120)
    }

    // MARK: - CSV files

    func testTheStrengthTemplateGivesLegPressTwoMachines() throws {
        let ctx = TestSupport.makeContext()
        _ = try CSVExerciseImporter(ctx, group: .strength).importText(CSVExerciseImporter.template(for: .strength))
        let leg = try XCTUnwrap(((try? ctx.fetch(FetchDescriptor<Exercise>())) ?? []).first { $0.name == "Leg Press" })
        let machines = leg.machineIds.compactMap { id in try? ctx.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == id })).first }
        XCTAssertEqual(machines.map(\.name), ["Leg Press", "Leg Press (plate loaded)"])
        XCTAssertEqual(machines.map(\.weight), [140, 120])
        XCTAssertEqual(machines.last?.activeSettings.map(\.label), ["Seat height", "Foot plate"])
        XCTAssertFalse(((try? ctx.fetch(FetchDescriptor<Exercise>())) ?? []).contains { $0.name == "^" })
    }

    func testCaretRowProblemsInAFileNameTheFileLine() throws {
        let ctx = TestSupport.makeContext()
        let csv = "exercise,kind,reps,sets,weight,per_side,machine\n^,,,,40,,Y Circuit\nChest Press,machine,12,3,95,single,Chest Press\n^,,,,95,single,Y Circuit\n"
        XCTAssertThrowsError(try CSVExerciseImporter(ctx, group: .strength).importText(csv)) { error in
            guard case CSVImportError.invalidData(let errors) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(errors.contains { $0.hasPrefix("Line 2: ^ adds a machine") }, "\(errors)")
            XCTAssertTrue(errors.contains { $0.hasPrefix("Line 4: a ^ row holds only") }, "\(errors)")
        }
    }

    func testAnImporterErrorAfterSplittingNamesTheFileLine() throws {
        let ctx = TestSupport.makeContext()
        // Line 4's kind is checked by the importer, after the ^ row (line 3) is taken out.
        let csv = "exercise,kind,machine\nChest Press,machine,Chest Press\n^,,Y Circuit\nRow,nonsense,\n"
        XCTAssertThrowsError(try CSVExerciseImporter(ctx, group: .strength).importText(csv)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Line 4:"), error.localizedDescription)
        }
    }

    func testACaretRowNeedsAKindColumn() throws {
        let ctx = TestSupport.makeContext()
        let csv = "exercise,set1_reps,set1_weight\nChest Press,12,95\n^,12,95\n"
        XCTAssertThrowsError(try CSVExerciseImporter(ctx, group: .strength).importText(csv)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Line 3: a ^ row"), error.localizedDescription)
        }
    }

    func testFileLinesStayRightAfterBlankRows() throws {
        let ctx = TestSupport.makeContext()
        let csv = "exercise,kind\nWalk,steady\n\n,\nRun,nonsense\n"
        XCTAssertThrowsError(try CSVExerciseImporter(ctx, group: .cardio).importText(csv)) { error in
            guard case CSVImportError.invalidData(let errors) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(errors.count, 1, "\(errors)")
            XCTAssertTrue(errors.first?.hasPrefix("Line 5:") == true, "\(errors)")
        }
    }

    func testAnOlderFileWithARepeatedNameStillImportsWhenUpdating() throws {
        let ctx = TestSupport.makeContext()
        let csv = "exercise,set1_reps,set1_weight\nLeg Press,10,100\nLeg Press,10,100\n"
        let report = try CSVExerciseImporter(ctx, group: .strength, replaceExisting: true).importText(csv)
        XCTAssertEqual(report.exercisesAdded, 1)
    }
}
