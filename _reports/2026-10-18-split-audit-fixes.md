# Split audit: fixes (2026-10-18)

These are fixes for the verified items in `2026-10-18-split-vs-broad-audit.md` (registry rows O-001 to O-015), plus O-009 from the registry seed. Every fix is now a **fixed** row in `regression-registry.md` (R-157 to R-168).

## Fixed

| Audit row | P | Fix | Where | Test |
|---|---|---|---|---|
| O-001 | P0 | A workout finished with only a logged distance now locks as partial, not "In Progress". | `Persistence/WorkoutRepository.swift` `recomputeStatus` | 2 tests |
| O-002 | P1 | Restore adds sections only under versions it created, and routine exercises only under sections it created, so parts deleted on the device stay deleted. | `Services/ExportImportService.swift` import loops | 3 tests |
| O-003 | P1 | Opening the routine editor writes nothing to the schedule until you change it. Editing no longer deletes the routine's other recurring rules, and both fetches use the same order. | `Views/RoutineEditorView.swift` | view code, none |
| O-004 | P1 | "Delete this and future" on the Workout tab ends only the rules that put the workout on today, as Calendar does. | `Views/TodayWorkoutView.swift` `applyDelete` | view code, none |
| O-005 | P1 | Delete Demo Data keeps the audit trail of the workouts it keeps: events keyed by the workout, its exercises and sets, and its corrections. | `Persistence/DemoDataManager.swift` `keepRealWorkouts` | 1 test |
| O-006 | P1 | Every Workout-tab delete asks first: the day-or-future question when the routine recurs today, otherwise Delete or Cancel. | `Views/TodayWorkoutView.swift` | view code, none |
| O-007 | P1 | `project.yml` matches the committed project: bundle ids `com.donohoeux.…`, team, camera and photo strings, orientations. | `project.yml` | compare with pbxproj |
| O-008 | P1–P2 | Once work is logged on an exercise, library sync no longer changes its machine, structure (kind, sides, reps) or cardio prescription. Only the sets not yet done are re-planned. | `Persistence/CatalogSyncService.swift` | 2 tests + 1 existing |
| O-009 | P2 | A sheet-imported schedule takes its routine's source, so a demo routine's schedule is demo. | `Services/SheetScheduleImporter.swift` | 1 test |
| O-011 | P2 | Demo graduation counts only live user data. The Schedule sheet discards a routine it created but didn't schedule when the sheet closes. | `Services/SeedDataService.swift`, `Views/ScheduleWorkoutSheet.swift` | 1 test (sheet part: view code) |
| O-013 | P2 | Library sync checks that a version is active before running the expensive comparison. | `Persistence/CatalogSyncService.swift` | existing sync tests |
| O-015 | P2 | The Calendar weekday header starts on the region's first weekday, like the grid. | `Views/CalendarView.swift` | 1 test |

**How the tests were checked:** I undid each tested fix in turn and confirmed its test failed, then put the fix back.

## The review found four problems in my first pass

All four are fixed:

| P | Problem | Fix |
|---|---|---|
| P0 | The Schedule sheet's discard was on the Form, which also disappears when "Edit routine" pushes. That would have deleted the routine while it was being edited. | It moved to the sheet's `NavigationStack`. |
| P2 | A correction's audit event is keyed by the corrected set, so it was still deleted. | Events keyed by the workout's exercises, sets and correction targets are kept as well; the test now covers a correction. |
| P3 | A logged cardio exercise still had its prescription rewritten. | Same `started` guard. |
| P3 | The plain delete dialog said "removed from your history" even for a planned card. | The message now depends on what's being deleted. |

## Regression testing

| Step | Result |
|---|---|
| Full suite | 305 tests: 305 passed, 0 failed, 0 skipped. 294 before, plus 11 new. |
| `regression-reviewer` | **PASS**. It also opened a store made by `1624f8f` in the current build on a throwaway simulator; it migrated in place with its data kept. |
| `swift-reviewer` | Its four findings are the ones above, all fixed. |

The final regression run left two P3 notes. Both are correct today, but no test covers them:
- opening an on-disk store from an older build (R-125)
- where the Schedule sheet's discard is attached (view code)

## Not fixed: needs a decision

- **O-012:** a routine CSV's `setK`/`set_cooldown` values are overwritten by the next library sync. The importer docs promise sets per routine, but the sync is built on routines following the library (`CatalogSyncService.swift`, "A routine doesn't choose a machine…"). R-112 and A-002 depend on that.
- **O-014, Dark Mode:** the theme is light-only with hardcoded colours (`Theme.surface = Color.white`). The choice is to lock the app to Light or to design a dark theme.

## Still open, not part of this audit's list

- **O-010:** locked history shows weights in the current unit.
- **O-016:** Delete Demo Data hard-deletes demo machines.
- **O-017:** `removeMachineEverywhere`/`repoint` edit versions that workouts used.

## Not tested on device or by UI test

O-003, O-004, O-006 and the sheet part of O-011 are view code. I read them, but none was driven in the simulator.
