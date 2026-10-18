//
//  SeedDataService.swift
//  WorkoutTracker
//
//  Seeds DEMO data: the machines, exercises and routines in
//  Resources/DemoData.json, plus schedules and a little history.
//  Everything created here is source == .seedDemo so it stays traceable for the
//  one-click "Delete Demo Data" feature, even after the user edits it.
//
//  Demo data policy, reconciled on every app launch via `reconcileDemoData()`:
//    - Before the user has any data of their own, demo data is kept present
//      by default — it's reseeded automatically if missing — UNLESS the user
//      explicitly deleted it via "Delete Demo Data", in which case it stays
//      gone until they explicitly reseed.
//    - The moment the user's own data first appears, demo data is deleted
//      automatically and this graduation is permanent: from then on demo data
//      never reappears on its own, no matter what happens to user data later.
//      The only way to bring it back after that is the explicit "Re-seed
//      demo data" action in Settings, which calls `seed()` directly.
//

import Foundation
import SwiftData

@MainActor
struct SeedDataService {
    let context: ModelContext

    init(_ context: ModelContext) { self.context = context }

    private let demo: DataSource = .seedDemo

    /// Permanent once set: the user has real data, so demo data must never
    /// automatically reappear again.
    static let hasGraduatedFromDemoKey = "com.workouttracker.hasGraduatedFromDemo"
    /// Set when the user explicitly deletes demo data (pre-graduation), so it
    /// isn't silently reseeded again on the next launch. Cleared whenever
    /// fresh demo data is seeded.
    static let userDeletedDemoKey = "com.workouttracker.userDeletedDemoManually"
    /// The user switched off "Add demo data on launch" (Settings › Demo Data).
    /// When set, launch never seeds demo data. Lives in UserDefaults, so it
    /// survives app updates and new builds installed over the app (it resets
    /// only if the app is deleted from the device).
    static let autoSeedDisabledKey = "com.workouttracker.demoAutoSeedDisabled"

    /// Call on every app launch to reconcile demo data against the rules
    /// above. Cheap to call repeatedly: once graduated, it's a single
    /// UserDefaults read and returns immediately.
    func reconcileDemoData() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.hasGraduatedFromDemoKey) else { return }

        if hasExistingUserData() {
            defaults.set(true, forKey: Self.hasGraduatedFromDemoKey)
            if DemoDataManager(context).hasDemoData() {
                DemoDataManager(context).deleteAllDemoData()
                try? context.save()
            }
            return
        }

        guard !DemoDataManager(context).hasDemoData() else { return }
        guard !defaults.bool(forKey: Self.userDeletedDemoKey) else { return }
        guard !defaults.bool(forKey: Self.autoSeedDisabledKey) else { return }
        seed()
    }

    /// Deleted records don't count: a routine the user deleted (or a workout
    /// they discarded) isn't data of their own, so it mustn't clear the demo.
    func hasExistingUserData() -> Bool {
        let routines = (try? context.fetchCount(
            FetchDescriptor<Routine>(predicate: #Predicate { $0.sourceRaw == "user" && $0.deletedAt == nil })
        )) ?? 0
        let sessions = (try? context.fetchCount(
            FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.sourceRaw == "user" && $0.deletedAt == nil })
        )) ?? 0
        return routines + sessions > 0
    }

    func seed() {
        let workouts = WorkoutRepository(context)

        // Machines, exercises and routines come from Resources/DemoData.json:
        // the latest exercise and active routine definitions taken from a real
        // backup (sources already set to seedDemo).
        guard let doc = Self.loadDemoDefinitions() else { return }
        _ = ExportImportService(context).restore(doc, logImport: false)
        let seeded = (try? context.fetch(FetchDescriptor<Routine>())) ?? []
        let routines = doc.routines
            .sorted { $0.name < $1.name }
            .compactMap { r in seeded.first { $0.id == r.id } }
        guard routines.count >= 2 else { try? context.save(); return }
        let routineA = routines[0], routineB = routines[1]

        // ---- Schedules: A on Monday, B on Thursday, weekly ----
        let cal = Calendar.current
        let monday = 2, thursday = 5 // Calendar weekday ints (1=Sun)
        let anchor = cal.date(byAdding: .day, value: -30, to: .now) ?? .now
        let schedA = ScheduleRule(routineId: routineA.id, freq: .weekly, interval: 1,
                                  weekdays: [monday], startDate: anchor, source: demo)
        let schedB = ScheduleRule(routineId: routineB.id, freq: .weekly, interval: 1,
                                  weekdays: [thursday], startDate: anchor, source: demo)
        context.insert(schedA)
        context.insert(schedB)

        // ---- A couple of completed past sessions for the history/calendar ----
        seedPastSession(workouts, routine: routineA, daysAgo: 7, completeAll: true)
        seedPastSession(workouts, routine: routineB, daysAgo: 4, completeAll: false) // partial

        try? context.save()
        UserDefaults.standard.set(false, forKey: Self.userDeletedDemoKey)
    }

    // MARK: - Builders

    /// Decodes the bundled demo definitions with every UUID replaced by a fresh
    /// one (consistently, so references still line up). Without this, demo
    /// records would share ids with the user's real backup they came from, and
    /// restoring that backup later would skip those records as "already exists".
    static func loadDemoDefinitions(bundle: Bundle = .main) -> BackupDocument? {
        guard let url = bundle.url(forResource: "DemoData", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let original = String(data: data, encoding: .utf8)
        else { return nil }
        let uuid = #/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/#
        var fresh: [String: String] = [:]
        let json = original.replacing(uuid) { match in
            let old = String(original[match.range]).uppercased()
            if let id = fresh[old] { return id }
            let id = UUID().uuidString
            fresh[old] = id
            return id
        }
        return try? ExportImportService.decodeBackup(Data(json.utf8))
    }

    private func seedPastSession(_ workouts: WorkoutRepository, routine: Routine, daysAgo: Int, completeAll: Bool) {
        let when = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
        let session = workouts.startWorkout(from: routine, scheduledDate: when, now: when)
        let strengthSets = session.exercises
            .filter { $0.sectionType == .strength }
            .flatMap { $0.orderedSets }
        for (i, set) in strengthSets.enumerated() {
            // A partial workout still needs one set done, or it is discarded.
            if !completeAll && i >= max(1, strengthSets.count / 2) { break }
            workouts.completeSet(set, in: session,
                                 actualWeight: set.plannedWeight,
                                 actualReps: set.plannedReps,
                                 effort: .moderate,
                                 now: when)
        }
        workouts.finishWorkout(session, now: when)
    }
}
