//
//  DataIntegrityService.swift
//  WorkoutTracker
//
//  Read-only verification of the data-safety invariants, powering the
//  "Data Safety Check" screen. Its problems can only arrive with imported
//  data, so it runs as part of Import / Export (ImportExportView), not on
//  its own. It never mutates data — it only reports, and
//  for each failure lists the records involved and the fixes that apply.
//  DataSafetyRepair (below) carries the fixes out.
//

import Foundation
import SwiftData

struct IntegrityCheck: Identifiable {
    /// `.action` failures need the user and count toward the badge; `.info`
    /// failures are worth knowing but need nothing done.
    enum Severity { case action, info }

    let id = UUID()
    let title: String
    /// What the check protects and why, shown from the check's info button
    /// whether or not it passes.
    let purpose: String
    let passed: Bool
    let detail: String
    var severity: Severity = .action
    /// What the user can do about a failure, in plain words.
    var guidance: String? = nil
    /// True when the app can repair every failure here without a decision
    /// (DataSafetyRepair.autoRepair). The screen shows a single Fix button.
    var autoFixable: Bool = false
    /// The records involved, each with the fixes that apply to it.
    var issues: [IntegrityIssue] = []

    var needsAttention: Bool { !passed && severity == .action }
}

/// One record behind a failing check.
struct IntegrityIssue: Identifiable {
    let id: String
    let title: String
    let detail: String
    var fixes: [IntegrityFix] = []
}

/// A repair the user can choose for one record. See DataSafetyRepair.apply.
enum IntegrityFix: Hashable {
    case deleteWorkout(UUID)
    case finishWorkout(UUID)
    case resumeWorkout(UUID)
    case setStartTime(UUID)
    case restoreExercise(UUID)
    case removeExerciseEverywhere(UUID)
    case restoreMachine(UUID)
    case removeMachineEverywhere(UUID)
    case deleteRoutine(UUID)

    var label: String {
        switch self {
        case .deleteWorkout:            return "Delete Workout"
        case .finishWorkout:            return "Finish Workout"
        case .resumeWorkout:            return "Resume Workout"
        case .setStartTime:             return "Use Created Time"
        case .restoreExercise:          return "Restore to Library"
        case .removeExerciseEverywhere: return "Remove from Routines"
        case .restoreMachine:           return "Restore Machine"
        case .removeMachineEverywhere:  return "Remove Machine"
        case .deleteRoutine:            return "Delete Routine"
        }
    }

    /// Fixes that delete or remove something ask for confirmation first.
    var isDestructive: Bool {
        switch self {
        case .deleteWorkout, .removeExerciseEverywhere, .removeMachineEverywhere, .deleteRoutine: return true
        default: return false
        }
    }
}

@MainActor
struct DataIntegrityService {
    let context: ModelContext

    init(_ context: ModelContext) { self.context = context }

