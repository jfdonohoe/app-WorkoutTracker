//
//  Catalog.swift
//  WorkoutTracker
//
//  "Catalog" entities are the reusable building blocks the user edits:
//  gym locations, machines (with their shared settings), and exercises.
//
//  Key data-safety rules embodied here:
//   • Every entity carries a stable `id`, `createdAt`, `updatedAt`, and a
//     soft-delete `deletedAt` (principle #4). We NEVER hard-delete catalog
//     records from the UI, so historical sessions that reference them by id
//     keep resolving.
//   • Every entity carries a `source` (.user / .seedDemo) that is set once at
//     creation and never flipped — this is what makes "Delete Demo Data"
//     correct even for edited demo records (principle #6/#7).
//   • Machine settings live on the Machine and are SHARED across routines, but
//     are SNAPSHOT into a session when a workout starts (principle: settings
//     shared across routines, snapshotted into sessions).
//

import Foundation
import SwiftData

// MARK: - Gym Location

/// A physical gym. v1 assumes a single gym location, but the model supports
/// multiple locations so machine settings can later differ per location.
@Model
final class GymLocation {
    var id: UUID
    var name: String
    var sourceRaw: String
    var createdAt: Date
    var updatedAt: Date
    /// Soft delete. Non-nil means "hidden" but still resolvable by history.
    var deletedAt: Date?

    var source: DataSource {
        get { DataSource(rawValue: sourceRaw) ?? .user }
        set { sourceRaw = newValue.rawValue }
    }
    var isSoftDeleted: Bool { deletedAt != nil }

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
    }
}

// MARK: - Machine

@Model
final class Machine {
    var id: UUID
    var name: String
    /// Optional link to a location. Stored by id to avoid cross-aggregate
    /// cascade deletes.
    var locationId: UUID?
    var sourceRaw: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    /// Up to 4 labeled setting definitions (seat height, arm position, ...).
    /// Cascade is safe: definitions belong only to this machine. History keeps
    /// its OWN snapshot copy, so deleting a definition never affects history.
    @Relationship(deleteRule: .cascade, inverse: \MachineSettingDefinition.machine)
    var settingDefinitions: [MachineSettingDefinition]

    var source: DataSource {
        get { DataSource(rawValue: sourceRaw) ?? .user }
        set { sourceRaw = newValue.rawValue }
    }
    var isSoftDeleted: Bool { deletedAt != nil }

    /// Active (non-deleted) settings sorted by their slot order. Empty slots are
    /// simply absent, satisfying "don't display empty setting fields".
    var activeSettings: [MachineSettingDefinition] {
        settingDefinitions
            .filter { $0.deletedAt == nil }
            .sorted { $0.order < $1.order }
    }

    init(id: UUID = UUID(),
         name: String,
         locationId: UUID? = nil,
         source: DataSource = .user,
         createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.locationId = locationId
        self.sourceRaw = source.rawValue
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.deletedAt = nil
        self.settingDefinitions = []
    }
}

/// A single labeled machine setting slot (max 4 per machine), e.g. "Seat height".
/// It holds both its label and the machine's CURRENT shared default value.
/// When a workout starts, the value is snapshot into the session, so changing
/// the shared default later never rewrites past workouts.
@Model
final class MachineSettingDefinition {
    var id: UUID
    var machine: Machine?
    /// User-created label. Required (every setting must have a label).
    var label: String
    /// Slot index 0...3.
    var order: Int

    /// Current shared default value. Either a 1...15 numeric pick, or free text
    /// when the user picked "Other".
    var numericValue: Int?
    var otherText: String?

    var sourceRaw: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    var source: DataSource {
        get { DataSource(rawValue: sourceRaw) ?? .user }
        set { sourceRaw = newValue.rawValue }
    }

    /// Human-readable current value ("8", "Other: lever down", or "—").
    var displayValue: String {
        if let n = numericValue { return "\(n)" }
        if let t = otherText, !t.isEmpty { return t }
        return "—"
    }

