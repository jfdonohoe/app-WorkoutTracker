//
//  Routine.swift
//  WorkoutTracker
//
//  Routines are VERSIONED (principle #3). A Routine is a stable identity + name;
//  its actual content lives in immutable RoutineVersion snapshots.
//
//  Editing a routine in a way that should affect future workouts creates a NEW
//  RoutineVersion and marks it active. Older versions are kept forever so that
//  past WorkoutSessions — which reference a version by id — stay accurate
//  (principle #2). We never mutate a version that a recorded session points to.
//

import Foundation
import SwiftData

@Model
final class Routine {
    var id: UUID
    var name: String
    var sourceRaw: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    /// All versions of this routine, newest-highest versionNumber.
    /// Cascade deletes versions IF the routine itself is ever hard-deleted:
    /// demo cleanup, or a scratch routine no workout ever used (RoutineEditorView,
    /// CalendarView, ScheduleWorkoutSheet). Routines with history are soft-deleted.
    @Relationship(deleteRule: .cascade, inverse: \RoutineVersion.routine)
    var versions: [RoutineVersion]

    var source: DataSource {
        get { DataSource(rawValue: sourceRaw) ?? .user }
        set { sourceRaw = newValue.rawValue }
    }
    var isSoftDeleted: Bool { deletedAt != nil }

    /// The currently active version (what new workouts snapshot from).
    var activeVersion: RoutineVersion? {
        versions
            .filter { $0.isActive }
            .max(by: { $0.versionNumber < $1.versionNumber })
            ?? versions.max(by: { $0.versionNumber < $1.versionNumber })
    }

    var nextVersionNumber: Int {
        (versions.map(\.versionNumber).max() ?? 0) + 1
    }

    init(id: UUID = UUID(),
         name: String,
         source: DataSource = .user,
         createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.sourceRaw = source.rawValue
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.deletedAt = nil
        self.versions = []
    }
}

/// An immutable-by-convention snapshot of a routine's content at a point in time.
/// Once a recorded session references it, it must not be edited; instead a new
/// version is created. See RoutineRepository.makeNewVersion(...).
@Model
final class RoutineVersion {
    var id: UUID
    var routine: Routine?
    var routineId: UUID
    var versionNumber: Int
    var isActive: Bool
    /// Default rest between exercises (seconds) for this routine version.
    /// Defaults to 1 minute.
    var defaultRestBetweenExercises: Int
    /// Default rest between sets (seconds). Set cooldown is a ROUTINE-level
    /// setting, not part of an exercise's definition. Defaults to 1 minute.
    var defaultRestBetweenSets: Int = 60
    /// Rests per exercise type (TypeRests; additive, so stores upgrade in
    /// place). Stretching: get-ready inside a stretch / into the next one.
    var stretchRestWithin: Int = 5
    var stretchRestBetween: Int = 5
    /// Cardio between sets; nil = not set yet, so the strength value is used.
    var cardioRestBetweenSetsOverride: Int?
    /// Cardio between exercises; 0 = back to back.
    var cardioRestBetweenExercises: Int = 0
    var note: String
    var sourceRaw: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \RoutineSection.version)
    var sections: [RoutineSection]

    var source: DataSource {
        get { DataSource(rawValue: sourceRaw) ?? .user }
        set { sourceRaw = newValue.rawValue }
    }

    var orderedSections: [RoutineSection] {
        sections.sorted { $0.order < $1.order }
    }

    init(id: UUID = UUID(),
         routineId: UUID,
         versionNumber: Int,
         isActive: Bool = true,
         defaultRestBetweenExercises: Int = 60,
         defaultRestBetweenSets: Int = 60,
         note: String = "",
         source: DataSource = .user,
         createdAt: Date = .now) {
        self.id = id
        self.routineId = routineId
        self.versionNumber = versionNumber
        self.isActive = isActive
        self.defaultRestBetweenExercises = defaultRestBetweenExercises
        self.defaultRestBetweenSets = defaultRestBetweenSets
        self.note = note
        self.sourceRaw = source.rawValue
        self.createdAt = createdAt
        self.sections = []
    }
}

