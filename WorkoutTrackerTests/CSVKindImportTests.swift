//
//  CSVKindImportTests.swift
//  WorkoutTrackerTests
//
//  CSV rows with a `kind` create exercises the current way (kind and its own
//  fields, one machine per exercise); rows without one still import as before.
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class CSVKindImportTests: XCTestCase {

    private func exercises(_ ctx: ModelContext) -> [String: Exercise] {
        let all = (try? ctx.fetch(FetchDescriptor<Exercise>())) ?? []
        return Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func machine(_ ctx: ModelContext, _ id: UUID?) -> Machine? {
        guard let id else { return nil }
        return try? ctx.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == id })).first
    }

    private func invalidMessages(_ block: () throws -> Void) -> [String] {
        do { try block() } catch CSVImportError.invalidData(let errs) { return errs } catch {
            XCTFail("Unexpected error \(error)")
        }
        return []
    }

    // MARK: - Templates

    func testEveryExerciseTemplateImportsWithKinds() throws {
        let ctx = TestSupport.makeContext()
        for group in SectionType.allCases {
            let report = try CSVExerciseImporter(ctx, group: group).importText(CSVExerciseImporter.template(for: group))
            XCTAssertGreaterThan(report.exercisesAdded, 0, "\(group)")
        }
        let ex = exercises(ctx)
        XCTAssertTrue(ex.values.allSatisfy { $0.kind != nil }, "every template row names its kind")

        let leg = try XCTUnwrap(ex["Leg Press"])
        XCTAssertEqual(leg.kind, .machine)
        XCTAssertEqual(leg.reps, 10)
        XCTAssertEqual(leg.sets, 3)
        let legMachine = try XCTUnwrap(machine(ctx, leg.machineId))
        XCTAssertEqual(legMachine.weight, 140)
        XCTAssertEqual(legMachine.activeSettings.map(\.label), ["Seat height", "Back angle"])
        XCTAssertEqual(leg.effectiveDefaultSets.count, 3)
        XCTAssertEqual(leg.effectiveDefaultSets.first?.weight, 140)

        let curl = try XCTUnwrap(ex["Dumbbell Curl"])
        XCTAssertEqual(curl.kind, .freeWeight)
        XCTAssertEqual(curl.weight, 25)
        XCTAssertEqual(curl.implement, .dumbbell)
        XCTAssertEqual(curl.perSide, .alternating)
        XCTAssertNil(curl.machineId)

        let plank = try XCTUnwrap(ex["Plank"])
        XCTAssertEqual(plank.kind, .hold)
        XCTAssertEqual(plank.holdSeconds, 45)

        let sprints = try XCTUnwrap(ex["Bike Sprints"])
        XCTAssertEqual(sprints.kind, .intervals)
        XCTAssertEqual(sprints.rounds, 8)
        XCTAssertEqual(sprints.workSeconds, 30)
        XCTAssertEqual(sprints.recoverySeconds, 60)
        XCTAssertEqual(sprints.effort, .hard)
        XCTAssertEqual(sprints.durationMinutes, 12)    // 8 × 90 s, from the legacy writer

        let run = try XCTUnwrap(ex["Outdoor Run"])
        XCTAssertEqual(run.kind, .distance)
        XCTAssertEqual(run.distance, 3)
        XCTAssertNil(run.machineId)

        let jacks = try XCTUnwrap(ex["Jumping Jacks"])
        XCTAssertEqual(jacks.kind, .calisthenics)
        XCTAssertEqual(jacks.defaultSectionType, .cardio)
        XCTAssertEqual(jacks.reps, 30)

        let ham = try XCTUnwrap(ex["Hamstring Stretch"])
        XCTAssertEqual(ham.kind, .staticStretch)
        XCTAssertEqual(ham.prop, "strap")
        XCTAssertEqual(ham.perSide, .leftRight)
        XCTAssertEqual(ham.sides, 2)

        let swings = try XCTUnwrap(ex["Leg Swings"])
        XCTAssertEqual(swings.kind, .dynamicStretch)
        XCTAssertEqual(swings.perSide, .forwardBack)
        XCTAssertEqual(swings.countTimerSeconds, 30)
        XCTAssertEqual(swings.holdSeconds, 0)
    }

    func testRoutineTemplateImports() throws {
        let ctx = TestSupport.makeContext()
        let report = try CSVRoutineImporter(ctx).importText(CSVRoutineImporter.exampleCSV)
        XCTAssertEqual(report.routinesCreated, 2)
        XCTAssertEqual(report.exercisesAdded, 7)

        let routines = try ctx.fetch(FetchDescriptor<Routine>())
        let a = try XCTUnwrap(routines.first { $0.name == "Gym Full Body A" })
        let strength = try XCTUnwrap(a.activeVersion?.orderedSections.first { $0.type == .strength })
        let leg = try XCTUnwrap(strength.orderedExercises.first { $0.displayName == "Leg Press" })
        // setK columns plan the routine; the exercise keeps its own reps/sets/weight.
        XCTAssertEqual(leg.plannedSets.count, 5)
        XCTAssertEqual(a.activeVersion?.defaultRestBetweenExercises, 180)
        let curl = try XCTUnwrap(strength.orderedExercises.first { $0.displayName == "Dumbbell Curl" })
        XCTAssertEqual(curl.plannedSets.count, 3)      // from the exercise's sets × reps
        XCTAssertEqual(curl.plannedSets.first?.plannedWeight, 25)

        let ex = exercises(ctx)
        XCTAssertEqual(ex["Leg Press"]?.kind, .machine)
        XCTAssertEqual(machine(ctx, ex["Leg Press"]?.machineId)?.weight, 120)
        XCTAssertEqual(ex["Bike Sprints"]?.kind, .intervals)
        XCTAssertEqual(machine(ctx, ex["Bike Sprints"]?.machineId)?.activeSettings.first?.numericValue, 8)
    }

    // MARK: - Validation

    func testKindMustBelongToTheGroup() {
        let ctx = TestSupport.makeContext()
        let errs = invalidMessages {
            _ = try CSVExerciseImporter(ctx, group: .strength).importText("exercise,kind\nTreadmill,steady\n")
        }
        XCTAssertEqual(errs.count, 1)
        XCTAssertTrue(errs[0].contains("isn't a strength kind"), errs[0])
    }

    func testUnknownKindAndValuesAreRejected() {
        let ctx = TestSupport.makeContext()
        let errs = invalidMessages {
            _ = try CSVExerciseImporter(ctx, group: .cardio).importText("""
            exercise,kind,effort,rounds
            Rower,rowing,,
            Sprints,intervals,extreme,40
            """)
        }
        XCTAssertEqual(errs.count, 3, "\(errs)")
        XCTAssertEqual(exercises(ctx).count, 0, "all-or-nothing")
    }

    func testColumnTheKindDoesNotUseIsAnError() {
        let ctx = TestSupport.makeContext()
        let errs = invalidMessages {
            _ = try CSVExerciseImporter(ctx, group: .strength).importText("""
            exercise,kind,implement,set1_reps,set1_weight
            Push-up,bodyweight,dumbbell,,
            Curl,free_weight,,10,20
            """)
        }
        XCTAssertEqual(errs.count, 2, "\(errs)")
        XCTAssertTrue(errs[0].contains("'implement'"), errs[0])
        XCTAssertTrue(errs[1].contains("reps, sets and weight"), errs[1])
    }

    func testCustomPerSideNeedsText() {
        let ctx = TestSupport.makeContext()
        let errs = invalidMessages {
            _ = try CSVExerciseImporter(ctx, group: .stretching).importText("exercise,kind,per_side\nNeck Roll,dynamic,custom\n")
        }
        XCTAssertEqual(errs.count, 1)

        XCTAssertNoThrow(try CSVExerciseImporter(ctx, group: .stretching).importText(
            "exercise,kind,per_side,per_side_custom\nNeck Roll,dynamic,custom,Up/Down\n"))
        XCTAssertEqual(exercises(ctx)["Neck Roll"]?.perSideCustom, "Up/Down")
    }

    func testBlankFieldsUseTheKindsDefaults() throws {
        let ctx = TestSupport.makeContext()
        _ = try CSVExerciseImporter(ctx, group: .cardio).importText("exercise,kind\nSprints,intervals\n")
        let e = try XCTUnwrap(exercises(ctx)["Sprints"])
        XCTAssertEqual(e.rounds, 8)
        XCTAssertEqual(e.effort, .hard)
    }

    func testLegacyIntensityColumnMapsToEffort() throws {
        let ctx = TestSupport.makeContext()
        _ = try CSVExerciseImporter(ctx, group: .cardio).importText("exercise,kind,intensity\nWalk,steady,low\n")
        XCTAssertEqual(exercises(ctx)["Walk"]?.effort, .easy)
    }

    func testStretchRowInRoutineRejectsSetColumns() {
        let ctx = TestSupport.makeContext()
        let errs = invalidMessages {
            _ = try CSVRoutineImporter(ctx).importText("""
            routine,group,exercise,kind,set1_reps,set1_weight
            R,stretching,Calf Stretch,static,10,0
            """)
        }
        XCTAssertEqual(errs.count, 1, "\(errs)")
    }

    func testBlankSetWeightIsZeroForKindsWithoutWeight() throws {
        let ctx = TestSupport.makeContext()
        _ = try CSVRoutineImporter(ctx).importText("""
        routine,group,exercise,kind,set1_reps,set1_weight,set2_reps,set2_weight
        R,strength,Push-up,bodyweight,15,,12,
        """)
        let re = try XCTUnwrap(ctx.fetch(FetchDescriptor<RoutineExercise>()).first)
        XCTAssertEqual(re.plannedSets.sorted { $0.order < $1.order }.map(\.plannedReps), [15, 12])
    }

    func testSteadyRowWithBlankDurationLeavesSectionLengthUnset() throws {
        let ctx = TestSupport.makeContext()
        _ = try CSVRoutineImporter(ctx).importText("routine,group,exercise,kind,duration_min\nR,cardio,Walk,steady,\nS,cardio,Jog,steady,30\n")
        let routines = try ctx.fetch(FetchDescriptor<Routine>())
        func section(_ name: String) -> RoutineSection? {
            routines.first { $0.name == name }?.activeVersion?.orderedSections.first
        }
        XCTAssertNil(section("R")?.durationMinutes)
        XCTAssertEqual(section("S")?.durationMinutes, 30)
    }

    func testRoutineKindMustMatchLibraryExercise() throws {
        let ctx = TestSupport.makeContext()
        _ = try CSVExerciseImporter(ctx, group: .cardio).importText("exercise,kind\nJacks,steady\n")
        let errs = invalidMessages {
            _ = try CSVRoutineImporter(ctx).importText("routine,group,exercise,kind\nR,cardio,Jacks,calisthenics\n")
        }
        XCTAssertEqual(errs.count, 1)
        XCTAssertTrue(errs[0].contains("already in your library"), errs[0])
        // Leaving kind blank reuses the library exercise.
        XCTAssertNoThrow(try CSVRoutineImporter(ctx).importText("routine,group,exercise,kind\nR,cardio,Jacks,\n"))
    }

    func testRowWithoutKindRejectsCurrentColumns() {
        let ctx = TestSupport.makeContext()
        let errs = invalidMessages {
            _ = try CSVExerciseImporter(ctx, group: .stretching).importText("exercise,kind,reps,per_side\nCalf Stretch,,3,left_right\n")
        }
        XCTAssertEqual(errs.count, 2, "\(errs)")
        XCTAssertTrue(errs[0].contains("fill 'kind'"), errs[0])
    }

    func testEffortAndIntensityTogetherIsAnError() {
        let ctx = TestSupport.makeContext()
        let errs = invalidMessages {
            _ = try CSVExerciseImporter(ctx, group: .cardio).importText("exercise,kind,effort,intensity\nWalk,steady,easy,low\n")
        }
        XCTAssertEqual(errs.count, 1, "\(errs)")
    }

    // MARK: - Machines and older rows

    func testEachExerciseGetsItsOwnMachine() throws {
        let ctx = TestSupport.makeContext()
        _ = try CSVExerciseImporter(ctx, group: .strength).importText("""
        exercise,kind,weight,machine
        Chest Press,machine,60,Y Circuit
        Shoulder Press,machine,40,Y Circuit
        """)
        let ex = exercises(ctx)
        let a = try XCTUnwrap(machine(ctx, ex["Chest Press"]?.machineId))
        let b = try XCTUnwrap(machine(ctx, ex["Shoulder Press"]?.machineId))
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.weight, 60)
        XCTAssertEqual(b.weight, 40)
    }

    func testOlderFormatStillImports() throws {
        let ctx = TestSupport.makeContext()
        let report = try CSVExerciseImporter(ctx, group: .strength).importText("""
        exercise,machine,setting1_label,setting1_value,set1_reps,set1_weight,set2_reps,set2_weight
        Leg Press,Leg Press,Seat height,5,12,100,10,120
        """)
        XCTAssertEqual(report.exercisesAdded, 1)
        ExerciseStructureMigration(ctx).run()
        let e = try XCTUnwrap(exercises(ctx)["Leg Press"])
        XCTAssertEqual(e.kind, .machine)
        XCTAssertEqual(e.sets, 2)
        XCTAssertEqual(machine(ctx, e.machineId)?.weight, 100)
    }

    // MARK: - Routine order and sections

    private func sections(_ ctx: ModelContext, _ routine: String) -> [(SectionType, [String])] {
        let r = (try? ctx.fetch(FetchDescriptor<Routine>()))?.first { $0.name == routine }
        return (r?.activeVersion?.orderedSections ?? []).map { ($0.type, $0.orderedExercises.map(\.displayName)) }
    }

    func testOrderWithoutGroupBuildsSectionsInRunOrder() throws {
        let ctx = TestSupport.makeContext()
        _ = try CSVExerciseImporter(ctx, group: .cardio).importText("exercise,kind,duration_min\nWalk,steady,10\n")
        _ = try CSVExerciseImporter(ctx, group: .stretching).importText("exercise,kind,hold_seconds\nHamstring,static,30\nCircles,dynamic,\n")
        _ = try CSVExerciseImporter(ctx, group: .strength).importText("exercise,kind,weight\nChest Press,machine,95\nRow,machine,80\n")
        // Rows out of file order; Hamstring runs both before and after strength.
        let report = try CSVRoutineImporter(ctx).importText("""
        routine,order,exercise
        Upper,5,Row
        Upper,1,Walk
        Upper,6,Hamstring
        Upper,3,Hamstring
        Upper,2,Circles
        Upper,4,Chest Press
        """)
        XCTAssertEqual(report.exercisesAdded, 6)
        let got = sections(ctx, "Upper")
        XCTAssertEqual(got.map(\.0), [.cardio, .stretching, .strength, .stretching])
        XCTAssertEqual(got.map(\.1), [["Walk"], ["Circles", "Hamstring"], ["Chest Press", "Row"], ["Hamstring"]])
        XCTAssertEqual(exercises(ctx).count, 5, "library exercises are reused, not duplicated")
    }

    func testWithoutOrderFileOrderSetsSections() throws {
        let ctx = TestSupport.makeContext()
        _ = try CSVRoutineImporter(ctx).importText("""
        routine,group,exercise,kind
        R,stretching,Reach,static
        R,strength,Plank,hold
        R,stretching,Reach,
        """)
        XCTAssertEqual(sections(ctx, "R").map(\.0), [.stretching, .strength, .stretching])
    }

    func testGroupComesFromKindOrAnotherRow() throws {
        let ctx = TestSupport.makeContext()
        _ = try CSVRoutineImporter(ctx).importText("routine,exercise,kind\nR,Plank,hold\nR,Plank,\nS,Plank,\n")
        XCTAssertEqual(sections(ctx, "R").map(\.0), [.strength])
        XCTAssertEqual(sections(ctx, "R").first?.1, ["Plank", "Plank"])
        XCTAssertEqual(sections(ctx, "S").map(\.0), [.strength])
    }

    func testUnknownOrAmbiguousExerciseNeedsGroup() throws {
        let ctx = TestSupport.makeContext()
        var errs = invalidMessages { _ = try CSVRoutineImporter(ctx).importText("routine,exercise\nR,Mystery\n") }
        XCTAssertEqual(errs.count, 1)
        XCTAssertTrue(errs[0].contains("isn't in your library"), errs[0])

        _ = try CSVExerciseImporter(ctx, group: .cardio).importText("exercise,kind\nJacks,calisthenics\n")
        _ = try CSVExerciseImporter(ctx, group: .strength).importText("exercise,kind\nJacks,bodyweight\n")
        errs = invalidMessages { _ = try CSVRoutineImporter(ctx).importText("routine,exercise\nR,Jacks\n") }
        XCTAssertEqual(errs.count, 1)
        XCTAssertTrue(errs[0].contains("more than one group"), errs[0])
        XCTAssertNoThrow(try CSVRoutineImporter(ctx).importText("routine,group,exercise\nR,cardio,Jacks\n"))
    }

    func testOrderMustBeCompleteAndUnique() {
        let ctx = TestSupport.makeContext()
        var errs = invalidMessages {
            _ = try CSVRoutineImporter(ctx).importText("routine,order,exercise,kind\nR,1,Plank,hold\nR,,Plank,\n")
        }
        XCTAssertEqual(errs.count, 1, "\(errs)")
        XCTAssertTrue(errs[0].contains("fill it on every row"), errs[0])

        errs = invalidMessages {
            _ = try CSVRoutineImporter(ctx).importText("routine,order,exercise,kind\nR,1,Plank,hold\nR,1,Plank,\nS,0,Plank,\n")
        }
        XCTAssertEqual(errs.count, 2, "\(errs)")
        XCTAssertTrue(errs.contains { $0.contains("whole number ≥ 1") }, "\(errs)")
        XCTAssertTrue(errs.contains { $0.contains("already has order 1") }, "\(errs)")
        XCTAssertTrue(((try? ctx.fetch(FetchDescriptor<Routine>())) ?? []).isEmpty, "nothing imported")
    }

    func testRowWithoutKindRunBeforeTheKindRowUsesItsDefinition() throws {
        let ctx = TestSupport.makeContext()
        // Within a routine (order puts the blank row first) and across routines.
        _ = try CSVRoutineImporter(ctx).importText("""
        routine,order,exercise,kind,hold_seconds,sets
        S,1,Wall Sit,,,
        R,2,Plank,hold,45,2
        R,1,Plank,,,
        S,2,Wall Sit,,,
        T,1,Wall Sit,hold,60,
        """)
        let ex = exercises(ctx)
        XCTAssertEqual(ex["Plank"]?.kind, .hold)
        XCTAssertEqual(ex["Plank"]?.holdSeconds, 45)
        XCTAssertEqual(ex["Plank"]?.sets, 2)
        XCTAssertEqual(ex["Wall Sit"]?.kind, .hold)
        XCTAssertEqual(ex["Wall Sit"]?.holdSeconds, 60)
        XCTAssertEqual(((try? ctx.fetch(FetchDescriptor<Exercise>())) ?? []).count, 2)
    }

    func testTwoKindsForOneExerciseInTheFileIsAnError() {
        let ctx = TestSupport.makeContext()
        let errs = invalidMessages {
            _ = try CSVRoutineImporter(ctx).importText("routine,group,exercise,kind\nR,strength,Plank,hold\nS,strength,Plank,bodyweight\n")
        }
        XCTAssertEqual(errs.count, 1, "\(errs)")
        XCTAssertTrue(errs[0].contains("on line 2"), errs[0])
    }

    func testCardioSectionLengthComesFromTheFirstRowWithADuration() throws {
        let ctx = TestSupport.makeContext()
        _ = try CSVRoutineImporter(ctx).importText("""
        routine,group,exercise,kind,duration_min,work_seconds
        R,cardio,Sprints,intervals,,30
        R,cardio,Walk,steady,15,
        """)
        let r = try ctx.fetch(FetchDescriptor<Routine>()).first { $0.name == "R" }
        XCTAssertEqual(r?.activeVersion?.orderedSections.count, 1)
        XCTAssertEqual(r?.activeVersion?.orderedSections.first?.durationMinutes, 15)
    }

    func testOrderProblemsAreReportedWithOtherRowErrors() {
        let ctx = TestSupport.makeContext()
        let errs = invalidMessages {
            _ = try CSVRoutineImporter(ctx).importText("routine,order,exercise,kind,reps\nR,1,Plank,hold,1\nR,,Plank,hold,999\n")
        }
        XCTAssertTrue(errs.contains { $0.contains("'reps'") }, "\(errs)")
        XCTAssertTrue(errs.contains { $0.contains("fill it on every row") }, "\(errs)")
    }
}
