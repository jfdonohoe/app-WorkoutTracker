# Agent benchmarks: swift-reviewer, plus making dead-code-finder the only dead-code owner (2026-10-17)

This follows `2026-10-17-agent-drift-review.md`. Everything below was measured with the harness in `~/.claude/agent-evals/`, at 3 runs per case. Across 66 runs (including two discarded rounds), the total cost was **$8.09**.

## 1. New benchmark: swift-reviewer

Location: `~/.claude/agent-evals/swift-reviewer/`. Each case is a small fake SwiftData app ("Lifts"), and the prompt is "review the most recent commit".

| Case | What it tests |
|---|---|
| `01-defects` | One planted defect for each checklist item: observation, a write to locked history, CSV split by `Character`, unstyled row buttons, a `.sheet` + `.fileImporter`, a missing brace. Each sits next to correct look-alike code. |
| `02-decoys` | The same feature written correctly. Every pitfall has a look-alike, including braces inside a string literal that fool the naive count. Exhaustive. |
| `03-clean` | A small, correct, wired-up feature (display unit). Exhaustive. |

`triggers.json` has 2 prompts that should route to it and 4 near-miss negatives. I haven't run the trigger check.

### Agent change measured

The **before** version uses only the P0–P3 and CONFIRMED/PLAUSIBLE scheme from the drift review. The **after** version adds:
- separate `file` and `line` keys
- a closed `category` list (`balance`, `swiftdata-observation`, `immutability`, `csv-parsing`, `list-row-buttons`, `presentations`, `correctness`)
- `short_summary`
- a literal example finding
- "no scratch files, even in `/tmp`"

| | Before | After |
|---|---|---|
| Recall, 01 (mean / min) | 0.83 / 0.67 | **1.0 / 1.0** |
| Observation defect found | 1/3 | **3/3** |
| Presentations defect found | 2/3 | **3/3** |
| Run-to-run consistency (Jaccard), 01 | 0.77 | **1.0** |
| Overall verdict right (NEEDS-WORK / PASS / PASS) | 9/9 | 9/9 |
| False positives rated P0/P1 (all cases) | 0* | **0** |
| Any false positive (P2/P3 nits on exhaustive cases) | 9 | 5 |
| Category accuracy | n/a (no field) | 0.95 |
| Verdict accuracy (CONFIRMED where expected) | 0.91 | 0.84 |
| Format compliance | 0.0 | 0.96–1.0 |
| Read-only violations | 1 run (wrote a Swift test file to `/tmp`) | 0 |

\*The before version has no categories, so it can't trigger the category-scoped decoys. Its decoy comparison isn't like-for-like.

**Reading it:**
- **Recall.** It finds every planted defect on every run now. Part of the "before" recall loss was its loose output format, which the parser read badly (see section 3).
- **False positives.** Every remaining one is a `correctness` P2/P3 nit (unused types, an unchecked field name, a duplicated `@AppStorage` key). None flagged a decoy for the pitfall it imitates, and none changed a verdict.
- **Verdict accuracy (0.84).** Almost all of it is the observation defect being rated `PLAUSIBLE`. That's defensible, because a missed re-render can't be proven statically. I left the answer key as `CONFIRMED` rather than tune it to the agent.

**Fixture lesson:** my first two fixture rounds had real bugs in the "correct" code: a Skip button calling the toggle action, a feature nothing used, an empty button action. The agent found them correctly. I fixed the fixtures and discarded those runs (`results/2026-10-17-baseline-fixture-v1-discard`).

## 2. Dead code: one owner

### dead-code-finder change

New rules:
- **Reachability over reference counts.** A reference only keeps code alive if the referencing code is live, and a `#Preview` of the same type doesn't count as a reference.
- **UI that can never be shown** (`unreachable-code`): the trigger state is never set to a presenting value.
- **Transitively dead code:** follow the chain and report every link.
- **New false-positive rule:** a presentation driven through a `Binding`, `.onOpenURL`, `.onReceive`, deep links or App Intents is live.

The cross-references between method steps were renumbered to match. The agent contains no fixture names (V9 check).

New case `05-swiftui-app`:
- **Dead code to find:** an always-nil computed property guarding a card, a full-screen cover whose flag is never set true, and the two-deep chain of views behind them.
- **Live decoys:** an `onOpenURL` sheet, a row-tap sheet, a flag set from a child view through a Binding, `@main`, a test found by naming convention, `#Preview` blocks.

| Case | Before (same model, today) | After |
|---|---|---|
| 01-node-api | recall 1.0, verdict 0.67 | recall 1.0, verdict 1.0 |
| 02-python-lib | recall 1.0, verdict 0.67 | recall 1.0, verdict 0.83 |
| 03-clean-cli | 0 FP | 0 FP |
| 04-next-app | recall 1.0, 1 decoy (unused local) 1/3 | recall 1.0, the same decoy 1/3 |
| **05-swiftui-app** | **recall 0.87 (min 0.6)**, consistency 0.73; the card and the row were each missed 1/3 | **recall 1.0 (min 1.0)**, consistency 1.0, verdict 1.0 |

No regression. The 09-14 results were on an older Sonnet. Today's unedited version already scores 1.0 on 01–04, so the only improvement attributable to the edit is on 05. The 04 decoy hit is present before the edit too, at one run in three, which is noise. The description is unchanged, so I didn't rerun the trigger check.

### ios-codebase-auditor change

Dead code is out of its brief: dead code, unused imports and extensions, commented-out code, and legacy files are removed from section 2, and step 5 now covers duplication only. It now says that dead code belongs to `dead-code-finder`, and that anything that looks dead goes once under "Possible Issues Requiring Verification" as a PLAUSIBLE lead. "Debug logging" stays.

**Not measured:** the auditor has no benchmark, so this change is untested. Its table format now parses (`Files` column alias), but no case exists for it.

## 3. Harness changes (`~/.claude/agent-evals/bin/`)

Backups are in the session scratchpad. The selftest passes: 279 checks, previously 244.

- **`findings.py`:**
  - A `**File:line:**` / `` `file:line` `` key is read as the file field. That was the cause of the swift-reviewer "before" parse failures.
  - An em/en-dash key separator (`` - `file` — path ``) is accepted.
  - A table `Files` column is read as the file.
  - An optional `severity` is parsed into P0–P3.
- **`score.py`:** adds `false_positives_p0p1` and `overall_verdict` per run, and `overall_verdict_accuracy` against an optional `expected_overall`.
- **`selftest.py`:** adds checks for all of the above, plus two real outputs saved as test data.
- **`README.md`:** documents the new answer-key fields and how to run a project agent (`--agent-file`).

## Still open

- swift-reviewer's checklist still lacks the problems that keep coming up in reports (I5 in the drift review), so the benchmark only covers its current six checks.
- No benchmark for `ios-codebase-auditor` or `ios-codebase-refactorer`.
- `.claude/` is still git-ignored, so the project agent files have no history.
- I haven't run `trigger_check.py` for swift-reviewer.
