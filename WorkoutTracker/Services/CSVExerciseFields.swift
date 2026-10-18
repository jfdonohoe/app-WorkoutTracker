//
//  CSVExerciseFields.swift
//  WorkoutTracker
//
//  The exercise-structure columns shared by both CSV importers. A row with a
//  `kind` describes its exercise with that kind's own fields (the same ones
//  the exercise editor shows); a row with no `kind` uses the older columns
//  and ExerciseStructureMigration picks its kind after import.
//
//  Columns (all optional apart from `kind`; blank uses the kind's default):
//      kind            machine, free_weight, bodyweight, hold, static,
//                      dynamic, steady, distance, intervals, calisthenics
//      reps, sets      reps per set (1…50) and sets (1…10)
//      per_side        single, left_right, alternating, forward_back,
//                      right_center_left, custom (+ per_side_custom text)
//      weight          free weight (per hand for dumbbells), or the machine's weight
//      implement       barbell, dumbbell, kettlebell, band, plate
//      added_weight    bodyweight: vest or belt
//      hold_seconds    hold, static
//      prop            static
//      timer_seconds   dynamic: per-side timer (blank = estimated from reps)
//      duration_min    steady
//      distance        distance, in the user's distance unit
//      work_seconds, recovery_seconds, rounds   intervals
//      effort          easy, moderate, hard, max (cardio). The older
//                      `intensity` column (low/moderate/high) is accepted too.
//
//  A filled column that the row's kind doesn't use is an error, so a value is
//  never silently dropped.
//

import Foundation
import SwiftData

@MainActor
struct CSVExerciseFields {
    var kind: ExerciseKind
    var reps = 10
    var sets = 3
    var perSide: PerSide = .single
    var perSideCustom = ""
    var weight: Double?
    var implement: Implement?
    var addedWeight: Double?
    var holdSeconds = 30
    var prop = ""
    var timerSeconds = 0
    var durationMinutes = 20
    var distance: Double?
    var workSeconds = 30
    var recoverySeconds = 30
    var rounds = 1
    var effort: Intensity = .moderate

    /// The kind's starting values, matching the exercise editor's defaults.
    init(kind: ExerciseKind) {
        self.kind = kind
        switch kind {
        case .machine, .freeWeight, .bodyweight:
            reps = 10; sets = 3; perSide = .single
        case .hold:
            holdSeconds = 30; reps = 1; sets = 3; perSide = .single
        case .staticStretch:
            holdSeconds = 30; reps = 1; sets = 1; perSide = .leftRight
        case .dynamicStretch:
            reps = 10; sets = 1; perSide = .leftRight
        case .steady:
            durationMinutes = 20; effort = .moderate
        case .distance:
            effort = .moderate
        case .intervals:
            workSeconds = 30; recoverySeconds = 30; rounds = 8; effort = .hard
        case .calisthenics:
            reps = 15; sets = 3; perSide = .single
        }
    }

    // MARK: - Which kinds use which column

    private static let setKinds: Set<ExerciseKind> = [.machine, .freeWeight, .bodyweight, .hold,
                                                      .staticStretch, .dynamicStretch, .calisthenics]
    private static let effortKinds: Set<ExerciseKind> = [.steady, .distance, .intervals]
    /// Kinds that can name a machine. Distance names one but has no settings.
    static let machineKinds: Set<ExerciseKind> = [.machine, .steady, .distance, .intervals]
    static let settingKinds: Set<ExerciseKind> = [.machine, .steady, .intervals]

    /// Columns that only exist in the current structure (not in older rows).
    private static let newColumns = ["reps", "sets", "per_side", "per_side_custom", "weight", "implement",
                                     "added_weight", "prop", "timer_seconds", "distance",
                                     "work_seconds", "recovery_seconds", "effort"]

    private static let columnKinds: [String: Set<ExerciseKind>] = {
        var map: [String: Set<ExerciseKind>] = [
            "reps": setKinds, "sets": setKinds, "per_side": setKinds, "per_side_custom": setKinds,
            "weight": [.machine, .freeWeight],
            "implement": [.freeWeight],
            "added_weight": [.bodyweight],
            "hold_seconds": [.hold, .staticStretch],
            "prop": [.staticStretch],
            "timer_seconds": [.dynamicStretch],
            "duration_min": [.steady],
            "distance": [.distance],
            "work_seconds": [.intervals], "recovery_seconds": [.intervals], "rounds": [.intervals],
            "effort": effortKinds, "intensity": effortKinds,
            "sides": [],                       // older stretching column; use per_side
            "machine": machineKinds,
            "machine_settings": settingKinds,
        ]
        for k in 1...Machine.maxSettings {
            map["setting\(k)_label"] = settingKinds
            map["setting\(k)_value"] = settingKinds
        }
        return map
    }()

