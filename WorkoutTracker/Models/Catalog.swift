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
    /// Optional reference photo of this machine (set from the exercise editor).
    /// Additive (lightweight) schema change; shown in place of the exercise
    /// photo when this machine is in use. Stored externally like Exercise's.
    @Attribute(.externalStorage) var photoData: Data? = nil
    /// The weight used on this machine for its exercise. A machine belongs to
    /// one exercise: two exercises' machines can share a name ("Y Circuit")
    /// but are separate, each with its own weight and settings.
    var weight: Double? = nil

    /// Up to `Machine.maxSettings` labeled setting definitions (seat height,
    /// arm position, ...).
    /// Cascade is safe: definitions belong only to this machine. History keeps
    /// its OWN snapshot copy, so deleting a definition never affects history.
    @Relationship(deleteRule: .cascade, inverse: \MachineSettingDefinition.machine)
    var settingDefinitions: [MachineSettingDefinition]

    /// How many labeled setting slots one machine may have. Every UI that adds a
    /// setting checks this; keep it in ONE place so the cap can't drift between
    /// the catalog editor, the routine builder, the CSV importers and the
    /// in-workout sheet.
    static let maxSettings = 10

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

/// A single labeled machine setting slot (max `Machine.maxSettings` per
/// machine), e.g. "Seat height".
/// It holds both its label and the machine's CURRENT shared default value.
/// When a workout starts, the value is snapshot into the session, so changing
/// the shared default later never rewrites past workouts.
@Model
final class MachineSettingDefinition {
    var id: UUID
    var machine: Machine?
    /// User-created label. Required (every setting must have a label).
    var label: String
    /// Slot index, 0 ..< `Machine.maxSettings`.
    var order: Int

    /// Current shared default value. Either a 0...15 numeric pick (see
    /// `MachineSettingDefinition.valueRange`), or free text
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

    /// The numeric values a setting can take. Starts at 0. Every picker and the
    /// CSV importer read this so the range can't drift between them.
    static let valueRange = 0...15

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
    /// The PRIMARY machine (the first of `machineIds`). Stored by id. Kept as
    /// its own field because routines/sessions created before multi-machine
    /// support, and default sets with no `machineId`, resolve to it.
    var machineId: UUID?
    /// Every machine this exercise can be done on, in order, as comma-separated
    /// UUID strings. Empty = just `machineId`. A plain string keeps this an
    /// additive (lightweight) schema change. Use `machineIds`.
    var machineIdsRaw: String = ""
    var notes: String
    /// Which routine grouping this exercise belongs to by default
    /// (strength / cardio / stretching / …). Stored as a stable raw string.
    var defaultSectionTypeRaw: String = SectionType.strength.rawValue
    /// Optional reference photo for the exercise definition. Stored externally
    /// so the database stays small.
    @Attribute(.externalStorage) var photoData: Data?
    /// The photo was picked or taken in the app. A sheet import never replaces
    /// it; any other photo is re-fetched from the row's photo_url on import
    /// and replaced when the image there has changed. Additive (lightweight).
    var photoSetInApp: Bool = false
    /// Legacy per-exercise rest (seconds). Nothing reads it any more: rest is
    /// set per routine and per workout (`TypeRests`). Kept so existing stores
    /// and older backups still load.
    var defaultRest: Int = 90

    // Cardio-group attributes.
    var durationMinutes: Int = 20
    var intensityRaw: String = CardioIntensity.moderate.rawValue

    // Stretching-group attributes. `holdSeconds > 0` = a timed stretch (hold
    // that long, `rounds` times per side). `holdSeconds == 0` = a count-based
    // stretch: `rounds` is the rep count, done once per side, and the guided
    // timer uses `countTimerSeconds` per side.
    var holdSeconds: Int = 30
    var sides: Int = 1
    var rounds: Int = 1
    /// Per-side timer for a count-based stretch, in seconds. 0 = never set by
    /// the user, so the estimate (`StretchTiming.estimate`) is used.
    var countTimerSeconds: Int = 0

    // MARK: Exercise structure (Oct 2026)
    // Every exercise has a kind (ExerciseKind) that decides which fields it
    // uses. Fields reused from above: holdSeconds (Hold, Static), durationMinutes
    // (Steady), rounds (Intervals), countTimerSeconds (Dynamic's per-side
    // timer). All additive with defaults, so the store upgrades in place;
    // ExerciseStructureMigration fills them in for exercises saved before.

