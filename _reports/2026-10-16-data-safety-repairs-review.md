# Data Safety repairs review — 2026-10-16

Scope: badges (RootView, SettingsView), action/info split, DataSafetyRepair (auto-repair + per-record fixes), DataSafetyCheckView rewrite, restore keeping the device's active version. Reviewed by the swift-reviewer subagent; findings verified against the cited code before fixing.

Verdict before fixes: NEEDS-WORK. After fixes: full suite 119/119 passing (iPhone 17 Pro simulator).

## Fixed

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | Medium | "Finish Workout" on a locked, unfinished workout skipped the status recompute (`recomputeStatus` returns early when locked, `WorkoutRepository.swift:254`), so a workout with sets done went into history still marked in progress. | Unlock, finish at the original lock time, lock reapplied. Test: `testFinishLockedWorkoutWithSetsDoneGetsRealStatus`. |
| 2 | Medium | "Remove from Routines" and "Remove Machine" call cascades that skip only *locked* sessions, so a finished-but-unlocked workout could be changed. | `apply()` locks finished workouts first (shared `lockFinishedWorkouts`). Test: `testFixesLeaveFinishedUnlockedWorkoutAlone`. |
| 3 | Medium | `runAll()` ran on every tab change; check 4 loaded every set of every finished workout. | Badge refreshes at launch, on returning to the foreground, when Settings appears, and on the check screen — not on every tab change. Check 4 fetches only bad sets by predicate. Test: `testBadPlannedValuesFoundByPredicate`. |
| 4 | Low | "Remove Machine" did nothing for a soft-deleted exercise still planned somewhere. | Machine stripped from soft-deleted exercises too; the replacement is never the removed machine. Test: `testRemoveMachineFromDeletedExerciseStillPlanned`. |
| 5 | Low | "Remove Machine" left that machine's default sets, and its settings on a workout in progress left with no machine. | Both removed; ad hoc settings stay. Test: `testRemoveMachineDropsItsDefaultSetsAndOpenSettings`. |
| 6 | Low | A workout with two problems produced two issues with the same id. | Id suffix. Test: `testWorkoutWithTwoProblemsHasUniqueIssueIds`. |
| 7 | Low | Fix button shown for failures it could not fix: a restored correction without its relationship, a routine with no versions. | Auto-repair matches corrections by session id; a version-less routine is listed with **Delete Routine** and is not auto-fixable. Tests: `testCorrectionWithoutRelationshipTakesSessionSource`, `testRoutineWithNoVersionsOffersDelete`. |
| 8 | Low | Row badge stale after Import or Delete Demo Data inside Settings. | Settings refreshes the badge when it appears. |
| 10 | Low | Fix buttons in one List row used `.bordered`; project rule requires `.borderless`. | `.borderless` with a tinted capsule background. |

## Follow-ups (same day)

| # | Finding | Resolution |
|---|---|---|
| 3b | Launch ran three full-store passes in `App.init`. | Measured on the Oct 16 backup (30 workouts, 468 sets, simulator): prune ≈ 85–95 ms, duplicate-set cleanup ≈ 70 ms, auto-repair ≈ 25 ms, `runAll()` ≈ 60 ms. Prune and dedupe clean up damage whose cause is fixed, so launch now runs them once per `CatalogSyncService.cleanupVersion` (UserDefaults); every import still runs them. Auto-repair stays every launch. Later damage surfaces in the Data Safety Check (check 7: Restore to Library / Remove from Routines) instead of being removed silently. Tests: `LaunchCleanupTests`. |
| 9 | `DataHubView` would crash if used. | Deleted — unreferenced, and its three links all exist in Settings. |
| 11 | Auto-repair audit entry logged as `.user` during demo seeding. | Auto-repair skipped when restoring with `logImport: false` (demo seeding). Test: `testDemoSeedingLogsNoRepairs`. |

Not changed: `removeDuplicatePlannedSets` edits old versions past workouts point to — acceptable, history is drawn from each session's own copy.

Full suite after follow-ups: 122/122 passing.
