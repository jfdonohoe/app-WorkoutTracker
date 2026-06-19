//
//  RootView.swift
//  WorkoutTracker
//
//  Tab shell. The app always opens to the Today tab.
//

import SwiftUI
import SwiftData

struct RootView: View {
    @State private var selection: Tab = .today

    enum Tab: Hashable { case today, calendar, settings }

    var body: some View {
        TabView(selection: $selection) {
            TodayWorkoutView()
                .tabItem { Label("Today", systemImage: "figure.strengthtraining.traditional") }
                .tag(Tab.today)

            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(Tab.calendar)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
    }
}
