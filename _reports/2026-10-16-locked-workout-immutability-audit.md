# Locked-workout immutability audit

Date: 2026-10-16
Auditor: ios-codebase-auditor subagent (read-only). I re-checked F1, F2, F3 and F5 in the code myself.

**Rule (from the user):** "historic data to not be affected by current definitions of exercises and routines. A locked workout will hold the values it had when it was locked forever."

**Exceptions:** corrections (WorkoutCorrectionEvent, append-only) and a delete the user asks for.

## Findings
| # | Severity | Status | Finding |
|---|---|---|---|
| F1 | High | Verified | **Resume unlocks a stopped (partial) workout and lets current definitions overwrite it.** `WorkoutRepository.reopen` (WorkoutRepository.swift:377-383) clears `lockedAt`/`completedAt`/`endedAt`. Today's Resume button calls it (TodayWorkoutView.swift:96, 436-441); so does Data Safety's resume repair (DataIntegrityService.swift:578-580). The next reconcile (CatalogSyncService.swift:76-101, 155-184) then rewrites notes, machine, structure fields and machine settings, even on exercises already completed, and deletes the session exercise if the exercise has left the library. The UI says stopping locks it permanently (WorkoutRunnerView.swift:134, WorkoutComponents.swift:370). |
| F2 | Medium | Verified | **Restoring a backup can add rows to an existing locked workout.** The session is skipped when it exists (ExportImportService.swift:361), but its exercises, sets and settings are inserted whenever their own id is missing (:367-406). Rows deleted mid-workout come back. |
| F3 | Med-High | Verified | **Demo cleanup deletes real workouts that were run on demo routines.** Sessions take their source from the routine (WorkoutRepository.swift:36-38). At launch, `reconcileDemoData` deletes all demo data once user data exists (SeedDataService.swift:50-60, DemoDataManager.swift:40). The footer says "Your own workouts are never touched". |
| F4 | Low-Med | Verified | **History shows distance in the current Settings unit,** so 5 mi becomes "5 km" after a switch (WorkoutHistoryDetailView.swift:159, 169-170). There is no conversion; it is a label change. |
| F5 | High (Debug only) | Verified | **Debug builds wipe the whole store when it fails to open** after a model change (AppContainer.swift:51-66). Release builds are protected (they stop with an error instead). It only matters if Debug builds are installed on the phone holding real history. |
| F6 | Low | Verified | **Exercise edits update the active routine version in place even when a locked workout references it** (CatalogSyncService.swift:49-69). Nothing shown or exported for a locked workout reads its routine version, so nothing visible changes. |
| F7 | Low | Verified / suspected | **Data Safety's "Finish Workout" repair re-finishes a locked-but-unfinished workout**; it is user-initiated and only fixes a broken state. **`purgeDiscardedWorkouts`** (WorkoutRepository.swift:321-334) may delete a restored v1 locked "abandoned" cardio/stretch workout as "nothing done" (suspected, not verified). |
| F8 | Low | Verified | **Four session-setting repository methods and SessionEditorView's edits don't check the lock themselves.** They can't be reached for a locked workout today. |
| F9 | Low | Suspected unreachable | **SessionExerciseSheet's locked mode reads live photo, notes, machine name and machine list** (:248, 543-571, 672-675, 713-714). The sheet never opens on a locked workout today. |

## Clean
- **Cascades:** no catalog→session relationship exists, so deleting a catalog item can't cascade into history.
- **Bulk session writes:** every reconcile, migration, prune, import and editor path checks `isLocked`.
- **Display:**
  - The history detail, calendar and Today cards read only the session's own snapshot (apart from F4).
  - Export reads snapshots only.
  - Corrections are append-only.

## Proposed fixes (not applied)
- **F1:** a decision is needed.
  - (a) No Resume once a workout is stopped; stopped is final, as the UI says.
  - (b) Keep Resume, but freeze everything already recorded. A workout that was ever locked never takes catalog changes on its completed work, and keeps its original end time.
