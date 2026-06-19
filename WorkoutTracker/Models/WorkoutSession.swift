//
//  WorkoutSession.swift
//  WorkoutTracker
//
//  A WorkoutSession is the historical record of a workout. It is the most
//  protected data in the app.
//
//  IMMUTABILITY CONTRACT (principles #1, #2, #5, #8):
//   • When a workout starts we SNAPSHOT the routine's planned values into the
//     session's own child entities. From then on the session is self-contained
//     and does NOT read live routine data — so editing the routine can never
//     change history.
//   • A session stores `routineVersionId` of the version it was created from.
//     Editing the routine creates a NEW version; this session keeps pointing at
//     the OLD one.
//   • Corrections to a recorded session are NEVER applied by overwriting these
//     fields. They are appended as WorkoutCorrectionEvent records and layered on
//     top for display only.
//   • `lockedAt` is set when a session becomes recorded history. Repository
//     write paths refuse to mutate locked sessions except to append corrections.
//

import Foundation
import SwiftData

@Model
final class WorkoutSession {
    var id: UUID

    // Snapshot references (by id) to the routine this came from. Stored by id —
    // not as a hard relationship — so routine edits/soft-deletes never cascade
    // into history.
    var routineId: UUID?
    var routineVersionId: UUID?
    /// Snapshot of the routine name at session-creation time.
    var routineName: String

    var statusRaw: String
    var sourceRaw: String

    var scheduledDate: Date?
    /// Start timecode — when the user actually began the workout.
    var startedAt: Date?
    /// End timecode — when the workout was finished/stopped.
    var endedAt: Date?
    /// When the session became recorded history (≈ end, kept for compatibility).
    var completedAt: Date?

    var createdAt: Date
    var updatedAt: Date
    /// Soft-delete marker. Only used for demo cleanup; user history is never
    /// surfaced for deletion in the UI.
    var deletedAt: Date?
    /// Set when the session becomes recorded history. Guards immutability.
    var lockedAt: Date?

    var note: String

    /// Session-level cooldown defaults (seconds), editable on the workout UI.
    /// Seeded from the routine at start; the live timers use these values.
    /// Defaults: 3 minutes between exercises, 1 minute between sets.
    var restBetweenExercises: Int = 180
    var restBetweenSets: Int = 60

    @Relationship(deleteRule: .cascade, inverse: \WorkoutSessionExercise.session)
    var exercises: [WorkoutSessionExercise]

    /// Append-only correction log. Cascade is correct: corrections belong only
    /// to this session. We never delete individual corrections.
    @Relationship(deleteRule: .cascade, inverse: \WorkoutCorrectionEvent.session)
    var corrections: [WorkoutCorrectionEvent]

    var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .scheduled }
        set { statusRaw = newValue.rawValue }
    }
    var source: DataSource {
        get { DataSource(rawValue: sourceRaw) ?? .user }
        set { sourceRaw = newValue.rawValue }
    }

    var isLocked: Bool { lockedAt != nil }
    var isSoftDeleted: Bool { deletedAt != nil }

    var orderedExercises: [WorkoutSessionExercise] {
        exercises.sorted { $0.order < $1.order }
    }

    /// Workout duration from start to end timecode, if both are present.
    var duration: TimeInterval? {
        guard let startedAt, let end = endedAt ?? completedAt else { return nil }
        return end.timeIntervalSince(startedAt)
    }

    init(id: UUID = UUID(),
         routineId: UUID? = nil,
         routineVersionId: UUID? = nil,
         routineName: String,
         status: SessionStatus = .started,
         source: DataSource = .user,
         scheduledDate: Date? = nil,
         startedAt: Date? = nil,
         createdAt: Date = .now,
         note: String = "") {
        self.id = id
        self.routineId = routineId
        self.routineVersionId = routineVersionId
        self.routineName = routineName
        self.statusRaw = status.rawValue
        self.sourceRaw = source.rawValue
        self.scheduledDate = scheduledDate
        self.startedAt = startedAt
        self.completedAt = nil
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.deletedAt = nil
        self.lockedAt = nil
        self.note = note
        self.exercises = []
        self.corrections = []
    }
}

/// Snapshot of one planned exercise inside a session, with its own copy of the
/// machine settings that were in effect when the workout started.
@Model
final class WorkoutSessionExercise {
    var id: UUID
    var session: WorkoutSession?

    /// References back to the source routine exercise / catalog / machine, by id.
    var sourceRoutineExerciseId: UUID?
    var exerciseId: UUID?
    var machineId: UUID?