    init(id: UUID = UUID(),
         label: String,
         order: Int,
         numericValue: Int? = nil,
         otherText: String? = nil,
         source: DataSource = .user,
         createdAt: Date = .now) {
        self.id = id
        self.label = label
        self.order = order
        self.numericValue = numericValue
        self.otherText = otherText
        self.sourceRaw = source.rawValue
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.deletedAt = nil
    }
}

// MARK: - Exercise

/// A reusable exercise in the catalog/library. It now carries DEFAULT planned
/// values (sets/reps/weight/rest) so it can be pulled into a routine fully
/// configured. The same exercise name may exist multiple times with different
/// defaults (e.g. heavy vs. light variants).
@Model
final class Exercise {
    var id: UUID
    var name: String
    /// Optional link to a Machine (v1 strength is machine-only). Stored by id.
    var machineId: UUID?
    var notes: String
    /// Which routine grouping this exercise belongs to by default
    /// (strength / cardio / stretching / …). Stored as a stable raw string.
    var defaultSectionTypeRaw: String = SectionType.strength.rawValue
    /// Optional reference photo for the exercise definition. Stored externally
    /// so the database stays small. (Strength & cardio only.)
    @Attribute(.externalStorage) var photoData: Data?
    /// Default cooldown between sets (seconds) when added to a routine. (Strength.)
    var defaultRest: Int = 90

    // Cardio-group attributes.
    var durationMinutes: Int = 20
    var intensityRaw: String = CardioIntensity.moderate.rawValue

    // Stretching-group attributes.
    var holdSeconds: Int = 30
    var sides: Int = 1
    var rounds: Int = 1

    var sourceRaw: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    /// Default per-set prescription used to seed a RoutineExercise.
    @Relationship(deleteRule: .cascade, inverse: \ExerciseDefaultSet.exercise)
    var defaultSets: [ExerciseDefaultSet]

    var source: DataSource {
        get { DataSource(rawValue: sourceRaw) ?? .user }
        set { sourceRaw = newValue.rawValue }
    }
    var defaultSectionType: SectionType {
        get { SectionType(rawValue: defaultSectionTypeRaw) ?? .strength }
        set { defaultSectionTypeRaw = newValue.rawValue }
    }
    var intensity: CardioIntensity {
        get { CardioIntensity(rawValue: intensityRaw) ?? .moderate }
        set { intensityRaw = newValue.rawValue }
    }
    var isSoftDeleted: Bool { deletedAt != nil }

    /// Default sets as plain tuples (empty if none defined yet).
    var effectiveDefaultSets: [(reps: Int, weight: Double)] {
        defaultSets.sorted { $0.order < $1.order }.map { ($0.reps, $0.weight) }
    }

    /// Short, group-aware summary line for lists.
    var summary: String {
        switch defaultSectionType {
        case .cardio:
            return "\(durationMinutes) min · \(intensity.displayName)"
        case .stretching:
            let sideText = sides > 1 ? "\(sides) sides" : "1 side"
            return "Hold \(holdSeconds)s · \(sideText) · \(rounds) round\(rounds == 1 ? "" : "s")"
        case .strength:
            let s = effectiveDefaultSets
            guard !s.isEmpty else { return "No default sets" }
            if s.allSatisfy({ $0.reps == s[0].reps && $0.weight == s[0].weight }) {
                return "\(s.count)×\(s[0].reps) @ \(Int(s[0].weight)) lb"
            }
            return "\(s.count) sets"
        }
    }

    init(id: UUID = UUID(),
         name: String,
         machineId: UUID? = nil,
         notes: String = "",
         defaultRest: Int = 90,
         source: DataSource = .user,
         createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.machineId = machineId
        self.notes = notes
        self.defaultRest = defaultRest
        self.sourceRaw = source.rawValue
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.deletedAt = nil
        self.defaultSets = []
    }
}

/// One default planned set on a library Exercise.
@Model
final class ExerciseDefaultSet {
    var id: UUID
    var exercise: Exercise?
    var order: Int
    var reps: Int
    var weight: Double

    init(id: UUID = UUID(), order: Int, reps: Int, weight: Double) {
        self.id = id
        self.order = order
        self.reps = reps
        self.weight = weight
    }
}
