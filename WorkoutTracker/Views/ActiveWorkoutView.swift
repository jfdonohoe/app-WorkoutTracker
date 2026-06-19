//
//  ActiveWorkoutView.swift
//  WorkoutTracker
//
//  The workout UI presented as a sheet (from Today or the Calendar). It wraps
//  the shared WorkoutRunnerView in a NavigationStack with a Close button and
//  reports completion so the presenter can show the summary screen.
//

import SwiftUI
import SwiftData

struct ActiveWorkoutView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var restTimer: RestTimerService

    @Bindable var session: WorkoutSession
    /// Called when the workout is finished (presenter shows the summary).
    var onFinished: (WorkoutSession) -> Void = { _ in }

    @State private var showStopConfirm = false

    var body: some View {
        NavigationStack {
            WorkoutRunnerView(session: session) {
                onFinished(session)
                dismiss()
            }
            .environmentObject(restTimer)
            .navigationTitle(session.routineName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { showStopConfirm = true }
                }
            }
            .confirmationDialog("Stop your workout?", isPresented: $showStopConfirm, titleVisibility: .visible) {
                Button("Yes, stop", role: .destructive) {
                    try? context.save()
                    restTimer.stop()
                    dismiss()
                }
                Button("No", role: .cancel) {}
            }
        }
    }
}