@Model
final class RoutineSection {
    var id: UUID
    var version: RoutineVersion?
    var typeRaw: String
    var title: String
    var order: Int
    /// For time-based sections (warm-up / cardio), an optional planned duration.
    var durationMinutes: Int?

    @Relationship(deleteRule: .cascade, inverse: \RoutineExercise.section)
    var exercises: [RoutineExercise]

    var type: SectionType {
        get { SectionType(rawValue: typeRaw) ?? .strength }
        set { typeRaw = newValue.rawValue }
    }

    var orderedExercises: [RoutineExercise] {
        exercises.sorted { $0.order < $1.order }
    }

    init(id: UUID = UUID(),
         type: SectionType,
         title: String? = nil,
         order: Int,
         durationMinutes: Int? = nil) {
        self.id = id
        self.typeRaw = type.rawValue
        self.title = title ?? type.displayName
        self.order = order
        self.durationMinutes = durationMinutes
        self.exercises = []
    }
}

/// A planned exercise inside a routine section. Holds the planned prescription
/// (sets/reps/weight/rest). The SAME exercise may appear in different routines
/// with different values — those values live here, not on the Exercise catalog.
@Model
final class RoutineExercise {
    var id: UUID
    var section: RoutineSection?
    /// Reference to the catalog Exercise (by id, soft-delete safe).
    var exerciseId: UUID
    /// Optional machine reference (by id).
    var machineId: UUID?
    /// Snapshot of the display name at edit time (also resolvable live).
    var displayName: String
    var order: Int

    /// Summary fields. `setCount`/`plannedWeight`/`plannedReps` describe the
    /// prescription at a glance and act as a fallback when no per-set rows exist.
    var setCount: Int
    var plannedWeight: Double   // as entered; the unit (WeightUnit) is a label, numbers are never converted
    var plannedReps: Int        // exact reps only
    var restBetweenSets: Int    // seconds; legacy per-exercise rest, kept for storage — timers read the version's TypeRests
    var notes: String
    var targetEffortRaw: String?

    /// Per-set planned values. When present these are the source of truth (each
    /// set can have its own reps/weight). When empty, the summary fields above
    /// are used to synthesize `setCount` identical sets.
    @Relationship(deleteRule: .cascade, inverse: \RoutinePlannedSet.exercise)
    var plannedSets: [RoutinePlannedSet]

    init(id: UUID = UUID(),
         exerciseId: UUID,
         machineId: UUID? = nil,
         displayName: String,
         order: Int,
         setCount: Int = 3,
         plannedWeight: Double = 0,
         plannedReps: Int = 10,
         restBetweenSets: Int = 60,
         notes: String = "",
         targetEffort: PerceivedEffort? = nil) {
        self.id = id
        self.exerciseId = exerciseId
        self.machineId = machineId
        self.displayName = displayName
        self.order = order
        self.setCount = setCount
        self.plannedWeight = plannedWeight
        self.plannedReps = plannedReps
        self.restBetweenSets = restBetweenSets
        self.notes = notes
        self.targetEffortRaw = targetEffort?.rawValue
        self.plannedSets = []
    }

    var targetEffort: PerceivedEffort? {
        get { targetEffortRaw.flatMap(PerceivedEffort.init(rawValue:)) }
        set { targetEffortRaw = newValue?.rawValue }
    }

    /// The planned sets to use when snapshotting a workout: explicit per-set rows
    /// if defined, otherwise `setCount` copies of the summary values.
    var effectivePlannedSets: [(reps: Int, weight: Double)] {
        if !plannedSets.isEmpty {
            return plannedSets.sorted { $0.order < $1.order }.map { ($0.plannedReps, $0.plannedWeight) }
        }
        return Array(repeating: (plannedReps, plannedWeight), count: max(0, setCount))
    }
}

/// One planned set inside a routine exercise (per-set reps + weight).
@Model
final class RoutinePlannedSet {
    var id: UUID
    var exercise: RoutineExercise?
    var order: Int
    var plannedReps: Int
    var plannedWeight: Double

    init(id: UUID = UUID(), order: Int, plannedReps: Int, plannedWeight: Double) {
        self.id = id
        self.order = order
        self.plannedReps = plannedReps
        self.plannedWeight = plannedWeight
    }
}
