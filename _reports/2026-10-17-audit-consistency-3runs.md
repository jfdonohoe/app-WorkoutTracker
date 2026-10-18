# Three-run audit consistency check — 2026-10-17

**Setup:**
- **What was audited:** the Sets app working tree (about 110 uncommitted files), read-only.
- **Agents:** the revised `ios-codebase-auditor` and `dead-code-finder`, each run 3 times in parallel with an identical prompt (6 runs).
- **Excluded:** `swift-reviewer` (it reviews a change, not a codebase) and `ios-codebase-refactorer` (it edits code).
- **Changes:** nothing was changed in the app. No agent wrote a file.
- **Verification:** I checked every disagreement listed below myself, with the cited file:line. Everything else is as the agents reported it.

## 1. Drift from the agent definitions: none found

| Rule | Auditor runs 1/2/3 | Dead-code runs 1/2/3 |
|---|---|---|
| Required output sections and order | ✓ ✓ ✓ | — |
| P0–P3 scale only (no High/Medium/Low) | ✓ ✓ ✓ | — |
| CONFIRMED table vs PLAUSIBLE list | ✓ ✓ ✓ | ✓ ✓ ✓ (verdict field) |
| Seven-key finding format | — | ✓ ✓ ✓ |
| **New rule: no dead code as findings, only PLAUSIBLE leads** | ✓ ✓ ✓ | — |
| Reads README, memory, prior `_reports/` (D2 fix) | ✓ ✓ ✓ (2 and 3 skipped already-fixed items explicitly) | — |
| No "warm-up / cooldown sections" assumption (D1 fix) | ✓ ✓ ✓ (run 1 flagged `Routine.swift:133` "warm-up" as a stale comment) | — |
| Read-only | ✓ ✓ ✓ | ✓ ✓ ✓ |

The definition fixes held. The problem is **what each run finds**, not how it reports it.

## 2. Auditor: consistency between runs is low

### Agreement

The three runs reported about **52 distinct issues** between them:

| Found by | Issues | Share |
|---|---|---|
| All 3 runs | 11 | about 21% |
| 2 runs | 13 | about 25% |
| 1 run only | 28 | about 54% |

The overall verdicts agreed: all three said "Needs Targeted Cleanup", complexity High.

**Found by all 3 runs:**
- the correction save is missing
- correction mode is offered on unlocked workouts
- the unfiltered tab `@Query`
- notes save on every keystroke
- the exercise-delete cascade is copied into two views
- the recurrence editor is duplicated
- the runner re-renders on every timer tick
- the raw distance-unit reads
- drifted comments
- structural edits are made in the session-editor view
- the two definitions of "work done"

### The top findings don't overlap

| Run | Its #1 | Its #2 | Its #3 |
|---|---|---|---|
| 1 | **P0**: a distance-only workout is locked as "In Progress" | P1: Workout-tab delete has no confirmation | P2: rules duplicated in views |
| 2 | P1: a "Just this day" clone has the same name and breaks imports | P1: a correction is never saved | P1/P2: duplicated rules have drifted |
| 3 | P1: Workout-tab delete has no confirmation | **P1**: Delete Demo Data erases real workouts' audit events | P2: rules in views |

No P0 or P1 appears in all three runs.

### Verified findings that a run missed

I checked each of these in the code:

