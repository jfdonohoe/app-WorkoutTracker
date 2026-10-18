//
//  RootView.swift
//  WorkoutTracker
//
//  Tab shell. The app always opens to the Workout tab. Selecting the Settings
//  tab (including tapping it again while on it) always shows the top of
//  Settings, not whatever screen was last pushed there.
//

import SwiftUI
import SwiftData

struct RootView: View {
    @State private var selection: Tab = .workout
    /// Changing this rebuilds Settings' NavigationStack at its root.
    @State private var settingsRootID = UUID()

    enum Tab: Hashable { case workout, calendar, settings }

    var body: some View {
        TabView(selection: Binding(
            get: { selection },
            set: { newTab in
                if newTab == .settings { settingsRootID = UUID() }
                selection = newTab
            })) {
            TodayWorkoutView()
                .tabItem { Label("Workout", systemImage: "figure.strengthtraining.traditional") }
                .tag(Tab.workout)

            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(Tab.calendar)

            SettingsView()
                .id(settingsRootID)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // On the Workout tab, scrolling down minimizes the tab bar and
        // scrolling up restores it. Uses the system behaviour: hiding the bar
        // by hand changes the safe area mid-scroll and makes the list jump.
        .modifier(MinimizeTabBarOnScroll(enabled: selection == .workout))
    }
}

/// iOS 26's built-in tab bar minimize-on-scroll; earlier iOS keeps the bar.
private struct MinimizeTabBarOnScroll: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(enabled ? .onScrollDown : .never)
        } else {
            content
        }
    }
}
