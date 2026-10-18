# Google Sheet import: review and fixes

Date: 2026-10-16
Scope: the new "Import from Google Sheet" option on the exercise and routine imports.

- `WorkoutTracker/Services/GoogleSheetImport.swift` (new)
- `WorkoutTracker/Views/ImportExportView.swift` (Google Sheet section and two buttons)
- `WorkoutTrackerTests/GoogleSheetImportTests.swift` (new)

Reviewer: swift-reviewer agent (read-only). Verdict on the first version: needs work.

## Findings and what was done

| # | Severity | Finding | Outcome |
|---|---|---|---|
| 1 | High | A blank `kind` cell went to the importer as an old-format row, so a Hold-tab row with `hold_seconds` failed, and others imported untyped. | Fixed. A blank kind now takes the tab's kind. Test: `testBlankKindTakesTheTabsKind`. |
| 2 | High | The by-name download (`gviz/tq?sheet=`) could blank text in a mostly-numeric column. | Confirmed on the live sheet with a temporary tab: `L` among numbers came back empty from gviz and intact from `export?format=csv&gid=`. Fixed: tabs are now downloaded by gid, and names are mapped to gids from the sheet's public `htmlview` page. Test: `testTabIDsFromHTMLView`. |
| 3 | Medium | A missing tab silently returned the first tab (confirmed live), so every tab in a group was required. A misspelt kind was reported as "wrong tab". | Fixed. With real tab ids, a missing tab is known and skipped, and a group needs at least one of its tabs. Only a row of another known kind is rejected as the wrong tab. A misspelt kind passes through to the importer's own message. Tests: `testOtherKindInTabIsRejected`, `testUnknownKindPassesThroughToImporter`. |
| 4 | Medium | Error "Line N" numbers referred to the merged CSV, not to any row in the sheet. | Fixed. Errors now read "<Tab> row N:". Test: `testErrorsNameTheTabAndRow`, `testRelabelLeavesOtherMessagesAlone`. |
| 5 | Low | A 404 HTML page (bad link) was reported as "not shared". | Fixed. 401/403 means not shared, 404 means sheet not found, other failures name the tab. |
| 6 | Low | Responses might be cached. | Fixed. Requests use `reloadIgnoringLocalCacheData`. gviz also sent `no-cache, no-store`. |
| 7 | Low | A row with values only under unnamed columns became an empty row and failed the import. | Fixed. Blank-row detection uses named columns only. Test: `testValuesOnlyUnderBlankHeadersAreSkipped`. |
| 8 | Info | Routines tab validation. | Not a bug. The Routines tab is now looked up by its id, and a missing one gives "The sheet has no "Routines" tab". |

## Known limits

- The tab list comes from the `htmlview` page, which Google doesn't document. If Google changes that page, the import fails with "Couldn't read the sheet's list of tabs". It doesn't import wrong data.
- Row numbers in errors assume no cell contains a line break.
- The sheet must be shared as "Anyone with the link" (Viewer). A private sheet would need Google sign-in.

## Verification

- Full suite: 208/208 passed (196 before this work, plus 12 new Google Sheet tests).
- Live check: a temporary test, since deleted, ran the real import against the WorkoutTracker Import Sheet into an in-memory store.
  - Exercises: 35 imported (machine 16, static 11, dynamic 5, steady 2, intervals 1), with no duplicates.
  - Seated Leg Curl kept all six settings, including `Y Ankle = L`.
  - Routines: 4 imported, with sections matching the Phase 2 brief. Upper Body is cardio 1, stretching 5, strength 9, stretching 6. Lower Body & Core is cardio 1, stretching 4, strength 8, stretching 7. Each elliptical day is cardio 1, stretching 7.
