//
//  ExportImportService.swift
//  WorkoutTracker
//
//  JSON backup/restore. Export captures all data needed to restore the app.
//  Import is NON-DESTRUCTIVE by design (principle: "Import should not overwrite
//  existing data without explicit handling"): any record whose id already
//  exists is SKIPPED, never overwritten. The result reports how many records
//  were added vs. skipped so the user understands what happened.
//

import Foundation
import SwiftData

// MARK: - Backup document (stable JSON shape)

struct BackupDocument: Codable {
    /// 4: the exercise structure (kind and its fields; machine weight; the
    /// workout's copy of them; each set's side). An exercise's own rest is no
    /// longer written — rest is set per routine and per workout (TypeRests);
    /// the routine-row and workout-row rest fields are still carried for
    /// older data.
    var formatVersion: Int = 4
    var exportedAt: Date = .now

    var locations: [LocationDTO] = []
    var machines: [MachineDTO] = []
    var settingDefs: [SettingDefDTO] = []
    var exercises: [ExerciseDTO] = []
    var exerciseDefaultSets: [ExerciseDefaultSetDTO] = []
    var routines: [RoutineDTO] = []
    var versions: [VersionDTO] = []
    var sections: [SectionDTO] = []
    var routineExercises: [RoutineExerciseDTO] = []
    var routinePlannedSets: [RoutinePlannedSetDTO] = []
    var sessions: [SessionDTO] = []
    var sessionExercises: [SessionExerciseDTO] = []
    var sessionSets: [SessionSetDTO] = []
    var sessionMachineSettings: [SessionMachineSettingDTO] = []
    var corrections: [CorrectionDTO] = []
    var schedules: [ScheduleDTO] = []
    /// Added in formatVersion 2. Optional (not `= []`) so a v1 backup, which
    /// has no `auditEvents` key at all, still decodes — see the note on
    /// SessionExerciseDTO for why a plain default value is not enough.
    var auditEvents: [AuditEventDTO]? = nil

    struct LocationDTO: Codable { var id: UUID; var name: String; var source: String; var createdAt: Date; var updatedAt: Date; var deletedAt: Date? }
    struct MachineDTO: Codable { var id: UUID; var name: String; var locationId: UUID?; var source: String; var createdAt: Date; var updatedAt: Date; var deletedAt: Date?
        // Optional so backups from before per-machine photos still decode.
        var photoData: Data? = nil
        // formatVersion 4: this machine's weight for its exercise.
        var weight: Double? = nil }
    struct SettingDefDTO: Codable { var id: UUID; var machineId: UUID?; var label: String; var order: Int; var numericValue: Int?; var otherText: String?; var source: String; var deletedAt: Date? }
    struct ExerciseDTO: Codable { var id: UUID; var name: String; var machineId: UUID?; var notes: String
        /// Read from older backups only; no longer written (rest is per routine).
        var defaultRest: Int? = nil; var defaultSection: String = "strength"; var photoData: Data? = nil; var durationMinutes: Int = 20; var intensity: String = "moderate"; var holdSeconds: Int = 30; var sides: Int = 1; var rounds: Int = 1; var source: String; var createdAt: Date; var updatedAt: Date; var deletedAt: Date?
        // Added in formatVersion 3 (Optional so older backups still decode).
        var machineIdsRaw: String? = nil; var countTimerSeconds: Int? = nil
        // formatVersion 4: the exercise structure. Absent in older backups;
        // ExerciseStructureMigration gives those exercises a kind on import.
        var kind: String? = nil; var reps: Int? = nil; var sets: Int? = nil
        var perSide: String? = nil; var perSideCustom: String? = nil
        var weight: Double? = nil; var implement: String? = nil; var addedWeight: Double? = nil
        var prop: String? = nil; var distance: Double? = nil
        var workSeconds: Int? = nil; var recoverySeconds: Int? = nil; var effort: String? = nil
        var varyBySet: Bool? = nil
        // A photo picked in the app (sheet imports leave it). Absent = false.
        var photoSetInApp: Bool? = nil }
    struct ExerciseDefaultSetDTO: Codable { var id: UUID; var exerciseId: UUID?; var order: Int; var reps: Int; var weight: Double; var machineId: UUID? = nil /* formatVersion 3 */ }
    struct RoutineDTO: Codable { var id: UUID; var name: String; var source: String; var createdAt: Date; var updatedAt: Date; var deletedAt: Date? }
    struct VersionDTO: Codable { var id: UUID; var routineId: UUID; var versionNumber: Int; var isActive: Bool; var defaultRest: Int; var defaultRestSets: Int = 90; var note: String; var source: String; var createdAt: Date
        // Rests per exercise type (absent in older backups: defaults).
        var stretchRestWithin: Int? = nil; var stretchRestBetween: Int? = nil; var cardioRestBetweenSets: Int? = nil; var cardioRestBetweenExercises: Int? = nil }
    struct SectionDTO: Codable { var id: UUID; var versionId: UUID?; var type: String; var title: String; var order: Int; var durationMinutes: Int? }
    struct RoutineExerciseDTO: Codable { var id: UUID; var sectionId: UUID?; var exerciseId: UUID; var machineId: UUID?; var displayName: String; var order: Int; var setCount: Int; var plannedWeight: Double; var plannedReps: Int; var restBetweenSets: Int; var notes: String; var targetEffort: String? }
    struct RoutinePlannedSetDTO: Codable { var id: UUID; var routineExerciseId: UUID?; var order: Int; var plannedReps: Int; var plannedWeight: Double }
    struct SessionDTO: Codable { var id: UUID; var routineId: UUID?; var routineVersionId: UUID?; var routineName: String; var status: String; var source: String; var scheduledDate: Date?; var startedAt: Date?; var endedAt: Date?; var completedAt: Date?; var createdAt: Date; var updatedAt: Date; var deletedAt: Date?; var lockedAt: Date?; var note: String; var restBetweenExercises: Int = 90; var restBetweenSets: Int = 90; var distanceUnit: String? = nil; var stretchRestWithin: Int? = nil; var stretchRestBetween: Int? = nil; var cardioRestBetweenSets: Int? = nil; var cardioRestBetweenExercises: Int? = nil }
    struct SessionExerciseDTO: Codable {
        var id: UUID; var sessionId: UUID?; var sourceRoutineExerciseId: UUID?; var exerciseId: UUID?; var machineId: UUID?
        var name: String; var sectionType: String; var order: Int; var plannedRest: Int; var notes: String; var isAddedDuringWorkout: Bool

