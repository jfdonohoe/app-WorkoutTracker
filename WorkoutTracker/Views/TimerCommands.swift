//
//  TimerCommands.swift
//  WorkoutTracker
//
//  The rest and guided timers for views that only command them (stop them
//  when a workout is discarded) and don't show them. Unlike
//  @EnvironmentObject, reading this doesn't re-render the view on every timer
//  tick — which on a tab root re-ran its whole-history filtering each second.
//  Views that show a timer keep @EnvironmentObject.
//

import SwiftUI

struct TimerCommands: Equatable {
    weak var rest: RestTimerService?
    weak var guided: GuidedTimerService?

    /// The same timers = unchanged, so the app's per-tick body run (which
    /// builds a new value) doesn't count as an environment change.
    static func == (a: TimerCommands, b: TimerCommands) -> Bool {
        a.rest === b.rest && a.guided === b.guided
    }

    @MainActor func stopAll() {
        rest?.stop()
        guided?.stop()
    }

    /// The workout's rests changed: a run under way takes them (GuidedTimerService.updateRests).
    @MainActor func updateRests(_ rests: TypeRests) {
        guided?.updateRests(rests)
    }
}

private struct TimerCommandsKey: EnvironmentKey {
    static let defaultValue = TimerCommands()
}

extension EnvironmentValues {
    var timerCommands: TimerCommands {
        get { self[TimerCommandsKey.self] }
        set { self[TimerCommandsKey.self] = newValue }
    }
}
