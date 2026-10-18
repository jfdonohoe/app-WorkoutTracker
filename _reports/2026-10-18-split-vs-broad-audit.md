# Split vs. broad audit, three rounds (2026-10-17/18)

This replaces `2026-10-17-split-audit-interim.md`.

## Setup

**What was compared.** The same working tree (app code unchanged throughout) was audited two ways, three times each:

| | Broad | Split |
|---|---|---|
| Per round | 1 `ios-codebase-auditor` run with the standard prompt | 4 area runs, then 1 boundary run |
| Areas | the whole app | history and data integrity · user flows and state · performance · config and build |
| Which runs | the three runs from the afternoon of 10-17 | rounds 1–3 |

**How the split rounds worked.**
- Each area run owned one kind of problem, not one folder, and could follow code into any file.
- Each boundary run received its round's area findings plus that round's broad findings. It was told to find only *new* places where two parts of the code disagree.

**Keeping the comparison fair.**
- Area runs were told not to open today's agent-review reports.
- The first launch was discarded after two config runs read the consistency report anyway.
- None of the 15 runs that counted cites the excluded reports.

**What I verified myself.** I checked the following in the code, with file and line:
- the restore re-attach
- delete-future on the Workout tab
- schedule rules soft-deleted when the editor opens
- reconcile overwriting logged exercises
- the missing dark-mode lock
- reconcile scanning every version
- the demo graduation wipe
- CSV `setK` being overwritten
- the four items verified on 10-17

Everything else is as the agents reported it.

## 1. Depth

| | Broad (one run) | Split (one round) |
|---|---|---|
| Confirmed findings | 25 / 26 / 29 | about 85–90 (areas: history about 15, flows 31–36, performance 13–17, config 9–10; boundary 8–15) |
| Tokens | about 400k | about 1.2M (about 3×) |
| Wall-clock | about 15 min | about 22 min (areas in parallel, then boundary) |

One user-flows run alone confirmed more findings than any whole broad run.

## 2. Consistency on the serious findings

Count = number of rounds (out of 3) in which the item was found.

| Finding | Broad | Split | Verified |
|---|---|---|---|
| A distance-only workout is locked as "In Progress" (P0) | 1 | **3** (history, every round) | ✓ |
| Restore re-attaches sections and exercises deleted on the device | 0 | **3** | ✓ `ExportImportService.swift:357-369` |
| Reconcile rewrites logged values in unfinished workouts | 0 | **3** | ✓ `CatalogSyncService.swift:114-116` |
| Delete Demo Data erases the kept workouts' audit log | 2 | **3** | ✓ |
| Weight unit isn't frozen when a workout locks | 0 | **3** | — |
| Workout-tab Delete has no confirmation | 2 | **3** | ✓ |
| Workout-tab "delete this and future" ends every rule | 0 | **3** | ✓ `TodayWorkoutView.swift:525-536` |
| Opening Calendar ▸ Edit routine soft-deletes other recurring rules | 0 | **3** (in some form; escalated by boundary run 3) | ✓ code path, runtime timing untested |
| Four different "which day is this workout" rules | 0 | **3** | — |
| `project.yml` bundle id and camera string drift | 1 | **3** | ✓ |
| Dark Mode not handled (white on white) | 0 | **3** (config ×2, flows ×1) | ✓ no lock; visuals untested |
| Reconcile scans every historical routine version | 0 | **3** | ✓ `CatalogSyncService.swift:51-63` |
| Calendar weekday header offset | 1 | **3** | ✓ |
| Weight shown truncated with `Int(weight)` | 2 | **3** | — |
| CSV `setK`/`set_cooldown` promised, then overwritten by sync | 1 (partly) | 2 (boundary) | ✓ |
| A cancelled "Create new routine…" makes the next launch wipe demo data | 0 | 2 (boundary) | ✓ `SeedDataService.swift:52-75` |

**What it means.**
- Split rounds agree with each other on almost every serious item.
- Broad runs agree on about a fifth of their findings (10-17 report).
- Splitting mainly removes the "which thread did this run happen to follow" variance.

## 3. Bugs that cross areas

The main risk of splitting was missing bugs that span areas. It didn't happen.

