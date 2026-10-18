//
//  AppContainer.swift
//  WorkoutTracker
//
//  Centralized ModelContainer construction. The app is local-only and
//  offline-only for v1: no CloudKit, no server. We explicitly disable any cloud
//  sync so there are no surprises.
//

import Foundation
import SwiftData

enum AppContainer {

    /// The shared on-disk container used by the running app.
    /// Built through the versioned schema + migration plan so future schema
    /// changes are forced through reviewable, non-destructive migrations.
    ///
    /// No build ever deletes the store on its own: a failure to open is fatal
    /// and loud, so real history is protected (principle #8) — including a
    /// Debug build installed from Xcode onto the phone that holds it. In
    /// DEBUG only, a `--reset-store` launch argument starts a clean store on
    /// purpose.
    static func makeLive() -> ModelContainer {
        let schema = Schema(versionedSchema: WorkoutSchemaV1.self)
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            cloudKitDatabase: .none // local-only / offline-only for v1
        )

        #if DEBUG
        // Opt-in hard reset: add `--reset-store` under
        // Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Arguments to start fresh.
        if CommandLine.arguments.contains("--reset-store") {
            destroyStoreFiles()
        }
        #endif

        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: WorkoutMigrationPlan.self,
                configurations: [config]
            )
        } catch {
            // Never delete the store to "fix" it — that would destroy history
            // (principle #8). Fail loudly so the user can back up / export
            // first. (Debug: launch with --reset-store to start clean.)
            fatalError(
                """
                Failed to open the workout database. The app never deletes or \
                recreates it automatically, to protect your history. \
                Underlying error: \(error)
                """
            )
        }
    }

    #if DEBUG
    /// The default SwiftData store location (Application Support/default.store),
    /// plus its write-ahead-log siblings. DEBUG-only.
    private static func destroyStoreFiles() {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: false) else { return }
        let store = base.appendingPathComponent("default.store")
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: store.path + suffix)
            try? fm.removeItem(at: url)
        }
        print("⚠️ [DEBUG] Dev store files removed.")
    }
    #endif

    /// An in-memory container for tests and previews. Never touches disk.
    static func makeInMemory() -> ModelContainer {
        let schema = Schema(versionedSchema: WorkoutSchemaV1.self)
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        // swiftlint:disable:next force_try
        return try! ModelContainer(
            for: schema,
            migrationPlan: WorkoutMigrationPlan.self,
            configurations: [config]
        )
    }
}
