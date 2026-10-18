# Codebase audit — 2026-10-17

The working tree after commit `1624f8f`, with about 110 files changed or new and all uncommitted. Two read-only agents ran it: **ios-codebase-auditor** (correctness, SwiftData, data integrity, performance, maintainability, tests) and **dead-code-finder**. The test suite stood at 288 passing tests at the time. No code was changed by this audit.

**Verification:**
- **Spot-checked by me:** the debug erase button (`DemoDataView.swift:74-76`), the 12 h filter (`TodayWorkoutView.swift:106-113`), the prefix assumption in reconcile (`CatalogSyncService.swift:144-150`), and `ActiveWorkoutView` being opened only from `CalendarView.swift:75`. All are as described.
- **Everything else** is as reported by the agents, which say they checked each finding in the code unless it is marked *Unverified*.

## Summary

- **Health:** needs targeted cleanup. The core design (versioned routines, snapshot sessions, lock guards, append-only corrections) is sound. The risks are a few data-integrity edges, hot-path performance, and oversized view files.
- **First thing to check:** that the current build opens a store created by the last commit (item H1). Partial evidence: the user has run newer builds on the iPhone today. But fields were added after that (`photoSetInApp`, the per-type rest fields), and a store that fails to open is now fatal.

## High priority

| # | Area | Finding | Failure scenario | Suggested fix |
|---|---|---|---|---|
| H1 | Schema (`Schema.swift:13-21`, `AppContainer.swift:41-58`) | About 50 stored properties were added in place to `WorkoutSchemaV1` (still 1.0.0), and a store that fails to open calls `fatalError`. *Unverified* whether SwiftData opens the existing store. The changes are all additive with defaults, which is the lightweight-migration case. | If it can't open, the app crashes on every launch on the phone. | Install over a build of `1624f8f` in the simulator, plus a fixture test that opens a HEAD `.store`. If it fails: freeze V1 and add V2 with a lightweight stage. |
| H2 | Debug erase (`DemoDataView.swift:72-85`, `DevTools.swift:20-46`) | "DEV: Erase ALL data & reseed" runs on one tap, with no confirmation. Debug builds go onto the phone that holds real history. | One mis-tap deletes every workout, routine, correction and audit event. | Confirmation dialog (plus a typed confirm), or launch-argument only, or remove it. |
| H3 | Stranded workouts (`TodayWorkoutView.swift:106-114`, `DataIntegrityService.swift:350-367`, `CatalogSyncService.swift:101-133`) | An unfinished workout with work done disappears from the Workout tab after 12 h and is never locked. Reconcile keeps rewriting it. | Logged Monday, not finished. Later library edits change its notes, rests, settings snapshots and planned values. | A Data Safety issue with a Finish fix, and/or auto-finish at launch. Exclude it from reconcile. Needs a product decision. |
| H4 | Set reconcile (`CatalogSyncService.swift:144-169`) | Assumes the completed sets are a leading prefix. "Mark not done" on Set 1 after Set 2 breaks that. | Set numbers duplicate ("Set 2" twice) and planned values shift, then get locked into history. | Re-plan by index: keep completed sets where they are and fill only incomplete slots. |
| H5 | Demo cleanup (`DemoDataManager.swift:41-46, 63-87`, `SeedDataService.swift:47-64`) | Only **locked** real workouts on demo routines are kept. An unfinished one with sets logged is hard-deleted. | Log sets on a demo routine, create your own routine. At next launch the logged sets are gone. A possible crash if it's the live session (*Unverified*). | Keep unlocked sessions that have work done (re-tag them as user), and skip the active one. |

## Medium priority

| # | Area | Finding | Suggested fix |
|---|---|---|---|
| M1 | Timer observation (`TodayWorkoutView.swift:27-32, 79-124`, `CalendarView.swift:16, 29-30`) | The tab roots observe the rest and guided timers, so they re-run `body` every second. Each pass scans all sessions; Calendar does it 42 cells × all sessions. | Don't observe what's only called. Narrow the `@Query`. |
| M2 | Sheet fetches in `body` (`SessionExerciseSheet.swift:314, 630, 795-805, 845-847`, `Catalog.swift:471-478`) | Machine list, names and photo are fetched, including multi-MB photo Data, on every timer tick. | Cache them in `@State` and refresh on change. |
| M3 | Restore is O(N²) (`ExportImportService.swift:488-494`) | `exists` / `first` fetch all rows of a type and scan them, for every record. | Build an id→object dictionary per type once. |
| M4 | Launch purge (`WorkoutRepository.swift:320-326`) | Faults in all of history at every launch. | Filter on cheap fields first, ideally in the predicate. |
| M5 | Reconcile scans locked history (`CatalogSyncService.swift:101-107, 177-186`) | Runs on every sheet open and every stepper tap. | Leave out locked sessions in the predicate (*Unverified* that SwiftData supports it). |
| M6 | Guided completion time (`GuidedTimerService.swift:456-458`, `WorkoutRunnerView`) | After a locked-phone catch-up, exercises are marked complete at "now", not at the phase's actual end. | Pass the phase end date into `markExerciseComplete(now:)`. |

