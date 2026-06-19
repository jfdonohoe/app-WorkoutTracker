//
//  UUIDIdentifiable.swift
//  WorkoutTracker
//
//  A tiny shared protocol giving every persistent entity a stable `id: UUID`.
//  Used by generic helpers (export/import lookups, integrity checks) so they
//  can find a record by id without per-type predicates.
//

import Foundation

protocol UUIDIdentifiable: AnyObject {
    var id: UUID { get }
}

extension GymLocation: UUIDIdentifiable {}
extension Machine: UUIDIdentifiable {}
extension MachineSettingDefinition: UUIDIdentifiable {}
extension Exercise: UUIDIdentifiable {}
extension ExerciseDefaultSet: UUIDIdentifiable {}
extension Routine: UUIDIdentifiable {}
extension RoutineVersion: UUIDIdentifiable {}
extension RoutineSection: UUIDIdentifiable {}
extension RoutineExercise: UUIDIdentifiable {}
extension RoutinePlannedSet: UUIDIdentifiable {}
extension WorkoutSession: UUIDIdentifiable {}
extension WorkoutSessionExercise: UUIDIdentifiable {}
extension WorkoutSessionSet: UUIDIdentifiable {}
extension SessionMachineSetting: UUIDIdentifiable {}
extension WorkoutCorrectionEvent: UUIDIdentifiable {}
extension AuditEvent: UUIDIdentifiable {}
extension ScheduleRule: UUIDIdentifiable {}
