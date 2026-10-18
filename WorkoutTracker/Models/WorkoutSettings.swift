//
//  WorkoutSettings.swift
//  WorkoutTracker
//
//  The Workout section of Settings (approved Figma "Settings: timer sounds and
//  stretch auto-advance"). Stored in UserDefaults; both default to on.
//

import Foundation

enum WorkoutSettings {
    /// Countdown beeps and chimes. Off = silent; vibrations still play.
    static let timerSoundsKey = "settings.timerSounds"
    /// A finished stretch moves on to the next one by itself. Off = its timer
    /// ends and Complete & Next appears, as after a strength rest.
    static let autoProgressStretchesKey = "settings.autoProgressStretches"

    static var timerSounds: Bool { flag(timerSoundsKey) }
    static var autoProgressStretches: Bool { flag(autoProgressStretchesKey) }

    /// A Bool that is true until the user turns it off.
    private static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}
