//
//  ExerciseKinds.swift
//  WorkoutTracker
//
//  The exercise structure: three categories (SectionType: strength, stretching,
//  cardio), each split into subcategories (ExerciseKind). The kind decides
//  which fields an exercise has; the form never shows a field its kind doesn't
//  use. The pick lists here are shared by every form.
//

import Foundation

/// An exercise's subcategory. Its category is `section`.
enum ExerciseKind: String, Codable, CaseIterable, Identifiable, Sendable {
    // Strength
    case machine
    case freeWeight
    case bodyweight
    case hold
    // Stretch
    case staticStretch
    case dynamicStretch
    // Cardio
    case steady
    case distance
    case intervals
    case calisthenics

    var id: String { rawValue }

    var section: SectionType {
        switch self {
        case .machine, .freeWeight, .bodyweight, .hold: return .strength
        case .staticStretch, .dynamicStretch: return .stretching
        case .steady, .distance, .intervals, .calisthenics: return .cardio
        }
    }

    var displayName: String {
        switch self {
        case .machine: return "Machine"
        case .freeWeight: return "Free weight"
        case .bodyweight: return "Bodyweight"
        case .hold: return "Hold"
        case .staticStretch: return "Static"
        case .dynamicStretch: return "Dynamic"
        case .steady: return "Steady"
        case .distance: return "Distance"
        case .intervals: return "Intervals"
        case .calisthenics: return "Calisthenics"
        }
    }

    /// The subcategories of one category, in form order.
    static func kinds(in section: SectionType) -> [ExerciseKind] {
        allCases.filter { $0.section == section }
    }

    /// The kind a new exercise of this category starts as.
    static func defaultKind(for section: SectionType) -> ExerciseKind {
        switch section {
        case .strength: return .machine
        case .stretching: return .staticStretch
        case .cardio: return .steady
        }
    }

    /// Strength kinds whose sets can each have their own weight and reps.
    /// (Hold keeps one hold time and count for every set.)
    var supportsVaryBySet: Bool { self == .machine || self == .freeWeight || self == .bodyweight }

    /// Kinds whose workout is logged as sets of reps (and weight, if any).
    var usesSets: Bool {
        switch self {
        case .machine, .freeWeight, .bodyweight, .hold, .calisthenics: return true
        default: return false
        }
    }
}

/// How an exercise is split across sides. Sides cycle within a set; further
/// sets repeat the cycle (Left/Right, 2 reps, 1 set = L, R, L, R).
enum PerSide: String, Codable, CaseIterable, Identifiable, Sendable {
    case single
    case leftRight
    case alternating
    case forwardBack
    case rightCenterLeft
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .single: return "Single"
        case .leftRight: return "Left/Right"
        case .alternating: return "Alternating L/R"
        case .forwardBack: return "Forward/Back"
        case .rightCenterLeft: return "Right/Center/Left"
        case .custom: return "Custom…"
        }
    }

    /// The sides one cycle goes through, e.g. ["Left", "Right"]. Single and
    /// Alternating are done in one pass (alternating is within each rep).
    /// Custom has one pass labeled with the user's text.
    func sides(custom: String = "") -> [String] {
        switch self {
        case .single, .alternating: return [""]
        case .leftRight: return ["Left", "Right"]
        case .forwardBack: return ["Forward", "Back"]
        case .rightCenterLeft: return ["Right", "Center", "Left"]
        case .custom: return [custom]
        }
    }
}

/// Effort for cardio. Stored with its RPE (rate of perceived exertion).
enum Intensity: String, Codable, CaseIterable, Identifiable, Sendable {
    case easy, moderate, hard, max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .easy: return "Easy"
        case .moderate: return "Moderate"
        case .hard: return "Hard"
        case .max: return "Max"
        }
    }

    var rpe: Int {
        switch self {
        case .easy: return 3
        case .moderate: return 5
        case .hard: return 7
        case .max: return 9
        }
    }

    /// The older three-level cardio intensity, as stored before the new
    /// structure: low → Easy, moderate → Moderate, high → Hard.
    init(legacy: CardioIntensity) {
        switch legacy {
        case .low: self = .easy
        case .moderate: self = .moderate
        case .high: self = .hard
        }
    }
}

/// The implement for a free-weight exercise (optional).
enum Implement: String, Codable, CaseIterable, Identifiable, Sendable {
    case barbell, dumbbell, kettlebell, band, plate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .barbell: return "Barbell"
        case .dumbbell: return "Dumbbell"
        case .kettlebell: return "Kettlebell"
        case .band: return "Band"
        case .plate: return "Plate"
        }
    }
}

/// Ranges for the shared Number pick list.
enum PickRange {
    static let reps = 1...50
    static let sets = 1...10
    static let rounds = 1...20
    /// Machine and cardio setting values; anything else is Custom… text.
    static let settingValue = 1...20
}

/// Weight unit, set once in Settings. Switching changes the label only;
/// stored numbers are not converted.
enum WeightUnit: String, CaseIterable, Identifiable, Sendable {
    case lb, kg
    var id: String { rawValue }
    static let storageKey = "settings.weightUnit"

    /// The unit chosen in Settings (a label only: numbers aren't converted).
    static var current: WeightUnit {
        WeightUnit(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .lb
    }
}

/// Distance unit, set once in Settings. Label only, like WeightUnit.
enum DistanceUnit: String, CaseIterable, Identifiable, Sendable {
    case mi, km
    var id: String { rawValue }
    /// The Distance field's increment.
    var step: Double { self == .mi ? 0.25 : 0.5 }
    static let storageKey = "settings.distanceUnit"

    /// The unit chosen in Settings.
    static var current: DistanceUnit {
        DistanceUnit(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .mi
    }
}

/// Planned sets for a per-side exercise: sides cycle within each set, so
/// Left/Right with 2 sets is Set 1 Left, Set 1 Right, Set 2 Left, Set 2 Right.
enum SidePlan {
    static func expand(_ planned: [(reps: Int, weight: Double)], sides: [String])
        -> [(reps: Int, weight: Double, side: String)] {
        let labels = sides.isEmpty ? [""] : sides
        return planned.flatMap { p in labels.map { (p.reps, p.weight, $0) } }
    }
}

/// One line for a list of sets that may vary ("Vary by set"):
/// "3 sets · 90–110 lb × 6–10". Same values throughout collapse to one
/// number ("3 sets · 90 lb × 10"); a zero weight is left out.
enum SetRangeText {
    static func text(_ sets: [(reps: Int, weight: Double)], unit: String, addedWeight: Bool = false) -> String {
        guard !sets.isEmpty else { return "No sets" }
        func num(_ v: Double) -> String { v.rounded() == v ? String(Int(v)) : String(v) }
        func range<T: Comparable>(_ values: [T], _ show: (T) -> String) -> String {
            let lo = values.min()!, hi = values.max()!
            return lo == hi ? show(lo) : "\(show(lo))–\(show(hi))"
        }
        var line = "\(sets.count) set\(sets.count == 1 ? "" : "s") · "
        let weights = sets.map(\.weight)
        if weights.contains(where: { $0 > 0 }) {
            line += (addedWeight ? "+" : "") + range(weights, num) + " \(unit) × "
        }
        line += range(sets.map(\.reps)) { String($0) }
        if !weights.contains(where: { $0 > 0 }) { line += sets.allSatisfy({ $0.reps == 1 }) ? " rep" : " reps" }
        return line
    }
}
