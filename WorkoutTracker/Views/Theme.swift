//
//  Theme.swift
//  WorkoutTracker
//
//  Central color palette — the single source of truth for the app's colors.
//  DesignSystem.html at the repo root is regenerated from this file (last
//  2026-10-19); change the colors here first. Brand accent, the timer colors,
//  the status colors and the warm neutral backgrounds all live here.
//
//  The palette is light-only, so the app is locked to Light appearance
//  (INFOPLIST_KEY_UIUserInterfaceStyle in project.yml and the Xcode project);
//  these colors never meet Dark Mode.
//

import SwiftUI

enum Theme {
    /// Brand accent (#007840). Matches AccentColor.colorset and the
    /// "all exercises complete" Finish button.
    static let accent = Color(red: 0.0, green: 0.470, blue: 0.250)

    // MARK: Rest-timer countdown (barber-pole) — see SetActionButtonLabel.
    /// Timer background — the faint container shown behind the countdown reveal (#D1E7DD).
    static let timerContainer = Color(red: 0xD1/255, green: 0xE7/255, blue: 0xDD/255)
    /// Timer status bar — barber-pole stripe / countdown fill (#75B798). Distinct
    /// from `statusGreen`/completed-state green — this is the timer's own color.
    static let stripeA = Color(red: 0x75/255, green: 0xB7/255, blue: 0x98/255)
    /// Pale barber-pole stripe (#EAEBDD).
    static let stripeB = Color(red: 0xEA/255, green: 0xEB/255, blue: 0xDD/255)

    // MARK: In-card timers (RestRingTimer / GetReadyCountdown)
    /// Rest ring panel wash — faint mint behind the ring (#F4FAF7).
    static let restWash = Color(red: 0xF4/255, green: 0xFA/255, blue: 0xF7/255)
    /// Rest ring caption and numerals — deep green (#0F5132).
    static let restInk = Color(red: 0x0F/255, green: 0x51/255, blue: 0x32/255)
    /// Get-ready countdown panel — light gray (#E5E5EA).
    static let getReadyBackground = Color(red: 0xE5/255, green: 0xE5/255, blue: 0xEA/255)
    /// An unlit start light (#C7C7CC).
    static let lightOff = Color(red: 0xC7/255, green: 0xC7/255, blue: 0xCC/255)

    // MARK: Workout-runner action buttons (SetActionButtonLabel)
    /// "Complete Set" button fill — same green as "set completed" (#198754).
    static let completeSetButton: Color = statusGreen
    /// "Complete Exercise" / "Complete & Next" button fill — same green as
    /// "set completed" (#198754).
    static let completeExerciseButton: Color = statusGreen

    // MARK: Status / semantic colors
    /// Success / completed / positive (#198754).
    static let statusGreen = Color(red: 0x19/255, green: 0x87/255, blue: 0x54/255)
    /// Warning / partial / attention (#FD7E14).
    static let statusOrange = Color(red: 0xFD/255, green: 0x7E/255, blue: 0x14/255)
    /// Error / destructive / skipped (#DC3545).
    static let statusRed = Color(red: 0xDC/255, green: 0x35/255, blue: 0x45/255)
    /// Caution (#FFC107).
    static let statusYellow = Color(red: 0xFF/255, green: 0xC1/255, blue: 0x07/255)
    /// Informational / corrected value (#0D6EFD).
    static let statusBlue = Color(red: 0x0D/255, green: 0x6E/255, blue: 0xFD/255)
    /// Neutral ink (#000000).
    static let statusBlack = Color.black
    /// Non-interactive badge fill, e.g. the DEFAULT pill (#3A3A3C). Green is
    /// reserved for things you can tap.
    static let neutralBadge = Color(red: 0x3A/255, green: 0x3A/255, blue: 0x3C/255)

    // MARK: Neutrals
    /// Launch-screen brand green (#6E7A3F). MUST match the background colour in
    /// LaunchBackdrop.storyboard, or the hand-off from the launch screen to
    /// SplashView flashes. Change both together.
    static let launchBackground = Color(red: 0x6E/255, green: 0x7A/255, blue: 0x3F/255)

    /// App / grouped screen background (#FAF8F2, warm off-white).
    static let groupedBackground = Color(red: 0xFA/255, green: 0xF8/255, blue: 0xF2/255)
    /// Card / surface (#FFFFFF).
    static let surface = Color.white
    /// Fill — unselected chips, inline tokens (#F2EEE4).
    static let fill = Color(red: 0xF2/255, green: 0xEE/255, blue: 0xE4/255)
    /// Muted foreground (#7A746A) — secondary button fill, subtitles, captions.
    /// "Muted Foreground" in the donohoeux styleguide.
    static let mutedForeground = Color(red: 0x7A/255, green: 0x74/255, blue: 0x6A/255)
    /// Secondary label — alias of the muted foreground.
    static let secondaryLabel = mutedForeground

    /// UIKit form of the grouped background, for appearance proxies.
    static var groupedBackgroundUI: UIColor {
        UIColor(red: 0xFA/255, green: 0xF8/255, blue: 0xF2/255, alpha: 1)
    }
}
