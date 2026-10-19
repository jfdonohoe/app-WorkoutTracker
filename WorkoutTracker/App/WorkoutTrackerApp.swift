//
//  WorkoutTrackerApp.swift
//  WorkoutTracker
//
//  App entry point. Builds the local-only SwiftData container, keeps the demo
//  data seeded until the user has data of their own (SeedDataService
//  .reconcileDemoData, every launch), runs the launch cleanups, and requests
//  notification permission for the rest and guided timer alerts.
//

import SwiftUI
import SwiftData
import UIKit

@main
struct WorkoutTrackerApp: App {
    /// `nil` only when this process is an XCTest host — see `isRunningTests`.
    let container: ModelContainer?
    @StateObject private var restTimer = RestTimerService()
    @StateObject private var guidedTimer = GuidedTimerService()
    @Environment(\.scenePhase) private var scenePhase
    /// Covers the app with the branded artwork for a beat after launch. See
    /// SplashView for why the branding lives here and not in the launch
    /// storyboard.
    @State private var showSplash = true

    /// True when this process is an XCTest host — XCTest injects the test
    /// bundle into a running instance of this app, so `init()`/`body` still
    /// run even though a unit test never touches this container. Each test
    /// builds its own in-memory ModelContainer via TestSupport; having a
    /// SECOND ModelContainer for the same @Model schema alive at the same
    /// time crashes SwiftData on some SDKs, so this container (and the demo
    /// seed it would trigger) must never be constructed in that case at all.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init() {
        guard !Self.isRunningTests else {
            self.container = nil
            return
        }
        let container = AppContainer.makeLive()
        self.container = container
        // Reconcile demo data against the current store, on a main-actor context.
        let ctx = container.mainContext
        SeedDataService(ctx).reconcileDemoData()
        // One-time cleanups of old damage (deleted exercises left in
        // routines, duplicated planned sets). The Data Safety repairs run on
        // import only — the only way those problems can arrive.
        let cleaned = CatalogSyncService(ctx).runOneTimeCleanupsIfNeeded()
        // Exercises saved before the exercise structure get a kind and its
        // fields (one predicate fetch when there is nothing to do).
        let migrated = ExerciseStructureMigration(ctx).run().changedAnything
        // Abandoned workouts (nothing done) are discarded, never kept.
        let purged = WorkoutRepository(ctx).purgeDiscardedWorkouts() > 0
        // Locked workouts keep the distance unit they were recorded in.
        let frozen = WorkoutRepository(ctx).freezeDistanceUnits() > 0
        if cleaned || purged || migrated || frozen {
            try? ctx.save()
        }
        NotificationService.shared.requestAuthorizationIfNeeded()
        // Warm grouped background (#FAF8F2) behind every List/Form. Cards (cells)
        // stay white (systemBackground), matching DesignSystem.html.
        UICollectionView.appearance().backgroundColor = Theme.groupedBackgroundUI
        UITableView.appearance().backgroundColor = Theme.groupedBackgroundUI
    }

    var body: some Scene {
        WindowGroup {
            if let container {
                ZStack {
                    RootView()
                        .environmentObject(restTimer)
                        .environmentObject(guidedTimer)
                        .environment(\.timerCommands, TimerCommands(rest: restTimer, guided: guidedTimer))
                        // Keep the screen awake whenever the app is in the foreground.
                        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
                        .onChange(of: scenePhase) { _, phase in
                            UIApplication.shared.isIdleTimerDisabled = (phase == .active)
                        }
                        .modelContainer(container)

                    if showSplash {
                        SplashView()
                            .transition(.opacity)
                    }
                }
                // The app is fully built underneath while this is up, so the
                // splash costs nothing but the hold time.
                .task {
                    try? await Task.sleep(for: SplashTiming.hold)
                    withAnimation(.easeOut(duration: SplashTiming.fade)) {
                        showSplash = false
                    }
                }
            }
        }
    }
}