        // Added in formatVersion 2. For cardio and stretching exercises these
        // fields ARE the recorded result — such exercises have no
        // WorkoutSessionSet rows, so `markedCompleteAt` is the only evidence the
        // exercise was performed at all (see WorkoutSessionExercise.isFullyCompleted).
        // v1 backups dropped them, which silently rendered every cardio and
        // stretching entry as "skipped" on restore.
        //
        // These MUST be Optional, not `var x: Int = 0`: Swift's synthesized
        // Codable decoder throws on a missing key and does NOT fall back to a
        // property's default value. Optional properties decode via
        // decodeIfPresent, so a v1 backup (which has none of these keys) still
        // imports, with each field coalesced to the model default in `restore`.
        var groupIndex: Int? = nil
        var startedAt: Date? = nil
        var endedAt: Date? = nil
        var durationMinutes: Int? = nil
        var intensity: String? = nil
        var holdSeconds: Int? = nil
        var sides: Int? = nil
        var rounds: Int? = nil
        var markedCompleteAt: Date? = nil
        // Added in formatVersion 3.
        var countTimerSeconds: Int? = nil
        // Added in formatVersion 4: the exercise structure as recorded.
        var kind: String? = nil; var reps: Int? = nil; var setCount: Int? = nil
        var perSide: String? = nil; var perSideCustom: String? = nil
        var workSeconds: Int? = nil; var recoverySeconds: Int? = nil; var effort: String? = nil
        var plannedDistance: Double? = nil; var actualDistance: Double? = nil
    }
    struct SessionSetDTO: Codable { var id: UUID; var exerciseId: UUID?; var index: Int; var plannedWeight: Double; var plannedReps: Int; var actualWeight: Double?; var actualReps: Int?; var isCompleted: Bool; var completedAt: Date?; var effort: String?; var effortNote: String?; var note: String?; var restOverride: Int?
        /// formatVersion 4: the side this set is for ("Left"…).
        var side: String? = nil }
    struct SessionMachineSettingDTO: Codable { var id: UUID; var exerciseId: UUID?; var definitionId: UUID?; var label: String; var order: Int; var numericValue: Int?; var otherText: String? }
    struct AuditEventDTO: Codable { var id: UUID; var timestamp: Date; var type: String; var entityName: String; var entityId: UUID?; var summary: String; var source: String }
    struct CorrectionDTO: Codable { var id: UUID; var workoutSessionId: UUID; var targetEntity: String; var targetEntityId: UUID?; var field: String; var previousValue: String; var correctedValue: String; var createdAt: Date; var note: String?; var source: String }
    struct ScheduleDTO: Codable { var id: UUID; var routineId: UUID; var freq: String; var interval: Int; var weekdaysRaw: String; var startDate: Date; var untilDate: Date?; var count: Int?; var byMonthDay: Int?; var rrule: String; var exceptionDatesRaw: String = ""; var source: String; var deletedAt: Date? }
}

