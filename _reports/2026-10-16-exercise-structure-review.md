# Exercise structure (stages 1–5) review — 2026-10-16

Scope: the new exercise data structure (kinds, editor, routines/rest, workout playback, backup v4, demo data). CSV importers excluded (owned by a parallel session). Reviewed by the swift-reviewer subagent; findings verified before fixing. Full suite after fixes: 175/175 (iPhone 17 Pro simulator), including the parallel session's CSV tests.

Verdict before fixes: NEEDS-WORK.

## Fixed

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | High | Older CSV imports shared one Machine across exercises (real data: "Home Elliptical" used by two cardio exercises; also in demo data). Per-machine weight/settings/photo then spilled between exercises. | `ExerciseStructureMigration.splitSharedMachines`: the oldest exercise keeps the machine; each other gets a copy (name, photo, weight, settings). Its default sets, routine plans and workouts in progress move to the copy; finished workouts keep the original. Runs on every migration pass; repeatable. Test: `SharedMachineSplitTests`. |
| 2 | High | SessionEditorView set editing passed per-side-expanded sets (L,R,L,R) as exercise defaults, doubling them on every save. | Passes one entry per set (first side), then `readBackSets` so Reps/Sets/weight stay in step. |
| 4 | Medium | SessionEditorView skipped `readBackSets` and still wrote per-exercise rest. | Fixed with #2; per-exercise rest no longer written. |
| 5 | Medium | Workout list rows, in-workout editor rows and history detail showed old fields for new kinds (Calisthenics sets hidden, Distance not shown, Intensity from the old field, sides not shown, doubled set counts). | Rows use the kind summary; history detail shows sets for any set-based kind, kind fields (Hold/Reps/Per side/Sets, Rounds, Distance planned/done, Intensity) and "Set n · Side". |
| 6 | Medium | Editor dropped an exercise-level photo for Steady/Intervals with a named machine; switching to Distance cleared the machine's photo and settings. | Exercise photo carried onto the machine on load; Distance leaves the machine's photo and settings alone. |
| 8 | Medium | Peek sheet showed a background cardio/stretch run's countdown on an unrelated exercise. | Only when the run includes the exercise on screen. |
| 9 | Low | `saveStructureToCatalog` could rebuild a set-based exercise's default sets without its machines. | Guarded to non-set kinds. |
| 10 | Low | A logged distance didn't count as "something done" → workout discarded. | `hasAnythingDone` counts `actualDistance`. |
| 11 | Low | Skip on the last exercise acted like completion (rest / finish prompt). | Skip just closes the sheet. |
| 12 | Low | A 0-minute Steady could not be completed (Complete hidden, nothing to time). | Complete stays available when there's nothing to time. |
| 13 | Low | Editor machine blocks used captured indices — stale-index crash risk on delete. | Binding-projected `ForEach($machines)`. |
| 14 | Low | HoldCountdown ticked 5×/s while idle; 0-second holds could never finish. | Ticks only while running; Start disabled for 0 s. |
| 15 | Low | Two buttons in one List row used `.plain`. | `.borderless`. |
| 16 | Low | Migration counted soft-deleted machines toward Machine vs Bodyweight. | Filtered. |

## Not changed

| # | Finding | Why |
|---|---|---|
| 3 | Every editor save rebuilds default sets as uniform sets × reps @ weight, losing per-set variation. | By spec: "Reps is one number"; one weight per machine. |
| 7 | A Calendar-opened workout sheet can stop a guided run started on the Workout tab (`stopsGuidedRunOnDisappear`). | Pre-existing behaviour, not introduced here; not confirmed reachable. |
