//
//  GuidedTimerPanel.swift
//  WorkoutTracker
//
//  The visible timer for a guided cardio / stretch run (GuidedTimerService),
//  as in the approved Figma Active Exercise frames: a caption, the big time,
//  what's being timed, a thin progress bar, then Pause / Resume (wide) and a
//  square green Skip.
//
//  During a between phase the card shows that phase's own countdown instead
//  (InCardTimers): an interval's recovery as the rest ring, a stretch's
//  "get ready" as the start-light countdown.
//
//  Shown inside the exercise sheet for the exercise being timed, and (compact,
//  with the exercise name) at the top of the workout list so the run can be
//  paused even with the sheet closed.
//

import SwiftUI

struct GuidedTimerPanel: View {
    @EnvironmentObject private var guided: GuidedTimerService
    /// Compact = workout-list version: names the exercise being timed.
    var compact = false

    var body: some View {
        if let phase = guided.current, phase.isBetween, !compact {
            betweenTimer(phase)
        } else if let phase = guided.current {
            VStack(spacing: 12) {
                VStack(spacing: 4) {
                    Text(caption(phase))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.secondaryLabel)
                        .textCase(.uppercase)
                    Text(guided.formattedRemaining)
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.default, value: guided.remainingSeconds)
                    // The list version names the exercise up top, so the set
                    // and side go here.
                    Text(compact && !phase.caption.isEmpty ? "\(phase.caption) · \(phase.detail)" : phase.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !guided.isRunning {
                        Text("Paused").font(.caption.bold()).foregroundStyle(Theme.statusBlack)
                    }
                }
                .frame(maxWidth: .infinity)

                ProgressView(value: min(max(guided.progress, 0), 1))
                    .tint(Theme.stripeA)
                    .animation(.linear(duration: 0.25), value: guided.progress)

                HStack(spacing: 12) {
                    // Rounded rectangles, as in the approved frames.
                    Button {
                        if guided.isRunning { guided.pause() } else { guided.resume() }
                    } label: {
                        Label(guided.isRunning ? "Pause" : "Resume",
                              systemImage: guided.isRunning ? "pause.fill" : "play.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(guided.isRunning ? Theme.statusBlack : Theme.accent,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.borderless)

                    Button { guided.skipPhase() } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 48)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(phase.isBetween ? "Skip countdown" : "Skip")
                }
                .labelStyle(.titleAndIcon)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    /// Recovery or the rest between cardio exercises → rest ring; a stretch's
    /// get-ready → start lights.
    @ViewBuilder
    private func betweenTimer(_ phase: GuidedPhase) -> some View {
        let pauseResume = { if guided.isRunning { guided.pause() } else { guided.resume() } }
        if phase.isRecovery || phase.isRest {
            RestRingTimer(caption: phase.isRest ? phase.caption
                              : phase.caption.isEmpty ? "Recovery" : "Recovery · \(phase.caption)",
                          time: guided.formattedRemaining,
                          progress: guided.progress,
                          detail: phase.detail,
                          isRunning: guided.isRunning,
                          onPauseResume: pauseResume,
                          onSkip: { guided.skipPhase() })
        } else {
            GetReadyCountdown(caption: phase.caption.isEmpty ? "Get ready" : "Get ready · \(phase.caption)",
                              remaining: guided.remainingSeconds,
                              total: phase.seconds,
                              detail: phase.detail,
                              isRunning: guided.isRunning,
                              onPauseResume: pauseResume,
                              onSkip: { guided.skipPhase() })
        }
    }

    private func caption(_ phase: GuidedPhase) -> String {
        if compact {
            return phase.isBetween ? (phase.isRest ? "Rest" : phase.isRecovery ? "Recovery" : "Get ready") : phase.exerciseName
        }
        // Where in the exercise: "Work · Round 2 of 8", "Set 2 of 2 · Forward".
        return phase.caption.isEmpty ? "Time left" : phase.caption
    }
}