    // MARK: - Parsing

    /// Parse a row's kind columns. Returns nil when `kind` is blank (an
    /// older-format row). `group` is the group being imported or the row's
    /// `group` column; the kind must belong to it. `maxSet` is how many
    /// setK_reps/setK_weight pairs the header defines; `allowsSetColumns` is
    /// true for routine rows, where those columns plan that routine's sets.
    static func parse(_ field: (String) -> String,
                      group: SectionType,
                      lineNo: Int,
                      maxSet: Int,
                      allowsSetColumns: Bool,
                      errors: inout [String]) -> CSVExerciseFields? {
        let kindStr = field("kind")
        guard !kindStr.isEmpty else {
            // An older-format row: the current-structure columns need a kind.
            for column in newColumns where !field(column).isEmpty {
                errors.append("Line \(lineNo): fill 'kind' to use '\(column)' (got \"\(field(column))\").")
            }
            return nil
        }
        guard let kind = kind(from: kindStr) else {
            errors.append("Line \(lineNo): 'kind' must be one of \(kindNames) (got \"\(kindStr)\").")
            return nil
        }
        guard kind.section == group else {
            let allowed = ExerciseKind.kinds(in: group).map(name(of:)).joined(separator: ", ")
            errors.append("Line \(lineNo): kind \"\(name(of: kind))\" isn't a \(group.rawValue) kind (use \(allowed)).")
            return nil
        }

        var f = CSVExerciseFields(kind: kind)
        let before = errors.count

        // A value in a column this kind doesn't use is a mistake, not a default.
        for (column, kinds) in columnKinds.sorted(by: { $0.key < $1.key })
        where !kinds.contains(kind) && !field(column).isEmpty {
            errors.append("Line \(lineNo): kind \"\(name(of: kind))\" doesn't use '\(column)' (got \"\(field(column))\").")
        }
        for n in stride(from: 1, through: maxSet, by: 1)
        where !field("set\(n)_reps").isEmpty || !field("set\(n)_weight").isEmpty {
            if !allowsSetColumns {
                errors.append("Line \(lineNo): a row with a kind uses reps, sets and weight, not set\(n)_reps/set\(n)_weight.")
                break
            } else if !kind.usesSets {
                errors.append("Line \(lineNo): kind \"\(name(of: kind))\" has no sets, so set\(n)_reps/set\(n)_weight must be blank.")
                break
            }
        }

        func int(_ column: String, _ range: ClosedRange<Int>, into value: inout Int) {
            let s = field(column)
            guard !s.isEmpty else { return }
            if let v = Int(s), range.contains(v) { value = v }
            else { errors.append("Line \(lineNo): '\(column)' must be a whole number from \(range.lowerBound) to \(range.upperBound) (got \"\(s)\").") }
        }
        func number(_ column: String, positive: Bool, into value: inout Double?) {
            let s = field(column)
            guard !s.isEmpty else { return }
            if let v = Double(s), positive ? v > 0 : v >= 0 { value = v }
            else { errors.append("Line \(lineNo): '\(column)' must be a number \(positive ? "> 0" : "≥ 0") (got \"\(s)\").") }
        }

        int("reps", PickRange.reps, into: &f.reps)
        int("sets", PickRange.sets, into: &f.sets)
        int("hold_seconds", 1...600, into: &f.holdSeconds)
        int("timer_seconds", 5...600, into: &f.timerSeconds)
        int("duration_min", 1...300, into: &f.durationMinutes)
        int("work_seconds", 1...600, into: &f.workSeconds)
        int("recovery_seconds", 0...600, into: &f.recoverySeconds)
        int("rounds", PickRange.rounds, into: &f.rounds)
        number("weight", positive: false, into: &f.weight)
        number("added_weight", positive: false, into: &f.addedWeight)
        number("distance", positive: true, into: &f.distance)
        f.prop = field("prop")

        let sideStr = field("per_side")
        if !sideStr.isEmpty {
            if let side = perSide(from: sideStr) { f.perSide = side }
            else { errors.append("Line \(lineNo): 'per_side' must be single, left_right, alternating, forward_back, right_center_left or custom (got \"\(sideStr)\").") }
        }
        f.perSideCustom = field("per_side_custom")
        if f.perSide == .custom && f.perSideCustom.isEmpty {
            errors.append("Line \(lineNo): per_side custom needs 'per_side_custom' text describing the sides.")
        } else if f.perSide != .custom && !f.perSideCustom.isEmpty {
            errors.append("Line \(lineNo): 'per_side_custom' is only used when per_side is custom.")
        }

        let implStr = field("implement")
        if !implStr.isEmpty {
            if let i = Implement(rawValue: implStr.lowercased()) { f.implement = i }
            else { errors.append("Line \(lineNo): 'implement' must be barbell, dumbbell, kettlebell, band or plate (got \"\(implStr)\").") }
        }

        let effortStr = field("effort"), intensityStr = field("intensity")
        if !effortStr.isEmpty && !intensityStr.isEmpty {
            errors.append("Line \(lineNo): fill 'effort' or 'intensity', not both.")
        } else if !effortStr.isEmpty {
            if let e = Intensity(rawValue: effortStr.lowercased()) { f.effort = e }
            else { errors.append("Line \(lineNo): 'effort' must be easy, moderate, hard or max (got \"\(effortStr)\").") }
        } else if !intensityStr.isEmpty {
            if let legacy = CardioIntensity(rawValue: intensityStr.lowercased()) { f.effort = Intensity(legacy: legacy) }
            else { errors.append("Line \(lineNo): 'intensity' must be low, moderate or high (got \"\(intensityStr)\"); or use 'effort'.") }
        }

        return errors.count == before ? f : nil
    }

