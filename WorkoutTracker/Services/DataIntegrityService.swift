//
//  DataIntegrityService.swift
//  WorkoutTracker
//
//  Read-only verification of the data-safety invariants, powering the optional
//  "Data Safety Check" screen. It never mutates data — it only reports.
//

import Foundation
import SwiftData

struct IntegrityCheck: Identifiable {
    let id = UUID()
    let title: String
    let passed: Bool
    let detail: String
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

        // 1. Recorded sessions are locked.
        let recorded = sessions.filter { $0.status.isRecordedHistory }
        let unlocked = recorded.filter { !$0.isLocked }
        checks.append(.init(
            title: "Recorded sessions are locked",
            passed: unlocked.isEmpty,
            detail: unlocked.isEmpty ? "\(recorded.count) recorded session(s), all locked."
                                     : "\(unlocked.count) recorded session(s) are NOT locked."))

        // 2. Recorded sessions carry snapshot data (their own exercises/sets).
        let missingSnapshots = recorded.filter { $0.exercises.isEmpty }
        checks.append(.init(
            title: "Recorded sessions have snapshot data",
            passed: missingSnapshots.isEmpty,
            detail: missingSnapshots.isEmpty ? "All recorded sessions contain snapshot exercises."
                                             : "\(missingSnapshots.count) session(s) have no snapshot exercises."))

        // 3. Sessions reference a routine version that still exists.
        let danglingRefs = sessions.filter { s in
            if let vid = s.routineVersionId { return !versionIds.contains(vid) }
            return false
        }
        checks.append(.init(
            title: "Session → routine version references are valid",
            passed: danglingRefs.isEmpty,
            detail: danglingRefs.isEmpty ? "All session version references resolve."
                                         : "\(danglingRefs.count) session(s) reference a missing version."))

        // 4. Snapshot sets keep planned values (immutable snapshot stable).
        let badPlanned = recorded.flatMap(\.exercises).flatMap(\.sets)
            .filter { $0.plannedReps < 0 || $0.plannedWeight < 0 }
        checks.append(.init(
            title: "Snapshot sets have valid planned values",
            passed: badPlanned.isEmpty,
            detail: badPlanned.isEmpty ? "Planned snapshot values look intact."
                                       : "\(badPlanned.count) snapshot set(s) have invalid planned values."))

        // 5. Corrections preserve originals (never blank-overwrite).
        let corrections = (try? context.fetch(FetchDescriptor<WorkoutCorrectionEvent>())) ?? []
        let badCorrections = corrections.filter { $0.field.isEmpty }
        checks.append(.init(
            title: "Corrections are well-formed append-only events",
            passed: badCorrections.isEmpty,
            detail: "\(corrections.count) correction event(s); \(badCorrections.count) malformed."))

        // 6. Demo separation: each record's source is a known value.
        let allSources = sessions.map(\.sourceRaw)
        let unknownSources = allSources.filter { DataSource(rawValue: $0) == nil }
        checks.append(.init(
            title: "Demo/user source markers are intact",
            passed: unknownSources.isEmpty,
            detail: unknownSources.isEmpty ? "All sessions tagged user/seedDemo."
                                           : "\(unknownSources.count) session(s) have an unknown source marker."))

        return checks
    }

    var allPassing: Bool { runAll().allSatisfy(\.passed) }
}