- **Unprompted.** The history area runs found both known cross-area bugs (the distance P0 and the demo audit erase) every round, without being told about them. The user-flows runs also flagged the distance P0's cause as out of area in 2 of 3 rounds.
- **New finds.** The boundary runs added 8–15 confirmed findings per round that no area or broad run had. The most valuable:
  - CSV per-routine sets being overwritten
  - demo-data graduation triggered by a routine the user cancelled
  - a sheet import bringing back days the user had deleted
  - Delete Demo Data keeping a workout but deleting its exercises
  - an auto-started empty workout counting as "recorded"
  - two importers matching routine names differently in one run
- **Escalations.** Boundary runs also escalated listed items when they found a worse effect across areas. Two examples: the stray-routine finding turned into an automatic demo wipe, and the schedule-collapse finding turned into a routine vanishing from all future days.

## 4. What the split missed

A few items appeared only in broad runs, all P3 or unconfirmed:
- the rest timer's stale "go" beep
- a UTF-8 BOM in a CSV header
- the snapshot call-order coupling
- duplicated notification code
- a temp export file that's never removed
- the SetBuilder `ForEach` stale-index risk

Nothing P0, P1 or P2 was found only by the broad runs.

## 5. Recommendation

1. **For a full audit, use split + boundary.** It goes about 3× deeper and is far more consistent. It catches bugs that cross areas at least as well as broad runs do, for about 3× the tokens.
2. **Config is the cheap win.** Each config run is about 110k tokens and the results are almost deterministic.
3. **Keep one broad run, or the boundary pass.** The boundary pass replaces most of what the broad run adds. For whole-app items (health rating, refactor order, what not to change), keep one broad run or ask the boundary run for them.
4. **One split round is enough for routine audits.** Rounds agree well. Run 2–3 rounds only before risky work such as migrations, releases or big refactors.
5. **Make it permanent only after benchmarking it.** This used prompts on the existing auditor. If you adopt it, turn the four areas and the boundary run into agent definitions with benchmark cases (as `swift-reviewer` has), and add "don't read in-progress review reports" to the auditor's instructions.

## 6. Combined priority list (verified items only)

| P | Item |
|---|---|
| P0 | A distance-only workout is locked as "In Progress" (`WorkoutRepository.swift:248-293` vs `WorkoutSession.swift:119`) |
| P1 | Restore re-attaches deleted sections and exercises (`ExportImportService.swift:357-369`) |
| P1 | Opening Calendar ▸ Edit routine can soft-delete a routine's other recurring rules (`RoutineEditorView.swift:262-301`) |
| P1 | Workout-tab "delete this and future" ends every rule, including unrelated ones (`TodayWorkoutView.swift:525-536`) |
| P1 | Workout-tab Delete has no confirmation (`TodayWorkoutView.swift:499-507`) |
| P1 | Delete Demo Data erases the kept workouts' audit events (`DemoDataManager.swift:51, 66-79`) |
| P1 | `project.yml` bundle id and camera string drift (`project.yml:31`) |
| P1–P2 | Reconcile rewrites notes, rest and machine on logged exercises in unfinished workouts (`CatalogSyncService.swift:114-116`) |
| P2 | A cancelled "Create new routine…" makes the next launch auto-delete all demo data (`SeedDataService.swift:52-75`, `ScheduleWorkoutSheet.swift:187-193`) |
| P2 | CSV `setK`/`set_cooldown` are overwritten by the library on the next sync (`CatalogSyncService.swift:71-81`) |
| P2 | Reconcile scans every historical version, so the cost grows with history (`CatalogSyncService.swift:51-63`) |
| P2 | Dark Mode isn't locked or supported (no `UIUserInterfaceStyle`; `Theme.surface` is white) |
| P2 | Calendar weekday header is offset in Monday-first regions (`CalendarView.swift:136` vs `:416-417`) |

Unverified but reported in all 3 rounds: weight unit not frozen, four day-assignment rules, `Int(weight)` truncation, and the rest-bar +30s / Done / Reset semantics.

## Raw data

Per-run summaries are in `/private/tmp/claude-501/-Users-john-Documents-Claude-Projects-WorkoutApp/31ecd11b-45c9-4684-88ba-06fc03b3609c/scratchpad/split-runs/` and `.../audit-runs/`. They are session-scoped and will not survive the session.