    /// The CSV spelling of each kind, in form order.
    static func name(of kind: ExerciseKind) -> String {
        switch kind {
        case .freeWeight: return "free_weight"
        case .staticStretch: return "static"
        case .dynamicStretch: return "dynamic"
        default: return kind.rawValue
        }
    }

    private static var kindNames: String { ExerciseKind.allCases.map(name(of:)).joined(separator: ", ") }

    /// Lowercased, with spaces, hyphens, underscores and slashes removed, so
    /// "Free weight", "free_weight" and "freeWeight" all match.
    private static func squash(_ s: String) -> String {
        s.lowercased().filter { !" -_/".contains($0) }
    }

    static func kind(from raw: String) -> ExerciseKind? {
        let key = squash(raw)
        for kind in ExerciseKind.allCases
        where key == squash(name(of: kind)) || key == squash(kind.rawValue) || key == squash(kind.displayName) {
            return kind
        }
        return nil
    }

    static func perSide(from raw: String) -> PerSide? {
        let key = squash(raw)
        return PerSide.allCases.first {
            key == squash($0.rawValue) || key == squash($0.displayName.replacingOccurrences(of: "…", with: ""))
        }
    }

    // MARK: - Applying

    /// Write these fields onto a new exercise. Its machines are created by
    /// the caller; finish with `ExerciseLegacyFields.write`.
    func apply(to e: Exercise) {
        e.kind = kind
        e.defaultSectionType = kind.section
        e.reps = reps
        e.sets = sets
        e.perSide = perSide
        e.perSideCustom = perSide == .custom ? perSideCustom : ""
        e.weight = kind == .freeWeight ? weight : nil
        e.implement = kind == .freeWeight ? implement : nil
        e.addedWeight = kind == .bodyweight ? addedWeight : nil
        e.prop = kind == .staticStretch ? prop : ""
        e.distance = kind == .distance ? distance : nil
        e.holdSeconds = holdSeconds
        e.countTimerSeconds = timerSeconds
        e.durationMinutes = durationMinutes
        e.effort = effort
        e.workSeconds = workSeconds
        e.recoverySeconds = recoverySeconds
        if kind == .intervals { e.rounds = rounds }
    }

    /// The weight stored on this exercise's machine (Machine kind only).
    var machineWeight: Double? { kind == .machine ? weight : nil }

    /// Whether a new exercise of this kind gets a machine: always for Machine
    /// (named after the exercise if the row names none), and for cardio only
    /// when the row names one.
    func needsMachine(named name: String) -> Bool {
        kind == .machine || (Self.machineKinds.contains(kind) && !name.isEmpty)
    }
}