## Low priority

| # | Area | Finding |
|---|---|---|
| L1 | `SessionExerciseSheet.swift:155-162` | `photoItem` is never reset, so picking the same photo again after removing it does nothing. |
| L2 | `SessionExerciseSheet.swift:719-729`, `CSVExerciseImporter.swift:358-361` | "Remove photo" isn't sticky: the next sheet import downloads it again (confirm intent). |
| L3 | Weight unit (`SessionExerciseSheet.swift:989, 1011`, `WorkoutHistoryDetailView.swift:206-295`, `SetBuilderSheet.swift:144`, `SessionEditorView.swift:170`) | "lb" is hardcoded in places while others follow the setting. |
| L4 | `SheetScheduleImporter.swift:83, 98` | Routine names are matched case-insensitively across demo and user routines; with duplicates, the first fetched wins. |
| L5 | Create / instance-edit routine sheets (`TodayWorkoutView.swift:171-178`, `CalendarView.swift:85-93`, `RoutineEditorView.swift:436-441`) | Swiping down leaves a saved, unnamed routine or clone. |
| L6 | Save errors (`ImportExportView.swift:275-277`; 76 `try? context.save()` in total) | Failures are silent; an import can report success after a failed save. |
| L7 | `WorkoutHistoryDetailView.swift:302` vs `204-205` | The correction sheet title uses the raw set index ("Correct Set 2" for "Set 1 · Right"). |
| L8 | `SessionEditorView.swift:214-222` | `removeExercises` deletes without detaching first and doesn't recompute status. |
| L9 | Rests | A rest changed during a guided run only applies from the next run. |

## Dead code

| File:line | Unused | Confidence |
|---|---|---|
| `Views/ExerciseMachineEditorView.swift:20` (whole file) | `ExerciseMachineEditorView`: nothing creates it | High |
| `Views/WorkoutComponents.swift:183` | `AddUnplannedExerciseSheet` (and its `Row`) | High |
| `Persistence/WorkoutRepository.swift:409-438` | Name-based `addUnplannedExercise` | High (auditor) |
| `Views/CalendarView.swift:437-445` → `:73-77` and the whole `Views/ActiveWorkoutView.swift` | A sheet with no callers, and the view it opens | High (auditor; `ActiveWorkoutView` is only referenced there) |
| `Views/TodayWorkoutView.swift:306-322, 440` | An empty `resume()` and its card, which can't be reached | High (auditor) |
| `Views/RestCountdownViews.swift:142` | `RestCountdownButton` | High (auditor) |
| `Services/ScheduleService.swift:87` | `scheduledDates(inMonthOf:rules:)` | High |
| `Services/RestTimerService.swift:167` | `endInstant` | High |
| `Services/GuidedTimerService.swift:271` | (as reported by the auditor) | High (auditor) |
| `Models/Enums.swift:103` | `isRecordedHistory` | High |
| `Persistence/DemoDataManager.swift:26` | `private let demoRaw` | High |
| `claude-light-test.txt` (tracked) | A stray file | High (auditor) |

