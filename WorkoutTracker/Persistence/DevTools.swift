//
//  DevTools.swift
//  WorkoutTracker
//
//  Development-only helpers. The ENTIRE file's functionality is wrapped in
//  `#if DEBUG`, so none of it ships in a Release/App Store build — there is no
//  way to trigger a full wipe in production.
//

import Foundation
import SwiftData

#if DEBUG
enum DevTools {

    /// Delete EVERY record of EVERY model type (in-app, no relaunch needed).
    /// Debug-only — used by the dev reset button. Order doesn't matter because
    /// we explicitly clear every entity including children.
    @MainActor
    static func wipeAllData(_ context: ModelContext) {
        try? context.delete(model: WorkoutCorrectionEvent.self)
        try? context.delete(model: WorkoutSessionSet.self)
        try? context.delete(model: SessionMachineSetting.self)
        try? context.delete(model: WorkoutSessionExercise.self)
        try? context.delete(model: WorkoutSession.self)
        try? context.delete(model: RoutinePlannedSet.self)
        try? context.delete(model: RoutineExercise.self)
        try? context.delete(model: RoutineSection.self)
        try? context.delete(model: RoutineVersion.self)
        try? context.delete(model: Routine.self)
        try? context.delete(model: MachineSettingDefinition.self)
        try? context.delete(model: Machine.self)
        try? context.delete(model: ExerciseDefaultSet.self)
        try? context.delete(model: Exercise.self)
        try? context.delete(model: GymLocation.self)
        try? context.delete(model: ScheduleRule.self)
        try? context.delete(model: AuditEvent.self)
        try? context.save()
    }

    /// Wipe everything and reseed fresh demo data.
    @MainActor
    static func resetAndReseed(_ context: ModelContext) {
        wipeAllData(context)
        SeedDataService(context).seed()
        try? context.save()
    }
}
#endif
