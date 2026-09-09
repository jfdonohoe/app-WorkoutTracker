//
//  SplashView.swift
//  WorkoutTracker
//
//  The branded launch screen, drawn by the APP rather than by the launch
//  storyboard.
//
//  WHY THIS EXISTS (not just decoration):
//  iOS caches the rendered launch storyboard per app on the device. That cache
//  survives `devicectl` uninstall, deleting the app from the Home screen, a
//  device restart, a build-number bump, renaming the storyboard AND renaming the
//  image asset — verified, one at a time, on a real device. The result is that
//  updated launch artwork silently never appears, while the simulator shows it
//  correctly, which makes the problem look like a build failure when it isn't.
//
//  So the launch storyboard (LaunchBackdrop.storyboard) is now a bare brand-green
//  screen with no image — nothing that can go stale — and the artwork is drawn
//  here, as an ordinary SwiftUI view over the app's content. Ordinary image
//  loading is not subject to that cache, so the artwork updates with every build.
//
//  The green here MUST match LaunchBackdrop.storyboard's background exactly, or
//  the hand-off from launch screen to app will visibly flash.
//

import SwiftUI

struct SplashView: View {
    var body: some View {
        Theme.launchBackground
            .overlay(
                // 2208x2208 square, deliberately larger than the screen. `.fill`
                // scales by height and crops the SIDES. Measured on the supplied
                // artwork (2026-09-09): content sits within x 35.3%-64.5%, well
                // inside the 30-70% safe zone. The PNG is used flat and uncropped
                // here — the layout is the artwork's, not this view's.
                // `Color` is the sizing parent — an unclipped `.fill` image
                // otherwise overflows and drags the layout off-centre.
                Image("LaunchImage")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            )
            .clipped()
            .ignoresSafeArea()
        // The splash is decorative — the real UI is already built underneath it.
        .accessibilityHidden(true)
    }
}

/// Drives how long `SplashView` stays up. Kept separate from the view so the
/// timing is stated in one place and can be tuned without touching layout.
enum SplashTiming {
    /// How long the artwork holds before it starts fading.
    static let hold: Duration = .milliseconds(900)
    /// How long the cross-fade into the app takes.
    static let fade: TimeInterval = 0.35
}

#Preview {
    SplashView()
}
