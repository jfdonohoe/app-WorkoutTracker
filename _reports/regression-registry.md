# Regression registry

Every fixed bug, the shape its fix must keep, and the test that pins it. `regression-reviewer` checks each **fixed** row after every revision. The main session keeps this file current:
- **When a fix lands:** add a row with its fix, location and pinning test.
- **When a pinning test is renamed:** update the row.
- **After each full run:** update the test count.

**Last full run:** 2026-10-18, after the O-012/O-014 decisions (regression-reviewer: PASS): 307 tests, 307 passed, 0 failed, 0 skipped (306 before, plus the R-169 pin).

**Conventions:**
- Locations are relative to `WorkoutTracker/`. Tests are in `WorkoutTrackerTests/`.
- "Fix" describes the shape to keep.
- Statuses:
  - **fixed**: check it
  - **open**: known bug, not fixed
  - **accepted**: deliberate
  - **superseded**: the code was later removed or replaced on purpose

**How this was built:** seeded on 2026-10-18 from the review reports dated 2026-09-08 to 2026-10-17. At that point:
- every fixed row still had its fixed shape in the code (checked by reading, not by running)
- every test named here existed

## Fixed

| ID | Fix | Location | Pinning test | Status | Source |
|---|---|---|---|---|---|
| R-001 | Backups keep cardio and stretching results (completion, times, duration, intensity, hold, sides, rounds) | Services/ExportImportService.swift:76-100, :202, :402-413 | ExportCompletenessTests › test18_nonSetExerciseResultsSurviveRoundTrip | fixed | 2026-09-08-export-data-loss |
| R-002 | Backups keep and restore the audit log | Services/ExportImportService.swift:43, :232, :459-463 | ExportCompletenessTests › test19_auditLogSurvivesRoundTrip | fixed | 2026-09-08-export-data-loss |
| R-003 | An older v1 backup still imports, using model defaults | Services/ExportImportService.swift:402-413 | ExportCompletenessTests › test20_version1BackupStillImports | fixed | 2026-09-08-export-data-loss |
| R-004 | Re-importing a backup doesn't duplicate audit events | Services/ExportImportService.swift:460 | ExportCompletenessTests › test21_reimportDoesNotDuplicateAuditEvents | fixed | 2026-09-08-export-data-loss |
| R-005 | The guided timer advances or closes the sheet only when the open sheet is the exercise it just finished | Views/WorkoutRunnerView.swift:257, :268-271 | none | fixed | 2026-10-07-guided-timers |
| R-006 | "Create a routine" starts the workout only after the editor sheet closes | Views/TodayWorkoutView.swift:196-197, :201 | none | fixed | 2026-10-07-guided-timers |
| R-007 | Closing a sheet-presented workout stops its guided run and unhooks its callbacks | Views/WorkoutRunnerView.swift:167-172; Views/TodayWorkoutView.swift:262 | none | fixed | 2026-10-07-guided-timers |
| R-008 | Duration, hold, reps and timer steppers are locked while the exercise is in a guided run | Views/SessionExerciseSheet.swift:243, :387 | none | fixed | 2026-10-07-guided-timers |
| R-009 | Making an untimed stretch timed caps its rounds at 20 | Views/SessionExerciseSheet.swift:381, :467 (ExerciseEditorView: only `PickRange.rounds = 1...20`, Models/ExerciseKinds.swift:174) | none | fixed | 2026-10-07-guided-timers |
| R-010 | Rest beeps play again after an audio interruption | Services/SoundCues.swift:61 | none | fixed | 2026-10-07-guided-timers |
| R-011 | The machine picker hides an unlinked stored machine; the set builder falls back to the default machine | Views/SessionExerciseSheet.swift:808-811, :840; Views/SetBuilderSheet.swift:248-251 | none | fixed | 2026-10-07-guided-timers |
| R-012 | Switching to a deleted machine is refused | Persistence/WorkoutRepository.swift:491-493 | MultiMachineAndGuidedTests › testSwitchToDeletedMachineIsRefused | fixed | 2026-10-07-guided-timers |
| R-013 | A workout deleted from anywhere isn't auto-started again that day | Views/TodayWorkoutView.swift:146-150 | none | fixed | 2026-10-08-workout-tab |
| R-014 | When the live workout disappears, its rest and guided timers stop | Views/TodayWorkoutView.swift:175-179 | none | fixed | 2026-10-08-workout-tab |
| R-015 | A workout running past midnight stays live and blocks the next day's auto-start | Views/TodayWorkoutView.swift:116-128, :478 | none | fixed | 2026-10-08-workout-tab |
| R-016 | The summary after Save & Exit appears after a 500 ms delay so it isn't dropped | Views/TodayWorkoutView.swift:269 | none | fixed | 2026-10-08-workout-tab |
| R-017 | A stretch routine row rejects setK_reps/setK_weight instead of dropping them | Services/CSVExerciseFields.swift:160-162; Services/CSVRoutineImporter.swift:349, :363 | CSVKindImportTests › testStretchRowInRoutineRejectsSetColumns | fixed | 2026-10-16-csv-kind-import |
| R-018 | A steady row with a blank duration doesn't set the cardio section length | Services/CSVRoutineImporter.swift:375-378 | CSVKindImportTests › testSteadyRowWithBlankDurationLeavesSectionLengthUnset | fixed | 2026-10-16-csv-kind-import |
| R-019 | A routine row whose kind differs from the library exercise is rejected | Services/CSVRoutineImporter.swift:350-353 | CSVKindImportTests › testRoutineKindMustMatchLibraryExercise | fixed | 2026-10-16-csv-kind-import |
| R-020 | A row with no kind that fills new-structure columns is an error | Services/CSVExerciseFields.swift:130-135 | CSVKindImportTests › testRowWithoutKindRejectsCurrentColumns | fixed | 2026-10-16-csv-kind-import |
| R-021 | Filling both effort and intensity is an error | Services/CSVExerciseFields.swift:210-212 | CSVKindImportTests › testEffortAndIntensityTogetherIsAnError | fixed | 2026-10-16-csv-kind-import |
| R-022 | Unused setting columns on a stretch row are reported only once | Services/CSVExerciseImporter.swift:249-252 | none | fixed | 2026-10-16-csv-kind-import |
| R-023 | Import footers list the current routine columns and per_side_custom | Views/ImportExportView.swift:67-71, :229 | none | fixed | 2026-10-16-csv-kind-import |
| R-024 | A blank setK_weight on a kinded routine row counts as 0 | Services/CSVRoutineImporter.swift:367-368 | CSVKindImportTests › testBlankSetWeightIsZeroForKindsWithoutWeight | fixed | 2026-10-16-csv-kind-import |
| R-025 | A workout restored from a backup with no audit log passes the audit-log check | Services/DataIntegrityService.swift:422-425 | DataSafetyCheckTests › testRestoreWithoutAuditLogPasses | fixed | 2026-10-16-data-safety-check |
| R-026 | Re-logging a set on a reopened, corrected workout isn't flagged "original overwritten" | Services/DataIntegrityService.swift:198-199 | DataSafetyCheckTests › testReopenedCorrectedWorkoutRelogIsNotOverwrite | fixed | 2026-10-16-data-safety-check |
| R-027 | Any workout with a completion time counts as recorded history | Services/DataIntegrityService.swift:111-112 | DataSafetyCheckTests › testCompletedButUnlockedSessionFails | fixed | 2026-10-16-data-safety-check |
| R-028 | The active-version check names each routine and its count | Services/DataIntegrityService.swift:313 | none (testRoutineWithTwoActiveVersionsFails asserts only `passed`) | fixed | 2026-10-16-data-safety-check |
| R-029 | The check run fetches routines, exercises, machines and audit events once | Services/DataIntegrityService.swift:94-97 | none | fixed | 2026-10-16-data-safety-check |
| R-030 | The in-progress-with-deleted-exercise test asserts that the check fails | (test fix) | DataSafetyCheckTests › testWorkoutInProgressWithDeletedExerciseFails | fixed | 2026-10-16-data-safety-check |
| R-032 | "Finish Workout" on a locked, unfinished workout gives it its real status at the original lock time | Services/DataIntegrityService.swift:579-587 | DataSafetyRepairTests › testFinishLockedWorkoutWithSetsDoneGetsRealStatus | fixed | 2026-10-16-data-safety-repairs |
| R-033 | Fixes lock finished-but-unlocked workouts first, so the cascades can't change them | Services/DataIntegrityService.swift:561-568, :573 | DataSafetyRepairTests › testFixesLeaveFinishedUnlockedWorkoutAlone | fixed | 2026-10-16-data-safety-repairs |
| R-034 | The bad-planned-values check loads only the bad sets | Services/DataIntegrityService.swift:151-153 | DataSafetyRepairTests › testBadPlannedValuesFoundByPredicate | fixed | 2026-10-16-data-safety-repairs |
| R-036 | "Remove Machine" also covers soft-deleted exercises and never picks the removed machine as replacement | Services/DataIntegrityService.swift:621-623, :632-635 | DataSafetyRepairTests › testRemoveMachineFromDeletedExerciseStillPlanned | fixed | 2026-10-16-data-safety-repairs |
| R-037 | "Remove Machine" drops that machine's default sets and its open-workout settings | Services/DataIntegrityService.swift:624-628, :645-651 | DataSafetyRepairTests › testRemoveMachineDropsItsDefaultSetsAndOpenSettings | fixed | 2026-10-16-data-safety-repairs |
| R-038 | A workout with two problems gets two distinct issue ids | Services/DataIntegrityService.swift:370, :461-463 | DataSafetyRepairTests › testWorkoutWithTwoProblemsHasUniqueIssueIds | fixed | 2026-10-16-data-safety-repairs |
| R-039 | Auto-repair matches corrections by session id when the relationship is missing | Services/DataIntegrityService.swift:534-539 | DataSafetyRepairTests › testCorrectionWithoutRelationshipTakesSessionSource | fixed | 2026-10-16-data-safety-repairs |
| R-040 | A routine with no versions offers Delete Routine and isn't auto-fixable | Services/DataIntegrityService.swift:306, :317-319, :606-608 | DataSafetyRepairTests › testRoutineWithNoVersionsOffersDelete | fixed | 2026-10-16-data-safety-repairs |
| R-042 | Fix buttons in one list row use `.borderless` with a tinted capsule | Views/DataSafetyCheckView.swift:149-151, :156 | none | fixed | 2026-10-16-data-safety-repairs |
| R-043 | Launch runs the prune and duplicate-set cleanups once per cleanup version | Persistence/CatalogSyncService.swift:301-318; App/WorkoutTrackerApp.swift:49 | LaunchCleanupTests › testCleanupsRunOnceThenSkip; › testCleanupsRunAgainAfterVersionBump | fixed | 2026-10-16-data-safety-repairs |
| R-044 | The crash-prone Data Hub screen stays deleted | Views/DataHubView.swift absent, no references | none | fixed | 2026-10-16-data-safety-repairs |
| R-045 | Demo seeding logs no auto-repair entry | Services/ExportImportService.swift:477-480; Services/SeedDataService.swift:85 | LaunchCleanupTests › testDemoSeedingLogsNoRepairs | fixed | 2026-10-16-data-safety-repairs |
| R-046 | Copying a demo routine keeps it demo | Persistence/RoutineRepository.swift:231 | AbandonedAndDemoSeparationTests › testCopyOfDemoRoutineStaysDemo | fixed | 2026-10-16-discard-and-demo |
| R-047 | Empty unfinished workouts from an earlier day are purged at launch; today's are kept | Persistence/WorkoutRepository.swift:316-321; App/WorkoutTrackerApp.swift:54 | AbandonedAndDemoSeparationTests › testEmptyWorkoutLeftOpenOnEarlierDayIsPurged; › testTodaysEmptyWorkoutInProgressIsKept | fixed | 2026-10-16-discard-and-demo |
| R-049 | The purge never deletes a workout with anything done, whatever its label | Persistence/WorkoutRepository.swift:319 | AbandonedAndDemoSeparationTests › testOpenWorkoutWithASetDoneIsNeverPurged | fixed | 2026-10-16-discard-and-demo |
| R-050 | A workout discarded today stays hidden until tomorrow, so it isn't auto-started again | Persistence/WorkoutRepository.swift:277-283, :319; Views/TodayWorkoutView.swift:146-150 | AbandonedAndDemoSeparationTests › testFinishingWithNothingDoneDiscardsTheWorkout | fixed | 2026-10-16-discard-and-demo |
| R-051 | Schedules for demo routines are demo and go with Delete Demo Data (Calendar, editor, schedule sheet) | Views/CalendarView.swift:117, :283; Views/RoutineEditorView.swift:311; Views/ScheduleWorkoutSheet.swift:231 | AbandonedAndDemoSeparationTests › testScheduleForDemoRoutineIsDemoAndGoesWithIt | fixed (sheet import path: R-165) | 2026-10-16-discard-and-demo |
| R-052 | Discarded or deleted workouts don't force a new routine version | Persistence/RoutineRepository.swift:128-138 | none | fixed | 2026-10-16-discard-and-demo |
| R-053 | Data Safety offers Delete Workout, not Finish, for a stuck empty workout | Services/DataIntegrityService.swift:452 | DataSafetyRepairTests › testStuckEmptyWorkoutOffersDelete | fixed | 2026-10-16-discard-and-demo |
| R-054 | The seeded demo partial workout always has a set done | Services/SeedDataService.swift:142-143 | none | fixed | 2026-10-16-discard-and-demo |
| R-055 | Data Safety Check runs only around imports and backup creation, not at launch or in Settings | Views/ImportExportView.swift:249-260, :278, :299, :370, :393; Services/ExportImportService.swift:480 | none | fixed | 2026-10-16-discard-and-demo |
| R-056 | Exercises sharing one machine each get their own copy; finished workouts keep the original | Persistence/ExerciseStructureMigration.swift:50, :85 | ExerciseStructureMigrationTests › SharedMachineSplitTests.testSharedMachineIsCopiedForTheSecondExercise | fixed | 2026-10-16-exercise-structure |
| R-057 | Editing sets in Edit Workout doesn't double per-side sets | Views/SessionEditorView.swift:115-117, :131 | WorkoutPlaybackTests › testPerSideSetsReadBackOncePerSet (read-back half only) | fixed | 2026-10-16-exercise-structure |
| R-058 | Edit Workout doesn't write a per-exercise rest | Views/SessionEditorView.swift:124-133 | none | fixed | 2026-10-16-exercise-structure |
| R-059 | Workout rows and history show each kind's own fields and "Set n · Side" | Views/SessionEditorView.swift:167; Views/WorkoutRunnerView.swift:207; Views/WorkoutHistoryDetailView.swift:164-170, :205 | WorkoutPlaybackTests › testUpNextSummaries (summary text only) | fixed | 2026-10-16-exercise-structure |
| R-060 | The editor keeps an exercise photo on the machine; Distance leaves machine photo and settings alone | Views/ExerciseEditorView.swift:834, :888-891, :901 | none | fixed | 2026-10-16-exercise-structure |
| R-062 | Editing a non-set exercise never rebuilds a set-based exercise's default sets | Views/SessionExerciseSheet.swift:580 | none | fixed | 2026-10-16-exercise-structure |
| R-063 | A logged distance counts as something done (`hasAnythingDone`) | Models/WorkoutSession.swift:119 | none | fixed (status rule: R-157) | 2026-10-16-exercise-structure |
| R-064 | Skip on the last exercise just closes the sheet | Views/SessionExerciseSheet.swift:591-597 | none | fixed | 2026-10-16-exercise-structure |
| R-065 | A 0-minute Steady can still be completed | Views/SessionExerciseSheet.swift:527 | none | fixed | 2026-10-16-exercise-structure |
| R-066 | Deleting an editor machine block can't hit a stale index | Views/ExerciseEditorView.swift:509-511 | none | fixed | 2026-10-16-exercise-structure |
| R-067 | The hold countdown ticks only while running; Start is disabled for 0 s | Views/SessionExerciseSheet.swift:1282, :1294 | none | fixed | 2026-10-16-exercise-structure |
| R-068 | Two buttons in one list row use `.borderless` | Views/SessionExerciseSheet.swift:422, :431 | none | fixed | 2026-10-16-exercise-structure |
| R-069 | The migration ignores deleted machines when choosing Machine vs Bodyweight | Persistence/ExerciseStructureMigration.swift:140 | none | fixed | 2026-10-16-exercise-structure |
| R-070 | A no-kind row that runs before the kind row uses that row's definition | Services/CSVRoutineImporter.swift:278-280, :509 | CSVKindImportTests › testRowWithoutKindRunBeforeTheKindRowUsesItsDefinition | fixed | 2026-10-16-routine-order-import |
| R-071 | Two different kinds for one exercise in the file is an error | Services/CSVRoutineImporter.swift:354-356 | CSVKindImportTests › testTwoKindsForOneExerciseInTheFileIsAnError | fixed | 2026-10-16-routine-order-import |
| R-072 | A cardio section's length comes from the first row that gives a duration | Services/CSVRoutineImporter.swift:620-621 | CSVKindImportTests › testCardioSectionLengthComesFromTheFirstRowWithADuration | fixed | 2026-10-16-routine-order-import |
| R-073 | Order problems are reported with the other row errors | Services/CSVRoutineImporter.swift:275-277, :297, :464-478 | CSVKindImportTests › testOrderProblemsAreReportedWithOtherRowErrors | fixed | 2026-10-16-routine-order-import |
| R-074 | Routines help text says "every row or none" for order | Views/ImportExportView.swift:229 | none | fixed | 2026-10-16-routine-order-import |
| R-075 | A workout that did different sets turns Vary by set on, so the next save doesn't flatten them | Persistence/ExerciseStructureMigration.swift:219-222 | VaryBySetTests › testWorkoutWithDifferentSetsTurnsVaryOn | fixed | 2026-10-16-vary-by-set |
| R-076 | Changing Type while varying carries the shown sets into an empty list | Views/ExerciseEditorView.swift:393-400 | none | fixed | 2026-10-16-vary-by-set |
| R-077 | Saving an empty set list uses the machine's or exercise's weight, not 0 | Views/ExerciseEditorView.swift:917-923 | none | fixed | 2026-10-16-vary-by-set |
| R-078 | The "Use set 1 for every set" message reads correctly | Views/ExerciseEditorView.swift:419-425 | none | fixed | 2026-10-16-vary-by-set |
| R-079 | The Hold summary reads "3 × 1 · hold 30s" | Views/WorkoutPeekSheet.swift:71 | WorkoutPlaybackTests › testUpNextSummaries | fixed | 2026-10-16-vary-by-set |
| R-080 | The migration turns Vary on when machines have different set counts | Persistence/ExerciseStructureMigration.swift:152-154 | VaryBySetTests › testMigrationVariesWhenMachinesHaveDifferentSetCounts | fixed | 2026-10-16-vary-by-set |
| R-081 | Range text says "1 rep", not "1 reps" | Models/ExerciseKinds.swift:233 | none | fixed | 2026-10-16-vary-by-set |
| R-082 | A blank kind cell on a sheet tab takes the tab's kind | Services/GoogleSheetImport.swift:384 | GoogleSheetImportTests › testBlankKindTakesTheTabsKind | fixed | 2026-10-16-google-sheet-import |
| R-083 | Tabs download by gid, with ids read from the htmlview page | Services/GoogleSheetImport.swift:246-254, :257, :279-289 | GoogleSheetImportTests › testTabIDsFromHTMLView (parsing only) | fixed | 2026-10-16-google-sheet-import |
| R-084 | A missing tab is skipped instead of silently returning the first tab | Services/GoogleSheetImport.swift:119-121 | none | fixed | 2026-10-16-google-sheet-import |
| R-085 | A row of another known kind is rejected; a misspelt kind gets the importer's own message | Services/GoogleSheetImport.swift:379-382 | GoogleSheetImportTests › testOtherKindInTabIsRejected; › testUnknownKindPassesThroughToImporter | fixed | 2026-10-16-google-sheet-import |
| R-086 | Errors name the sheet tab and row | Services/GoogleSheetImport.swift:206, :363, :419-434 | GoogleSheetImportTests › testErrorsNameTheTabAndRow; › testRelabelLeavesOtherMessagesAlone | fixed | 2026-10-16-google-sheet-import |
| R-087 | 401/403 reads "not shared", 404 "not found", other failures name the tab | Services/GoogleSheetImport.swift:268-273 | none | fixed | 2026-10-16-google-sheet-import |
| R-088 | Sheet downloads skip the local cache | Services/GoogleSheetImport.swift:266 | none | fixed | 2026-10-16-google-sheet-import |
| R-089 | A row with values only under unnamed columns is skipped as blank | Services/GoogleSheetImport.swift:358, :362 | GoogleSheetImportTests › testValuesOnlyUnderBlankHeadersAreSkipped | fixed | 2026-10-16-google-sheet-import |
| R-090 | A locked (stopped) workout can never be reopened | Persistence/WorkoutRepository.swift:391 | LockedHistoryTests › testStoppedWorkoutIsNeverReopenedOrResynced; DataSafetyRepairTests › testResumeNeverUnlocksALockedWorkout | fixed | 2026-10-16-locked-workout-immutability |
| R-091 | Today shows a locked workout as complete or stopped, with View Summary and no Resume | Views/TodayWorkoutView.swift:368-392 | none | fixed | 2026-10-16-locked-workout-immutability |
| R-092 | Data Safety offers only Finish or Delete for a locked, never-finished workout | Services/DataIntegrityService.swift:368, :451-453 | DataSafetyRepairTests › testFinishLockedUnfinishedWorkout; › testStuckEmptyWorkoutOffersDelete | fixed | 2026-10-16-locked-workout-immutability |
| R-093 | Restore adds child rows only under workouts it created | Services/ExportImportService.swift:378-436 | LockedHistoryTests › testRestoreDoesNotAddRowsToAnExistingWorkout | fixed | 2026-10-16-locked-workout-immutability |
| R-094 | Restore doesn't add corrections to an existing workout | Services/ExportImportService.swift:443-445 | none | fixed | 2026-10-16-locked-workout-immutability |
| R-095 | A real workout on a demo routine becomes the user's and survives demo cleanup | Persistence/DemoDataManager.swift:41, :66-81 | LockedHistoryTests › testDemoCleanupKeepsRealWorkoutsOnDemoRoutines | fixed (audit events: R-161) | 2026-10-16-locked-workout-immutability |
| R-096 | Corrections on a kept workout are re-tagged even without the relationship | Persistence/DemoDataManager.swift:76 | none | fixed | 2026-10-16-locked-workout-immutability |
| R-097 | A real workout missing a timestamp isn't mistaken for a seeded one | Persistence/DemoDataManager.swift:95-98 | LockedHistoryTests › testWorkoutMissingATimeIsReal | fixed | 2026-10-16-locked-workout-immutability |
| R-098 | The demo-data footer says real workouts on demo routines are kept | Views/DemoDataView.swift:71 | none | fixed | 2026-10-16-locked-workout-immutability |
| R-099 | A workout keeps the distance unit it was locked with | Models/WorkoutSession.swift:71-75; Persistence/WorkoutRepository.swift:373; Views/WorkoutHistoryDetailView.swift:159 | LockedHistoryTests › testDistanceUnitIsFrozenAtLock | fixed | 2026-10-16-locked-workout-immutability |
| R-100 | Older workouts get a distance unit at launch and restore; backups carry it | Persistence/WorkoutRepository.swift:380-383; App/WorkoutTrackerApp.swift:56; Services/ExportImportService.swift:394, :474 | LockedHistoryTests › testDistanceUnitIsFrozenAtLock (backfill part) | fixed | 2026-10-16-locked-workout-immutability |
| R-101 | Re-locking keeps the recorded distance unit | Persistence/WorkoutRepository.swift:373 | LockedHistoryTests › testRelockKeepsRecordedUnit | fixed | 2026-10-16-locked-workout-immutability |
| R-102 | No build wipes the store on open failure; only `--reset-store` (Debug) does | Persistence/AppContainer.swift:33-39, :47-57 | none | fixed | 2026-10-16-locked-workout-immutability |
| R-103 | Library sync forks a new routine version when a workout used the current one, and changes only rows that differ | Persistence/CatalogSyncService.swift:58-62, :68-70, :86-95 | CatalogSyncTests › testReconcileForksAVersionAWorkoutUses; › testReconcileEditsAnUnusedVersionInPlace | fixed | 2026-10-16-locked-workout-immutability |
| R-104 | An up-to-date routine doesn't fork extra versions on sync | Persistence/CatalogSyncService.swift:86-95 | CatalogSyncTests › testReconcileForksAVersionAWorkoutUses | fixed | 2026-10-16-locked-workout-immutability |
| R-105 | The routine editor matches a newly added row to the library at once | Views/RoutineEditorView.swift:419-421 | none | fixed | 2026-10-16-locked-workout-immutability |
| R-106 | The routine editor stops editing a version that sync replaced | Views/RoutineEditorView.swift:320-323 | none | fixed | 2026-10-16-locked-workout-immutability |
| R-107 | The four session-setting edits are refused on a locked workout | Persistence/WorkoutRepository.swift:508, :522, :555, :608 | LockedHistoryTests › testSessionSettingEditsRefusedWhenLocked | fixed | 2026-10-16-locked-workout-immutability |
| R-108 | Edit Workout's changes are refused on a locked workout | Views/SessionEditorView.swift:217, :230, :240 | none | fixed | 2026-10-16-locked-workout-immutability |
| R-109 | In replace mode, a repeated exercise name is an error | Services/CSVExerciseImporter.swift:253-262 | GoogleSheetImportTests › testRepeatedExerciseIsRejectedWhenReplacing | fixed | 2026-10-16-multi-machine-sheet-import |
| R-110 | A Machine exercise whose photo is on its machine doesn't re-download it on each import | Services/CSVExerciseImporter.swift:358-359, :460-463 | none | fixed | 2026-10-16-multi-machine-sheet-import |
| R-111 | A ^ row weight must be finite (`inf` rejected) | Services/GoogleSheetImport.swift:411 | none | fixed | 2026-10-16-multi-machine-sheet-import |
| R-112 | Routine re-import compares structure only, so unchanged routines aren't "updated" or forked | Services/CSVRoutineImporter.swift:628-646 | GoogleSheetRunTests › testRunningTheSameSheetAgainChangesNothing; › testRoutineSetsFromTheSheetDontCountAsAnEditAfterReconcile | fixed | 2026-10-17-google-sheet-one-tap-import |
| R-113 | A blank cardio length isn't compared, and a rebuild keeps the routine's own length | Services/CSVRoutineImporter.swift:576-581, :641 | GoogleSheetRunTests › testABlankCardioLengthKeepsTheRoutinesOwn | fixed | 2026-10-17-google-sheet-one-tap-import |
| R-114 | A failed final sheet-import save throws and rolls back | Services/GoogleSheetImport.swift:150-156 | none | fixed | 2026-10-17-google-sheet-one-tap-import |
| R-115 | "Already defined" errors name the tab and row of both sheet rows | Services/GoogleSheetImport.swift:427-431 | GoogleSheetRunTests › testARepeatedExerciseNamesBothSheetRows | fixed | 2026-10-17-google-sheet-one-tap-import |
| R-116 | All-blank Routines-tab rows are skipped, and row numbers stay right | Services/CSVRoutineImporter.swift:233-235 | GoogleSheetRunTests › testBlankRowsInTheRoutinesTabAreSkippedAndRowNumbersStayRight | fixed | 2026-10-17-google-sheet-one-tap-import |
| R-117 | A new routine version keeps its rest between sets | Persistence/RoutineRepository.swift:160 | GoogleSheetRunTests › testANewVersionKeepsTheRestBetweenSets | fixed | 2026-10-17-google-sheet-one-tap-import |
| R-118 | A sheet run with any problem changes nothing (dry run in a scratch context first) | Services/GoogleSheetImport.swift:133-146 | GoogleSheetRunTests › testARollbackRestoresExistingExercisesAndRoutines; › testAProblemOnAnyTabImportsNothing | fixed | 2026-10-17-google-sheet-one-tap-import |
| R-119 | An unchanged two-machine exercise counts as unchanged on re-import | Services/CSVExerciseImporter.swift:451-453 | GoogleSheetRunTests › testAMultiMachineExerciseReimportedUnchangedIsUnchanged | fixed | 2026-10-17-google-sheet-one-tap-import |
| R-120 | The one-row-per-exercise rule applies only to rows with a kind | Services/CSVExerciseImporter.swift:256 | GoogleSheetRunTests › testAnOlderFileWithARepeatedNameStillImportsWhenUpdating | fixed | 2026-10-17-google-sheet-one-tap-import |
| R-121 | Exercise CSV line numbers are counted before blank rows are skipped | Services/CSVExerciseImporter.swift:212-216 | GoogleSheetRunTests › testFileLinesStayRightAfterBlankRows | fixed | 2026-10-17-google-sheet-one-tap-import |
| R-122 | ^ rows work in exercise CSV files, with errors naming file lines; a ^ row needs a kind column | Services/GoogleSheetImport.swift `splitMachineRows` (line not recorded) | GoogleSheetRunTests › testCaretRowProblemsInAFileNameTheFileLine; › testAnImporterErrorAfterSplittingNamesTheFileLine; › testACaretRowNeedsAKindColumn | fixed | 2026-10-17-google-sheet-one-tap-import |
| R-123 | The strength template gives Leg Press a second machine | strength template file (line not recorded) | GoogleSheetRunTests › testTheStrengthTemplateGivesLegPressTwoMachines | fixed | 2026-10-17-google-sheet-one-tap-import |
| R-124 | CSV file imports update existing exercises and routines that differ; an identical routine row is skipped | `replaceExisting` / `updateExisting` in the CSV importers (line not recorded) | GoogleSheetRunTests › testRoutineCSVFileImportStillSkipsExistingRoutines (covers the skip half only) | fixed | 2026-10-17-google-sheet-one-tap-import |
| R-125 | The current build opens a store made by commit 1624f8f; the schema is still V1 | MigrationIntegrityTests.swift:72-80 (in-memory only) | none: hand checks. 2026-10-18: a store made by `1624f8f` opened in the current build and migrated in place with its data (regression-reviewer, throwaway simulator). The on-disk fixture test is still missing | fixed | 2026-10-17-codebase-audit |
| R-126 | The debug "Erase ALL data" button asks first | Views/DemoDataView.swift:76, :81-89 | none | fixed | 2026-10-17-codebase-audit |
| R-127 | Older unfinished workouts with work logged are listed with Resume and never replace today's workout | Views/TodayWorkoutView.swift:93-96, :116-119, :133-140, :354, :469, :485-488 | none | fixed | 2026-10-17-codebase-audit |
| R-128 | Un-marking an earlier set keeps every set in place, with no duplicate numbers | Persistence/CatalogSyncService.swift:149-178 | AuditFixesTests › testMarkingSetOneNotDoneKeepsEverySetInItsPlace | fixed | 2026-10-17-codebase-audit |
| R-129 | Demo cleanup keeps an unfinished workout on a demo routine as the user's | Persistence/DemoDataManager.swift:41, :66-81 | AuditFixesTests › testDemoCleanupKeepsAnUnfinishedWorkoutOnADemoRoutine | fixed | 2026-10-17-codebase-audit |
| R-130 | Library clean-up doesn't remove an exercise with logged work in an open workout | Persistence/WorkoutRepository.swift:584 | AuditFixesTests › testDemoCleanupKeepsAnUnfinishedWorkoutOnADemoRoutine (prune step) | fixed | 2026-10-17-codebase-audit |
| R-131 | Calendar and the Workout tab don't redraw on every timer tick (`TimerCommands` is Equatable) | Views/TimerCommands.swift:14-22; Views/TodayWorkoutView.swift:28; App/WorkoutTrackerApp.swift:74; Views/CalendarView.swift:15 | none | fixed | 2026-10-17-codebase-audit |
| R-132 | The exercise sheet caches machines, names and photos, loaded after the open-time reconcile | Views/SessionExerciseSheet.swift:180-186, :818 | none | fixed | 2026-10-17-codebase-audit |
| R-133 | Backup restore looks records up by id instead of scanning per record | Services/ExportImportService.swift:263, :496-506, :509-512 | AuditFixesTests › testRestoreLinksRestoredRecordsTogether | fixed | 2026-10-17-codebase-audit |
| R-134 | The launch purge filters in the store first | Persistence/WorkoutRepository.swift:316-320 | outcome only: the purge tests in R-047/R-049 | fixed | 2026-10-17-codebase-audit |
| R-135 | Library sync reaches only unlocked workouts | Persistence/CatalogSyncService.swift:103-107, :111, :184 | CatalogSyncTests › testReconcileNeverTouchesLockedSession (outcome only) | fixed | 2026-10-17-codebase-audit |
| R-136 | A guided exercise that finished while the phone was locked is marked complete at its real end time | Services/GuidedTimerService.swift:260, :516-517; Views/WorkoutRunnerView.swift:254 | AuditFixesTests › testGuidedCatchUpReportsWhenTheExerciseActuallyEnded (timer side only) | fixed | 2026-10-17-codebase-audit |
| R-137 | Picking the same photo again after removing it works | Views/SessionExerciseSheet.swift:170 | none | fixed | 2026-10-17-codebase-audit |
| R-138 | A photo removed in the app stays removed on sheet import | Views/SessionExerciseSheet.swift:735; Services/CSVExerciseImporter.swift:358, :589 | PhotoRefreshTests › testAPhotoSetInTheAppIsNotFetchedOrReplaced (photo present, not removed) | fixed | 2026-10-17-codebase-audit |
| R-139 | Every weight label follows the weight-unit setting; the duplicate distance-unit reader is gone | Views/WorkoutHistoryDetailView.swift:206, :212, :295; Views/SetBuilderSheet.swift:144; Views/SessionEditorView.swift:171; Views/SessionExerciseSheet.swift:552, :1015, :1037 | none | fixed (locked history: see O-010) | 2026-10-17-codebase-audit |
| R-140 | Schedule import prefers the user's routines; a shared user name is an error | Services/SheetScheduleImporter.swift:98-107 | SheetScheduleTests › testADuplicateRoutineNameIsAProblemAndUserRoutinesWin | fixed | 2026-10-17-codebase-audit |
| R-141 | Swipe-down can't leave a half-made routine or calendar copy | Views/RoutineEditorView.swift:119; Views/CalendarView.swift:73, :80; Views/TodayWorkoutView.swift:203 | none | fixed | 2026-10-17-codebase-audit |
| R-142 | A failed save during restore or import is reported, not shown as success | Views/ImportExportView.swift:276-279, :368, :391; Services/CSVExerciseImporter.swift:424; Services/CSVRoutineImporter.swift:602; Services/GoogleSheetImport.swift:152 | none | fixed | 2026-10-17-codebase-audit |
| R-143 | A failed save on Finish shows "Workout not saved" with Try Again on the Workout tab | Views/WorkoutRunnerView.swift:29, :236-241; Views/TodayWorkoutView.swift:214, :251 | none | fixed | 2026-10-17-codebase-audit |
| R-144 | The Correct Set title uses the row's per-side numbering | Views/WorkoutHistoryDetailView.swift:302-304 | none | fixed | 2026-10-17-codebase-audit |
| R-145 | Removing exercises in Edit Workout detaches first and updates status | Views/SessionEditorView.swift:216-227 | none | fixed | 2026-10-17-codebase-audit |
| R-146 | Rests changed mid-run update the rests and get-readies not yet started | Services/GuidedTimerService.swift:437-442; Views/WorkoutRunnerView.swift:130; Views/SessionEditorView.swift:187; Views/TimerCommands.swift:30-31 | AuditFixesTests › testChangingRestsMidRunUpdatesTheStepsAhead | fixed | 2026-10-17-codebase-audit |
| R-147 | Dead views stay removed: ExerciseMachineEditorView, ActiveWorkoutView, AddUnplannedExerciseSheet, RestCountdownButton | files absent, no references | n/a | fixed | 2026-10-17-codebase-audit |
| R-149 | One shared helper each for copying routine sections, machine settings and cardio/stretch fields | Persistence/RoutineRepository.swift:198; Persistence/WorkoutRepository.swift:135; Models/WorkoutSession.swift:295 | indirect only | fixed | 2026-10-17-codebase-audit |
| R-150 | Deleting an unfinished earlier-day workout leaves today's schedule alone | Views/TodayWorkoutView.swift:505-506, :525 | none | fixed | 2026-10-17-codebase-audit |
| R-151 | The missing-from-library check skips exercises with work logged in an open workout, in both the issue list and the pass/fail count | Services/DataIntegrityService.swift:267-269, :279 | DataSafetyCheckTests › testExerciseWithLoggedWorkInAnOpenWorkoutPassesLibraryCheck | fixed (count half completed 2026-10-18) | 2026-10-17-codebase-audit |
| R-157 | A workout finished with only a logged distance locks as partial, not "In Progress" (`recomputeStatus` counts `hasAnythingDone`) | Persistence/WorkoutRepository.swift:261-264 | SplitAuditFixesTests › testDistanceOnlyWorkoutFinishesPartialNotStarted; › testDistanceMarkedCompleteFinishesCompleted | fixed | 2026-10-18 split audit (O-001) |
| R-158 | Restore adds sections only under versions it created and routine exercises only under sections it created | Services/ExportImportService.swift:357-380 | SplitAuditFixesTests › testRestoreDoesNotReattachADeletedSection; › testRestoreDoesNotReattachADeletedRoutineExercise; › testRestoreIntoEmptyStoreStillBringsSectionsAndExercises | fixed | 2026-10-18 split audit (O-002) |
| R-159 | Opening the routine editor writes no schedule until the user changes it; editing keeps the routine's other recurring rules; both fetches are sorted by `createdAt` | Views/RoutineEditorView.swift `loadSchedule`, `scheduleChanged`, `applySchedule` | none (view code) | fixed | 2026-10-18 split audit (O-003) |
| R-160 | Workout-tab "delete this and future" ends only the rules that put the workout on today | Views/TodayWorkoutView.swift `applyDelete` | none (view code) | fixed | 2026-10-18 split audit (O-004) |
| R-161 | Delete Demo Data re-tags a kept workout's audit events as the user's: those keyed by the workout, its exercises and sets, and its corrections' targets | Persistence/DemoDataManager.swift `keepRealWorkouts` | SplitAuditFixesTests › testDemoCleanupKeepsAKeptWorkoutsAuditEvents (workout- and set-keyed events; the correction-target line is a backstop, untested on its own) | fixed | 2026-10-18 split audit (O-005) |
| R-162 | Every Workout-tab delete asks first: the scope question when the routine recurs today, otherwise "Delete workout" / Cancel | Views/TodayWorkoutView.swift `requestDelete`, delete `confirmationDialog` | none (view code) | fixed | 2026-10-18 split audit (O-006) |
| R-163 | `project.yml` matches the committed project: bundle ids `com.donohoeux.workouttracker(.tests)`, team, camera and photo strings, orientations | project.yml | none: compare with project.pbxproj | fixed | 2026-10-18 split audit (O-007) |
| R-164 | Library sync doesn't change the machine, structure or cardio/stretch prescription of a workout exercise once work is logged on it (notes and rest still follow; only undone sets re-plan) | Persistence/CatalogSyncService.swift `reconcileSessionExercises` | SplitAuditFixesTests › testReconcileKeepsTheMachineOfAnExerciseWithWorkLogged; › testReconcileKeepsTheStructureOfAnExerciseWithWorkLogged; CatalogSyncTests › testReconcileCardioSkipsAlreadyMarkedComplete (prescription) | fixed | 2026-10-18 split audit (O-008) |
| R-165 | A sheet-imported schedule takes its routine's source, so a demo routine's schedule is demo | Services/SheetScheduleImporter.swift:147 | SplitAuditFixesTests › testSheetScheduleForADemoRoutineIsDemo | fixed | 2026-10-18 split audit (O-009) |
| R-166 | Demo graduation counts only live user routines and workouts; the Schedule sheet discards routines it created that weren't scheduled, when the sheet closes (`.onDisappear` on the NavigationStack, not the Form, so pushing "Edit routine" keeps the routine) | Services/SeedDataService.swift `hasExistingUserData`; Views/ScheduleWorkoutSheet.swift `discardCreatedRoutines` | SplitAuditFixesTests › testADeletedUserRoutineDoesNotCountAsUserData (sheet part: none, view code) | fixed | 2026-10-18 split audit (O-011) |
| R-167 | Library sync checks a routine exercise's version is active before comparing it, so old versions cost no planned-set loads | Persistence/CatalogSyncService.swift `reconcileRoutineExercises` | outcome only: CatalogSyncTests | fixed | 2026-10-18 split audit (O-013) |
| R-168 | The Calendar weekday header starts on the calendar's first weekday, like the grid | Views/CalendarView.swift `weekdaySymbols(for:)` | SplitAuditFixesTests › testWeekdayHeaderStartsOnTheCalendarsFirstWeekday | fixed | 2026-10-18 split audit (O-015) |
| R-169 | The app is locked to Light appearance (`UIUserInterfaceStyle = Light`), because the palette in Theme.swift is light-only | project.yml; WorkoutTracker.xcodeproj/project.pbxproj (both app configurations) | SplitAuditFixesTests › testAppIsLockedToLightAppearance | fixed | 2026-10-18 split audit (O-014) |

