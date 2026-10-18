# Regression check (2026-10-18, after the split-audit fixes)

**Agent:** `regression-reviewer`, on the current working tree (HEAD `1624f8f` plus 129 uncommitted entries).

**Verdict: NEEDS-WORK.** The build succeeded, and the full suite ran 305 tests: 305 passed, 0 failed, 0 skipped. That matches the registry. The verdict comes from one older fix (R-151) that turned out to be incomplete. None of today's fixes is affected.

## Findings

| # | P | Category | Item | Where | Checked by me |
|---|---|---|---|---|---|
| 1 | P1 | fix-regressed | R-151 is only half fixed. Check 7 ("Routines use only library exercises") leaves an exercise with logged work in an open workout out of its issue list, but still counts it in `workoutsOutsideLibrary`, which decides whether the check passes. The check then fails with no fix offered. Scenario: log a set, delete that exercise from the library, then import or back up. Data Safety shows "1 workout(s) in progress use an exercise that is not in the library" and gives you nothing to tap. No test covers R-151. | `WorkoutTracker/Services/DataIntegrityService.swift:265-267` vs `:275` | ✓ |
| 2 | P3 | unpinned | No test opens an on-disk store made by an older build. The versioned-migrations rule rests on a plan-shape test and an in-memory container, while the V1 models have been changed in place. A hand check this morning passed. | `WorkoutTrackerTests/MigrationIntegrityTests.swift:72` | — |

## Status

| Item | Result |
|---|---|
| Registry fixed rows | 157 checked: 156 intact, 1 with a problem (R-151). Every named pinning test exists, runs and passes. |
| Product rules | 6 of 7 pinned (versioned migrations only partly) |
| Features | 11 of 11 wired |
| Open / accepted / superseded | O-010, O-012, O-014, O-016, O-017 / A-001 to A-003 / R-035, R-041, R-048, R-061 |

## Notes

- **Consistency:** the two earlier runs today read R-151 as intact. This run read it more closely and found the first half of the check unchanged. The agent samples older rows that have no tests, so a row without a pinning test can pass one run and fail the next. Pinning R-151 with a test would stop that.
- **Referral:** the README's "Testing the product rules" list ends in an empty bullet, and the README documents no build or test command.

## Follow-up: fixed

- **Finding 1 (R-151):** `workoutsOutsideLibrary` now skips exercises with work done (`DataIntegrityService.swift:265-268`), matching the issue list.
- **New pinning test:** `DataSafetyCheckTests › testExerciseWithLoggedWorkInAnOpenWorkoutPassesLibraryCheck`. With the fix undone it fails with exactly the reported message ("0 routine(s) and 1 workout(s) in progress use an exercise that is not in the library").
- **Full suite:** 306 run, 306 passed.

## Re-check after the fix: PASS

**Result:** `regression-reviewer` gave PASS. 306 tests ran: 306 passed, 0 failed, 0 skipped. 156 of the 157 fixed rows were intact and pinned.

| P | Finding | Action |
|---|---|---|
| P2 | The new R-151 test asserted only pass/fail, so the issue-list half was unpinned | Done: added `XCTAssertTrue(result.issues.isEmpty)`. It fails with that half undone. Full suite: 306/306 |
| P3 | The locked-session guards in `WorkoutRepository` (`completeSet`, `uncompleteSet`, `editActual`, `markExerciseComplete`, `unmarkExerciseComplete`) have no test. They call `assertionFailure`, which stops a Debug test run | Not fixed; recorded under "Known unpinned" in the registry |
