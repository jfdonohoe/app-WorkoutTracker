# One-tap Google Sheet import — review (2026-10-17)

## The change
- **Import / Export:** a new **Google Sheet** section at the top of the screen, with the link field and one **Import from Google Sheet** button. The per-group and routine sheet buttons in the CSV sections are gone.
- **One run, in order:**
  1. Every exercise tab, for all groups.
  2. The Routines tab.
- **All or nothing:**
  - The whole run is first tried in a scratch context that is never saved.
  - It runs for real only if no row on any tab has a problem.
  - Photos download after the save.
- **Existing exercises:** overwritten from the sheet. A re-import with the same values counts as unchanged.
- **Existing routines:**
  - Compared with the sheet.
  - Rebuilt only if their structure differs. A new version is made when a workout used the current one.
  - Routines that aren't in the sheet are left alone.
- **CSV file imports:** unchanged. They stay additive and skip existing items.
- **Figma mockup:** "Sets – App Screens", 🚧 WIP page, section "WIP - Google Sheet import, one tap (2026-10-17)".

## Reviewer findings (swift-reviewer) and outcomes

| # | Severity | Finding | Outcome |
|---|---|---|---|
| 1 | Medium | The routine comparison checked sets, set cooldowns and notes, which CatalogSyncService rewrites from the library. Every run reported "updated" and forked versions. | **Fixed.** Only structure is compared: sections, exercises and their order, plus a cardio length or exercise cooldown the sheet fills. |
| 2 | Low-Med | A blank cardio length in the sheet counted as a difference, and a rebuild dropped the app's length. | **Fixed.** A blank length isn't compared, and the routine's own length is kept on rebuild. |
| 3 | Low-Med | The final save was `try?`, so a failed save was reported as success. | **Fixed.** A failed save throws and rolls back. |
| 4 | Low | "already defined on line N" gave a merged-CSV line number. | **Fixed.** It now names the tab and row, e.g. "on Machine row 2". |
| 5 | Medium | A blank row in the Routines tab (",,,") failed the run. Row numbers after a skipped row were also off. | **Fixed.** All-blank rows are skipped, and each row keeps its own number. |
| 6 | Low | An unchanged exercise still rewrites its default sets and bumps machine timestamps. | **Not changed.** No visible effect. |
| 7 | Low | After a workout records different sets, the next import overwrites them and counts the exercise as updated. | **Not changed.** This is the agreed rule (the sheet owns definitions). Noted for the user. |
| 8 | Low | Moving an exercise to another group's tab creates a second exercise with that name, and its routine rows then fail with "is in more than one group". | **Not changed.** Noted for the user. |
| 9 | Low | `makeNewVersion` didn't copy the version's rest between sets. | **Fixed** (RoutineRepository). |
| 10 | Test gap | No test rolled back edits to existing records. | **Added.** The test failed at first: SwiftData `rollback()` left an edited exercise's sets and a forked routine version in place. Atomicity was redesigned to use the scratch-context check. |

## Found during live testing
- **Real sheet, in-memory store:**
  - Run 1 added 35 exercises and 4 routines.
  - Run 2 first reported 2 exercises as updated when nothing had changed. The cause: default sets of exercises with two machines (each numbered from 0) were compared in an unstable order.
  - **Fixed** (sort by machine, then set), with a repeat-run test. After the fix, run 2 reported 35 unchanged exercises and 4 unchanged routines.

## Verification
- Full suite: **241/241 passing**.
- New tests are in `WorkoutTrackerTests/GoogleSheetRunTests.swift` (16).

## Follow-up: CSV files brought in line with the sheet
- **^ rows in exercise CSV files:**
  - Handled the same way as on a sheet tab (`GoogleSheetImport.splitMachineRows`). Errors name file lines.
  - A ^ row in a file without a `kind` column is rejected.
- **Templates:**
  - Strength and cardio now have 6 settings pairs, matching the sheet.
  - The strength template has a ^ row that gives Leg Press a second machine.
  - Cardio has no ^ example: only the Machine kind takes more than one machine.
- **CSV file imports update if changed:**
  - Exercises: `replaceExisting`.
  - Routines: `updateExisting`. These follow the same rules as the sheet.
- **Results:** summaries add "N routine(s), N exercise(s) already matched."

### Review (swift-reviewer): PASS
| # | Severity | Finding | Outcome |
|---|---|---|---|
| 1 | Low | The one-row-per-exercise rule also rejected older files without a kind that list a name twice. | **Fixed.** It now applies only to rows with a kind. |
| 2 | Low | Exercise files counted lines after removing blank rows (and ",,," rows weren't skipped), so line numbers drifted. | **Fixed.** Lines are counted first, then all-blank rows are skipped. |
| 3 | Info | A header with two `exercise` columns could split on one and read the other. | Not changed (malformed file). |
| 4 | Info | In a file without a kind column, a ^ row also gets its group's required-field errors. | Not changed (extra errors only). |
| 5 | Info | Re-importing an older routine file now rebuilds existing routines that differ. | Intended; the footers say so. |

Full suite: **247/247 passing**.