struct ImportResult {
    var added = 0
    var skipped = 0
    var summary: String { "Added \(added) record(s), skipped \(skipped) existing." }
}

@MainActor
struct ExportImportService {
    /// Per-restore id lookups (see `first`). A class, so the struct's methods can fill it.
    private final class IdIndex { var byType: [ObjectIdentifier: [UUID: any PersistentModel]] = [:] }
    private let index = IdIndex()

    let context: ModelContext

    init(_ context: ModelContext) { self.context = context }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Export

    /// Build a backup. By default includes EVERYTHING (user + demo) so a restore
    /// is faithful; pass includeDemo: false to export only real user data.
    func makeBackup(includeDemo: Bool = true) -> BackupDocument {
        var doc = BackupDocument()
        func keep(_ src: DataSource) -> Bool { includeDemo || src == .user }

        for x in fetchAll(GymLocation.self) where keep(x.source) {
            doc.locations.append(.init(id: x.id, name: x.name, source: x.sourceRaw, createdAt: x.createdAt, updatedAt: x.updatedAt, deletedAt: x.deletedAt))
        }
        for x in fetchAll(Machine.self) where keep(x.source) {
            doc.machines.append(.init(id: x.id, name: x.name, locationId: x.locationId, source: x.sourceRaw, createdAt: x.createdAt, updatedAt: x.updatedAt, deletedAt: x.deletedAt, photoData: x.photoData, weight: x.weight))
            for d in x.settingDefinitions {
                doc.settingDefs.append(.init(id: d.id, machineId: x.id, label: d.label, order: d.order, numericValue: d.numericValue, otherText: d.otherText, source: d.sourceRaw, deletedAt: d.deletedAt))
            }
        }
        for x in fetchAll(Exercise.self) where keep(x.source) {
            doc.exercises.append(.init(id: x.id, name: x.name, machineId: x.machineId, notes: x.notes, defaultSection: x.defaultSectionTypeRaw, photoData: x.photoData, durationMinutes: x.durationMinutes, intensity: x.intensityRaw, holdSeconds: x.holdSeconds, sides: x.sides, rounds: x.rounds, source: x.sourceRaw, createdAt: x.createdAt, updatedAt: x.updatedAt, deletedAt: x.deletedAt, machineIdsRaw: x.machineIdsRaw, countTimerSeconds: x.countTimerSeconds,
                                       kind: x.kindRaw.isEmpty ? nil : x.kindRaw, reps: x.reps, sets: x.sets,
                                       perSide: x.perSideRaw, perSideCustom: x.perSideCustom,
                                       weight: x.weight, implement: x.implementRaw.isEmpty ? nil : x.implementRaw,
                                       addedWeight: x.addedWeight, prop: x.prop, distance: x.distance,
                                       workSeconds: x.workSeconds, recoverySeconds: x.recoverySeconds, effort: x.effortRaw,
                                       varyBySet: x.varyBySet ? true : nil,
                                       photoSetInApp: x.photoSetInApp ? true : nil))
            for ds in x.defaultSets {
                doc.exerciseDefaultSets.append(.init(id: ds.id, exerciseId: x.id, order: ds.order, reps: ds.reps, weight: ds.weight, machineId: ds.machineId))
            }
        }
        for r in fetchAll(Routine.self) where keep(r.source) {
            doc.routines.append(.init(id: r.id, name: r.name, source: r.sourceRaw, createdAt: r.createdAt, updatedAt: r.updatedAt, deletedAt: r.deletedAt))
            for v in r.versions {
                doc.versions.append(.init(id: v.id, routineId: r.id, versionNumber: v.versionNumber, isActive: v.isActive, defaultRest: v.defaultRestBetweenExercises, defaultRestSets: v.defaultRestBetweenSets, note: v.note, source: v.sourceRaw, createdAt: v.createdAt,
                                          stretchRestWithin: v.stretchRestWithin, stretchRestBetween: v.stretchRestBetween,
                                          cardioRestBetweenSets: v.cardioRestBetweenSetsOverride, cardioRestBetweenExercises: v.cardioRestBetweenExercises))
                for s in v.sections {
                    doc.sections.append(.init(id: s.id, versionId: v.id, type: s.typeRaw, title: s.title, order: s.order, durationMinutes: s.durationMinutes))
                    for e in s.exercises {
                        doc.routineExercises.append(.init(id: e.id, sectionId: s.id, exerciseId: e.exerciseId, machineId: e.machineId, displayName: e.displayName, order: e.order, setCount: e.setCount, plannedWeight: e.plannedWeight, plannedReps: e.plannedReps, restBetweenSets: e.restBetweenSets, notes: e.notes, targetEffort: e.targetEffortRaw))
                        for ps in e.plannedSets {
                            doc.routinePlannedSets.append(.init(id: ps.id, routineExerciseId: e.id, order: ps.order, plannedReps: ps.plannedReps, plannedWeight: ps.plannedWeight))
                        }
                    }
                }
            }
        }
        for ss in fetchAll(WorkoutSession.self) where keep(ss.source) {
            doc.sessions.append(.init(id: ss.id, routineId: ss.routineId, routineVersionId: ss.routineVersionId, routineName: ss.routineName, status: ss.statusRaw, source: ss.sourceRaw, scheduledDate: ss.scheduledDate, startedAt: ss.startedAt, endedAt: ss.endedAt, completedAt: ss.completedAt, createdAt: ss.createdAt, updatedAt: ss.updatedAt, deletedAt: ss.deletedAt, lockedAt: ss.lockedAt, note: ss.note, restBetweenExercises: ss.restBetweenExercises, restBetweenSets: ss.restBetweenSets, distanceUnit: ss.distanceUnitRaw,
                                      stretchRestWithin: ss.stretchRestWithin, stretchRestBetween: ss.stretchRestBetween,
                                      cardioRestBetweenSets: ss.cardioRestBetweenSetsOverride, cardioRestBetweenExercises: ss.cardioRestBetweenExercises))
            for se in ss.exercises {
                doc.sessionExercises.append(.init(id: se.id, sessionId: ss.id, sourceRoutineExerciseId: se.sourceRoutineExerciseId, exerciseId: se.exerciseId, machineId: se.machineId, name: se.name, sectionType: se.sectionTypeRaw, order: se.order, plannedRest: se.plannedRestBetweenSets, notes: se.notes, isAddedDuringWorkout: se.isAddedDuringWorkout,
                                                  groupIndex: se.groupIndex, startedAt: se.startedAt, endedAt: se.endedAt,
                                                  durationMinutes: se.durationMinutes, intensity: se.intensityRaw,
                                                  holdSeconds: se.holdSeconds, sides: se.sides, rounds: se.rounds,
                                                  markedCompleteAt: se.markedCompleteAt,
                                                  countTimerSeconds: se.countTimerSeconds,
                                                  kind: se.kindRaw.isEmpty ? nil : se.kindRaw, reps: se.reps, setCount: se.setCount,
                                                  perSide: se.perSideRaw, perSideCustom: se.perSideCustom,
                                                  workSeconds: se.workSeconds, recoverySeconds: se.recoverySeconds,
                                                  effort: se.effortRaw.isEmpty ? nil : se.effortRaw,
                                                  plannedDistance: se.plannedDistance, actualDistance: se.actualDistance))
                for set in se.sets {
                    doc.sessionSets.append(.init(id: set.id, exerciseId: se.id, index: set.index, plannedWeight: set.plannedWeight, plannedReps: set.plannedReps, actualWeight: set.actualWeight, actualReps: set.actualReps, isCompleted: set.isCompleted, completedAt: set.completedAt, effort: set.perceivedEffortRaw, effortNote: set.effortNote, note: set.note, restOverride: set.restOverrideSeconds,
                                                     side: set.side.isEmpty ? nil : set.side))
                }
                for ms in se.machineSettings {
                    doc.sessionMachineSettings.append(.init(id: ms.id, exerciseId: se.id, definitionId: ms.definitionId, label: ms.label, order: ms.order, numericValue: ms.numericValue, otherText: ms.otherText))
                }
            }
            for c in ss.corrections {
                doc.corrections.append(.init(id: c.id, workoutSessionId: ss.id, targetEntity: c.targetEntity, targetEntityId: c.targetEntityId, field: c.field, previousValue: c.previousValue, correctedValue: c.correctedValue, createdAt: c.createdAt, note: c.note, source: c.sourceRaw))
            }
        }
        for sch in fetchAll(ScheduleRule.self) where keep(sch.source) {
            doc.schedules.append(.init(id: sch.id, routineId: sch.routineId, freq: sch.freqRaw, interval: sch.interval, weekdaysRaw: sch.byWeekdaysRaw, startDate: sch.startDate, untilDate: sch.untilDate, count: sch.count, byMonthDay: sch.byMonthDay, rrule: sch.rruleString, exceptionDatesRaw: sch.exceptionDatesRaw, source: sch.sourceRaw, deletedAt: sch.deletedAt))
        }
        // The append-only audit log (session.started / session.finished /
        // routine.versioned / import.performed ...). It is the only record of
        // WHEN data-safety-relevant things happened, so a backup that omits it
        // cannot reproduce the Data Safety Check screen after a restore.
        var audits: [BackupDocument.AuditEventDTO] = []
        for a in fetchAll(AuditEvent.self) where keep(a.source) {
            audits.append(.init(id: a.id, timestamp: a.timestamp, type: a.type, entityName: a.entityName, entityId: a.entityId, summary: a.summary, source: a.sourceRaw))
        }
        doc.auditEvents = audits
        return doc
    }