- **F2:** only insert session children whose session was created by this restore.
- **F3:** a decision is needed.
  - Keep locked workouts that have completed work out of demo cleanup (re-tag them as the user's own).
  - Or ask before cleaning up.
- **F4:** save the distance unit on the workout when it starts and show that unit; existing workouts default to mi.
- **F5:** wipe only with the explicit `--reset-store` launch argument.
- **F6:** fork a new routine version before reconcile edits one that a locked workout references, so the rule holds literally.
- **F7–F9:** add lock guards in the repository and the sheet, and keep v1 restores from being purged.
- **Tests:**
  - reopen then reconcile (F1)
  - restore after a mid-workout delete (F2)
  - demo cleanup with a locked real workout (F3)
  - unit switch (F4)

## Decisions (user)
- F1: (a). Stopped is final; a locked workout is never reopened.
- F3: yes. A real workout done on a demo routine becomes the user's and survives demo cleanup.
- Rule, from the user: "A locked workout will hold the values it had when it was locked forever."

## Outcomes
| # | Outcome |
|---|---|
| F1 | **Fixed.**<br>• Today shows a locked workout's card ("Workout complete" or "Workout stopped") with View Summary and no Resume (TodayWorkoutView.swift).<br>• `reopen` refuses locked workouts.<br>• Data Safety offers only Finish or Delete for "Locked but never finished". |
| F2 | **Fixed.** Restore adds exercises, sets, settings and corrections only under workouts it created. |
| F3 | **Fixed.**<br>• `DemoDataManager.keepRealWorkouts` re-tags real locked workouts and their corrections (matched by id) as the user's.<br>• A seeded workout is recognised by equal start and end times.<br>• Footer text updated. |
| F4 | **Fixed.**<br>• New `WorkoutSession.distanceUnitRaw`, set at lock; a re-lock keeps it.<br>• Launch and restore backfill older workouts with the current unit.<br>• Backups carry it.<br>• History displays it. |
| F5 | **Fixed.** No build wipes the store on its own; only `--reset-store` (Debug) does. |
| F6 | **Fixed.**<br>• Reconcile changes only routine rows that differ from the library.<br>• When a workout used the active version, it saves a new version first.<br>• The routine editor matches a newly added row to the library at once and stops editing a version that sync replaced. |
| F7 | **Partly fixed.**<br>• Data Safety's finish repair is unchanged (user-initiated, broken state only).<br>• Purge: a guard was tried and reverted. It contradicted the existing tested behaviour of dropping empty abandoned workouts from old backups, and the risk was only suspected. |
| F8 | **Fixed.** Lock checks added to the four session-setting methods and to SessionEditorView's edits. |
| F9 | **Not changed.** The sheet never opens on a locked workout. |

## Follow-up review (swift-reviewer): NEEDS-WORK (minor)
- **Fixed:**
  - Extra version forks from editor defaults.
  - Corrections without a session relationship were lost during demo cleanup.
  - A real workout missing a timestamp was treated as seeded.
  - The routine editor stayed pinned to a replaced version.
  - Re-lock overwrote the recorded unit.
  - Restore could add corrections to existing workouts.
  - Stale comment in TodayWorkoutView.
- **Not changed:**
  - `removeMachineEverywhere` (DataIntegrityService.swift:635-639) and the migration's `repoint` edit routine rows in versions workouts used. Session data is guarded, so history is unaffected.
  - Data Safety check 3 (info only) will list kept demo-routine workouts, whose routine versions were deleted.
  - Weight is hard-coded as "lb" in history. It would need the same freezing if it ever used the weight-unit setting.

## Verification
- Full suite: 225/225 pass.
- Simulator upgrade check: a store written by the previous build opened under the new build without a crash. The `ZDISTANCEUNITRAW` column was added, and both locked workouts were backfilled "mi". A copy of that store was kept in the session scratchpad.