**Checked and not dead:**
- every Theme token;
- `upcomingSummary` (the workout list's rest bar uses it);
- `StretchTiming.transitionSeconds`;
- `CameraPicker` / `photosPicker`;
- `DataHubView`: no references remain.

`setRest(betweenSets:betweenExercises:)` is now used only by tests.

## Duplication

| Where | What | Fix |
|---|---|---|
| `RoutineRepository.swift:168-204, 239-261, 276-298` | The section deep-copy is written 3 times | Extract `copySections(from:to:)` |
| `WorkoutRepository.swift:104-117, 141-152, 478-500`; `CatalogSyncService.swift:118-131` | The machine-setting snapshot is written twice, and the cardio/stretch field snapshot 3 times | Extract `snapshotMachineSettings` and `snapshotGroupFields` |
| `SessionExerciseSheet.swift:540-542` vs `ExerciseKinds.swift:194-196` | A duplicate distance-unit reader | Keep `DistanceUnit.current` |
| about 29 sites | Inline fetch-by-id predicates | Small `ModelContext` fetch helpers |
| `SessionExerciseSheet.swift` (1280 lines), `ExerciseEditorView.swift` (1004 lines) | Oversized views | Split them (higher risk; later) |

## Possible issues to verify

1. H1, the store-open check.
2. Deleting demo data while that demo workout is live: a possible invalidated-model crash.
3. Whether Camera / Choose Photo present reliably from the dialog on a list row, on a device.
4. Backup size and memory with full-resolution photos embedded as base64.
5. Main-thread image decoding during photo download for a sheet import.

## Test gaps

- No test opens an existing on-disk store.
- Reconcile after a non-prefix completion.
- Unfinished past-day workouts.
- Demo cleanup with an unlocked real session.
- Guided background catch-up timestamps.
- Restore performance with about 5k sets.
- Schedule import with duplicate or demo routine names.
- No UI tests at all.

## Recommended order

1. **Batch 1 (safe):** H1 check. H2 confirmation. Remove the dead code. L1, L7.
2. **Batch 2 (targeted):** M1–M4. Duplication helpers. L3–L6.
3. **Batch 3 (needs approval / product decisions):** H3, H4, H5, M5, M6. A V2 schema if H1 fails. Splitting the large views.

## What not to change

- The lock guards and the snapshot-on-start logic.
- The routine versioning rules.
- The append-only corrections.
- The ordering of the sheet import's scratch dry run and `processPendingChanges`.
- The replan index math, which is covered by GuidedReplanTests.
- The no-auto-delete store policy.

---

## Fixes applied (2026-10-17, same day)

The user asked to "fix all". A snapshot of the tree before the fixes is at `/private/tmp/claude-501/-Users-john-Documents-Claude-Projects-WorkoutApp/64d25f8e-5143-4e6b-88d5-b681f2e682fe/scratchpad/worktree-before-audit-fixes.tgz`.

**Results:**
- **Full suite:** 294 tests pass (288 before, plus `AuditFixesTests` (5) and 1 extra schedule test).
- **Launch:** the fixed build launches on a simulator over a database created by `1624f8f` and upgraded.
- **Commit:** nothing is committed.

| # | Status | What was done |
|---|---|---|
| H1 | **Verified OK** | On a fresh simulator: `1624f8f` was built, launched and seeded (2 routines, 5 exercises). The current build was installed over it: it opened, kept the data, and SwiftData added the new columns. No V2 was needed for the current fields. A permanent fixture test that opens an old store was **not** added (optional follow-up). |
| H2 | Fixed | The debug erase asks first: a confirmation dialog that names what is deleted. |
| H3 | Fixed (chosen default; reworked after review) | Older unfinished workouts with work logged are listed at the top of the Workout tab's day list ("Unfinished from Tue, Oct 14 — 2/5 exercises"), with Resume, which makes that one the live workout (`resume()` was empty). They never take the place of today's workout, and starting a workout clears a Resume pick. No auto-finish. |
| H4 | Fixed | `reconcileStrengthSets` re-plans by position: done sets keep their place and values, other positions take that position's prescription, and the result is renumbered with no gaps. Test added. |
| H5 | Fixed | Demo cleanup keeps every unfinished workout on a demo routine (the seed only creates finished ones) as the user's. After review: `removeExerciseFromActiveSessions` no longer removes an exercise with logged work, so a later library clean-up can't take it. Test added. |
| M1 | Fixed | Calendar no longer observes the timers. The Workout tab uses the non-observing `TimerCommands` environment value, which is `Equatable` by identity, so the app's per-tick body run doesn't count as a change. |
| M2 | Fixed | The exercise sheet caches its machines, names and photos (`loadMachinesAndPhotos`, run after the open-time reconcile) instead of fetching per render. |
| M3 | Fixed | Restore uses per-type id dictionaries, kept current by `add` (all 17 inserts). Test added. |
| M4 | Fixed | The launch purge filters in the store first (`completedAt == nil` or abandoned), then by date, then loads only those left. |
| M5 | Fixed | Reconcile reaches workout exercises through unlocked workouts only. |
| M6 | Fixed | The guided timer records `lastExerciseEndedAt`, and exercises are marked complete at that time. Test added. |
| L1 | Fixed | The photo picker selection is reset after loading. |
| L2 | Fixed (chosen default) | Removing a photo in the app sticks; sheet imports don't bring it back. |
| L3 | Fixed | `WeightUnit.current` is used for every weight label; the duplicate distance-unit reader is removed. |
| L4 | Fixed | The Schedule tab prefers the user's routines; a name shared by two of them is a row error. Test added. |
| L5 | Fixed | Swipe-down is disabled while creating a routine or calendar clone (Cancel discards). |
| L6 | Fixed (key paths) | Backup restore and the CSV and sheet imports `try` their save and report a failure. If saving Finish/Stop fails, the Workout tab shows "Workout not saved" with Try Again; the runner itself can't, since it goes away with the finish. Other `try? save()` sites are unchanged. |
| L7 | Fixed | The correction sheet title uses the row's per-side numbering. |
| L8 | Fixed | Removing exercises in Edit Workout detaches before deleting and recomputes the status. |
| L9 | Fixed (partly) | Rests changed mid-run update the get-readies and rests not yet started (0 drops them). A rest turned on from None applies from the next run. Test added. |
| Dead code | Removed | `ExerciseMachineEditorView.swift`, `ActiveWorkoutView.swift` (and Calendar's unreachable cover and `start`), `AddUnplannedExerciseSheet`, the name-based `addUnplannedExercise`, `RestCountdownButton`, `scheduledDates(inMonthOf:)`, `endInstant`, `isRecordedHistory`, `demoRaw`, `GuidedTimerService.previous`. |
| Dead code | **Not removed** | `claude-light-test.txt` (repo root, "Blink(1) test"). It isn't code and may belong to the status-light hook; left for the user to decide. |
| Duplication | Fixed | `RoutineRepository.copySections`, `WorkoutRepository.snapshotMachineSettings` and `WorkoutSessionExercise.snapshotGroupFields` replace the copies. |
| Duplication | **Not done** | About 29 inline fetch-by-id predicates were left as they are: the gain is small, and generic `#Predicate` helpers are a translation risk. Splitting `SessionExerciseSheet` (about 1300 lines) and `ExerciseEditorView` was **not** done: it's a large refactor with UI regression risk and no device testing. |

### Review of the fixes (swift-reviewer)

The first review found these problems in the first round of fixes; all are now fixed:

1. **H3, first version:** an old unfinished workout could take over the Workout tab and hide today's workout and its auto-start. → Reworked as above.
2. **H3:** the Resume card couldn't be reached. → Older unfinished workouts are now listed in the day list.
3. **L6:** the finish-save alert **had not actually been applied**. Its edit was skipped because a preceding command in the same shell chain failed, and the first version of this report wrongly said it was done. → Applied and confirmed in the file; every other fix was re-checked by a marker search.
4. **H5:** a kept workout's logged work could later be removed by the library clean-up. → `removeExerciseFromActiveSessions` keeps exercises with work.
5. **M2:** the cache was loaded before the reconcile that can change the machine. → Load order fixed.
6. **M1:** `TimerCommands` wasn't `Equatable`. → Equatable by identity.

After these fixes: 294 tests pass.

### Second review (swift-reviewer) and fixes

1. **Deleting an unfinished earlier-day workout changed today's schedule.** It added an exception for today, or ended the recurrence. → An earlier-day workout is now just deleted; today's schedule is untouched.
2. **The finish-save alert could never show.** The runner is removed as the workout locks in memory. → The alert moved to the Workout tab ("Workout not saved", Try Again / Later); the runner reports the failure through `onSaveFailed`.
3. **Data Safety check 7 kept failing after "Remove from Routines"** for an exercise with logged work, which is now kept. → Exercises with work logged in an unfinished workout aren't counted as a problem.

**Not changed:**
- **P2:** today's scheduled routine doesn't auto-start right after a resumed or finished workout ends, because the `.task` id doesn't change. This behaviour predates the fixes; auto-starting a second workout straight after finishing one may be unwanted anyway.
- **P3, plausible:** a second unlocked workout from just before midnight could be hidden for up to 12 h. No way to create one was found.
- **P3:** set drafts load before the open-time reconcile. Pre-existing, and the fallback is the planned values.

**Final state:**
- 294 tests pass.
- The fixed build launches on a simulator over a database upgraded from `1624f8f`.
- The temporary simulator and the `1624f8f` checkout were removed.
- Nothing is committed.
