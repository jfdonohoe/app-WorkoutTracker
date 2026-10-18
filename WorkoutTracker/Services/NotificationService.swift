//
//  NotificationService.swift
//  WorkoutTracker
//
//  Thin wrapper over UserNotifications for rest-timer alerts. Local only — no
//  push, no server. Scheduling a notification for the timer's end means the user
//  is alerted (sound + banner) even when the app is backgrounded or the phone
//  is locked.
//

import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private init() {}

    /// Request authorization once, early in the app lifecycle.
    func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Schedule the "rest complete" alert `seconds` from now.
    func scheduleRestComplete(id: String, after seconds: Int) {
        guard seconds > 0 else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])

        let content = UNMutableNotificationContent()
        content.title = "Rest complete"
        content.body = "Time for your next set."
        content.sound = WorkoutSettings.timerSounds ? .default : nil   // Settings ▸ Timer sounds

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(request)
    }

    /// Schedule a general timer alert `seconds` from now (guided cardio /
    /// stretch timers).
    func schedule(id: String, after seconds: Int, title: String, body: String) {
        guard seconds > 0 else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = WorkoutSettings.timerSounds ? .default : nil   // Settings ▸ Timer sounds

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func cancel(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}
