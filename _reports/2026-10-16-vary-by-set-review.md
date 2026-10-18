# Vary by set — review (2026-10-16)

Scope: the "Vary by set" feature for strength exercises (Machine, Free weight, Bodyweight; Hold excluded). With it on, each set has its own weight and reps. The workout write-back still saves what was done. Progression is separate and not built.

The swift-reviewer subagent did the review, and its findings were checked before fixing. After the fixes, the full suite passes 187/187 on the iPhone 17 Pro simulator, including 12 new `VaryBySetTests` and one new Hold summary assertion.

Verdict before fixes: NEEDS-WORK. The editor's toggle and machine flows lost no data.

## Fixed

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | Medium | A workout that did different sets on a same-every-set exercise left the sets varying but the flag off, so the next editor save, even Notes only, flattened them back to Sets × Reps. | `readBackSets` turns `varyBySet` on when the sets it reads back differ (strength kinds only). Test: `testWorkoutWithDifferentSetsTurnsVaryOn`. |
| 2 | Medium | Changing a varying Free weight / Bodyweight exercise to Machine showed "Sets 0", then saved 3 × 10 @ 0. | Changing Type while varying carries the sets just shown into any empty list. |
| 3 | Low | The save fallback for an empty list used weight 0. | It now uses that machine's weight, or the exercise's weight / added weight. |
| 4 | Low | The "Use set 1 for every set" message could read "Every set will be ." or "0 lb × 10", and had no "+" for added weight. | Reads "10 reps" at zero weight, "+10 lb × 10" for Bodyweight, and "the same" if empty. |
| 5 | Low | The workout summary for Hold read "3 sets · 1 reps", with no hold time. | Now "3 × 1 · hold 30s", matching the library summary. The test is in `testUpNextSummaries`. |
| 6 | Low | The migration missed machines with the same values but different set counts, so a later save would give every machine the first one's count. | Different counts across machines also turn Vary on. Test: `testMigrationVariesWhenMachinesHaveDifferentSetCounts`. |
| 7 | Low | "1 reps" in range text. | "1 rep". |

## Not changed

| # | Finding | Why |
|---|---|---|
| 8 | Turning Vary off with more than 10 loaded sets, or reps over 50, clamps them to the Sets / Reps limits. | Same limits as the pickers. Only reachable with imported data past the limits. |
| 9 | A range like "90–110 lb × 6–10" doesn't pair each weight with its reps. | Matches the approved list design. The editor shows each set. |
| 10 | Two confirmation dialogs, an alert and a full-screen cover are attached to one List. | Separate modifiers are supported on iOS 17+. Not seen to fail; not checked by hand yet. |
