//
//  CorrectionService.swift
//  WorkoutTracker
//
//  Past workouts are read-only. The ONLY way to "fix" a recorded value is to
//  append a WorkoutCorrectionEvent (principle #5). Original snapshot fields are
//  never overwritten; the corrected view is computed by layering the latest
//  correction per (entity id, field) on top of the original.
//

import Foundation
import SwiftData

@MainActor
struct CorrectionService {
    let context: ModelContext

    init(_ context: ModelContext) { self.context = context }

    /// Append a correction. Allowed even on locked sessions — that's the point.
    @discardableResult
    func correct(session: WorkoutSession,
                 targetEntity: String,
                 targetEntityId: UUID?,
                 field: String,
                 previousValue: String,
                 correctedValue: String,
                 note: String? = nil) -> WorkoutCorrectionEvent {
        let event = WorkoutCorrectionEvent(workoutSessionId: session.id,
                                           targetEntity: targetEntity,
                                           targetEntityId: targetEntityId,
                                           field: field,
                                           previousValue: previousValue,
                                           correctedValue: correctedValue,
                                           note: note,
                                           source: session.source)
        event.session = session
        session.corrections.append(event)
        context.insert(event)
        Audit.log(context, type: "session.corrected", entity: targetEntity,
                  entityId: targetEntityId,
                  summary: "Corrected \(field): \(previousValue) → \(correctedValue)",
                  source: session.source)
        return event
    }

    /// Convenience: correct a set's actual weight.
    func correctActualWeight(_ set: WorkoutSessionSet, in session: WorkoutSession, to newValue: Double, note: String? = nil) {
        correct(session: session,
                targetEntity: "WorkoutSessionSet",
                targetEntityId: set.id,
                field: "actualWeight",
                previousValue: Self.string(set.actualWeight),
                correctedValue: String(newValue),
                note: note)
    }

    func correctActualReps(_ set: WorkoutSessionSet, in session: WorkoutSession, to newValue: Int, note: String? = nil) {
        correct(session: session,
                targetEntity: "WorkoutSessionSet",
                targetEntityId: set.id,
                field: "actualReps",
                previousValue: Self.string(set.actualReps),
                correctedValue: String(newValue),
                note: note)
    }

    private static func string(_ value: Double?) -> String { value.map { String($0) } ?? "" }
    private static func string(_ value: Int?) -> String { value.map { String($0) } ?? "" }
}

/// Read-side resolver that applies corrections on top of original snapshots.
/// Pure functions over a session's `corrections` array — never mutates storage.
enum CorrectedView {
    static func latest(_ session: WorkoutSession, entityId: UUID?, field: String) -> WorkoutCorrectionEvent? {
        session.corrections
            .filter { $0.targetEntityId == entityId && $0.field == field }
            .max(by: { $0.createdAt < $1.createdAt })
    }

    static func effectiveActualWeight(_ set: WorkoutSessionSet, in session: WorkoutSession) -> Double? {
        if let c = latest(session, entityId: set.id, field: "actualWeight"), let v = Double(c.correctedValue) {
            return v
        }
        return set.actualWeight
    }

    static func effectiveActualReps(_ set: WorkoutSessionSet, in session: WorkoutSession) -> Int? {
        if let c = latest(session, entityId: set.id, field: "actualReps"), let v = Int(c.correctedValue) {
            return v
        }
        return set.actualReps
    }

    /// Whether a given set/field has a correction layered on top.
    static func isCorrected(_ set: WorkoutSessionSet, field: String, in session: WorkoutSession) -> Bool {
        latest(session, entityId: set.id, field: field) != nil
    }
}

extension RoutineRepository {
    /// Apply a single-field change as a FUTURE default by creating a new routine
    /// version and editing only the matching exercise. Past sessions keep the
    /// old version (principles #2, #3, #7). Only the changed value differs in the
    /// new version; everything else is an exact copy.
    func updateFutureDefault(routine: Routine,
                             sourceRoutineExerciseId: UUID,
                             apply change: (RoutineExercise) -> Void) {
        guard let active = routine.activeVersion else { return }
        // Capture the position of the target exercise in the current version.
        var sectionOrder: Int?
        var exerciseOrder: Int?
        for section in active.sections {
            if let ex = section.exercises.first(where: { $0.id == sourceRoutineExerciseId }) {
                sectionOrder = section.order
                exerciseOrder = ex.order
                break
            }
        }
        guard let so = sectionOrder, let eo = exerciseOrder else { return }

        let newVersion = makeNewVersion(of: routine, note: "Saved change from a workout")
        if let ns = newVersion.sections.first(where: { $0.order == so }),
           let ne = ns.exercises.first(where: { $0.order == eo }) {
            change(ne)
        }
    }
}