    /// Snapshot of the name and section at start time.
    var name: String
    var sectionTypeRaw: String
    var order: Int
    var plannedRestBetweenSets: Int
    var notes: String
    /// True if the user added this exercise spontaneously during the workout.
    var isAddedDuringWorkout: Bool

    @Relationship(deleteRule: .cascade, inverse: \WorkoutSessionSet.exercise)
    var sets: [WorkoutSessionSet]

    @Relationship(deleteRule: .cascade, inverse: \SessionMachineSetting.exercise)
    var machineSettings: [SessionMachineSetting]

    var sectionType: SectionType {
        get { SectionType(rawValue: sectionTypeRaw) ?? .strength }
        set { sectionTypeRaw = newValue.rawValue }
    }

    var orderedSets: [WorkoutSessionSet] {
        sets.sorted { $0.index < $1.index }
    }

    /// An exercise is "skipped" when its first set was never completed.
    var isSkipped: Bool {
        guard let first = orderedSets.first else { return true }
        return !first.isCompleted
    }
    /// Partially incomplete: at least one set done but not all.
    var isPartiallyIncomplete: Bool {
        let done = sets.filter(\.isCompleted).count
        return done > 0 && done < sets.count
    }
    var isFullyCompleted: Bool {
        !sets.isEmpty && sets.allSatisfy(\.isCompleted)
    }

    init(id: UUID = UUID(),
         sourceRoutineExerciseId: UUID? = nil,
         exerciseId: UUID? = nil,
         machineId: UUID? = nil,
         name: String,
         sectionType: SectionType,
         order: Int,
         plannedRestBetweenSets: Int,
         notes: String = "",
         isAddedDuringWorkout: Bool = false) {
        self.id = id
        self.sourceRoutineExerciseId = sourceRoutineExerciseId
        self.exerciseId = exerciseId
        self.machineId = machineId
        self.name = name
        self.sectionTypeRaw = sectionType.rawValue
        self.order = order
        self.plannedRestBetweenSets = plannedRestBetweenSets
        self.notes = notes
        self.isAddedDuringWorkout = isAddedDuringWorkout
        self.sets = []
        self.machineSettings = []
    }
}

/// Snapshot of a single machine setting value as used in a specific workout.
/// Independent of the live Machine, so future default changes never rewrite it.
@Model
final class SessionMachineSetting {
    var id: UUID
    var exercise: WorkoutSessionExercise?
    /// The originating definition id (for traceability), plus a snapshot label.
    var definitionId: UUID?
    var label: String
    var order: Int
    var numericValue: Int?
    var otherText: String?

    var displayValue: String {
        if let n = numericValue { return "\(n)" }
        if let t = otherText, !t.isEmpty { return t }
        return "—"
    }

    init(id: UUID = UUID(),
         definitionId: UUID? = nil,
         label: String,
         order: Int,
         numericValue: Int? = nil,
         otherText: String? = nil) {
        self.id = id
        self.definitionId = definitionId
        self.label = label
        self.order = order
        self.numericValue = numericValue
        self.otherText = otherText
    }
}

/// A single set within a session exercise. Stores PLANNED and ACTUAL values
/// separately so the prescription is preserved alongside what really happened.
@Model
final class WorkoutSessionSet {
    var id: UUID
    var exercise: WorkoutSessionExercise?
    var index: Int

    // Planned snapshot (never edited after start).
    var plannedWeight: Double
    var plannedReps: Int

    // Actuals (editable during the active workout only).
    var actualWeight: Double?
    var actualReps: Int?

    var isCompleted: Bool
    var completedAt: Date?

    var perceivedEffortRaw: String?
    var effortNote: String?
    var note: String?

    /// Per-workout rest override (seconds). Does not change the routine.
    var restOverrideSeconds: Int?

    var perceivedEffort: PerceivedEffort? {
        get { perceivedEffortRaw.flatMap(PerceivedEffort.init(rawValue:)) }
        set { perceivedEffortRaw = newValue?.rawValue }
    }

    init(id: UUID = UUID(),
         index: Int,
         plannedWeight: Double,
         plannedReps: Int,
         actualWeight: Double? = nil,
         actualReps: Int? = nil,
         isCompleted: Bool = false) {
        self.id = id
        self.index = index
        self.plannedWeight = plannedWeight
        self.plannedReps = plannedReps
        self.actualWeight = actualWeight
        self.actualReps = actualReps
        self.isCompleted = isCompleted
        self.completedAt = nil
    }
}
