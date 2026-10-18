# Data Safety Check review — 2026-10-16

Scope: `WorkoutTracker/Services/DataIntegrityService.swift` (checks 1, 5, 6 revised; checks 7–11 added) and `WorkoutTrackerTests/DataSafetyCheckTests.swift`. Reviewed by the swift-reviewer subagent; findings verified against the cited code.

Verdict before fixes: NEEDS-WORK. `runAll()` confirmed read-only.

## Fixed in the checks

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | High | Check 11 failed every finished workout restored from a backup made before the audit log was exported (`ExportImportService.swift:347` restores `doc.auditEvents ?? []`). | Only workouts the log knows about (any `WorkoutSession` event) must have a `session.finished` event. Test: `testRestoreWithoutAuditLogPasses`. |
| 2 | High | Check 5 reported "original overwritten" after a corrected workout was reopened and the set re-logged (`reopen` at `WorkoutRepository.swift:314-320`; `editActual` writes at `:244-245`). | Value comparison only while the session is locked and has not been finished again since the correction. Test: `testReopenedCorrectedWorkoutRelogIsNotOverwrite`. |
| 6 | Low | A session with `completedAt` but no lock and a non-recorded status was caught by neither check 1 nor 10. | Check 1 treats any session with `completedAt` as recorded history. Test: `testCompletedButUnlockedSessionFails`. |
| 7 | Low | Check 8 detail read "have 2, 0 active versions". | Detail lists routine names with their active-version count. |
| 8 | Low | Routine/Exercise/Machine/AuditEvent fetched twice. | Fetched once at the top of `runAll()`. |
| 9 | Low | `testWorkoutInProgressWithDeletedExerciseFails` never asserted failure. | Added `XCTAssertFalse(result.passed)`. |
| 10 | Low | No tests for the two High cases. | Added (see 1 and 2). |

Also: check 7's comment now lists Delete Demo Data as a third cause.

## Not fixed — app behaviour the checks correctly report

| # | Severity | Finding | Evidence |
|---|---|---|---|
| 3 | Medium | Deleting demo data hard-deletes demo machines with no machine equivalent of the exercise prune, so a user exercise or routine pointing at a demo machine fails check 9 permanently. Not verified whether the UI lets a user attach a demo machine. | `DemoDataManager.swift:41`; `SeedDataService.swift:53-58` |
| 4 | Medium | Delete Demo Data does not run `pruneExercisesMissingFromLibrary`, so check 7 fails until the next launch if a user routine or workout used a demo exercise. | `DemoDataManager.swift:35-50`; `WorkoutTrackerApp.swift:47` |
| 5 | Medium | A merge-restore inserts new routine versions with their `isActive` flag into an existing routine, which can leave two active versions (check 8 fails). | `ExportImportService.swift:268-272` |
| — | — | After a corrected workout is reopened and re-logged, `CorrectedView.effectiveActualWeight` still shows the old correction over the newly logged value. | `CorrectionService.swift:81-86` |

## Verification

Full suite: 88/88 passing (iPhone 17 Pro simulator). Not run against on-device data.
