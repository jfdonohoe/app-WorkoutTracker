# Regression reviewer: built, benchmarked, first run (2026-10-18)

## What was added

- **`.claude/agents/regression-reviewer.md`:** a read-only project agent that runs after any revision. It covers:
  1. the build and the **full** `xcodebuild test` suite
  2. the regression registry: each fix is still in place, and its pinning test exists, actually runs, and asserts the fix
  3. the README's product rules
  4. launch-path wiring

  It uses the shared P0–P3 / CONFIRMED-PLAUSIBLE scheme and ends with PASS or NEEDS-WORK.
- **`_reports/regression-registry.md`:**
  - 145 fixed rows, seeded from the review reports dated 2026-09-08 to 2026-10-17, each with location and pinning test
  - 4 superseded rows
  - 17 open rows (O-001…O-017, the 2026-10-18 audit findings plus two new gaps)
  - 3 accepted rows

  I checked every test name it cites against `WorkoutTrackerTests/`.
- **`ios-codebase-refactorer`:** now runs the full test suite after each batch instead of just the "relevant" tests.
- **`.claude/agents/README.md`:** has a "Regression checks" section.
- **Harness fixes in `~/.claude/agent-evals/bin/`:**
  - `findings.py` dropped the leading `_` from paths, so `_reports/…` became `reports/…`
  - `score.py` flagged the read-only `git stash list` as a write
  - `trigger_check.py` gained `--agent-file` for project agents

  Selftest: all 348 checks pass.

## Benchmark (`~/.claude/agent-evals/regression-reviewer/`)

The fixtures are small Swift packages, so the agent really builds them and runs their tests.

| Case | Planted | Result (3 runs) |
|---|---|---|
| 01-regressions | a fix undone, caught by a failing test; a fix undone with no test; a pinning test deleted; a pinning test renamed so XCTest skips it; a README rule broken under a weakened test; a feature not wired at launch | 6/6 found in every run, 0 false positives, NEEDS-WORK 3/3, categories and verdicts 100%, read-only |
| 02-clean | everything intact, plus decoys: an open row, an accepted row with a deliberately skipped test, an intact pinned fix | 0 false positives, PASS 3/3 |
| Triggers | 2 should route, 4 near misses | 6/6 |

About 2 minutes and $0.30 per run.

**Fixture fix during the build:** the first clean-case version had three real gaps that the agent rightly reported:
- no test for a weight-only workout counting as done
- no test for re-finishing a locked workout
- a user's workout on a demo routine tagged as demo (the same bug the app fixed in R-095)

I fixed the fixture and discarded those runs (`results/2026-10-18-v1-fixture-v1-discard-clean`).

## First run on the app: PASS

- **Build:** succeeded.
- **Tests:** 294 executed, 294 passed, 0 failed, 0 skipped. This is now the registry's baseline.
- **Registry:**
  - all 145 fixed rows have their fixed shape
  - all 86 named pinning tests exist and ran
  - 67 rows have no direct test
- **Product rules:** 7/7 pinned at the repository level.
- **Features:** 13/13 wired.

Findings, all P3 (`unpinned`: correct today, but no test would catch a break). I checked the first, second and fourth in the code myself:

| # | Item | Where |
|---|---|---|
| 1 | Restore adding corrections only to workouts it created (R-094) has no test | `Services/ExportImportService.swift:443-445` ✓ |
| 2 | Discarded workouts not forcing a new routine version (R-052) has no test | `Persistence/RoutineRepository.swift:134` ✓ |
| 3 | The routine editor's own version-fork logic has no test, so "edits create versions" isn't pinned on the main editing path | `Views/RoutineEditorView.swift:325` |
| 4 | Edit Workout's locked-workout guards (R-108, R-145) are view code no test reaches | `Views/SessionEditorView.swift:217`, `:230`, `:240` ✓ |
| 5 | "Never wipe the store on open failure" (R-102) has no test; the on-disk fixture test (R-125) was never added | `Persistence/AppContainer.swift:47` |

**Referral (not a finding):** `Views/WorkoutPeekSheet.swift:84` and `Models/Catalog.swift:357` read the distance unit straight from `UserDefaults` instead of through `DistanceUnit.current`. This duplication belongs to `ios-codebase-auditor`.

## Limits

- **Open bugs are excluded.** PASS means nothing fixed has regressed. It doesn't mean the app is bug-free: the 17 open rows include the P0 distance-only workout.
- **Only what tests and code reading reach.** There's still no UI test target. The agent reads the code for view-layer rows but can't run them.
- **Registry upkeep is manual.** When a fix lands, the main session must add its row, or the agent won't guard it.