    /// The subcategory. Empty = saved before the structure existed.
    var kindRaw: String = ""
    /// Reps per set. Static stretch: holds per side. Hold: holds per set.
    var reps: Int = 10
    var sets: Int = 3
    var perSideRaw: String = PerSide.single.rawValue
    /// The text of a Custom… per-side choice.
    var perSideCustom: String = ""
    /// Free weight: the weight (per hand for dumbbells). A machine exercise's
    /// weight lives on each of its machines (Machine.weight).
    var weight: Double? = nil
    /// Free weight: optional implement.
    var implementRaw: String = ""
    /// Bodyweight: optional added weight (vest or belt).
    var addedWeight: Double? = nil
    /// Static stretch: optional prop (strap, wall, foam roller).
    var prop: String = ""
    /// Cardio Distance, in the user's distance unit.
    var distance: Double? = nil
    /// Cardio Intervals.
    var workSeconds: Int = 30
    var recoverySeconds: Int = 30
    /// Cardio effort (Steady, Distance, Intervals).
    var effortRaw: String = Intensity.moderate.rawValue
    /// Strength (Machine, Free weight, Bodyweight): each set has its own
    /// weight and reps, kept as the default-set rows (per machine). Off = every
    /// set is Reps × Weight, and the rows are rebuilt from those on save.
    var varyBySet: Bool = false

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

    /// The subcategory; nil only for an exercise not yet migrated.
    var kind: ExerciseKind? {
        get { ExerciseKind(rawValue: kindRaw) }
        set { kindRaw = newValue?.rawValue ?? "" }
    }
    var perSide: PerSide {
        get { PerSide(rawValue: perSideRaw) ?? .single }
        set { perSideRaw = newValue.rawValue }
    }
    var implement: Implement? {
        get { Implement(rawValue: implementRaw) }
        set { implementRaw = newValue?.rawValue ?? "" }
    }
    var effort: Intensity {
        get { Intensity(rawValue: effortRaw) ?? .moderate }
        set { effortRaw = newValue.rawValue }
    }

    /// Every machine this exercise can use, primary first. Setting it also
    /// moves `machineId` to the new first entry.
    var machineIds: [UUID] {
        get {
            let parsed = machineIdsRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            if parsed.isEmpty { return machineId.map { [$0] } ?? [] }
            return parsed
        }
        set {
            var seen = Set<UUID>()
            let unique = newValue.filter { seen.insert($0).inserted }
            machineIdsRaw = unique.map(\.uuidString).joined(separator: ",")
            machineId = unique.first
        }
    }

    /// Default sets for the PRIMARY machine (or for a machine-less exercise).
    var effectiveDefaultSets: [(reps: Int, weight: Double)] {
        defaultSets(for: machineId)
    }

    /// Default sets for one machine. Rows with no `machineId` (saved before
    /// multi-machine support) belong to the primary machine. A machine with
    /// no sets of its own yet falls back to the primary's sets.
    func defaultSets(for machine: UUID?) -> [(reps: Int, weight: Double)] {
        let target = machine ?? machineId
        let rows = defaultSets.filter { ($0.machineId ?? machineId) == target }
        if rows.isEmpty && target != machineId {
            return defaultSets(for: machineId)
        }
        return rows.sorted { $0.order < $1.order }.map { ($0.reps, $0.weight) }
    }

    /// True when `defaultSets(for:)` has rows of its own for this machine.
    func hasOwnDefaultSets(for machine: UUID?) -> Bool {
        let target = machine ?? machineId
        return defaultSets.contains { ($0.machineId ?? machineId) == target }
    }

    /// Count-based stretch (no hold time — `rounds` is a rep count).
    var isCountBasedStretch: Bool { holdSeconds == 0 }

    /// The per-side timer a count-based stretch actually uses.
    var resolvedCountTimerSeconds: Int {
        StretchTiming.resolvedCountSeconds(stored: countTimerSeconds, reps: rounds)
    }

