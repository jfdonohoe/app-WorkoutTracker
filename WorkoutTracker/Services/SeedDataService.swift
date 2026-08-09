//
//  SeedDataService.swift
//  WorkoutTracker
//
//  Builds sample gym machine-only routines + a little history as DEMO data.
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
        seed()
    }

    private func hasExistingUserData() -> Bool {
        let routines = (try? context.fetchCount(
            FetchDescriptor<Routine>(predicate: #Predicate { $0.sourceRaw == "user" })
        )) ?? 0
        let sessions = (try? context.fetchCount(
            FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.sourceRaw == "user" })
        )) ?? 0
        return routines + sessions > 0
    }

    func seed() {
        let routines = RoutineRepository(context)
        let workouts = WorkoutRepository(context)

        // Single gym location.
        let gym = GymLocation(name: "Gym", source: demo)
        context.insert(gym)

        // Machines with shared settings (values 1...15 pickers).
        let legPress = makeMachine("Leg Press", location: gym,
                                   settings: [("Seat height", 5), ("Back angle", 3)])
        let chestPress = makeMachine("Chest Press", location: gym,
                                     settings: [("Seat height", 6), ("Handle position", 2)])
        let latPulldown = makeMachine("Lat Pulldown", location: gym,
                                      settings: [("Seat height", 4), ("Thigh pad", 7)])
        let seatedRow = makeMachine("Seated Row", location: gym,
                                    settings: [("Chest pad", 5), ("Seat height", 6)])
        let shoulderPress = makeMachine("Shoulder Press", location: gym,
                                        settings: [("Seat height", 8)])

        // Exercises linked to machines.
        let exLegPress = makeExercise("Leg Press", machine: legPress)
        let exChestPress = makeExercise("Chest Press", machine: chestPress)
        let exLat = makeExercise("Lat Pulldown", machine: latPulldown)
        let exRow = makeExercise("Seated Row", machine: seatedRow)
        let exShoulder = makeExercise("Shoulder Press", machine: shoulderPress)

        // ---- Routine: Gym Full Body A ----
        let routineA = routines.createRoutine(name: "Gym Full Body A", source: demo)
        if let v = routineA.activeVersion {
            v.source = demo
            let strength = routines.addSection(to: v, type: .strength)
            routines.addExercise(to: strength, exercise: exLegPress, setCount: 3, plannedWeight: 120, plannedReps: 10, restBetweenSets: 90)
            routines.addExercise(to: strength, exercise: exChestPress, setCount: 3, plannedWeight: 60, plannedReps: 10, restBetweenSets: 90)
            routines.addExercise(to: strength, exercise: exLat, setCount: 3, plannedWeight: 80, plannedReps: 10, restBetweenSets: 90)
            let cardio = routines.addSection(to: v, type: .cardio, title: "Cardio", durationMinutes: 20)
            _ = cardio
        }

        // ---- Routine: Gym Full Body B ----
        let routineB = routines.createRoutine(name: "Gym Full Body B", source: demo)
        if let v = routineB.activeVersion {
            v.source = demo
            let strength = routines.addSection(to: v, type: .strength)
            routines.addExercise(to: strength, exercise: exRow, setCount: 3, plannedWeight: 70, plannedReps: 10, restBetweenSets: 90)
            routines.addExercise(to: strength, exercise: exShoulder, setCount: 3, plannedWeight: 40, plannedReps: 10, restBetweenSets: 90)
            routines.addExercise(to: strength, exercise: exLegPress, setCount: 3, plannedWeight: 130, plannedReps: 8, restBetweenSets: 120)
            _ = routines.addSection(to: v, type: .cardio, title: "Cardio", durationMinutes: 20)
        }

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

    private func makeMachine(_ name: String, location: GymLocation, settings: [(String, Int)]) -> Machine {
        let machine = Machine(name: name, locationId: location.id, source: demo)
        context.insert(machine)
        for (i, s) in settings.enumerated() {
            let def = MachineSettingDefinition(label: s.0, order: i, numericValue: s.1, source: demo)
            def.machine = machine
            machine.settingDefinitions.append(def)
            context.insert(def)
        }
        return machine
    }

    private func makeExercise(_ name: String, machine: Machine) -> Exercise {
        let ex = Exercise(name: name, machineId: machine.id, source: demo)
        context.insert(ex)
        return ex
    }

    private func seedPastSession(_ workouts: WorkoutRepository, routine: Routine, daysAgo: Int, completeAll: Bool) {
        let when = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
        let session = workouts.startWorkout(from: routine, scheduledDate: when, now: when)
        let strengthSets = session.exercises
            .filter { $0.sectionType == .strength }
            .flatMap { $0.orderedSets }
        for (i, set) in strengthSets.enumerated() {
            if !completeAll && i >= strengthSets.count / 2 { break }
            workouts.completeSet(set, in: session,
                                 actualWeight: set.plannedWeight,
                                 actualReps: set.plannedReps,
                                 effort: .moderate,
                                 now: when)
        }
        workouts.finishWorkout(session, now: when)
    }
}
