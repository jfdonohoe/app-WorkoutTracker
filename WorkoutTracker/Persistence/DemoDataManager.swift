//
//  DemoDataManager.swift
//  WorkoutTracker
//
//  One-click demo cleanup (principles #6, #7). Demo records carry source ==
//  .seedDemo for their entire life — editing never flips the flag — so this
//  removes ALL demo-originated data, including demo records the user edited
//  during QA, while leaving every .user record untouched.
//

import Foundation
import SwiftData

@MainActor
struct DemoDataManager {
    let context: ModelContext

    init(_ context: ModelContext) { self.context = context }

    private let demoRaw = DataSource.seedDemo.rawValue

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