    /// Short summary line for lists, from the kind's own fields.
    var summary: String {
        guard let kind else { return legacySummary }
        let wUnit = WeightUnit.current.rawValue
        let dUnit = UserDefaults.standard.string(forKey: DistanceUnit.storageKey) ?? DistanceUnit.mi.rawValue
        func num(_ v: Double) -> String { v.rounded() == v ? String(Int(v)) : String(v) }
        let side = perSide == .single ? "" : " · \(perSide == .custom ? perSideCustom : perSide.displayName)"
        let setsReps = "\(sets)×\(reps)"
        if varyBySet && kind.supportsVaryBySet {
            let line = SetRangeText.text(defaultSets(for: machineId), unit: wUnit, addedWeight: kind == .bodyweight)
            return (kind == .machine ? kind.displayName + " · " : "") + line + side
        }
        switch kind {
        case .machine:
            return kind.displayName + " · " + setsReps + side
        case .freeWeight:
            return setsReps + (weight.map { " @ \(num($0)) \(wUnit)" } ?? "") + side
        case .bodyweight:
            return setsReps + (addedWeight.map { " +\(num($0)) \(wUnit)" } ?? "") + side
        case .hold:
            return "\(sets)×\(reps) · hold \(holdSeconds)s" + side
        case .staticStretch:
            return "Hold \(holdSeconds)s · \(reps)×" + side + (sets > 1 ? " · \(sets) sets" : "")
        case .dynamicStretch:
            return "\(reps) reps" + side + (sets > 1 ? " · \(sets) sets" : "")
        case .steady:
            return "\(durationMinutes) min · \(effort.displayName)"
        case .distance:
            return (distance.map { "\(num($0)) \(dUnit)" } ?? "Distance") + " · \(effort.displayName)"
        case .intervals:
            return "\(rounds) × \(workSeconds)s / \(recoverySeconds)s · \(effort.displayName)"
        case .calisthenics:
            return setsReps + side
        }
    }

    /// Summary for an exercise not yet migrated to a kind.
    private var legacySummary: String {
        switch defaultSectionType {
        case .cardio:
            return "\(durationMinutes) min · \(intensity.displayName)"
        case .stretching:
            let sideText = sides > 1 ? "\(sides) sides" : "1 side"
            if isCountBasedStretch {
                return "\(rounds) rep\(rounds == 1 ? "" : "s") · \(sideText) · ~\(resolvedCountTimerSeconds)s"
            }
            return "Hold \(holdSeconds)s · \(sideText) · \(rounds) round\(rounds == 1 ? "" : "s")"
        case .strength:
            let s = effectiveDefaultSets
            guard !s.isEmpty else { return "No default sets" }
            if s.allSatisfy({ $0.reps == s[0].reps && $0.weight == s[0].weight }) {
                return "\(s.count)×\(s[0].reps) @ \(Int(s[0].weight)) \(WeightUnit.current.rawValue)"
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

/// One default planned set on a library Exercise, for one of its machines.
@Model
final class ExerciseDefaultSet {
    var id: UUID
    var exercise: Exercise?
    /// Which of the exercise's machines this set belongs to. nil = the
    /// exercise's primary machine (rows saved before multi-machine support).
    var machineId: UUID? = nil
    var order: Int
    var reps: Int
    var weight: Double

    init(id: UUID = UUID(), order: Int, reps: Int, weight: Double, machineId: UUID? = nil) {
        self.id = id
        self.order = order
        self.reps = reps
        self.weight = weight
        self.machineId = machineId
    }
}

/// Timing rules for guided stretches.
enum StretchTiming {
    /// Pause between one stretch set and the next (and between stretches).
    static let transitionSeconds = 5
    /// Estimated seconds per rep for a count-based stretch.
    static let secondsPerRep = 3

    /// Estimated per-side duration for `reps` reps, at least 10s.
    static func estimate(reps: Int) -> Int { max(10, reps * secondsPerRep) }

    /// The user's saved timer if they set one, else the estimate.
    static func resolvedCountSeconds(stored: Int, reps: Int) -> Int {
        stored > 0 ? stored : estimate(reps: reps)
    }
}

extension Exercise {
    /// The photo to show for this exercise on a given machine: that machine's
    /// own photo, falling back to the exercise-level photo (machine-less
    /// exercises, and photos added before machines had their own).
    func photo(on machineId: UUID?, in context: ModelContext) -> Data? {
        if let machineId,
           let machine = try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == machineId })).first,
           let data = machine.photoData {
            return data
        }
        return photoData
    }
}
