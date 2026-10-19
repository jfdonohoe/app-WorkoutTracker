//
//  Schema.swift
//  WorkoutTracker
//
//  Versioned SwiftData schema + migration plan.
//
//  WHY THIS EXISTS (principle #8, "migration safety"):
//  SwiftData can perform automatic lightweight migrations, but those are only
//  safe for additive changes. By pinning an explicit VersionedSchema and a
//  SchemaMigrationPlan from day one, every future schema change is forced to go
//  through a named version with an explicit, reviewable migration stage.
//
//  HARD RULES for anyone adding WorkoutSchemaV2 later:
//   1. NEVER delete WorkoutSession / WorkoutSessionExercise / WorkoutSessionSet
//      records in a migration. History is sacred.
//   2. NEVER overwrite snapshot fields on recorded sessions.
//   3. Prefer additive changes (new optional properties with defaults). These
//      can use a `.lightweight` stage.
//   4. If a transform is unavoidable, use a `.custom` stage with willMigrate to
//      back up affected rows, and assert counts in didMigrate. Add a test in
//      MigrationIntegrityTests proving session counts and ids are preserved.
//

import Foundation
import SwiftData

/// The complete list of model types in the current schema.
/// Keep this in ONE place; AppContainer and tests both consume it.
enum WorkoutModels {
    static var all: [any PersistentModel.Type] {
        [
            GymLocation.self,
            Machine.self,
            MachineSettingDefinition.self,
            Exercise.self,
            ExerciseDefaultSet.self,
            Routine.self,
            RoutineVersion.self,
            RoutineSection.self,
            RoutineExercise.self,
            RoutinePlannedSet.self,
            WorkoutSession.self,
            WorkoutSessionExercise.self,
            WorkoutSessionSet.self,
            SessionMachineSetting.self,
            WorkoutCorrectionEvent.self,
            AuditEvent.self,
            ScheduleRule.self,
        ]
    }
}

/// Version 1.0.0 of the persistent schema.
enum WorkoutSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        WorkoutModels.all
    }
}

/// The migration plan. Today it has a single version and no stages.
///
/// To add a new version safely:
///   enum WorkoutSchemaV2: VersionedSchema { ... }
///   static var schemas = [WorkoutSchemaV1.self, WorkoutSchemaV2.self]
///   static var stages = [migrateV1toV2]
///   static let migrateV1toV2 = MigrationStage.custom(
///       fromVersion: WorkoutSchemaV1.self,
///       toVersion: WorkoutSchemaV2.self,
///       willMigrate: { context in /* back up, NEVER delete history */ },
///       didMigrate: { context in /* assert session counts unchanged */ })
enum WorkoutMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [WorkoutSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        [] // No migrations yet. Add named stages here for future versions.
    }
}
