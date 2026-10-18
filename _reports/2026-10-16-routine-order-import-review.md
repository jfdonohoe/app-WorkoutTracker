# Routine CSV order and sections: review findings

**Date:** 2026-10-16
**Scope:** Routine CSV import without `group`, a new `order` column, and sections built from runs of consecutive rows in the same group.
**Files changed:**
- `WorkoutTracker/Services/CSVRoutineImporter.swift`
- `WorkoutTracker/Views/ImportExportView.swift` (the routines help text)
- `WorkoutTrackerTests/CSVKindImportTests.swift` (9 new tests)

**Reviewer:** the swift-reviewer subagent. **Verdict:** needs work. Items 1, 2b, 3 and 6 are now fixed.

**Regression check after the fixes:** the full suite passes, 196 of 196 tests on the iPhone 17 Pro simulator.

| # | Severity | Finding | Status |
|---|---|---|---|
| 1 | High | A row with no kind that ran before the row with the kind created a kind-less exercise, and the kind row then reused it, so its values were lost. Order sorting made this easy to hit, and it could also happen across routines. | Fixed: the first row with a kind defines the exercise for every row with that name and group. Test: `testRowWithoutKindRunBeforeTheKindRowUsesItsDefinition`. |
| 1b | Low | Two rows in the file with the same name and group but different kinds weren't reported; whichever ran first won. | Fixed: this is now an error. Test: `testTwoKindsForOneExerciseInTheFileIsAnError`. |
| 2a | Medium | An older file that splits a group's rows (strength, cardio, strength) now gets a section per run instead of one merged section. | Intended: row order sets sections. No routine CSV exporter exists whose files would change. |
| 2b | Medium | A cardio section's length came only from its first row, so a later row's duration was ignored. | Fixed: the first row in the section that gives a duration sets it. Test: `testCardioSectionLengthComesFromTheFirstRowWithADuration`. |
| 3 | Low | Order checks ignored rows that failed other checks, so order errors only showed on a second attempt. | Fixed: order is checked on every row. Test: `testOrderProblemsAreReportedWithOtherRowErrors`. |
| 4 | Low | Group lookup uses rows that later fail validation. This can't import bad data (the import is all-or-nothing), but it can add a confusing extra message. | Not changed. |
| 5 | Low | Matching only the user's own exercises and routines (`sourceRaw == user`) changes the result for older files that name demo data. | Not changed: this comes from the earlier demo-separation work and is intended. |
| 6 | Low | The help text left out "every row or none" for order, and said "in this file" where it meant rows that give a group or kind. | Fixed. |
| 7 | — | `ImportExportView` has a Data Safety `.sheet` next to `.fileImporter` (more than one presentation on the view). | Not changed: part of separate in-progress work, outside this change. |

**Test gaps the review listed and that are still open:** interleaved routines in the file (R, S, R), order gaps or padded values, and group taken only from a library exercise that has no kind.
