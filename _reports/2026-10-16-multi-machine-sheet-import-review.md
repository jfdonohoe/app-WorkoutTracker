# Multi-machine sheet import (^ rows) — review

Date: 2026-10-16
Reviewer: swift-reviewer subagent. Verdict: PASS with items. It found no change to history.

## Feature
- On an exercise tab, a row with `^` in the exercise column adds another machine to the exercise above it. A `^` row holds only machine, weight and settings. The exercise row's own machine is the default.
- The Google Sheet import overwrites existing exercises' definitions in place, keeping their ids (`replaceExisting`). History is not changed. CSV file imports stay additive.
- Sheet: Machine tab row 14 is the `^` row for Seated Leg Curl (Y). `^` cells are grayed by a conditional format rule. Lists!D leaves `^` out.

## Findings and outcomes
| # | Severity | Finding | Outcome |
|---|---|---|---|
| 1 | Medium | In replace mode, a repeated exercise name was silently dropped, so tab order picked the winner | Fixed: it is now an error ("… is already defined on line N"), shown as tab and row. Test added |
| 2 | Low-Med | For Machine exercises whose photo lives on the machine, the photo was downloaded again on every re-import | Fixed: skipped when a linked machine has a photo |
| 3 | Low | A machine that was unlinked and later listed again creates a new machine; the old one stays orphaned | Not changed (clutter only, no history risk) |
| 4 | Low (suspect) | Machines shared between exercises would be updated for both exercises | Not changed: ExerciseStructureMigration splits shared machines at launch and after every import |
| 5 | Low | `inf` was accepted as a `^` row weight | Fixed (`isFinite`) |
| 6 | Low | One fetch per machine inside the loop | Not changed (1–3 fetches per exercise) |
| 7 | Info | Errors from `^` rows are reported before the importer's own errors (two rounds) | Not changed |
| 8 | Info | `reconcileExercise` edits the active routine version even when a finished workout references it | Not changed: the exercise editor has always done this (ExerciseEditorView.swift:920), and no history view reads a session's version. Flagged for the user's decision |

## Tests added
- `^` adds a machine with its own weight and settings, and the default is first.
- `^` row errors give the tab and row: no exercise above, no exercise name, exercise-level column, missing machine name, bad weight, setting value without label.
- `^` across tabs, including a `^` at the top of a second tab. Two exercises each with a `^` machine.
- Repeated exercise rejected in replace mode. Duplicate machine names rejected. `^` only allowed on the Machine kind.
- Re-import updates in place: same exercise and machine ids, settings matched by label, removed settings soft-deleted, the routine picks up the new plan. The finished workout's settings, planned and actual sets are unchanged.
- A machine dropped from the sheet is unlinked, not deleted. The CSV file import still skips existing exercises.

## Verification
- Full suite: 217/217 pass (baseline 208).
- Live import from the real sheet (temporary test, deleted afterwards):
  - Pass 1 imported 16 strength exercises; pass 2 updated those 16, with no duplicates (17 machines).
  - Seated Leg Curl: Ankle 1, Back 4, Thigh 3 (default); Seated Leg Curl (Y): Ankle L, Pitch 1, Back 4.
  - Live import ran before fixes 1, 2 and 5; the sheet has no repeated names (Lists!D has 35 unique names).

## Known limits
- Sorting a tab moves `^` rows away from their exercise, and the importer can't detect it.
- Photos are fetched only for an exercise that has none, so a changed photo_url isn't picked up on re-import.
- The routine import is still additive. Existing routines are skipped by name.
