//
//  WorkoutTrackerApp.swift
//  WorkoutTracker
//
//  App entry point. Builds the local-only SwiftData container, seeds demo data
//  on first launch, and requests notification permission for rest-timer alerts.
//

import SwiftUI
import SwiftData
import UIKit

@main
struct WorkoutTrackerApp: App {
    /// `nil` only when this process is an XCTest host — see `isRunningTests`.
    let container: ModelContainer?
    @StateObject private var restTimer = RestTimerService()
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
