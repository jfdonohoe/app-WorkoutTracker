# Review: guided timers, multi-machine exercises, Today/Settings changes — 2026-10-07

Reviewer: `swift-reviewer` subagent, over the uncommitted changes for:
Add Workout sheet, guided cardio/stretch timers, rest-countdown beeps,
multiple machines per exercise, the set-2 weight bug, setting values from 0,
the Settings tab reset, and the demo auto-seed toggle.

Verdict before fixes: NEEDS-WORK (1 real bug, 2 lifecycle/presentation gaps).
No path writes to a locked session.

## Findings and outcome

| # | Severity | Finding | Location | Outcome |
|---|----------|---------|----------|---------|
| 1 | Bug | Guided timer redirected/closed whatever exercise sheet was open (could discard un-saved reps/weight on a strength sheet; replaced its rest timer) | `Views/WorkoutRunnerView.swift` `guidedExerciseFinished` / `guidedSequenceFinished` | **Fixed** — only acts when the open sheet is the exercise the timer just finished |
| 2a | Medium | "Create a routine" started the workout while the editor sheet was still up (presentation could be dropped after a session was created) | `Views/TodayWorkoutView.swift` `onCommit` | **Fixed** — start deferred to the editor sheet's `onDismiss` |
| 2b | Low | Five `.sheet`s on TodayWorkoutView; checklist prefers one enum-driven presentation | `Views/TodayWorkoutView.swift` | Not changed (style) |
| 2c | Low | Finish prompt set from a timer callback can be dropped if the session editor sheet is open | `Views/WorkoutRunnerView.swift` | Not changed (rare) |
| 3 | Medium | Guided run outlived a swiped-away workout; stale callbacks; stale panel in next workout | `Views/WorkoutRunnerView.swift` | **Fixed** — `onDisappear` stops the run and clears callbacks |
| 4 | Low | Duration/hold/reps/timer steppers editable during a run the timer won't pick up | `Views/SessionExerciseSheet.swift` | **Fixed** — disabled while the exercise is in the run |
| 5 | Low | Untimed → timed stretch kept up to 100 reps as rounds | `Views/SessionExerciseSheet.swift`, `Views/ExerciseEditorView.swift` | **Fixed** — rounds capped at 20 when a hold time is set |
| 6 | Low (unverified) | Beeps could stay silent after an audio interruption | `Services/SoundCues.swift` | **Fixed** — `play()` called unconditionally |
| 7 | Low | Machine pickers blank / edits vanish when the stored machine is no longer linked | `Views/SessionExerciseSheet.swift`, `Views/SetBuilderSheet.swift` | **Fixed** — picker hidden for an unlinked id; set builder falls back to the default machine |
| 8 | Low | Switching to a soft-deleted machine left the old machine's settings | `Persistence/WorkoutRepository.swift` `switchMachine` | **Fixed** — switch refused; test added |
| 9 | Low | Out-of-order completion can duplicate set indexes | `Persistence/CatalogSyncService.swift` `reconcileStrengthSets` | Not changed — pre-existing behaviour |
| 10 | Info | Three bordered buttons in one List row | `Views/GuidedTimerPanel.swift` | No change — bordered styles hit-test independently |

## Verified correct (per reviewer)
GuidedTimerService re-entrancy and pause/skip/stop paths; SwiftData relationship
handling in `updateExerciseDefaults` and the editor save; version-fork handling
in `RoutineEditorView.saveSets`; every new write path guards `isLocked`;
backup v3 fields are optional with v2 fallbacks.

## Regression
- Full suite after fixes: **55 tests, 0 failures** (37 pre-existing + 18 new in
  `MultiMachineAndGuidedTests`).
- Schema migration: pre-change build run on a simulator store, then the new
  build installed over it — launched cleanly, new columns added, row counts
  unchanged (2 sessions, 18 sets, 5 exercises, 2 routines, 5 machines).
