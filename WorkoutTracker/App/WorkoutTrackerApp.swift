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
    let container: ModelContainer
    @StateObject private var restTimer = RestTimerService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        self.container = AppContainer.makeLive()
        // Seed demo data once, on a main-actor context.
        let ctx = container.mainContext
        SeedDataService(ctx).seedIfNeeded()
        NotificationService.shared.requestAuthorizationIfNeeded()
        // Warm grouped background (#FAF8F2) behind every List/Form. Cards (cells)
        // stay white (systemBackground), matching DesignSystem.html.
        UICollectionView.appearance().backgroundColor = Theme.groupedBackgroundUI
        UITableView.appearance().backgroundColor = Theme.groupedBackgroundUI
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(restTimer)
                // Keep the screen awake whenever the app is in the foreground.
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
                .onChange(of: scenePhase) { _, phase in
                    UIApplication.shared.isIdleTimerDisabled = (phase == .active)
                }
        }
        .modelContainer(container)
    }
}
