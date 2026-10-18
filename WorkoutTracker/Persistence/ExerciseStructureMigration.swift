//
//  ExerciseStructureMigration.swift
//  WorkoutTracker
//
//  Converts exercises saved before the exercise structure (Oct 2026) — no
//  kind yet — to a kind and its fields, from the older fields:
//
//  - Strength with machines → Machine. Reps and Sets come from the primary
//    machine's default sets (first row's reps; row count); each machine's
//    weight is the first of ITS default sets. Machines all named
//    "Bodyweight" → Bodyweight. No machine → Free weight if the sets carry a
//    weight, else Bodyweight. Sets whose reps vary take the first set's reps.
//  - Stretching with a hold → Static; hold 0 (count-based) → Dynamic, keeping
//    its per-side timer. Reps = rounds; 2 sides → Left/Right.
//  - Cardio → Steady; low/moderate/high → Easy/Moderate/Hard. An exercise
//    whose notes mention intervals is reported so the user can convert it to
//    Intervals by hand.
//
//  Only library exercises change. Routines, workouts and their history are
//  not touched. Old fields are left as they were. Runs at launch and after
//  every import; an exercise that already has a kind is skipped, so it is
//  safe to repeat.
//

import Foundation
import SwiftData

@MainActor
struct ExerciseStructureMigration {
    let context: ModelContext

    init(_ context: ModelContext) { self.context = context }

    struct Result: Equatable {
        var converted = 0
        /// Cardio exercises whose notes suggest work/recovery rounds.
        var maybeIntervals: [String] = []
        /// Machines copied so each exercise has its own (see splitSharedMachines).
        var splitMachines = 0

        var changedAnything: Bool { converted > 0 || splitMachines > 0 }
    }

