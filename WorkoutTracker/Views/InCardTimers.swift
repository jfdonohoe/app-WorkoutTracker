//
//  InCardTimers.swift
//  WorkoutTracker
//
//  The countdowns between pieces of work, shown inside the exercise card
//  (approved Figma "Rest & get-ready timers in the exercise card"):
//
//   • RestRingTimer — rest between sets or exercises (strength) and an
//     interval's recovery: a mint ring counting down around deep-green
//     numerals on a faint mint wash.
//   • GetReadyCountdown — a stretch's 5 s get-ready between sides, sets or
//     stretches: start lights on light gray, one per second, red on the two
//     low-beep seconds.
//
//  Both end with Pause / Resume (white) and a square green Skip.
//

import SwiftUI

struct RestRingTimer: View {
    let caption: String
    let time: String
    /// Fraction of the rest elapsed (0…1); the ring shows what's left.
    let progress: Double
    let detail: String
    let isRunning: Bool
    let onPauseResume: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(caption)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.restInk)
                .textCase(.uppercase)
            ZStack {
                Circle().stroke(Theme.timerContainer, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: 1 - min(max(progress, 0), 1))
                    .stroke(Theme.stripeA, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: progress)
                Text(time)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.restInk)
                    .contentTransition(.numericText(countsDown: true))
            }
            .frame(width: 150, height: 150)
            .accessibilityElement(children: .combine)
            .padding(.vertical, 4)   // 14 pt above and below the ring
            if !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !isRunning {
                Text("Paused").font(.caption.bold()).foregroundStyle(Theme.restInk)
            }
            TimerControls(isRunning: isRunning, ink: Theme.restInk, outline: Theme.timerContainer,
                          skipLabel: "Skip rest", onPauseResume: onPauseResume, onSkip: onSkip)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .padding(.bottom, 2)   // 16 pt below the buttons
        .background(Theme.restWash, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct GetReadyCountdown: View {
    let caption: String
    let remaining: Int
    /// Length of the get-ready; one light per second, at most five.
    let total: Int
    let detail: String
    let isRunning: Bool
    let onPauseResume: () -> Void
    let onSkip: () -> Void

    private var lightCount: Int { min(max(total, 1), 5) }
    /// One more light each second: 5 left → 1 lit … 1 left → all lit.
    private var lit: Int { min(max(lightCount - remaining + 1, 0), lightCount) }

    var body: some View {
        VStack(spacing: 10) {
            Text(caption)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.neutralBadge)
                .textCase(.uppercase)
            Text("\(remaining)")
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 0x1C/255, green: 0x1C/255, blue: 0x1E/255))
                .contentTransition(.numericText(countsDown: true))
                .animation(.default, value: remaining)
            HStack(spacing: 12) {
                ForEach(1...lightCount, id: \.self) { i in
                    // The last two lights are the low-beep seconds.
                    let colour = i > lit ? Theme.lightOff
                        : (i > lightCount - 2 ? Theme.statusRed : Theme.statusYellow)
                    Circle()
                        .fill(colour)
                        .frame(width: 26, height: 26)
                        .shadow(color: i > lit ? .clear : colour.opacity(0.6), radius: 5)
                }
            }
            .animation(.easeOut(duration: 0.15), value: lit)
            .accessibilityHidden(true)
            if !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !isRunning {
                Text("Paused").font(.caption.bold()).foregroundStyle(Theme.statusBlack)
            }
            TimerControls(isRunning: isRunning, ink: .black, outline: Color(red: 0xD1/255, green: 0xD1/255, blue: 0xD6/255),
                          skipLabel: "Skip countdown", onPauseResume: onPauseResume, onSkip: onSkip)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(Theme.getReadyBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// White Pause / Resume (wide) and a square green Skip.
private struct TimerControls: View {
    let isRunning: Bool
    let ink: Color
    let outline: Color
    let skipLabel: String
    let onPauseResume: () -> Void
    let onSkip: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPauseResume) {
                Label(isRunning ? "Pause" : "Resume", systemImage: isRunning ? "pause.fill" : "play.fill")
                    .font(.headline)
                    .foregroundStyle(ink)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Theme.surface, in: shape)
                    .overlay(shape.stroke(outline, lineWidth: 1.5))
            }
            .buttonStyle(.borderless)

            Button(action: onSkip) {
                Image(systemName: "forward.end.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 48)
                    .background(Theme.accent, in: shape)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(skipLabel)
        }
        .labelStyle(.titleAndIcon)
    }
}