    func runAll() -> [IntegrityCheck] {
        var checks: [IntegrityCheck] = []
        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        let versions = (try? context.fetch(FetchDescriptor<RoutineVersion>())) ?? []
        let versionIds = Set(versions.map(\.id))
        let allRoutines = fetchAll(Routine.self)
        let allExercises = fetchAll(Exercise.self)
        let allMachines = fetchAll(Machine.self)
        let audits = fetchAll(AuditEvent.self)
        /// Every session.finished time per session. A session finished more
        /// than once was reopened in between.
        var finishTimes: [UUID: [Date]] = [:]
        for a in audits where a.type == "session.finished" {
            if let id = a.entityId { finishTimes[id, default: []].append(a.timestamp) }
        }

        // 1. Recorded sessions are locked. "Recorded" means FINISHED: status
        //    alone is not enough, because a workout in progress becomes
        //    .partial as soon as one set is done (WorkoutRepository
        //    .recomputeStatus) and is rightly unlocked until it is finished.
        //    finishWorkout sets completedAt with the lock; Resume cleared both
        //    on workouts reopened before Oct 2026 (locked ones no longer reopen).
        let recorded = sessions.filter { $0.completedAt != nil }
        let unlocked = recorded.filter { !$0.isLocked }
        checks.append(.init(
            title: "Recorded sessions are locked",
            purpose: "Once you finish a workout it is locked, so nothing (an edit, a routine change, an import) can alter your history. This check confirms every finished workout is locked.",
            passed: unlocked.isEmpty,
            detail: unlocked.isEmpty ? "\(recorded.count) recorded session(s), all locked."
                                     : "\(unlocked.count) recorded session(s) are NOT locked.",
            guidance: "Finished workouts should never change. Fix locks them as they are.",
            autoFixable: true,
            issues: unlocked.map { Self.workoutIssue($0, "Finished but not locked") }))

        // 2. Recorded sessions carry snapshot data (their own exercises/sets).
        let missingSnapshots = recorded.filter { $0.deletedAt == nil && $0.exercises.isEmpty }
        checks.append(.init(
            title: "Recorded sessions have snapshot data",
            purpose: "Each workout keeps its own copy of the exercises and sets you did, so your history stays the same when you edit a routine later. This check confirms every finished workout still has that copy.",
            passed: missingSnapshots.isEmpty,
            detail: missingSnapshots.isEmpty ? "All recorded sessions contain snapshot exercises."
                                             : "\(missingSnapshots.count) session(s) have no snapshot exercises.",
            guidance: "These finished workouts have no exercises, so there is nothing to show. Delete them, or restore a backup that still has them.",
            issues: missingSnapshots.map { Self.workoutIssue($0, "No exercises", fixes: [.deleteWorkout($0.id)]) }))

        // 3. Sessions reference a routine version that still exists. Info
        //    only: history is drawn from each session's own snapshot.
        let danglingRefs = sessions.filter { s in
            if let vid = s.routineVersionId { return !versionIds.contains(vid) }
            return false
        }
        checks.append(.init(
            title: "Session → routine version references are valid",
            purpose: "Every workout remembers which version of its routine it came from. This check confirms those versions still exist. It is a note only: history is shown from each workout's own copy and doesn't depend on them.",
            passed: danglingRefs.isEmpty,
            detail: danglingRefs.isEmpty ? "All session version references resolve."
                                         : "\(danglingRefs.count) session(s) reference a missing version.",
            severity: .info,
            guidance: "Nothing to do. Each workout keeps its own copy of the plan, so history still shows correctly."))

        // 4. Snapshot sets keep planned values (immutable snapshot stable).
        //    Fetched by predicate so only the bad sets are loaded.
        let badPlanned = ((try? context.fetch(FetchDescriptor<WorkoutSessionSet>(
            predicate: #Predicate { $0.plannedReps < 0 || $0.plannedWeight < 0 }))) ?? [])
            .filter { $0.exercise?.session?.completedAt != nil }
        var seenBad = Set<UUID>()
        let badPlannedSessions = badPlanned.compactMap { $0.exercise?.session }
            .filter { seenBad.insert($0.id).inserted }
        checks.append(.init(
            title: "Snapshot sets have valid planned values",
            purpose: "Each set in a past workout records what was planned: reps and weight. This check looks for impossible values, such as a negative weight, that would mean the record was damaged.",
            passed: badPlanned.isEmpty,
            detail: badPlanned.isEmpty ? "Planned snapshot values look intact."
                                       : "\(badPlanned.count) snapshot set(s) have invalid planned values.",
            guidance: "The app can't rebuild these values. If you have a backup from before the problem, restore it.",
            issues: badPlannedSessions.map { Self.workoutIssue($0, "Negative planned reps or weight") }))

        // 5. Corrections are append-only and preserve originals. A correction
        //    is layered on top of a recorded value, never written into it
        //    (CorrectionService), so every correction must point at a session
        //    and set that still exist, and its previousValue must still equal
        //    the value stored on the set. A mismatch means the original was
        //    overwritten or the correction was detached from what it corrects.
        //    The value comparison only applies while the session has stayed
        //    locked since the correction: a workout reopened before Oct 2026
        //    (when Resume still unlocked it) may legitimately have re-logged the set.
        let corrections = (try? context.fetch(FetchDescriptor<WorkoutCorrectionEvent>())) ?? []
        let sessionsById = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var malformed = 0, orphaned = 0, overwritten = 0
        var correctionIssues: [IntegrityIssue] = []
        for c in corrections {
            let session = sessionsById[c.workoutSessionId]
            let title = session.map(Self.workoutTitle) ?? "Missing workout"
            guard !c.field.isEmpty, !c.targetEntity.isEmpty else {
                malformed += 1
                correctionIssues.append(.init(id: c.id.uuidString, title: title, detail: "Correction is missing what it changes"))
                continue
            }
            guard let session else {
                orphaned += 1
                correctionIssues.append(.init(id: c.id.uuidString, title: title, detail: "Correction to \(c.field) points at a deleted workout"))
                continue
            }
            guard c.targetEntity == "WorkoutSessionSet" else { continue }
            guard let set = session.exercises.flatMap(\.sets).first(where: { $0.id == c.targetEntityId }) else {
                orphaned += 1
                correctionIssues.append(.init(id: c.id.uuidString, title: title, detail: "Correction to \(c.field) points at a deleted set"))
                continue
            }
            let reopenedSince = (finishTimes[session.id] ?? []).contains { $0 > c.createdAt }
            guard session.isLocked, !reopenedSince else { continue }
            if !Self.matchesStoredValue(c.previousValue, field: c.field, on: set) {
                overwritten += 1
                correctionIssues.append(.init(id: c.id.uuidString, title: title,
                    detail: "\(c.field): original was \(c.previousValue.isEmpty ? "blank" : c.previousValue), now \(Self.storedValue(c.field, on: set))"))
            }
        }
        let correctionProblems = malformed + orphaned + overwritten
        checks.append(.init(
            title: "Corrections preserve originals",
            purpose: "Correcting a past workout never overwrites it. The change is stored alongside the original value. This check confirms every original is still intact and every correction still points at its workout and set.",
            passed: correctionProblems == 0,
            detail: correctionProblems == 0
                ? "\(corrections.count) correction event(s); every original value is intact."
                : "\(corrections.count) correction event(s): \(malformed) malformed, \(orphaned) point at a missing session or set, \(overwritten) original value(s) overwritten.",
            guidance: "Past workouts are never edited directly, so the app won't change these values. The original is shown for each one; restore a backup from before the change if you need it back.",
            issues: correctionIssues))

        // 6. Demo separation. Every record that carries a source marker must
        //    hold a known value, and records that inherit lineage must match
        //    their parent — a routine version shares its routine's source and
        //    a correction shares its session's — or deleting demo data would
        //    take user records with it (or leave demo records behind).
        var unknownSources = 0
        func tally(_ raws: [String]) { unknownSources += raws.filter { DataSource(rawValue: $0) == nil }.count }
        tally(sessions.map(\.sourceRaw))
        tally(versions.map(\.sourceRaw))
        tally(corrections.map(\.sourceRaw))
        tally(allRoutines.map(\.sourceRaw))
        tally(allExercises.map(\.sourceRaw))
        tally(allMachines.map(\.sourceRaw))
        tally(fetchAll(MachineSettingDefinition.self).map(\.sourceRaw))
        tally(fetchAll(GymLocation.self).map(\.sourceRaw))
        tally(fetchAll(ScheduleRule.self).map(\.sourceRaw))
        tally(audits.map(\.sourceRaw))
        let mixedVersions = versions.filter { v in v.routine.map { $0.sourceRaw != v.sourceRaw } ?? false }.count
        let mixedCorrections = corrections.filter { c in sessionsById[c.workoutSessionId].map { $0.sourceRaw != c.sourceRaw } ?? false }.count
        let sourceProblems = unknownSources + mixedVersions + mixedCorrections
        checks.append(.init(
            title: "Demo/user source markers are intact",
            purpose: "Every record is tagged as yours or as demo data, and Delete Demo Data relies on those tags. This check makes sure none are missing or mismatched, so deleting demo data can never remove your own data.",
            passed: sourceProblems == 0,
            detail: sourceProblems == 0
                ? "Every record is tagged user/seedDemo, and versions and corrections match their parent."
                : "\(unknownSources) record(s) have an unknown source marker; \(mixedVersions) version(s) and \(mixedCorrections) correction(s) differ from their parent's source.",
            guidance: "This decides what Delete Demo Data removes. Fix marks unknown records as yours and matches versions and corrections to their parent. Fix this before deleting demo data.",
            autoFixable: true))

        // 7. Routines and workouts in progress use only library exercises.
        //    Deleting an exercise from the library removes it everywhere it is
        //    still planned (RoutineRepository.removeExerciseFromAllRoutines);
        //    anything left over predates that cascade, came from a restore, or
        //    was a demo exercise removed by Delete Demo Data (cleared at the
        //    next launch by CatalogSyncService.pruneExercisesMissingFromLibrary).
        //    Finished workouts keep their exercises as history.
        let routines = allRoutines.filter { $0.deletedAt == nil }
        let liveExercises = allExercises.filter { $0.deletedAt == nil }
        let liveExerciseIds = Set(liveExercises.map(\.id))
        let exercisesById = Dictionary(allExercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let activeVersions = routines.compactMap(\.activeVersion)
        let plannedExercises = activeVersions.flatMap(\.sections).flatMap(\.exercises)
        let inProgress = sessions.filter { $0.deletedAt == nil && $0.completedAt == nil }
        let openExercises = inProgress.filter { !$0.isLocked }.flatMap(\.exercises)
        let routinesOutsideLibrary = Set(activeVersions.filter { v in
            v.sections.flatMap(\.exercises).contains { !liveExerciseIds.contains($0.exerciseId) }
        }.map(\.id)).count
        // Logged work keeps an exercise in its workout (see below), so like
        // the issue list, the count leaves those out.
        let workoutsOutsideLibrary = Set(openExercises.filter { se in
            !se.hasWorkDone && (se.exerciseId.map { !liveExerciseIds.contains($0) } ?? false)   // nil = ad hoc
        }.compactMap { $0.session?.id }).count
        // One issue per missing exercise, naming where it is still used.
        var usedIn: [UUID: (name: String, routines: Set<String>, workouts: Int)] = [:]
        for re in plannedExercises where !liveExerciseIds.contains(re.exerciseId) {
            var entry = usedIn[re.exerciseId] ?? (re.displayName, [], 0)
            if let name = re.section?.version?.routine?.name { entry.routines.insert(name) }
            usedIn[re.exerciseId] = entry
        }
        // An exercise with work logged in an unfinished workout stays there
        // (the removal keeps logged work), so it isn't a problem to fix.
        for se in openExercises where !se.hasWorkDone {
            guard let id = se.exerciseId, !liveExerciseIds.contains(id) else { continue }
            var entry = usedIn[id] ?? (se.name, [], 0)
            entry.workouts += 1
            usedIn[id] = entry
        }
        let libraryIssues = usedIn.sorted { $0.value.name < $1.value.name }.map { id, use in
            let canRestore = exercisesById[id] != nil   // soft-deleted, so it can come back
            var places = use.routines.sorted()
            if use.workouts > 0 { places.append("workout in progress") }
            return IntegrityIssue(id: id.uuidString, title: exercisesById[id]?.name ?? use.name,
                                  detail: (canRestore ? "Deleted from the library; still in " : "Missing from the library; still in ")
                                      + places.joined(separator: ", "),
                                  fixes: (canRestore ? [.restoreExercise(id)] : []) + [.removeExerciseEverywhere(id)])
        }
        checks.append(.init(
            title: "Routines use only library exercises",
            purpose: "Routines and workouts in progress may only use exercises from your exercise library, so editing an exercise updates it everywhere. This check finds exercises deleted from the library that are still planned.",
            passed: routinesOutsideLibrary + workoutsOutsideLibrary == 0,
            detail: routinesOutsideLibrary + workoutsOutsideLibrary == 0
                ? "Every exercise in \(routines.count) routine(s) and \(inProgress.count) workout(s) in progress is in the library."
                : "\(routinesOutsideLibrary) routine(s) and \(workoutsOutsideLibrary) workout(s) in progress use an exercise that is not in the library.",
            guidance: "Bring the exercise back to the library, or remove it from your routines. Past workouts keep it either way.",
            issues: libraryIssues))

        // 8. Each routine has exactly one active version. Editing a routine
        //    deactivates the old version as it adds the new one; zero or two
        //    active versions means the app is guessing which plan is current
        //    (Routine.activeVersion falls back to the newest).
        let badActive = routines.filter { $0.versions.filter(\.isActive).count != 1 }
        let versionless = badActive.filter(\.versions.isEmpty)
        checks.append(.init(
            title: "Each routine has one active version",
            purpose: "Editing a routine after you have used it saves a new version, and exactly one version is the current plan. This check confirms each routine has one, so the app never has to guess which plan to show.",
            passed: badActive.isEmpty,
            detail: badActive.isEmpty ? "\(routines.count) routine(s), each with one active version."
                                      : "\(badActive.count) routine(s) do not have exactly one active version: \(badActive.map { "\($0.name) (\($0.versions.filter(\.isActive).count))" }.joined(separator: ", ")).",
            guidance: versionless.isEmpty
                ? "Fix keeps the plan the app is already showing as the current one."
                : "Fix keeps the plan the app is already showing as the current one. A routine with no versions has no plan at all and can only be deleted.",
            autoFixable: badActive.count > versionless.count,
            issues: versionless.map { IntegrityIssue(id: $0.id.uuidString, title: $0.name, detail: "Has no versions",
                                                     fixes: [.deleteRoutine($0.id)]) }))

        // 9. Machine references point at machines that exist and are not
        //    deleted — from library exercises, current routine plans and
        //    workouts in progress. Finished workouts keep snapshot settings
        //    and do not depend on the machine.
        let liveMachineIds = Set(allMachines.filter { $0.deletedAt == nil }.map(\.id))
        let machinesById = Dictionary(allMachines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let referencedMachines = liveExercises.flatMap(\.machineIds)
            + plannedExercises.compactMap(\.machineId)
            + openExercises.compactMap(\.machineId)
        let badMachineRefs = referencedMachines.filter { !liveMachineIds.contains($0) }.count
        let badMachineIds = Set(referencedMachines.filter { !liveMachineIds.contains($0) })
        let machineIssues = badMachineIds.map { mid -> IntegrityIssue in
            let users = Set(liveExercises.filter { $0.machineIds.contains(mid) }.map(\.name)
                            + plannedExercises.filter { $0.machineId == mid }.map(\.displayName)
                            + openExercises.filter { $0.machineId == mid }.map(\.name)).sorted()
            let machine = machinesById[mid]
            return IntegrityIssue(id: mid.uuidString, title: machine?.name ?? "Missing machine",
                                  detail: (machine != nil ? "Deleted; still used by " : "No longer exists; still used by ")
                                      + users.joined(separator: ", "),
                                  fixes: (machine != nil ? [.restoreMachine(mid)] : []) + [.removeMachineEverywhere(mid)])
        }.sorted { $0.title < $1.title }
        checks.append(.init(
            title: "Machine references are valid",
            purpose: "Exercises, routines and workouts in progress link to machines in your library. This check finds links to machines that were deleted or no longer exist.",
            passed: badMachineRefs == 0,
            detail: badMachineRefs == 0 ? "\(referencedMachines.count) machine reference(s), all valid."
                                        : "\(badMachineRefs) of \(referencedMachines.count) machine reference(s) point at a missing or deleted machine.",
            guidance: "Bring the machine back, or remove it so those exercises use their other (or no) machine.",
            issues: machineIssues))

        // 10. Workouts in progress are in a consistent state: not locked (a
        //     locked workout can no longer be logged to), not marked abandoned
        //     (only finishing sets that), and started ones have a start time.
        let lockedOpen = inProgress.filter(\.isLocked)
        let abandonedOpen = inProgress.filter { !$0.isLocked && $0.status == .abandoned }
        let noStart = inProgress.filter { $0.status != .scheduled && $0.status != .missed && $0.startedAt == nil }
        let openProblems = lockedOpen.count + abandonedOpen.count + noStart.count
        checks.append(.init(
            title: "Workouts in progress are consistent",
            purpose: "A workout you haven't finished should be open for logging: not locked, not marked abandoned, and with a start time. This check finds workouts stuck in between.",
            passed: openProblems == 0,
            detail: openProblems == 0
                ? "\(inProgress.count) scheduled or in-progress workout(s), all consistent."
                : "\(lockedOpen.count) locked, \(abandonedOpen.count) marked abandoned and \(noStart.count) without a start time among \(inProgress.count) unfinished workout(s).",
            guidance: "Finish the workout to file it in history, or resume it to keep logging. A locked workout can only be finished: it is never reopened.",
            // With nothing logged, finishing would discard it, so say so: offer
            // Delete Workout instead of Finish.
            issues: lockedOpen.map { Self.workoutIssue($0, "Locked but never finished", fixes: [Self.closeFix($0)]) }
                + abandonedOpen.map { Self.workoutIssue($0, "Marked abandoned but still open", fixes: Self.openFixes($0)) }
                + noStart.map { Self.workoutIssue($0, "Started, but no start time", fixes: [.setStartTime($0.id)], idSuffix: "-start") }))

        // 12. Demo and user data never mix. A routine only uses exercises of
        //     its own source, an exercise only machines of its own source, and
        //     a workout in progress only exercises of its own source; the
        //     exercise picker and editors enforce this (ExercisePickerSheet).
        //     Mixing would let Delete Demo Data break the user's routines.
        var mixIssues: [IntegrityIssue] = []
        for r in routines {
            guard let v = r.activeVersion else { continue }
            let foreign = v.sections.flatMap(\.exercises).filter { re in
                exercisesById[re.exerciseId].map { $0.sourceRaw != r.sourceRaw } ?? false
            }
            if !foreign.isEmpty {
                mixIssues.append(.init(id: r.id.uuidString, title: r.name,
                    detail: "\(r.source == .seedDemo ? "Demo" : "Your") routine uses \(r.source == .seedDemo ? "your" : "demo") exercise(s): "
                        + Set(foreign.map(\.displayName)).sorted().joined(separator: ", ")))
            }
        }
        for e in liveExercises {
            let foreign = e.machineIds.compactMap { machinesById[$0] }.filter { $0.sourceRaw != e.sourceRaw }
            if !foreign.isEmpty {
                mixIssues.append(.init(id: e.id.uuidString, title: e.name,
                    detail: "Uses machine(s) from the other source: " + foreign.map(\.name).joined(separator: ", ")))
            }
        }
        for s in inProgress {
            let foreign = s.exercises.filter { se in
                se.exerciseId.flatMap { exercisesById[$0] }.map { $0.sourceRaw != s.sourceRaw } ?? false
            }
            if !foreign.isEmpty {
                mixIssues.append(Self.workoutIssue(s, "Workout in progress uses exercise(s) from the other source: "
                    + foreign.map(\.name).joined(separator: ", ")))
            }
        }
        checks.append(.init(
            title: "Demo and your data are separate",
            purpose: "Demo data is only for trying the app. Your routines, exercises and workouts never use demo exercises or machines, and demo ones never use yours, so Delete Demo Data can never affect your own data.",
            passed: mixIssues.isEmpty,
            detail: mixIssues.isEmpty ? "No routine, exercise or workout mixes demo and your data."
                                      : "\(mixIssues.count) item(s) mix demo and your data.",
            guidance: "The app no longer lets demo and your data mix; these come from earlier versions. Replace the demo exercise with one of your own in the routine, then delete demo data.",
            issues: mixIssues))

        // 11. The audit log is intact: events are well-formed, none are dated
        //     in the future, and every finished workout that the log knows
        //     about has its session.finished event (WorkoutRepository
        //     .finishWorkout). Workouts with no events at all are skipped:
        //     backups made before the log was exported restore without it.
        //     Info only: the log is a record, and nothing in it can be fixed.
        let malformedAudits = audits.filter { $0.type.isEmpty || $0.entityName.isEmpty }.count
        let futureAudits = audits.filter { $0.timestamp > Date.now.addingTimeInterval(300) }.count
        let logged = Set(audits.filter { $0.entityName == "WorkoutSession" }.compactMap(\.entityId))
        let unlogged = sessions.filter {
            $0.deletedAt == nil && $0.completedAt != nil && logged.contains($0.id) && finishTimes[$0.id] == nil
        }.count
        let auditProblems = malformedAudits + futureAudits + unlogged
        checks.append(.init(
            title: "Audit log is intact",
            purpose: "The app keeps a log of important events: workouts started and finished, new routine versions, imports and repairs. This check confirms the log is complete and correctly dated. It is a note only.",
            passed: auditProblems == 0,
            detail: auditProblems == 0
                ? "\(audits.count) audit event(s); every finished workout is logged."
                : "\(malformedAudits) malformed and \(futureAudits) future-dated event(s); \(unlogged) finished workout(s) missing from the log.",
            severity: .info,
            guidance: "Nothing to do. The log is a record only; gaps usually come from restoring an older backup, and future dates from a wrong clock."))

        return checks
    }

    var allPassing: Bool { runAll().allSatisfy(\.passed) }

    private func fetchAll<T: PersistentModel>(_ type: T.Type) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }

    private static func openFixes(_ s: WorkoutSession) -> [IntegrityFix] {
        [closeFix(s), .resumeWorkout(s.id)]
    }

    /// Finish it, or delete it when nothing was logged (finishing would discard it).
    private static func closeFix(_ s: WorkoutSession) -> IntegrityFix {
        s.hasAnythingDone ? .finishWorkout(s.id) : .deleteWorkout(s.id)
    }

    private static func workoutTitle(_ s: WorkoutSession) -> String {
        let date = s.startedAt ?? s.scheduledDate ?? s.createdAt
        return "\(s.routineName) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private static func workoutIssue(_ s: WorkoutSession, _ detail: String, fixes: [IntegrityFix] = [],
                                     idSuffix: String = "") -> IntegrityIssue {
        // The suffix keeps ids unique when one workout has two problems.
        IntegrityIssue(id: s.id.uuidString + idSuffix, title: workoutTitle(s), detail: detail, fixes: fixes)
    }

    /// Whether a correction's previousValue still equals the value stored on
    /// the set. CorrectionService records nil as "". Fields it does not know
    /// how to compare are treated as matching.
    private static func matchesStoredValue(_ previous: String, field: String, on set: WorkoutSessionSet) -> Bool {
        switch field {
        case "actualWeight": return (previous.isEmpty ? nil : Double(previous)) == set.actualWeight
        case "actualReps":   return (previous.isEmpty ? nil : Int(previous)) == set.actualReps
        default:             return true
        }
    }

    private static func storedValue(_ field: String, on set: WorkoutSessionSet) -> String {
        switch field {
        case "actualWeight": return set.actualWeight.map { String($0) } ?? "blank"
        case "actualReps":   return set.actualReps.map { String($0) } ?? "blank"
        default:             return "?"
        }
    }
}

// MARK: - Repairs

/// Records that carry a demo/user source marker (check 6).
protocol SourceTagged: AnyObject {
    var sourceRaw: String { get set }
}
extension WorkoutSession: SourceTagged {}
extension RoutineVersion: SourceTagged {}
extension Routine: SourceTagged {}
extension Exercise: SourceTagged {}
extension Machine: SourceTagged {}
extension MachineSettingDefinition: SourceTagged {}
extension GymLocation: SourceTagged {}
extension ScheduleRule: SourceTagged {}
extension WorkoutCorrectionEvent: SourceTagged {}
extension AuditEvent: SourceTagged {}

/// Carries out Data Safety fixes. Every repair is logged to the audit trail as
/// "data.repaired". Callers save the context.
@MainActor
struct DataSafetyRepair {
    let context: ModelContext

    init(_ context: ModelContext) { self.context = context }

    /// The repairs that need no decision — checks 1, 6 and 8. Run at launch,
    /// after every import, and from the check screen's Fix button. Safe to
    /// repeat. Returns the number of records changed.
    @discardableResult
    func autoRepair() -> Int {
        var changed = lockFinishedWorkouts()

        // 6. Unknown source markers become .user: keeping a record is safer
        //    than letting Delete Demo Data remove it. Then versions and
        //    corrections follow their parent.
        func claim<T: PersistentModel & SourceTagged>(_ type: T.Type) {
            for r in fetchAll(type) where DataSource(rawValue: r.sourceRaw) == nil {
                r.sourceRaw = DataSource.user.rawValue
                changed += 1
            }
        }
        claim(WorkoutSession.self); claim(RoutineVersion.self); claim(Routine.self)
        claim(Exercise.self); claim(Machine.self); claim(MachineSettingDefinition.self)
        claim(GymLocation.self); claim(ScheduleRule.self); claim(WorkoutCorrectionEvent.self)
        claim(AuditEvent.self)
        for v in fetchAll(RoutineVersion.self) {
            if let r = v.routine, r.sourceRaw != v.sourceRaw { v.sourceRaw = r.sourceRaw; changed += 1 }
        }
        // Match by id, as check 6 does: a restored correction can lack the
        // relationship while its session id is valid.
        let sessionsById = Dictionary(fetchAll(WorkoutSession.self).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for c in fetchAll(WorkoutCorrectionEvent.self) {
            if let s = sessionsById[c.workoutSessionId], s.sourceRaw != c.sourceRaw { c.sourceRaw = s.sourceRaw; changed += 1 }
        }

        // 8. Exactly one active version: the one the app already shows
        //    (Routine.activeVersion — the newest active one, else the newest).
        for r in fetchAll(Routine.self) where r.deletedAt == nil && r.versions.filter(\.isActive).count != 1 {
            guard let keep = r.activeVersion else { continue }
            for v in r.versions where v.isActive != (v.id == keep.id) {
                v.isActive = (v.id == keep.id)
                changed += 1
            }
        }

        if changed > 0 {
            Audit.log(context, type: "data.repaired", entity: "*",
                      summary: "Data Safety auto-repair changed \(changed) record(s)")
        }
        return changed
    }

    /// 1. A finished workout is locked as of when it was finished. Shared by
    /// autoRepair and apply: the cascades apply uses skip only LOCKED
    /// sessions, so history must be locked before any of them runs.
    private func lockFinishedWorkouts() -> Int {
        var changed = 0
        for s in fetchAll(WorkoutSession.self) where s.completedAt != nil && s.lockedAt == nil {
            s.lockedAt = s.completedAt
            changed += 1
        }
        return changed
    }

    /// Apply one fix the user chose on the check screen.
    func apply(_ fix: IntegrityFix) {
        let workouts = WorkoutRepository(context)
        _ = lockFinishedWorkouts()
        switch fix {
        case .deleteWorkout(let id):
            guard let s = first(WorkoutSession.self, id) else { return }
            workouts.softDeleteSession(s)
        case .finishWorkout(let id):
            guard let s = first(WorkoutSession.self, id) else { return }
            // finishWorkout recomputes the status only for an unlocked
            // session, so unlock first; the lock is reapplied at the time it
            // was originally locked, which becomes the end time.
            let lockedAt = s.lockedAt ?? .now
            s.lockedAt = nil
            workouts.finishWorkout(s, now: lockedAt)
        case .resumeWorkout(let id):
            guard let s = first(WorkoutSession.self, id) else { return }
            workouts.reopen(s)
        case .setStartTime(let id):
            guard let s = first(WorkoutSession.self, id) else { return }
            s.startedAt = s.createdAt
            s.updatedAt = .now
        case .restoreExercise(let id):
            guard let e = first(Exercise.self, id) else { return }
            e.deletedAt = nil
            e.updatedAt = .now
        case .removeExerciseEverywhere(let id):
            RoutineRepository(context).removeExerciseFromAllRoutines(exerciseId: id)
            workouts.removeExerciseFromActiveSessions(exerciseId: id)
        case .restoreMachine(let id):
            guard let m = first(Machine.self, id) else { return }
            m.deletedAt = nil
            m.updatedAt = .now
        case .removeMachineEverywhere(let id):
            removeMachineEverywhere(id)
        case .deleteRoutine(let id):
            guard let r = first(Routine.self, id) else { return }
            RoutineRepository(context).softDelete(r)
        }
        Audit.log(context, type: "data.repaired", entity: "*",
                  summary: "Data Safety: \(fix.label)")
    }

    /// Drop a machine from every library exercise, then point current routine
    /// plans and workouts in progress at the exercise's remaining primary
    /// machine (or none). Finished workouts keep their snapshot.
    private func removeMachineEverywhere(_ machineId: UUID) {
        let exercises = fetchAll(Exercise.self)
        let byId = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var touched = Set<UUID>()
        // Soft-deleted exercises too: one can still be planned somewhere.
        for e in exercises where e.machineIds.contains(machineId) {
            e.machineIds = e.machineIds.filter { $0 != machineId }
            // Default sets saved for this machine no longer belong to anything.
            let stale = e.defaultSets.filter { $0.machineId == machineId }
            let staleIds = Set(stale.map(\.id))
            e.defaultSets.removeAll { staleIds.contains($0.id) }
            for row in stale { context.delete(row) }
            e.updatedAt = .now
            touched.insert(e.id)
        }
        /// The exercise's machine after the removal — never the removed one.
        func replacement(_ exerciseId: UUID?) -> UUID? {
            let next = exerciseId.flatMap { byId[$0]?.machineId }
            return next == machineId ? nil : next
        }
        for re in fetchAll(RoutineExercise.self) where re.machineId == machineId {
            guard let version = re.section?.version, let routine = version.routine,
                  routine.deletedAt == nil, version.id == routine.activeVersion?.id else { continue }
            re.machineId = replacement(re.exerciseId)
            touched.insert(re.exerciseId)
        }
        for se in fetchAll(WorkoutSessionExercise.self) where se.machineId == machineId {
            guard let session = se.session, !session.isLocked, session.completedAt == nil else { continue }
            se.machineId = replacement(se.exerciseId)
            if se.machineId == nil {
                // No machine now: drop the removed machine's settings. Ad hoc
                // settings (no definition) were the user's own and stay.
                let stale = se.machineSettings.filter { $0.definitionId != nil }
                let staleIds = Set(stale.map(\.id))
                se.machineSettings.removeAll { staleIds.contains($0.id) }
                for row in stale { context.delete(row) }
            }
            if let id = se.exerciseId { touched.insert(id) }
        }
        // Re-plan sets and machine settings for the machine now in use.
        let sync = CatalogSyncService(context)
        for id in touched { sync.reconcileExercise(id) }
    }

    private func fetchAll<T: PersistentModel>(_ type: T.Type) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }

    private func first<T: PersistentModel & UUIDIdentifiable>(_ type: T.Type, _ id: UUID) -> T? {
        fetchAll(type).first { $0.id == id }
    }
}
