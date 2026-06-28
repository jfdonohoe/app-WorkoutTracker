//
//  Theme.swift
//  WorkoutTracker
//
//  Central color palette — the single source of truth for the app's colors,
//  mirroring DesignSystem.html. Brand accent, the rest-timer barber-pole
//  countdown colors, and the warm neutral backgrounds all live here.
//

import SwiftUI

enum Theme {
    /// Brand accent (#007840). Matches AccentColor.colorset and the
    /// "all exercises complete" Finish button.
    static let accent = Color(red: 0.0, green: 0.470, blue: 0.250)

    // MARK: Rest-timer countdown (barber-pole) — see SetActionButtonLabel.
    /// Faint base shown behind the countdown reveal. rgba(31,29,26,0.08).
    static let timerContainer = Color(red: 31/255, green: 29/255, blue: 26/255).opacity(0.08)
    /// Olive barber-pole stripe (#6E7A3F).
    static let stripeA = Color(red: 0x6E/255, green: 0x7A/255, blue: 0x3F/255)
    /// Pale barber-pole stripe (#EAEBDD).
    static let stripeB = Color(red: 0xEA/255, green: 0xEB/255, blue: 0xDD/255)

    // MARK: Neutrals
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
