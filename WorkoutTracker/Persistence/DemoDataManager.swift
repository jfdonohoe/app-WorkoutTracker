//
//  DemoDataManager.swift
//  WorkoutTracker
//
//  One-click demo cleanup (principles #6, #7). Demo records carry source ==
//  .seedDemo for their entire life — editing never flips the flag — so this
//  removes ALL demo-originated data, including demo records the user edited
//  during QA, while leaving every .user record untouched.
//
//  One exception: a REAL workout the user did on a demo routine. It is
//  tagged demo (sessions take their routine's source), but it is locked
//  history, so it becomes the user's and is kept. A seeded demo workout is
//  told apart by its timestamps: SeedDataService starts, logs and finishes it
//  at one instant, so its start and end times are equal; a real one's never are.
//

import Foundation
import SwiftData

@MainActor
struct DemoDataManager {
    let context: ModelContext

    init(_ context: ModelContext) { self.context = context }


    /// True if any demo data currently exists.
    func hasDemoData() -> Bool {
        let d = FetchDescriptor<Routine>(predicate: #Predicate { $0.sourceRaw == "seedDemo" })
        let routines = (try? context.fetchCount(d)) ?? 0
        let sd = FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.sourceRaw == "seedDemo" })
        let sessions = (try? context.fetchCount(sd)) ?? 0
        return routines + sessions > 0
    }

    /// Delete every demo-originated top-level record. Child records (sections,
    /// exercises, sets, machine settings, corrections) are removed via cascade
    /// delete rules on their parents.
    @discardableResult
    func deleteAllDemoData() -> Int {
        keepRealWorkouts()
        var deleted = 0
        deleted += deleteDemo(WorkoutSession.self)
        deleted += deleteDemo(Routine.self)
        deleted += deleteDemo(Exercise.self)
        deleted += deleteDemo(Machine.self)
        deleted += deleteDemo(GymLocation.self)
        deleted += deleteDemo(ScheduleRule.self)
        // Any stray demo correction/audit events not covered by cascade.
        deleted += deleteDemo(WorkoutCorrectionEvent.self)
        deleted += deleteDemo(AuditEvent.self)

        Audit.log(context, type: "demo.deleted", entity: "*",
                  summary: "Deleted \(deleted) demo top-level records", source: .user)
        UserDefaults.standard.set(true, forKey: SeedDataService.userDeletedDemoKey)
        return deleted
    }

    /// Make real workouts done on demo routines the user's own (with their
    /// corrections and audit events), so the cleanup below leaves them: locked ones with real
    /// work, and every unfinished one — the seed only makes finished workouts,
    /// so an unfinished one is the user's, possibly open on screen right now
    /// (one with nothing done is still discarded by the launch purge).
    /// Returns how many.
    @discardableResult
    func keepRealWorkouts() -> Int {
        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.sourceRaw == "seedDemo" && $0.deletedAt == nil }))) ?? []
        var kept = 0
        let corrections = (try? context.fetch(FetchDescriptor<WorkoutCorrectionEvent>())) ?? []
        let audits = (try? context.fetch(FetchDescriptor<AuditEvent>(
            predicate: #Predicate { $0.sourceRaw == "seedDemo" }))) ?? []
        for s in sessions where Self.isRealLockedWorkout(s) || !s.isLocked {
            s.source = .user
            // By id as well: a restored correction can lack the relationship.
            for c in corrections where c.workoutSessionId == s.id { c.source = .user }
            // Its audit trail (started, finished, …) is logged with the
            // workout's demo source; it goes with the workout, not the demo.
            // A correction's audit is keyed by the set or exercise corrected.
            var ids: Set<UUID> = [s.id]
            for ex in s.exercises { ids.insert(ex.id); ids.formUnion(ex.sets.map(\.id)) }
            for c in corrections where c.workoutSessionId == s.id { if let t = c.targetEntityId { ids.insert(t) } }
            for a in audits where a.entityId.map(ids.contains) == true { a.source = .user }
            kept += 1
        }
        if kept > 0 {
            Audit.log(context, type: "demo.keptWorkouts", entity: "WorkoutSession",
                      summary: "Kept \(kept) workout(s) done on demo routines as your own", source: .user)
        }
        return kept
    }

    /// Seeded workouts always have both times, equal; anything else with
    /// work done is real (including one missing a time).
    static func isRealLockedWorkout(_ s: WorkoutSession) -> Bool {
        guard s.isLocked, s.hasAnythingDone else { return false }
        if let start = s.startedAt, let end = s.endedAt { return end != start }
        return true
    }

    /// Generic helper: delete all instances of a model whose source is demo.
    /// Uses a string raw filter so it works across every model uniformly.
    private func deleteDemo<T: PersistentModel>(_ type: T.Type) -> Int {
        // Fetch all and filter in memory on `sourceRaw` via reflection-free
        // protocol. We instead fetch all and check a known accessor.
        let all = (try? context.fetch(FetchDescriptor<T>())) ?? []
        var count = 0
        for object in all where Self.isDemo(object) {
            context.delete(object)
            count += 1
        }
        return count
    }

    /// Centralized "is this a demo record?" check.
    private static func isDemo(_ object: Any) -> Bool {
        switch object {
        case let x as Routine: return x.source == .seedDemo
        case let x as WorkoutSession: return x.source == .seedDemo
        case let x as Exercise: return x.source == .seedDemo
        case let x as Machine: return x.source == .seedDemo
        case let x as GymLocation: return x.source == .seedDemo
        case let x as ScheduleRule: return x.source == .seedDemo
        case let x as WorkoutCorrectionEvent: return x.source == .seedDemo
        case let x as AuditEvent: return x.source == .seedDemo
        default: return false
        }
    }
}
