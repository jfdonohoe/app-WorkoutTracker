# Workout tab (inline workout) – code review

Date: 2026-10-08
Scope: `RootView.swift`, `TodayWorkoutView.swift`, `WorkoutRunnerView.swift` changes that turn the Today tab into the Workout tab: inline live workout, auto-open of the day's scheduled workout, "<date> Workout" header with no nav bar, and the tab bar hiding on scroll.
Reviewer: swift-reviewer subagent. Verdict before fixes: NEEDS-WORK.

## Findings

| # | Severity | Finding | Status |
|---|----------|---------|--------|
| 1 | High | A workout deleted outside the tab's ••• menu (from its summary sheet, or from Calendar → history detail) was restarted straight away by auto-start, because only the tab's own delete adds a schedule exception. | **Fixed.** `routineToAutoStart` skips any routine that had a session today, including a deleted one. The planned card with Start still appears. |
| 1b | Medium | Deleting a live session from Calendar's history detail left the rest and guided timers running against it. | **Fixed.** `onChange(of: activeSession?.id)` stops both timers when the live workout disappears. |
| 2 | Medium-high | Crossing midnight: the next re-render dropped the running workout (it no longer counted as "today"), auto-started the next day's routine, and stranded the unlocked session. | **Fixed.** `activeSession` also takes an unlocked session started in the last 12 hours. While one exists, auto-start is blocked. |
| 3 | Low-medium | With two workouts in a day, `.task(id:)` timing makes auto-start inconsistent. | **Not fixed.** Outside the agreed "one workout a day" assumption. |
| 4 | Medium (inferred) | The summary sheet set during Save & Exit could be dropped, because it was presented in the same update as the runner's sheet dismissal. | **Fixed.** Presentation is delayed 500 ms. Not checked on a device. |
| 5 | Low-medium | Guided-timer callbacks stay attached to the off-screen tab runner, and a finish prompt could fire while another tab is selected. | **Not fixed.** Calendar's `ActiveWorkoutView` sheet path currently has no callers, so the two-runner case can't happen. |
| 6 | Low | Tab-bar hide on scroll: rest/guided panels appearing can shift the offset and toggle the bar, and the bottom bounce can briefly show it. | **Not fixed.** Cosmetic. |
| 7 | Low | `TodayWorkoutView` has 5 `.sheet`s plus a confirmationDialog. An enum-driven single sheet would be safer. | **Not fixed.** Pre-existing structure, refactor candidate. |

## Verification

- Build: succeeded (iPhone 17 Pro simulator, iOS 26.5). Only pre-existing Swift 6 concurrency warnings.
- Tests: 56/56 passed after the fixes.
- Simulator: the Workout tab opens into the inline workout with the "Oct 8 Workout" header and the Workout tab label.
- Not exercised by hand: tab-bar hide on scroll (the simulator's workout was too short to scroll), the summary after Save & Exit, and the midnight case.
