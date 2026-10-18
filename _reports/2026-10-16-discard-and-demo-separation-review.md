# Discard abandoned workouts + demo/user separation review — 2026-10-16

User rules: (1) don't save abandoned workouts — delete them; (2) demo exercises are demo-only — no mingling of demo and user data; (3) if Data Safety problems can only come from import/export, remove the check from Settings and run it only during import/export.

Reviewed by the swift-reviewer subagent; findings verified against the code before fixing. Full suite after fixes: 135/135 passing (iPhone 17 Pro simulator).

## Fixed

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | High | `cloneRoutine` always created a `.user` copy, so "this instance only" / "save as new" on a demo routine made a user routine pointing at demo exercises (`RoutineRepository.swift:229`). | Copy keeps its original's source. Test: `testCopyOfDemoRoutineStaysDemo`. |
| 2 | High | Empty workouts stopped from the Calendar, started on a past day, or auto-started and never used were never discarded. | Calendar "Yes, stop" discards when nothing is logged; the launch purge also removes unfinished workouts with nothing done from an earlier day. Tests: `testEmptyWorkoutLeftOpenOnEarlierDayIsPurged`, `testTodaysEmptyWorkoutInProgressIsKept`. |
| 3 | Medium | Purge deleted by the `abandoned` label alone. | Purge requires nothing done. Test: `testOpenWorkoutWithASetDoneIsNeverPurged`. |
| 4 | Medium | After the purge, Today would auto-start a discarded scheduled routine again the same day. | Today's discarded workouts are kept (hidden) until the next day. Test: `testFinishingWithNothingDoneDiscardsTheWorkout`. |
| 5 | Medium | Schedules for demo routines were created as `.user` (4 places), surviving Delete Demo Data. | Schedules take their routine's source. Test: `testScheduleForDemoRoutineIsDemoAndGoesWithIt`. |
| 7 | Low | Discarded/deleted workouts still forced a routine version fork. | `isReferencedBySession` ignores deleted sessions. |
| 8 | Low | Data Safety "Finish" on a stuck empty workout silently discarded it. | Offers **Delete Workout** instead. Test: `testStuckEmptyWorkoutOffersDelete`. |
| 9 | Low | Seeded demo partial workout could have nothing done and be discarded. | Seed completes at least one set. |
| 10 | Low | Stale comments in `TodayWorkoutView` about resumable abandoned workouts. | Updated. |

## Not changed (decision for the user)

| # | Finding |
|---|---|
| 6 | Resume a locked partial workout (Today → Resume reopens it), un-complete every set, then stop: it is now discarded, removing a workout that had been recorded history. Consistent with "abandoned workouts are deleted", but it deletes something that was once locked. |

## Data Safety Check moved to Import / Export

- Removed from Settings, with the Settings-tab and row badges.
- Runs after every backup or CSV import (restore first makes the repairs that need no decision) and after creating a backup; opens only when something needs attention.
- Launch no longer runs the import-only auto-repair; it keeps the one-time cleanups and the abandoned-workout purge.