| Finding | Run 1 | Run 2 | Run 3 | Evidence |
|---|---|---|---|---|
| A distance-only workout is locked with status `.started` | **P0** | P3: noted the two "done" rules, missed the effect | P3: same | `recomputeStatus` counts no done units for a distance (`WorkoutRepository.swift:255-266`). `hasAnythingDone` counts it (`WorkoutSession.swift:119`). So `finishWorkout` locks it as `.started` (`:275-293`). |
| Delete Demo Data deletes the kept workouts' audit events | — | P2 | P1 | `keepRealWorkouts` re-tags sessions and corrections, not `AuditEvent`s (`DemoDataManager.swift:66-79`). `session.started` is logged with the session's demo source (`WorkoutRepository.swift:70-73`). Then `deleteDemo(AuditEvent.self)` runs (`DemoDataManager.swift:51`). |
| Workout-tab ••• Delete has no confirmation for non-recurring workouts | P1 | — | P1 | `requestDelete` calls `applyDelete` directly unless it's recurring today (`TodayWorkoutView.swift:499-507`). |
| `RestTimerService.stop()` doesn't clear `isFinished` | P2 | — | — | `RestTimerService.swift:103-109` |
| `project.yml` has the wrong bundle id (a regenerate would orphan the on-device store) | — | P1 | — | `project.yml:31` `com.workouttracker…` vs `project.pbxproj:336` `com.donohoeux…` |
| Machine-setting value range 1…20 vs 0…15 | — | P2 | — | `ExerciseKinds.swift:176` vs `Catalog.swift:154` |
| Calendar weekday header is always Sunday-first, but the grid uses `firstWeekday` | — | — | P2 | `CalendarView.swift:136` vs `:416-417` |

### Severity spread on shared items

When runs agree on an issue, they often differ by one level:

| Issue | Run 1 / 2 / 3 |
|---|---|
| Correction save | P2 / P1 / P2 |
| Calendar Edit on unlocked workouts | P3 / P2 / P2 |
| Per-tick re-render | P3 / P2 / P2 |
| JSON import with no rollback | PLAUSIBLE P3 / PLAUSIBLE P2 / CONFIRMED P2 |
| Calendar scope dialog dropped | PLAUSIBLE P2 / — / PLAUSIBLE P1 |

### One direct contradiction

**Schema V1 changed in place:**
- Run 1 calls it a P2 risk (freeze V1 before the next non-additive change).
- Runs 2 and 3 list it under "What Not To Change" as the correct posture.

They aren't fully incompatible, but they give opposite advice.

### Reading it

- **No single run is a complete audit.** Each run confirmed 25–29 findings, against 52 issues across all three. One run covers roughly half of what three runs find.
- **The misses look like a breadth limit, not drift.** The codebase is about 22k lines, and each run spent about 85–95 tool calls. Each run then followed different threads in depth: run 1 went into status semantics, run 2 into config and ranges, run 3 into demo, audit and the calendar.
- **This is my hypothesis, not something I measured:** splitting the audit by area (data integrity and persistence / views and state / performance) would raise recall per area more than repeating the same broad prompt.

## 3. dead-code-finder: the core is stable, the edge cases aren't

| Item | Run 1 | Run 2 | Run 3 | Verified |
|---|---|---|---|---|
| `RestCountdownViews.swift`: the whole file is dead | orphaned-file | orphaned-file | 3 separate unused-symbol findings | ✓ |
| `SectionType.sortIndex` | ✓ | ✓ | ✓ | ✓ |
| `RestTimerBar.showOverride` | ✓ | ✓ | ✓ | ✓ |
| `CardioIntensity.rpe` | ✓ | **missed** | ✓ | ✓ no `.rpe` use |
| Test-only: `hasOwnDefaultSets`, `allPassing` | ✓ ✓ | ✓ ✓ | ✓ ✓ | ✓ |
| Test-only: `exerciseTabs` | ✓ | — | ✓ | ✓ |
| Test-only: `setRest` | **"used by tests", not flagged** | ✓ | ✓ | ✓ |
| Test-only: `makeInMemory` | **"used by tests", not flagged** | ✓ | — | ✓ |
| `useStripes` hardcoded false | separate finding | inside the file finding | inside the file finding | ✓ |

**Inconsistencies:**
1. **Code only tests call.** The definition has no rule for it, so each run makes its own. Run 1 even contradicts itself: it flags 3 test-only symbols and dismisses 2 others as "used by tests".
2. **How a dead file is reported.** One orphaned-file finding in two runs, per-symbol findings in the third. Run-to-run comparison and the merged reports both suffer.