    /// `log: false` for demo seeding, so no user audit entry outlives the
    /// demo data it describes.
    @discardableResult
    func run(log: Bool = true) -> Result {
        // A machine belongs to one exercise; older CSV imports shared one
        // machine (by name) across exercises. Split those first.
        let split = splitSharedMachines()
        if split > 0, log {
            Audit.log(context, type: "data.migrated", entity: "Machine",
                      summary: "Gave \(split) exercise(s) their own copy of a shared machine")
        }
        let pending = (try? context.fetch(FetchDescriptor<Exercise>(
            predicate: #Predicate { $0.kindRaw == "" }))) ?? []
        guard !pending.isEmpty else { return Result(splitMachines: split) }
        let machines = Dictionary(((try? context.fetch(FetchDescriptor<Machine>())) ?? []).map { ($0.id, $0) },
                                  uniquingKeysWith: { a, _ in a })
        var result = Result(splitMachines: split)
        for exercise in pending {
            switch exercise.defaultSectionType {
            case .strength: convertStrength(exercise, machines: machines)
            case .stretching: convertStretch(exercise)
            case .cardio:
                exercise.kind = .steady
                exercise.effort = Intensity(legacy: exercise.intensity)
                if Self.mentionsIntervals(exercise.notes) { result.maybeIntervals.append(exercise.name) }
            }
            result.converted += 1
        }
        var summary = "Converted \(result.converted) exercise(s) to the new structure"
        if !result.maybeIntervals.isEmpty {
            summary += "; may be Intervals: " + result.maybeIntervals.joined(separator: ", ")
        }
        if log { Audit.log(context, type: "data.migrated", entity: "Exercise", summary: summary) }
        return result
    }

    /// Give every exercise its own machines. Where several exercises list the
    /// same machine, the oldest keeps it and each other gets a copy (name,
    /// photo, weight and settings). That exercise's default sets, current
    /// routine plans and workouts in progress move to the copy; finished
    /// workouts keep pointing at the original. Returns the copies made.
    private func splitSharedMachines() -> Int {
        let exercises = ((try? context.fetch(FetchDescriptor<Exercise>())) ?? [])
            .sorted { $0.createdAt < $1.createdAt }
        let machines = Dictionary(((try? context.fetch(FetchDescriptor<Machine>())) ?? []).map { ($0.id, $0) },
                                  uniquingKeysWith: { a, _ in a })
        var owner: [UUID: UUID] = [:]   // machine → the exercise that keeps it
        var copies = 0
        for e in exercises {
            var ids = e.machineIds
            for (i, mid) in ids.enumerated() {
                guard let original = machines[mid] else { continue }
                if owner[mid] == nil { owner[mid] = e.id; continue }
                let copy = Machine(name: original.name, locationId: original.locationId, source: e.source)
                copy.photoData = original.photoData
                copy.weight = original.weight
                context.insert(copy)
                var defMap: [UUID: UUID] = [:]
                for def in original.activeSettings {
                    let d = MachineSettingDefinition(label: def.label, order: def.order,
                                                     numericValue: def.numericValue, otherText: def.otherText,
                                                     source: e.source)
                    d.machine = copy
                    copy.settingDefinitions.append(d)
                    context.insert(d)
                    defMap[def.id] = d.id
                }
                ids[i] = copy.id
                repoint(e, from: mid, to: copy.id, settings: defMap)
                copies += 1
            }
            if ids != e.machineIds { e.machineIds = ids }
        }
        return copies
    }

    private func repoint(_ e: Exercise, from old: UUID, to new: UUID, settings: [UUID: UUID]) {
        for d in e.defaultSets where d.machineId == old { d.machineId = new }
        let eid = e.id
        for re in (try? context.fetch(FetchDescriptor<RoutineExercise>(predicate: #Predicate { $0.exerciseId == eid }))) ?? []
        where re.machineId == old {
            re.machineId = new
        }
        let optionalId: UUID? = eid
        for se in (try? context.fetch(FetchDescriptor<WorkoutSessionExercise>(predicate: #Predicate { $0.exerciseId == optionalId }))) ?? []
        where se.machineId == old {
            guard let session = se.session, !session.isLocked else { continue }   // history keeps the original
            se.machineId = new
            for s in se.machineSettings {
                if let def = s.definitionId { s.definitionId = settings[def] }
            }
        }
    }

    private func convertStrength(_ e: Exercise, machines: [UUID: Machine]) {
        // Deleted machines don't count toward Machine vs Bodyweight.
        let own = e.machineIds.compactMap { machines[$0] }.filter { $0.deletedAt == nil }
        let primary = e.effectiveDefaultSets
        if let first = primary.first {
            e.reps = max(1, first.reps)
            e.sets = max(1, primary.count)
        }
        e.perSide = .single
        // Sets that already differ (e.g. 12 then 10 reps) keep their plan:
        // the exercise varies by set instead of being flattened to set 1.
        let machineLists = own.isEmpty ? [primary] : own.map { e.defaultSets(for: $0.id) }
        // Also when machines have different set counts — a same-every-set
        // save would give every machine the first one's count.
        e.varyBySet = machineLists.contains { list in
            list.contains { $0.reps != list.first?.reps || $0.weight != list.first?.weight }
        } || Set(machineLists.map(\.count)).count > 1
        if !own.isEmpty, !own.allSatisfy({ $0.name.trimmingCharacters(in: .whitespaces).lowercased() == "bodyweight" }) {
            e.kind = .machine
            for m in own {
                let w = e.defaultSets(for: m.id).first?.weight ?? 0
                m.weight = w > 0 ? w : nil
            }
        } else if let w = primary.first?.weight, w > 0, own.isEmpty {
            e.kind = .freeWeight
            e.weight = w
        } else {
            e.kind = .bodyweight
            let w = primary.first?.weight ?? 0
            e.addedWeight = w > 0 ? w : nil
        }
    }

    private func convertStretch(_ e: Exercise) {
        e.kind = e.holdSeconds <= 1 ? .dynamicStretch : .staticStretch
        e.reps = max(1, e.rounds)
        e.sets = 1
        e.perSide = e.sides > 1 ? .leftRight : .single
    }

    static func mentionsIntervals(_ notes: String) -> Bool {
        let n = notes.lowercased()
        return n.contains("interval") || (n.contains("work") && n.contains("recover"))
    }
}

/// Writes the fields used before the exercise structure from an exercise's
/// kind and its new fields. Until routines and workouts read the new fields
/// directly, these keep them working: default sets per machine (strength),
/// hold/sides/rounds (stretches), duration/intensity (cardio).
@MainActor
enum ExerciseLegacyFields {
    /// Reps and Sets from the default machine's (or the machine-less) rows,
    /// and each machine's weight from its own set 1.
    static func syncSummaryFromRows(_ e: Exercise, machines: [Machine]) {
        let rows = e.defaultSets(for: e.machineId)
        if let first = rows.first {
            e.reps = max(1, first.reps)
            e.sets = max(1, rows.count)
            switch e.kind {
            case .freeWeight: e.weight = first.weight > 0 ? first.weight : nil
            case .bodyweight: e.addedWeight = first.weight > 0 ? first.weight : nil
            default: break
            }
        }
        for m in machines {
            let w = e.defaultSets(for: m.id).first?.weight ?? 0
            m.weight = w > 0 ? w : nil
        }
    }

    /// After a workout writes an exercise's default sets (what was actually
    /// done), carry them into the new fields: Reps from the first set, Sets
    /// from the count, and the weight onto the machine (or the exercise).
    static func readBackSets(_ e: Exercise, machineId: UUID?, context: ModelContext) {
        let rows = e.defaultSets(for: machineId)
        guard let first = rows.first else { return }
        e.reps = max(1, first.reps)
        e.sets = max(1, rows.count)
        // A workout that did different weights / reps per set leaves the
        // exercise varying, so the next editor save doesn't flatten it.
        if e.kind?.supportsVaryBySet == true,
           rows.contains(where: { $0.reps != first.reps || $0.weight != first.weight }) {
            e.varyBySet = true
        }
        switch e.kind {
        case .machine:
            if let mid = machineId,
               let m = try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == mid })).first {
                m.weight = first.weight > 0 ? first.weight : nil
            }
        case .freeWeight: e.weight = first.weight > 0 ? first.weight : nil
        case .bodyweight: e.addedWeight = first.weight > 0 ? first.weight : nil
        default: break
        }
    }

    static func write(_ e: Exercise, machines: [Machine], context: ModelContext) {
        guard let kind = e.kind else { return }
        e.defaultSectionType = kind.section
        // Vary by set: the per-set rows ARE the plan — keep them, and only
        // keep Reps / Sets / weight in step with set 1 for summaries.
        if e.varyBySet && kind.supportsVaryBySet {
            syncSummaryFromRows(e, machines: machines)
            return
        }
        for d in e.defaultSets { context.delete(d) }
        e.defaultSets = []
        func addSets(weight: Double, machineId: UUID?) {
            for i in 0..<max(1, e.sets) {
                let d = ExerciseDefaultSet(order: i, reps: max(1, e.reps), weight: weight, machineId: machineId)
                d.exercise = e
                e.defaultSets.append(d)
                context.insert(d)
            }
        }
        switch kind {
        case .machine:
            for m in machines { addSets(weight: m.weight ?? 0, machineId: m.id) }
        case .freeWeight: addSets(weight: e.weight ?? 0, machineId: nil)
        case .bodyweight: addSets(weight: e.addedWeight ?? 0, machineId: nil)
        case .hold, .calisthenics: addSets(weight: 0, machineId: nil)
        case .staticStretch, .dynamicStretch:
            if kind == .dynamicStretch { e.holdSeconds = 0 }
            e.sides = e.perSide.sides(custom: e.perSideCustom).count
            // Further sets repeat the side cycle.
            e.rounds = max(1, e.reps) * max(1, e.sets)
        case .steady, .distance, .intervals:
            switch e.effort {
            case .easy: e.intensity = .low
            case .moderate: e.intensity = .moderate
            case .hard, .max: e.intensity = .high
            }
            if kind == .intervals {
                let seconds = max(1, e.rounds) * (e.workSeconds + e.recoverySeconds)
                e.durationMinutes = max(1, Int((Double(seconds) / 60).rounded(.up)))
            }
        }
    }
}
