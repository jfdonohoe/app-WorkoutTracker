//
//  RestTimerService.swift
//  WorkoutTracker
//
//  Rest timer between sets. Designed to keep correct time even when the phone is
//  locked or the app is backgrounded: remaining time is always derived from an
//  absolute `endDate`, not from accumulated ticks. A local notification is
//  scheduled for `endDate` so the user is alerted even if the app is suspended.
//
//  Timer history is intentionally NOT persisted (per spec).
//

import Foundation
import Combine
import AudioToolbox
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class RestTimerService: ObservableObject {
    @Published private(set) var totalSeconds: Int = 0
    @Published private(set) var remainingSeconds: Int = 0
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var isFinished: Bool = false

    /// Label of the upcoming set, shown while resting.
    @Published var upcomingSummary: String = ""
    /// What this rest is, for the peek sheet's caption ("Rest between sets").
    @Published private(set) var title: String = "Rest"

    private var endDate: Date?
    private var pausedRemaining: Int?
    private var ticker: AnyCancellable?
    private let notifications: NotificationService

    private let notificationId = "rest-timer"
    /// How many final seconds of a rest get a countdown beep.
    static let countdownBeepSeconds = 5

    init(notifications: NotificationService = .shared) {
        self.notifications = notifications
    }

    /// Start a fresh countdown.
    func start(seconds: Int, upcoming: String = "", title: String = "Rest") {
        guard seconds > 0 else { return }
        self.title = title
        totalSeconds = seconds
        remainingSeconds = seconds
        upcomingSummary = upcoming
        isFinished = false
        endDate = Date().addingTimeInterval(TimeInterval(seconds))
        pausedRemaining = nil
        isRunning = true
        scheduleTick()
        notifications.scheduleRestComplete(id: notificationId, after: seconds)
    }

    func pause() {
        guard isRunning, let endDate else { return }
        pausedRemaining = max(0, Int(endDate.timeIntervalSinceNow.rounded()))
        remainingSeconds = pausedRemaining ?? 0
        isRunning = false
        ticker?.cancel()
        notifications.cancel(id: notificationId)
    }

    func resume() {
        guard !isRunning, let paused = pausedRemaining, paused > 0 else { return }
        endDate = Date().addingTimeInterval(TimeInterval(paused))
        pausedRemaining = nil
        isRunning = true
        isFinished = false
        scheduleTick()
        notifications.scheduleRestComplete(id: notificationId, after: paused)
    }

    /// Reset back to the full configured duration (stopped).
    func reset() {
        ticker?.cancel()
        isRunning = false
        isFinished = false
        remainingSeconds = totalSeconds
        endDate = nil
        pausedRemaining = nil
        notifications.cancel(id: notificationId)
    }

    /// Override the duration for THIS workout only (does not touch the routine).
    func override(seconds: Int) {
        let wasRunning = isRunning
        ticker?.cancel()
        totalSeconds = seconds
        if wasRunning {
            start(seconds: seconds, upcoming: upcomingSummary, title: title)
        } else {
            remainingSeconds = seconds
            if pausedRemaining != nil { pausedRemaining = seconds }   // Resume continues from the new length
        }
    }

    func stop() {
        ticker?.cancel()
        isRunning = false
        endDate = nil
        pausedRemaining = nil
        notifications.cancel(id: notificationId)
    }

    private func scheduleTick() {
        ticker?.cancel()
        ticker = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard let endDate else { return }
        let remaining = Int(endDate.timeIntervalSinceNow.rounded())
        if remaining <= 0 {
            remainingSeconds = 0
            isRunning = false
            isFinished = true
            ticker?.cancel()
            fireCompletionFeedback()
        } else if remaining != remainingSeconds {
            // Only publish when the whole-second value actually changes, so views
            // observing the timer don't re-render 4×/sec for no visible change.
            remainingSeconds = remaining
            // Raceway countdown: a low beep on each of the last 5 seconds; the
            // high "go" beep at zero (fireCompletionFeedback) ends it.
            if (1...Self.countdownBeepSeconds).contains(remaining) {
                SoundCues.shared.lowBeep()
            }
        }
    }

    /// The high "go" beep + haptic when the countdown reaches zero in
    /// foreground, as at the end of a stretch's get-ready. (A local
    /// notification covers the backgrounded/locked case separately.)
    private func fireCompletionFeedback() {
        SoundCues.shared.highBeep()
    }

    /// Paused part-way through (Resume continues it).
    /// (Paused with nothing left counts as over: Resume can't continue it.)
    var isPaused: Bool { !isRunning && (pausedRemaining ?? 0) > 0 }

    /// Running or paused: the rest still holds the set's action slot.
    var isActive: Bool { isRunning || isPaused }

    var formattedRemaining: String {
        let m = remainingSeconds / 60
        let s = remainingSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return 1.0 - (Double(remainingSeconds) / Double(totalSeconds))
    }
}