**Missed by all 3 runs** (verified):
- `WorkoutRepository.reorder(_:orderedIds:)` (`:475`) has **zero callers**, in app or tests. It's a plain CONFIRMED case.
- `RoutineRepository.softDelete(_ exercise:)` and `softDelete(_ machine:)` (`:284`, `:321`) are called only from tests (`ImmutabilityAndVersioningTests.swift:246`, `DataSafetyRepairTests.swift:193…`).
- `WorkoutRunnerView.stopsGuidedRunOnDisappear`: its only caller passes `false` (`TodayWorkoutView.swift:250`), so the default-`true` branch (`:167-172`) is dead.
- `SetBuilderSheet.allowsMachineChoice`: defaults to `false`, and its only caller (`SessionEditorView.swift:109`) never sets it, so the branch at `:109` can't run.

**The auditor's leads caught all of these and the dead-code agent didn't.** The hand-off only helps if the main session actually passes the leads to `dead-code-finder`.

## 4. Suggested fixes (not applied)

1. **`dead-code-finder`, code only tests call:** always report it as `PLAUSIBLE` / `unused-symbol`, naming the test files that call it, and never call it "used". Add a benchmark case with three such symbols.
2. **`dead-code-finder`, flags no caller sets:** treat a parameter or property whose non-default value no call site ever passes as a flag hardcoded off (`unreachable-code`). Add a benchmark case.
3. **`dead-code-finder`, one finding per dead file:** report an orphaned file once, listing its symbols in `failure_scenario`, not once per symbol.
4. **`dead-code-finder`, completeness:** check every symbol declared in the file with zero call sites (`reorder` slipped through). Run 1 said it only hand-checked symbols seen at most twice.
5. **Auditor:** for full coverage, either run 2–3 times and merge, or split the audit into area-specific runs. Have the main session reconcile severities using the shared P0–P3 definitions.
6. **Process:** after any audit, pass the auditor's dead-code leads to `dead-code-finder` explicitly, or merge them in as PLAUSIBLE.

## 5. Combined verified priority list (from all 6 runs)

| P | Item | Runs |
|---|---|---|
| P0 | A distance-only workout is locked as "In Progress" (`WorkoutRepository.swift:248-293`, `WorkoutSession.swift:116-120`) | A1 (A2, A3 saw the cause) |
| P1 | Workout-tab delete has no confirmation (`TodayWorkoutView.swift:499-507`) | A1, A3 |
| P1 | Delete Demo Data erases the kept workouts' audit events (`DemoDataManager.swift:51, 66-79`) | A2, A3 |
| P1 | `project.yml` bundle id and usage strings drifted (`project.yml:31`) | A2 |
| P1–P2 | Corrections not saved explicitly (`WorkoutHistoryDetailView.swift:314-323`) | A1, A2, A3 |
| P1–P2 | A same-name "Just this day" clone breaks name-matched imports | A2, A3 |
| P1–P2 | "Save as a new routine" doesn't leave the original intact | A2, A3 |
| P2 | Calendar weekday header is offset in Monday-first locales | A3 |
| P2 | Weight is shown truncated (`Int(weight)`) in history | A2, A3 |
| P2 | `RestTimerService.stop()` leaves `isFinished` set | A1 |
| P2 | Machine-setting range mismatch (1…20 vs 0…15) | A2 |
| P2 | Unfiltered tab `@Query`, per-tick re-render, notes saved per keystroke | all |
| P2 | Duplicated rules: exercise-delete cascade, recurrence editor, versioning, machine-setting edits | all / A1 |
| Dead | `RestCountdownViews.swift`, `sortIndex`, `showOverride`, `rpe`, `reorder`, the `stopsGuidedRunOnDisappear` and `allowsMachineChoice` branches; test-only `setRest`, `softDelete`×2, `hasOwnDefaultSets`, `allPassing`, `exerciseTabs`, `makeInMemory` | mixed |