    func exportJSONData(includeDemo: Bool = true) throws -> Data {
        try Self.encoder().encode(makeBackup(includeDemo: includeDemo))
    }

    /// Write a backup file to a temporary URL and return it (for the share sheet).
    func writeBackupFile(includeDemo: Bool = true) throws -> URL {
        let data = try exportJSONData(includeDemo: includeDemo)
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutBackup-\(stamp).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Import (non-destructive)

    func importJSON(_ data: Data) throws -> ImportResult {
        return restore(try Self.decodeBackup(data))
    }

    static func decodeBackup(_ data: Data) throws -> BackupDocument {
        try decoder().decode(BackupDocument.self, from: data)
    }

    /// Insert any records whose id does not already exist. Existing ids are left
    /// completely untouched — we NEVER overwrite, satisfying the safety rule.
    /// Demo seeding passes `logImport: false` so it doesn't record a user import.
    func restore(_ doc: BackupDocument, logImport: Bool = true) -> ImportResult {
        index.byType = [:]   // fresh lookups for this restore
        var result = ImportResult()

        func src(_ s: String) -> DataSource { DataSource(rawValue: s) ?? .user }

        // Locations
        for d in doc.locations {
            if exists(GymLocation.self, id: d.id) { result.skipped += 1; continue }
            let x = GymLocation(id: d.id, name: d.name, source: src(d.source), createdAt: d.createdAt)
            x.updatedAt = d.updatedAt; x.deletedAt = d.deletedAt
            add(x); result.added += 1
        }
        // Machines
        for d in doc.machines {
            if exists(Machine.self, id: d.id) { result.skipped += 1; continue }
            let x = Machine(id: d.id, name: d.name, locationId: d.locationId, source: src(d.source), createdAt: d.createdAt)
            x.updatedAt = d.updatedAt; x.deletedAt = d.deletedAt; x.photoData = d.photoData
            x.weight = d.weight
            add(x); result.added += 1
        }
        // Setting defs
        for d in doc.settingDefs {
            if exists(MachineSettingDefinition.self, id: d.id) { result.skipped += 1; continue }
            let def = MachineSettingDefinition(id: d.id, label: d.label, order: d.order, numericValue: d.numericValue, otherText: d.otherText, source: src(d.source))
            def.deletedAt = d.deletedAt
            if let mid = d.machineId, let machine = first(Machine.self, id: mid) {
                def.machine = machine; machine.settingDefinitions.append(def)
            }
            add(def); result.added += 1
        }
        // Exercises. Sets belong to their exercise: when the exercise already
        // exists, the device's copy wins and the backup's sets are skipped with
        // it. Saving sets replaces the rows with new ids
        // (RoutineRepository.updateExerciseDefaults / setPlannedSets), so
        // merging sets by id appended the backup's older sets alongside the
        // current ones — 2 sets became 4.
        var restoredExerciseIds = Set<UUID>()
        for d in doc.exercises {
            if exists(Exercise.self, id: d.id) { result.skipped += 1; continue }
            restoredExerciseIds.insert(d.id)
            let x = Exercise(id: d.id, name: d.name, machineId: d.machineId, notes: d.notes, defaultRest: d.defaultRest ?? 90, source: src(d.source), createdAt: d.createdAt)
            x.updatedAt = d.updatedAt; x.deletedAt = d.deletedAt
            x.defaultSectionTypeRaw = d.defaultSection; x.photoData = d.photoData
            x.durationMinutes = d.durationMinutes; x.intensityRaw = d.intensity
            x.holdSeconds = d.holdSeconds; x.sides = d.sides; x.rounds = d.rounds
            x.machineIdsRaw = d.machineIdsRaw ?? ""; x.countTimerSeconds = d.countTimerSeconds ?? 0
            // formatVersion 4 structure (a missing kind is filled in after import).
            x.kindRaw = d.kind ?? ""
            if let v = d.reps { x.reps = v }
            if let v = d.sets { x.sets = v }
            if let v = d.perSide { x.perSideRaw = v }
            x.perSideCustom = d.perSideCustom ?? ""
            x.weight = d.weight; x.implementRaw = d.implement ?? ""; x.addedWeight = d.addedWeight
            x.prop = d.prop ?? ""; x.distance = d.distance
            if let v = d.workSeconds { x.workSeconds = v }
            if let v = d.recoverySeconds { x.recoverySeconds = v }
            if let v = d.effort { x.effortRaw = v }
            x.varyBySet = d.varyBySet ?? false
            x.photoSetInApp = d.photoSetInApp ?? false
            add(x); result.added += 1
        }
        for d in doc.exerciseDefaultSets {
            guard let eid = d.exerciseId, restoredExerciseIds.contains(eid),
                  !exists(ExerciseDefaultSet.self, id: d.id),
                  let e = first(Exercise.self, id: eid) else { result.skipped += 1; continue }
            let ds = ExerciseDefaultSet(id: d.id, order: d.order, reps: d.reps, weight: d.weight, machineId: d.machineId)
            ds.exercise = e; e.defaultSets.append(ds)
            add(ds); result.added += 1
        }
        // Routines / versions / sections / exercises
        var restoredRoutineIds = Set<UUID>()
        for d in doc.routines {
            if exists(Routine.self, id: d.id) { result.skipped += 1; continue }
            restoredRoutineIds.insert(d.id)
            let r = Routine(id: d.id, name: d.name, source: src(d.source), createdAt: d.createdAt)
            r.updatedAt = d.updatedAt; r.deletedAt = d.deletedAt
            add(r); result.added += 1
        }
        var restoredVersionIds = Set<UUID>()
        for d in doc.versions {
            if exists(RoutineVersion.self, id: d.id) { result.skipped += 1; continue }
            restoredVersionIds.insert(d.id)
            // A routine already on the device keeps its own current plan: a
            // version arriving from the backup is added as history, not made
            // active alongside it (which left two active versions).
            let isActive = d.isActive && restoredRoutineIds.contains(d.routineId)
            let v = RoutineVersion(id: d.id, routineId: d.routineId, versionNumber: d.versionNumber, isActive: isActive, defaultRestBetweenExercises: d.defaultRest, defaultRestBetweenSets: d.defaultRestSets, note: d.note, source: src(d.source), createdAt: d.createdAt)
            if let x = d.stretchRestWithin { v.stretchRestWithin = x }
            if let x = d.stretchRestBetween { v.stretchRestBetween = x }
            v.cardioRestBetweenSetsOverride = d.cardioRestBetweenSets
            if let x = d.cardioRestBetweenExercises { v.cardioRestBetweenExercises = x }
            if let r = first(Routine.self, id: d.routineId) { v.routine = r; r.versions.append(v) }
            add(v); result.added += 1
        }
        // Sections and routine exercises are added only under a version or
        // section this restore created, like workout children below. A version
        // already on the device keeps its own structure, so a section or
        // exercise deleted there isn't brought back.
        var restoredSectionIds = Set<UUID>()
        for d in doc.sections {
            guard let vid = d.versionId, restoredVersionIds.contains(vid),
                  !exists(RoutineSection.self, id: d.id) else { result.skipped += 1; continue }
            restoredSectionIds.insert(d.id)
            let s = RoutineSection(id: d.id, type: SectionType(rawValue: d.type) ?? .strength, title: d.title, order: d.order, durationMinutes: d.durationMinutes)
            if let v = first(RoutineVersion.self, id: vid) { s.version = v; v.sections.append(s) }
            add(s); result.added += 1
        }
        var restoredRoutineExerciseIds = Set<UUID>()
        for d in doc.routineExercises {
            guard let sid = d.sectionId, restoredSectionIds.contains(sid),
                  !exists(RoutineExercise.self, id: d.id) else { result.skipped += 1; continue }
            restoredRoutineExerciseIds.insert(d.id)
            let e = RoutineExercise(id: d.id, exerciseId: d.exerciseId, machineId: d.machineId, displayName: d.displayName, order: d.order, setCount: d.setCount, plannedWeight: d.plannedWeight, plannedReps: d.plannedReps, restBetweenSets: d.restBetweenSets, notes: d.notes, targetEffort: d.targetEffort.flatMap(PerceivedEffort.init(rawValue:)))
            if let s = first(RoutineSection.self, id: sid) { e.section = s; s.exercises.append(e) }
            add(e); result.added += 1
        }
        // Planned sets follow the same rule as default sets above.
        for d in doc.routinePlannedSets {
            guard let eid = d.routineExerciseId, restoredRoutineExerciseIds.contains(eid),
                  !exists(RoutinePlannedSet.self, id: d.id),
                  let e = first(RoutineExercise.self, id: eid) else { result.skipped += 1; continue }
            let ps = RoutinePlannedSet(id: d.id, order: d.order, plannedReps: d.plannedReps, plannedWeight: d.plannedWeight)
            ps.exercise = e; e.plannedSets.append(ps)
            add(ps); result.added += 1
        }
        // Sessions and children. Children are only added under a session
        // created by this restore: a workout already on the device keeps
        // exactly what it has (a locked one holds its values forever), so a
        // set or setting deleted from it mid-workout never comes back.
        var restoredSessionIds = Set<UUID>()
        var restoredSessionExerciseIds = Set<UUID>()
        for d in doc.sessions {
            if exists(WorkoutSession.self, id: d.id) { result.skipped += 1; continue }
            restoredSessionIds.insert(d.id)
            let ss = WorkoutSession(id: d.id, routineId: d.routineId, routineVersionId: d.routineVersionId, routineName: d.routineName, status: SessionStatus(rawValue: d.status) ?? .completed, source: src(d.source), scheduledDate: d.scheduledDate, startedAt: d.startedAt, createdAt: d.createdAt, note: d.note)
            ss.endedAt = d.endedAt; ss.completedAt = d.completedAt; ss.updatedAt = d.updatedAt; ss.deletedAt = d.deletedAt; ss.lockedAt = d.lockedAt
            ss.restBetweenExercises = d.restBetweenExercises; ss.restBetweenSets = d.restBetweenSets
            if let x = d.stretchRestWithin { ss.stretchRestWithin = x }
            if let x = d.stretchRestBetween { ss.stretchRestBetween = x }
            ss.cardioRestBetweenSetsOverride = d.cardioRestBetweenSets
            if let x = d.cardioRestBetweenExercises { ss.cardioRestBetweenExercises = x }
            ss.distanceUnitRaw = d.distanceUnit ?? ""   // older backups: filled by freezeDistanceUnits
            add(ss); result.added += 1
        }
        for d in doc.sessionExercises {
            guard let sid = d.sessionId, restoredSessionIds.contains(sid),
                  !exists(WorkoutSessionExercise.self, id: d.id) else { result.skipped += 1; continue }
            restoredSessionExerciseIds.insert(d.id)
            let se = WorkoutSessionExercise(id: d.id, sourceRoutineExerciseId: d.sourceRoutineExerciseId, exerciseId: d.exerciseId, machineId: d.machineId, name: d.name, sectionType: SectionType(rawValue: d.sectionType) ?? .strength, order: d.order, plannedRestBetweenSets: d.plannedRest, notes: d.notes, isAddedDuringWorkout: d.isAddedDuringWorkout)
            // formatVersion 2 fields. A v1 backup carries none of them, so each
            // falls back to the same default the model itself declares — that
            // restore is exactly as lossy as the v1 file, and no worse.
            se.groupIndex = d.groupIndex ?? 0
            se.startedAt = d.startedAt
            se.endedAt = d.endedAt
            se.durationMinutes = d.durationMinutes ?? 0
            se.intensityRaw = d.intensity ?? ""
            se.holdSeconds = d.holdSeconds ?? 0
            se.sides = d.sides ?? 1
            se.rounds = d.rounds ?? 1
            se.markedCompleteAt = d.markedCompleteAt
            se.countTimerSeconds = d.countTimerSeconds ?? 0
            // formatVersion 4. Older workouts have no kind and keep reading
            // the fields above.
            se.kindRaw = d.kind ?? ""
            se.reps = d.reps ?? 0; se.setCount = d.setCount ?? 0
            se.perSideRaw = d.perSide ?? PerSide.single.rawValue; se.perSideCustom = d.perSideCustom ?? ""
            se.workSeconds = d.workSeconds ?? 0; se.recoverySeconds = d.recoverySeconds ?? 0
            se.effortRaw = d.effort ?? ""
            se.plannedDistance = d.plannedDistance; se.actualDistance = d.actualDistance
            if let ss = first(WorkoutSession.self, id: sid) { se.session = ss; ss.exercises.append(se) }
            add(se); result.added += 1
        }
        for d in doc.sessionSets {
            guard let eid = d.exerciseId, restoredSessionExerciseIds.contains(eid),
                  !exists(WorkoutSessionSet.self, id: d.id) else { result.skipped += 1; continue }
            let set = WorkoutSessionSet(id: d.id, index: d.index, plannedWeight: d.plannedWeight, plannedReps: d.plannedReps, actualWeight: d.actualWeight, actualReps: d.actualReps, isCompleted: d.isCompleted)
            set.completedAt = d.completedAt; set.perceivedEffortRaw = d.effort; set.effortNote = d.effortNote; set.note = d.note; set.restOverrideSeconds = d.restOverride
            set.side = d.side ?? ""
            if let se = first(WorkoutSessionExercise.self, id: eid) { set.exercise = se; se.sets.append(set) }
            add(set); result.added += 1
        }
        for d in doc.sessionMachineSettings {
            guard let eid = d.exerciseId, restoredSessionExerciseIds.contains(eid),
                  !exists(SessionMachineSetting.self, id: d.id) else { result.skipped += 1; continue }
            let ms = SessionMachineSetting(id: d.id, definitionId: d.definitionId, label: d.label, order: d.order, numericValue: d.numericValue, otherText: d.otherText)
            if let se = first(WorkoutSessionExercise.self, id: eid) { ms.exercise = se; se.machineSettings.append(ms) }
            add(ms); result.added += 1
        }
        for d in doc.corrections {
            // Corrections too: only for workouts this restore created.
            guard restoredSessionIds.contains(d.workoutSessionId),
                  !exists(WorkoutCorrectionEvent.self, id: d.id) else { result.skipped += 1; continue }
            let c = WorkoutCorrectionEvent(id: d.id, workoutSessionId: d.workoutSessionId, targetEntity: d.targetEntity, targetEntityId: d.targetEntityId, field: d.field, previousValue: d.previousValue, correctedValue: d.correctedValue, note: d.note, source: src(d.source), createdAt: d.createdAt)
            if let ss = first(WorkoutSession.self, id: d.workoutSessionId) { c.session = ss; ss.corrections.append(c) }
            add(c); result.added += 1
        }
        for d in doc.schedules {
            if exists(ScheduleRule.self, id: d.id) { result.skipped += 1; continue }
            let sch = ScheduleRule(id: d.id, routineId: d.routineId, freq: RecurrenceFrequency(rawValue: d.freq) ?? .weekly, interval: d.interval, weekdays: [], startDate: d.startDate, untilDate: d.untilDate, count: d.count, byMonthDay: d.byMonthDay, source: src(d.source))
            sch.byWeekdaysRaw = d.weekdaysRaw; sch.rruleString = d.rrule; sch.exceptionDatesRaw = d.exceptionDatesRaw; sch.deletedAt = d.deletedAt
            add(sch); result.added += 1
        }

        // Audit events are append-only history in their own right; restore them
        // before logging this import so the log reads in chronological order.
        for d in doc.auditEvents ?? [] {
            if exists(AuditEvent.self, id: d.id) { result.skipped += 1; continue }
            let a = AuditEvent(id: d.id, type: d.type, entity: d.entityName, entityId: d.entityId, summary: d.summary, source: src(d.source), timestamp: d.timestamp)
            add(a); result.added += 1
        }

        // A backup can carry routine entries for exercises deleted from the
        // library; drop them so routines only use library exercises.
        CatalogSyncService(context).pruneExercisesMissingFromLibrary()
        // A backup taken after an older restore can itself carry duplicate
        // planned sets; clean them on the way in.
        CatalogSyncService(context).removeDuplicatePlannedSets()
        // A backup can carry abandoned workouts from before they were discarded.
        WorkoutRepository(context).purgeDiscardedWorkouts()
        // Backups made before the unit was recorded get this device's unit.
        WorkoutRepository(context).freezeDistanceUnits()
        // Exercises from a backup made before the exercise structure get a kind.
        ExerciseStructureMigration(context).run(log: logImport)
        // Demo seeding (logImport: false) loads data the app generated
        // itself; there is nothing to repair, and a repair entry would be
        // logged as the user's and outlive Delete Demo Data.
        if logImport { DataSafetyRepair(context).autoRepair() }

        if logImport {
            Audit.log(context, type: "import.performed", entity: "*", summary: result.summary, source: .user)
        }
        return result
    }

    // MARK: - Helpers

    private func fetchAll<T: PersistentModel>(_ type: T.Type) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }
    private func exists<T: PersistentModel & UUIDIdentifiable>(_ type: T.Type, id: UUID) -> Bool {
        first(type, id: id) != nil
    }
    /// Id lookup: each type's records are fetched once per restore into a
    /// dictionary (kept current by `add`), instead of a full fetch-and-scan
    /// per record — which made a large restore quadratic.
    private func first<T: PersistentModel & UUIDIdentifiable>(_ type: T.Type, id: UUID) -> T? {
        let key = ObjectIdentifier(type)
        if index.byType[key] == nil {
            var map: [UUID: any PersistentModel] = [:]
            for x in fetchAll(type) where map[x.id] == nil { map[x.id] = x }
            index.byType[key] = map
        }
        return index.byType[key]?[id] as? T
    }
    /// Insert a restored record and add it to its type's lookup (if built).
    private func add<T: PersistentModel & UUIDIdentifiable>(_ object: T) {
        context.insert(object)
        index.byType[ObjectIdentifier(T.self)]?[object.id] = object
    }
}
