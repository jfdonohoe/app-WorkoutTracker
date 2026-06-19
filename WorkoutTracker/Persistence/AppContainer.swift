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
    /// DEV vs PRODUCTION behavior is split by the `DEBUG` compile flag (on in
    /// Xcode, compiled OUT of Release/App Store builds):
    ///  • DEBUG  — a schema mismatch (common while iterating on the model) wipes
    ///             the disposable dev store and retries, so you never have to
    ///             hand-delete the app. A `--reset-store` launch argument forces
    ///             a clean store on demand.
    ///  • RELEASE — never deletes anything. A failure to open is fatal and loud
    ///             so real history is protected (principle #8).
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
            #if DEBUG
            // DEVELOPMENT ONLY: the dev store is disposable. A failure here is
            // almost always an incompatible schema after a model change, so wipe
            // and retry to keep iteration fast. This entire branch is removed
            // from Release builds.
            print("⚠️ [DEBUG] Could not open store (\(error)). Wiping dev store and retrying.")
            destroyStoreFiles()
            do {
                return try ModelContainer(
                    for: schema,
                    migrationPlan: WorkoutMigrationPlan.self,
                    configurations: [config]
                )
            } catch {
                fatalError("[DEBUG] Failed to recreate dev store: \(error)")
            }
            #else
            // PRODUCTION: never delete the store to "fix" it — that would
            // destroy history (principle #8). Fail loudly so the user can back
            // up / export first.
            fatalError(
                """
                Failed to open the workout database. Release builds never delete \
                or recreate the store automatically, to protect your history. \
                Underlying error: \(error)
                """
            )
            #endif
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
