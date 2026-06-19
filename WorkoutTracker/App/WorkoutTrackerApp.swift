//
//  WorkoutTrackerApp.swift
//  WorkoutTracker
//
//  App entry point. Builds the local-only SwiftData container, seeds demo data
//  on first launch, and requests notification permission for rest-timer alerts.
//

import SwiftUI
import SwiftData

@main
struct WorkoutTrackerApp: App {
    let container: ModelContainer
    @StateObject private var restTimer = RestTimerService()

    init() {
        self.container = AppContainer.makeLive()
        // Seed demo data once, on a main-actor context.
        let ctx = container.mainContext
        SeedDataService(ctx).seedIfNeeded()
        NotificationService.shared.requestAuthorizationIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(restTimer)
        }
        .modelContainer(container)
    }
}