**Tests found on the first run that pin product rules but aren't tied to a row:** `ImmutabilityAndVersioningTests › test11_correctionsAppendOnly`, `› test12_softDeleteKeepsHistory`, `MigrationIntegrityTests › test17_migrationPlanIsSafe`, `DemoExportImportTests › test14_userDataRemainsAfterDemoDeletion`, `ImmutabilityAndVersioningTests › test07_catalogEditUpdatesRoutineInANewVersion`.

**Known unpinned:** the locked-session guards in `WorkoutRepository` `completeSet`, `uncompleteSet`, `editActual`, `markExerciseComplete` and `unmarkExerciseComplete` have no test. They call `assertionFailure`, which stops a Debug test run, so they can't be tested as written.

## Superseded

These were removed or replaced on purpose, so they aren't regressions.

| ID | Fix | Why |
|---|---|---|
| R-035 | The safety badge doesn't re-run every check on each tab change | the badges were removed (R-055) |
| R-041 | The Settings badge refreshes after Import or Delete Demo Data | the badges were removed |
| R-048 | Calendar "Yes, stop" discards a workout with nothing logged | removed with ActiveWorkoutView |
| R-061 | A background run's countdown shows only on an exercise in the run | the peek sheet no longer shows countdowns; the guard lives at Views/SessionExerciseSheet.swift:406, :409 |

