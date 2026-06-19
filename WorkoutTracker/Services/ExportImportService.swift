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
    var formatVersion: Int = 1
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

    struct LocationDTO: Codable { var id: UUID; var name: String; var source: String; var createdAt: Date; var updatedAt: Date; var deletedAt: Date? }
    struct MachineDTO: Codable { var id: UUID; var name: String; var locationId: UUID?; var source: String; var createdAt: Date; var updatedAt: Date; var deletedAt: Date? }
    struct SettingDefDTO: Codable { var id: UUID; var machineId: UUID?; var label: String; var order: Int; var numericValue: Int?; var otherText: String?; var source: String; var deletedAt: Date? }
    struct ExerciseDTO: Codable { var id: UUID; var name: String; var machineId: UUID?; var notes: String; var defaultRest: Int = 90; var defaultSection: String = "strength"; var photoData: Data? = nil; var durationMinutes: Int = 20; var intensity: String = "moderate"; var holdSeconds: Int = 30; var sides: Int = 1; var rounds: Int = 1; var source: String; var createdAt: Date; var updatedAt: Date; var deletedAt: Date? }
    struct ExerciseDefaultSetDTO: Codable { var id: UUID; var exerciseId: UUID?; var order: Int; var reps: Int; var weight: Double }
    struct RoutineDTO: Codable { var id: UUID; var name: String; var source: String; var createdAt: Date; var updatedAt: Date; var deletedAt: Date? }
    struct VersionDTO: Codable { var id: UUID; var routineId: UUID; var versionNumber: Int; var isActive: Bool; var defaultRest: Int; var defaultRestSets: Int = 90; var note: String; var source: String; var createdAt: Date }
    struct SectionDTO: Codable { var id: UUID; var versionId: UUID?; var type: String; var title: String; var order: Int; var durationMinutes: Int? }
    struct RoutineExerciseDTO: Codable { var id: UUID; var sectionId: UUID?; var exerciseId: UUID; var machineId: UUID?; var displayName: String; var order: Int; var setCount: Int; var plannedWeight: Double; var plannedReps: Int; var restBetweenSets: Int; var notes: String; var targetEffort: String? }
    struct RoutinePlannedSetDTO: Codable { var id: UUID; var routineExerciseId: UUID?; var order: Int; var plannedReps: Int; var plannedWeight: Double }
    struct SessionDTO: Codable { var id: UUID; var routineId: UUID?; var routineVersionId: UUID?; var routineName: String; var status: String; var source: String; var scheduledDate: Date?; var startedAt: Date?; var endedAt: Date?; var completedAt: Date?; var createdAt: Date; var updatedAt: Date; var deletedAt: Date?; var lockedAt: Date?; var note: String; var restBetweenExercises: Int = 90; var restBetweenSets: Int = 90 }
    struct SessionExerciseDTO: Codable { var id: UUID; var sessionId: UUID?; var sourceRoutineExerciseId: UUID?; var exerciseId: UUID?; var machineId: UUID?; var name: String; var sectionType: String; var order: Int; var plannedRest: Int; var notes: String; var isAddedDuringWorkout: Bool }
    struct SessionSetDTO: Codable { var id: UUID; var exerciseId: UUID?; var index: Int; var plannedWeight: Double; var plannedReps: Int; var actualWeight: Double?; var actualReps: Int?; var isCompleted: Bool; var completedAt: Date?; var effort: String?; var effortNote: String?; var note: String?; var restOverride: Int? }
    struct SessionMachineSettingDTO: Codable { var id: UUID; var exerciseId: UUID?; var definitionId: UUID?; var label: String; var order: Int; var numericValue: Int?; var otherText: String? }
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
            doc.machines.append(.init(id: x.id, name: x.name, locationId: x.locationId, source: x.sourceRaw, createdAt: x.createdAt, updatedAt: x.updatedAt, deletedAt: x.deletedAt))
            for d in x.settingDefinitions {
                doc.settingDefs.append(.init(id: d.id, machineId: x.id, label: d.label, order: d.order, numericValue: d.numericValue, otherText: d.otherText, source: d.sourceRaw, deletedAt: d.deletedAt))
            }
        }
        for x in fetchAll(Exercise.self) where keep(x.source) {
            doc.exercises.append(.init(id: x.id, name: x.name, machineId: x.machineId, notes: x.notes, defaultRest: x.defaultRest, defaultSection: x.defaultSectionTypeRaw, photoData: x.photoData, durationMinutes: x.durationMinutes, intensity: x.intensityRaw, holdSeconds: x.holdSeconds, sides: x.sides, rounds: x.rounds, source: x.sourceRaw, createdAt: x.createdAt, updatedAt: x.updatedAt, deletedAt: x.deletedAt))
            for ds in x.defaultSets {
                doc.exerciseDefaultSets.append(.init(id: ds.id, exerciseId: x.id, order: ds.order, reps: ds.reps, weight: ds.weight))
            }
        }
        for r in fetchAll(Routine.self) where keep(r.source) {
            doc.routines.append(.init(id: r.id, name: r.name, source: r.sourceRaw, createdAt: r.createdAt, updatedAt: r.updatedAt, deletedAt: r.deletedAt))
            for v in r.versions {
                doc.versions.append(.init(id: v.id, routineId: r.id, versionNumber: v.versionNumber, isActive: v.isActive, defaultRest: v.defaultRestBetweenExercises, defaultRestSets: v.defaultRestBetweenSets, note: v.note, source: v.sourceRaw, createdAt: v.createdAt))
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
            doc.sessions.append(.init(id: ss.id, routineId: ss.routineId, routineVersionId: ss.routineVersionId, routineName: ss.routineName, status: ss.statusRaw, source: ss.sourceRaw, scheduledDate: ss.scheduledDate, startedAt: ss.startedAt, endedAt: ss.endedAt, completedAt: ss.completedAt, createdAt: ss.createdAt, updatedAt: ss.updatedAt, deletedAt: ss.deletedAt, lockedAt: ss.lockedAt, note: ss.note, restBetweenExercises: ss.restBetweenExercises, restBetweenSets: ss.restBetweenSets))
            for se in ss.exercises {
                doc.sessionExercises.append(.init(id: se.id, sessionId: ss.id, sourceRoutineExerciseId: se.sourceRoutineExerciseId, exerciseId: se.exerciseId, machineId: se.machineId, name: se.name, sectionType: se.sectionTypeRaw, order: se.order, plannedRest: se.plannedRestBetweenSets, notes: se.notes, isAddedDuringWorkout: se.isAddedDuringWorkout))
                for set in se.sets {
                    doc.sessionSets.append(.init(id: set.id, exerciseId: se.id, index: set.index, plannedWeight: set.plannedWeight, plannedReps: set.plannedReps, actualWeight: set.actualWeight, actualReps: set.actualReps, isCompleted: set.isCompleted, completedAt: set.completedAt, effort: set.perceivedEffortRaw, effortNote: set.effortNote, note: set.note, restOverride: set.restOverrideSeconds))
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
        let doc = try Self.decoder().decode(BackupDocument.self, from: data)
        return restore(doc)
    }

    /// Insert any records whose id does not already exist. Existing ids are left
    /// completely untouched — we NEVER overwrite, satisfying the safety rule.
    func restore(_ doc: BackupDocument) -> ImportResult {
        var result = ImportResult()

        func src(_ s: String) -> DataSource { DataSource(rawValue: s) ?? .user }

        // Locations
        for d in doc.locations {
            if exists(GymLocation.self, id: d.id) { result.skipped += 1; continue }
            let x = GymLocation(id: d.id, name: d.name, source: src(d.source), createdAt: d.createdAt)
            x.updatedAt = d.updatedAt; x.deletedAt = d.deletedAt
            context.insert(x); result.added += 1
        }
        // Machines
        for d in doc.machines {
            if exists(Machine.self, id: d.id) { result.skipped += 1; continue }
            let x = Machine(id: d.id, name: d.name, locationId: d.locationId, source: src(d.source), createdAt: d.createdAt)
            x.updatedAt = d.updatedAt; x.deletedAt = d.deletedAt
            context.insert(x); result.added += 1
        }
        // Setting defs
        for d in doc.settingDefs {
            if exists(MachineSettingDefinition.self, id: d.id) { result.skipped += 1; continue }
            let def = MachineSettingDefinition(id: d.id, label: d.label, order: d.order, numericValue: d.numericValue, otherText: d.otherText, source: src(d.source))
            def.deletedAt = d.deletedAt
            if let mid = d.machineId, let machine = first(Machine.self, id: mid) {
                def.machine = machine; machine.settingDefinitions.append(def)
            }
            context.insert(def); result.added += 1
        }
        // Exercises
        for d in doc.exercises {
            if exists(Exercise.self, id: d.id) { result.skipped += 1; continue }
            let x = Exercise(id: d.id, name: d.name, machineId: d.machineId, notes: d.notes, defaultRest: d.defaultRest, source: src(d.source), createdAt: d.createdAt)
            x.updatedAt = d.updatedAt; x.deletedAt = d.deletedAt
            x.defaultSectionTypeRaw = d.defaultSection; x.photoData = d.photoData
            x.durationMinutes = d.durationMinutes; x.intensityRaw = d.intensity
            x.holdSeconds = d.holdSeconds; x.sides = d.sides; x.rounds = d.rounds
            context.insert(x); result.added += 1
        }
        for d in doc.exerciseDefaultSets {
            if exists(ExerciseDefaultSet.self, id: d.id) { result.skipped += 1; continue }
            let ds = ExerciseDefaultSet(id: d.id, order: d.order, reps: d.reps, weight: d.weight)
            if let eid = d.exerciseId, let e = first(Exercise.self, id: eid) { ds.exercise = e; e.defaultSets.append(ds) }
            context.insert(ds); result.added += 1
        }
        // Routines / versions / sections / exercises
        for d in doc.routines {
            if exists(Routine.self, id: d.id) { result.skipped += 1; continue }
            let r = Routine(id: d.id, name: d.name, source: src(d.source), createdAt: d.createdAt)
            r.updatedAt = d.updatedAt; r.deletedAt = d.deletedAt
            context.insert(r); result.added += 1
        }
        for d in doc.versions {
            if exists(RoutineVersion.self, id: d.id) { result.skipped += 1; continue }
            let v = RoutineVersion(id: d.id, routineId: d.routineId, versionNumber: d.versionNumber, isActive: d.isActive, defaultRestBetweenExercises: d.defaultRest, defaultRestBetweenSets: d.defaultRestSets, note: d.note, source: src(d.source), createdAt: d.createdAt)
            if let r = first(Routine.self, id: d.routineId) { v.routine = r; r.versions.append(v) }
            context.insert(v); result.added += 1
        }
        for d in doc.sections {
            if exists(RoutineSection.self, id: d.id) { result.skipped += 1; continue }
            let s = RoutineSection(id: d.id, type: SectionType(rawValue: d.type) ?? .strength, title: d.title, order: d.order, durationMinutes: d.durationMinutes)
            if let vid = d.versionId, let v = first(RoutineVersion.self, id: vid) { s.version = v; v.sections.append(s) }
            context.insert(s); result.added += 1
        }
        for d in doc.routineExercises {
            if exists(RoutineExercise.self, id: d.id) { result.skipped += 1; continue }
            let e = RoutineExercise(id: d.id, exerciseId: d.exerciseId, machineId: d.machineId, displayName: d.displayName, order: d.order, setCount: d.setCount, plannedWeight: d.plannedWeight, plannedReps: d.plannedReps, restBetweenSets: d.restBetweenSets, notes: d.notes, targetEffort: d.targetEffort.flatMap(PerceivedEffort.init(rawValue:)))
            if let sid = d.sectionId, let s = first(RoutineSection.self, id: sid) { e.section = s; s.exercises.append(e) }
            context.insert(e); result.added += 1
        }
        for d in doc.routinePlannedSets {
            if exists(RoutinePlannedSet.self, id: d.id) { result.skipped += 1; continue }
            let ps = RoutinePlannedSet(id: d.id, order: d.order, plannedReps: d.plannedReps, plannedWeight: d.plannedWeight)
            if let eid = d.routineExerciseId, let e = first(RoutineExercise.self, id: eid) { ps.exercise = e; e.plannedSets.append(ps) }
            context.insert(ps); result.added += 1
        }
        // Sessions and children
        for d in doc.sessions {
            if exists(WorkoutSession.self, id: d.id) { result.skipped += 1; continue }
            let ss = WorkoutSession(id: d.id, routineId: d.routineId, routineVersionId: d.routineVersionId, routineName: d.routineName, status: SessionStatus(rawValue: d.status) ?? .completed, source: src(d.source), scheduledDate: d.scheduledDate, startedAt: d.startedAt, createdAt: d.createdAt, note: d.note)
            ss.endedAt = d.endedAt; ss.completedAt = d.completedAt; ss.updatedAt = d.updatedAt; ss.deletedAt = d.deletedAt; ss.lockedAt = d.lockedAt
            ss.restBetweenExercises = d.restBetweenExercises; ss.restBetweenSets = d.restBetweenSets
            context.insert(ss); result.added += 1
        }
        for d in doc.sessionExercises {
            if exists(WorkoutSessionExercise.self, id: d.id) { result.skipped += 1; continue }
            let se = WorkoutSessionExercise(id: d.id, sourceRoutineExerciseId: d.sourceRoutineExerciseId, exerciseId: d.exerciseId, machineId: d.machineId, name: d.name, sectionType: SectionType(rawValue: d.sectionType) ?? .strength, order: d.order, plannedRestBetweenSets: d.plannedRest, notes: d.notes, isAddedDuringWorkout: d.isAddedDuringWorkout)
            if let sid = d.sessionId, let ss = first(WorkoutSession.self, id: sid) { se.session = ss; ss.exercises.append(se) }
            context.insert(se); result.added += 1
        }
        for d in doc.sessionSets {
            if exists(WorkoutSessionSet.self, id: d.id) { result.skipped += 1; continue }
            let set = WorkoutSessionSet(id: d.id, index: d.index, plannedWeight: d.plannedWeight, plannedReps: d.plannedReps, actualWeight: d.actualWeight, actualReps: d.actualReps, isCompleted: d.isCompleted)
            set.completedAt = d.completedAt; set.perceivedEffortRaw = d.effort; set.effortNote = d.effortNote; set.note = d.note; set.restOverrideSeconds = d.restOverride
            if let eid = d.exerciseId, let se = first(WorkoutSessionExercise.self, id: eid) { set.exercise = se; se.sets.append(set) }
            context.insert(set); result.added += 1
        }
        for d in doc.sessionMachineSettings {
            if exists(SessionMachineSetting.self, id: d.id) { result.skipped += 1; continue }
            let ms = SessionMachineSetting(id: d.id, definitionId: d.definitionId, label: d.label, order: d.order, numericValue: d.numericValue, otherText: d.otherText)
            if let eid = d.exerciseId, let se = first(WorkoutSessionExercise.self, id: eid) { ms.exercise = se; se.machineSettings.append(ms) }
            context.insert(ms); result.added += 1
        }
        for d in doc.corrections {
            if exists(WorkoutCorrectionEvent.self, id: d.id) { result.skipped += 1; continue }
            let c = WorkoutCorrectionEvent(id: d.id, workoutSessionId: d.workoutSessionId, targetEntity: d.targetEntity, targetEntityId: d.targetEntityId, field: d.field, previousValue: d.previousValue, correctedValue: d.correctedValue, note: d.note, source: src(d.source), createdAt: d.createdAt)
            if let ss = first(WorkoutSession.self, id: d.workoutSessionId) { c.session = ss; ss.corrections.append(c) }
            context.insert(c); result.added += 1
        }
        for d in doc.schedules {
            if exists(ScheduleRule.self, id: d.id) { result.skipped += 1; continue }
            let sch = ScheduleRule(id: d.id, routineId: d.routineId, freq: RecurrenceFrequency(rawValue: d.freq) ?? .weekly, interval: d.interval, weekdays: [], startDate: d.startDate, untilDate: d.untilDate, count: d.count, byMonthDay: d.byMonthDay, source: src(d.source))
            sch.byWeekdaysRaw = d.weekdaysRaw; sch.rruleString = d.rrule; sch.exceptionDatesRaw = d.exceptionDatesRaw; sch.deletedAt = d.deletedAt
            context.insert(sch); result.added += 1
        }

        Audit.log(context, type: "import.performed", entity: "*", summary: result.summary, source: .user)
        return result
    }

    // MARK: - Helpers

    private func fetchAll<T: PersistentModel>(_ type: T.Type) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }
    private func exists<T: PersistentModel & UUIDIdentifiable>(_ type: T.Type, id: UUID) -> Bool {
        first(type, id: id) != nil
    }
    private func first<T: PersistentModel & UUIDIdentifiable>(_ type: T.Type, id: UUID) -> T? {
        // Generic id lookup via in-memory scan keeps this simple and predicate-free.
        fetchAll(type).first { $0.id == id }
    }
}
