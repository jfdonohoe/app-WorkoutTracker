# Split vs. broad audit: interim results (2026-10-17)

**Status:** superseded by `2026-10-18-split-vs-broad-audit.md`. The run was completed.

## Done

- **Area runs finished: 10 of 12.**
  - History and data integrity: round 1 only (rounds 2 and 3 were stopped).
  - User flows: rounds 1–3.
  - Performance: rounds 1–3.
  - Config and build: rounds 1–3.
- **Broad runs:** this afternoon's 3, reused because the app code is unchanged since they ran.
- **Contamination:**
  - The first launch was discarded: 2 config runs had read `2026-10-17-audit-consistency-3runs.md`.
  - The relaunched runs were told not to open it.
  - None of the 10 finished runs cites the excluded reports.
- **Raw findings:**
  - area runs: `/private/tmp/claude-501/-Users-john-Documents-Claude-Projects-WorkoutApp/31ecd11b-45c9-4684-88ba-06fc03b3609c/scratchpad/split-runs/`
  - broad runs: `.../scratchpad/audit-runs/`

## Not done

- History-integrity area runs for rounds 2 and 3.
- The 3 boundary runs. The round 1 input is ready: `split-runs/boundary-input-R1.md`.
- The full comparison and merged list.

## Early observations (not final)

1. **Depth: area runs found much more.**
   - Each user-flows run confirmed 31–36 findings, against 25–29 for an entire broad run.
   - Performance and config runs went well past what the broad runs found.
2. **Consistency between runs: much higher for area runs.**
   - Config: all 3 runs agree on the `project.yml` bundle-id drift and the missing camera string, plus the photo links blocked by ATS. Only 1 of 3 broad runs found the bundle-id drift.
   - Performance: all 3 runs independently found a new P1: reconcile scans every historical routine version (I verified this at `CatalogSyncService.swift:51-63`).
   - User flows: all 3 runs found the delete with no confirmation, the "Save as a new routine" flow, the hard delete in Edit Workout, the same-name clone, the weight truncation, and the unfrozen weight unit.
3. **Cross-area bugs: the area runs caught both known ones, unprompted.**
   - R1 history integrity found the distance-only "In Progress" bug and the demo audit-log erase.
   - R1 and R2 user flows noted the distance bug's cause as out of area.
4. **New P1s not in any broad run** (still unverified unless marked):
   - Restore re-attaches sections and exercises that were deleted on the device (`ExportImportService.swift:355-368`). Round 1 only.
   - Reconcile rewrites logged values in unfinished workouts (`CatalogSyncService.swift:110-129`).
   - Merely opening Calendar ▸ Edit routine soft-deletes the routine's other recurring rules (`RoutineEditorView.swift:107-112, 262-308`). Found in rounds 1 and 3.
   - "Delete this and future" on the Workout tab ends every rule for the routine (`TodayWorkoutView.swift:525-536`). Found in rounds 1, 2 and 3.
   - Dark Mode is not handled: white text on white surfaces. Found by 2 config runs and 1 user-flows run.