## Open

Known bugs, not fixed. Don't report these as regressions. When one is fixed, move it to **Fixed** with its pinning test.

| ID | Bug | Location | Source |
|---|---|---|---|
| O-010 | Locked history shows weights in the current unit setting, so switching units relabels old workouts | Views/WorkoutHistoryDetailView.swift:206, :212; Models/WorkoutSession.swift:71 | registry seed 2026-10-18 |
| O-016 | Delete Demo Data hard-deletes demo machines, and doesn't prune exercises until the next launch | Persistence/DemoDataManager.swift | 2026-10-16-data-safety-check (#3, #4) |
| O-017 | `removeMachineEverywhere` and the migration's `repoint` edit routine rows in versions that workouts used | Services/DataIntegrityService.swift; Persistence/ExerciseStructureMigration.swift | 2026-10-16-locked-workout-immutability |

## Accepted

| ID | Behavior | Source |
|---|---|---|
| A-001 | `removeDuplicatePlannedSets` edits old routine versions that past workouts point to | 2026-10-16-data-safety-repairs |
| A-002 | Sheet import overwrites routine sets that a workout recorded differently (the workout keeps its own record) | 2026-10-17-google-sheet-one-tap-import (#7) |
| A-003 | Google Sheet import relies on the undocumented htmlview page and needs "Anyone with the link" sharing | 2026-10-16-google-sheet-import |
| A-004 | A routine CSV's `setK`/`set_cooldown` for an exercise already in the library last only until the next library sync, when a Routines/Workout/Calendar tab appears (`CatalogSyncService.isStale` compares count, reps, weight and rest); `set_cooldown` never reaches `Exercise.defaultRest`, and setK becomes library defaults only on the no-`kind` strength path. The importer header and the Import footer say so | 2026-10-18-split-vs-broad-audit (O-012), decided 2026-10-18 |
