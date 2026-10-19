# Agent evaluation: ios-codebase-auditor and ios-codebase-refactorer (2026-10-18)

`review-agent-evaluator` checked both project agents after today's edits. Pre-edit snapshots: `~/.claude/agent-evals/ios-codebase-auditor/snapshots/2026-10-18-before-complexity-section.md`, `~/.claude/agent-evals/ios-codebase-refactorer/snapshots/2026-10-18-before-no-commit.md`. Neither agent has a benchmark, so this is a validity and routing check only: no recall or precision was measured.

## What was edited today, before the evaluation

| Agent | Change |
|---|---|
| ios-codebase-auditor | New §8 "Unnecessary complexity" (long or multi-purpose functions, nested conditionals and flag variables, special-case piles, single-use abstractions, hand-rolled stdlib, long parameter lists, state threaded through layers); each finding must give the simpler form and the test that proves equal behaviour, else PLAUSIBLE. Description mentions complexity. Step 1 reads the project `CLAUDE.md` (the "no CLAUDE.md" line was stale). |
| ios-codebase-refactorer | Step 6 no longer commits; the user commits. Step 3 makes a pinning test mandatory before every change that isn't a pure removal or move; no test possible → Category C, ask the user. Batch report names the test. |

## Trigger routing (auditor, 8 prompts, one pass)

| Prompt | Expected | Result |
|---|---|---|
| is there code here that could be simplified | route | PASS |
| audit this codebase for bloat | route | PASS |
| what state is this repo in | route | **FAIL**, main session answered itself |
| before I start refactoring, tell me which parts of this app are risky to touch | route | **FAIL**, main session answered itself |
| review this PR | don't | PASS |
| find dead code | don't (dead-code-finder) | PASS |
| fix this crash | don't | PASS |
| I just edited SessionEditorView.swift, check my change for Swift mistakes | don't | PASS (but swift-reviewer didn't fire either; out of scope) |

6/8. Both misses are question-form prompts; the global "Questions vs. Instructions" rule plausibly pulls the main session to answer directly. Cost of the pass: about $10–12.

## Findings and what was done

| # | P | Agent | Finding | Verdict | Action |
|---|---|---|---|---|---|
| 1 | P0 | refactorer | The no-commit rule is prompt-only. `tools` grants Bash under `permissionMode: default`, and `.claude/settings.local.json` lines 10, 15, 26–28 pre-approve `git stash`, `git checkout`, `git add`, `git commit -m`, `git push`, so nothing but the prompt stops a commit. | CONFIRMED | **Fixed (user's choice, 2026-10-18):** the five git allow entries were removed from `.claude/settings.local.json`, so git writes prompt again for every session; and the refactorer's frontmatter now carries a PreToolUse hook on Bash, `.claude/hooks/refactorer-git-guard.py`, which exits 2 on commit/add/stash/push/reset/checkout/restore/rebase/merge/cherry-pick/switch/rm/mv/tag/clean/am/apply/revert, including `git -C … commit` and quoted subcommands, and across `&&`/`;`/`|` chains; `git status/diff/log/branch --show-current` pass. Tested offline with sample payloads; not yet observed inside a live subagent run (the benchmark's refactorer case will). Background from the docs (sub-agents, permissions, hooks): a `disallowedTools` entry with a specifier such as `Bash(git commit *)` removes *all* of Bash from the subagent, so that route is out. The remaining options: an agent-scoped PreToolUse hook in the refactorer's frontmatter (runs only while that agent runs, exit 2 blocks the call; command-text matching, so `git -C . commit` would slip past), a `permissions.deny` rule in settings (beats every allow rule, but also blocks the main session's commits when the user asks for one), or trimming the allow entries from `settings.local.json` so git commands prompt again. The settings files are the user's permission config; not changed. |
| 2 | P1 | refactorer | Line 58 still said the project has no `CLAUDE.md`. | CONFIRMED | Fixed: mirrors the auditor's Step 1. |
| 3 | P1 | refactorer | Step 3's no-test → Category C rule silently reclassified three listed A/B examples (view fragments, work out of `body`, `ForEach` identity). | CONFIRMED | Fixed: the three examples are annotated as view-body work that is Category C unless a unit test, screenshot or UI-test check applies. |
| 4 | P1 | refactorer | The Category A carve-out was defined by exclusion and stalled a plain file split. | CONFIRMED | Fixed: positive list — dead code, dead helpers, unused imports, debug logging, moving code without editing it. Everything else pins first. |
| 5 | P1 | auditor | Question-form whole-repo prompts don't route to it. | CONFIRMED | Fixed in the description: "Use PROACTIVELY for whole-codebase health or refactoring-readiness questions… even when phrased as a question", with a negative scope. Not re-measured. |
| 6 | P2 | auditor | §8 overlaps §1–§3 with no report-once rule. | PLAUSIBLE | Fixed: report each item once, under the first area it fits. |
| 7 | P2 | auditor | No batch assignment for non-view complexity findings. | PLAUSIBLE | Fixed: Batch 2; view-body in Batch 3; never Batch 1. |
| 8 | P2 | auditor | §8 used PLAUSIBLE for "unprovable change", not "unprovable finding". | PLAUSIBLE | Fixed: the Possible Issues section now admits both meanings and names the test to write as the verification. |
| 9 | P2 | refactorer | Step 3 runs one test; Step 5 forbids subsets. | PLAUSIBLE | Fixed: Step 5 excepts the Step 3 runs. |
| 10 | P2 | refactorer | Stop condition accepted a manual checklist; Step 3 didn't. | PLAUSIBLE | Fixed: the stop condition now refers to the pinning test, with a checklist only for approved Category C work. |
| 11 | P2 | refactorer | The pinning-test report line lacked the file and floated above "Include:". | CONFIRMED | Fixed. |
| 12 | P3 | auditor | "short sketch" vs "Do not write code". | PLAUSIBLE | Fixed: "one line of prose or pseudocode, no Swift". |
| 13 | P3 | auditor | Removing one-user abstractions brushes the no-pattern-conversion guardrail. | PLAUSIBLE | Fixed: bounded by that rule; Why It Matters must state the material cost. |
| 14 | P3 | refactorer | `git force-push` isn't a command; rule inside an "Examples:" list; "when they ask for it" ambiguous. | CONFIRMED | Fixed: `git push --force`; the B rule is a sentence after the examples; "the user commits, in their own session, when they choose to". The two forbidden-git lists are left as they are (different purposes: destructive commands vs. any Git-state change). |
| 15 | P3 | auditor | Step 1 matches the tree, but `CLAUDE.md` and `.claude/agents/` are untracked. | CONFIRMED | Part of the pending commit. |
| 16 | P3 | both | `effort:` frontmatter key unverified; the agents README documents fewer keys. | Resolved | `effort` is a documented subagent field (low/medium/high/xhigh/max). Unrecognised keys fail silently, so spelling matters. README not updated. |
| 17 | — | both | No benchmark; §8 now warrants one. | CONFIRMED (absence) | **Open, needs the user.** The evaluator sketched the fixture: one planted item per §8 bullet, decoys for a two-conformer protocol, a long but linear function, an unused function (lead only), a tested view model that must not land in Batch 3; one clean case; `read_only: true`. For the refactorer: a planted duplicate formatter, scored on `tools.jsonl` for git commands and on the pinning test appearing before the edit. |

## Still to decide

1. ~~Enforcing no-commit outside the prompt~~ — done: hook plus trimmed allow-list (finding 1).
2. **Benchmark** for the auditor's §8 and the refactorer's no-commit and pin-first rules (finding 17). Until it exists, the complexity area is unmeasured and its false-positive risk is unknown.
3. **Re-run the trigger check** after the description change (about $10) or accept the edit on reading.

## First benchmark runs (2026-10-18, one run each)

| Case | Cost | Time | Harness score | Hand adjudication |
|---|---|---|---|---|
| auditor `01-complexity` | $2.83 | 7.3 min | recall 0/7, FP 0 | **Recall 7/7**: every planted §8 item found, each with its simpler form and the covering test or the test to write. Decoys 0/4 flagged. Batch placement right: §8 items in Batch 2, the threaded binding in Batch 3, the tested view model in Batch 2. Verdicts 4/7 against the key (three untested items were CONFIRMED where the key said PLAUSIBLE). Bonus: a real, unplanted bug, `RestTimerModel.isRunning` is false right after `start()` so the timer loop never runs (`RestTimerModel.swift:15,18`, confirmed by reading). |
| auditor `02-clean` | $2.07 | 5.8 min | FP 13 | Most "false positives" are real findings on a fixture that isn't clean: `try? context.save()` twice discarding errors (§6), the done-set rule written twice (§2). Genuine §8 nitpicks: 2, both P3 (`?? []` after a key lookup; two near-identical test builders). 1 key-listed FP (the `fatalError` init, raised as a PLAUSIBLE product decision). |
| refactorer `01-pin-first` | $2.06 | 4.6 min | `check_run.py` PASS ×3 | No git write attempted; pinning tests (17 new) written at call 19, first production edit at call 21; `swift test` run five times, including between pin and change. The git-guard hook was not exercised here (no git write, and the hook file isn't in the fixture); it was exercised live in the project instead: `git stash list` blocked, `git status` and `git branch --show-current` allowed. The guard now lets `stash list`, `stash show` and `tag -l` through. |

**Why the harness scores are wrong for the auditor.** `score.py` matches file paths exactly, and the auditor cited `Services/PlanImporter.swift` where the key says `Lifts/Services/PlanImporter.swift`; and its format score expects per-finding `category`/`verdict`/`summary` fields the auditor's 8-column table doesn't have. Fixes made: the auditor must now cite paths from the repository root (contract change, good for merging too). Not changed: the parser; its format score will stay 0 for this agent until the shared contract gains those fields or the parser learns this table.

**Contract change from the run.** The §8 "PLAUSIBLE when the change isn't yet proven behaviour-preserving" rule was dropped: it conflicted with the Validation column's "or the test to write first", the agent didn't follow it, and the evaluator had already flagged (finding 8) that it changed PLAUSIBLE's meaning. A complexity finding is CONFIRMED when the code is as described; the test to write goes in Validation and the refactorer's Step 3 enforces it. The answer key's four untested items are now `CONFIRMED` to match.

## Second runs (2026-10-18, after the fixes and the path contract)

| Case | Cost | Time | Harness | Hand |
|---|---|---|---|---|
| auditor `01-complexity` | $2.68 | 8.6 min | **recall 6/7, precision 1.0, FP 0, decoys 0** | 7/7: the one "miss" (the one-conformer protocol) was reported as a PLAUSIBLE P3 in a numbered list the parser doesn't read. Batches: §8 items in Batch 2 with the test to write named first; the threaded binding in Batch 3; the tested `label` collapse in Batch 1, which the contract then forbade but which is right when an existing test pins it. Found the real `try?` sites and the missing `.gitignore` as well. |
| auditor `02-clean` (first fix) | $2.54 | 6.9 min | FP 5 | Health "Healthy", complexity "Low". 1 defensible P1 on code added by the first fix (mutate-then-save with no rollback), 2 P3s the fixture's README invites (views in the app file; three test builders), 1 P3 §8 note, 1 self-labelled "stylistic preference only". Genuine §8 FPs: 1 P3. |

**Contract changes from the second runs:** a complexity finding pinned by an existing test may go in Batch 1 (Validation names the test); the Confirmed table and the Possible Issues table both carry a Verdict column and Possible Issues must be a table, so the harness (and anyone merging reports) reads verdicts per row. **Fixture changes:** `02-clean` revised a second time (rollback on failed save, views out of the app file, one shared test builder, locale-safe formatter tests, a declared test scheme); `01-complexity`'s unplanted rest-timer bug fixed.

## Third runs (2026-10-18, 3× each): half lost to the usage limit

| Case | Runs completed | Cost (all 6) | Result |
|---|---|---|---|
| auditor `01-complexity` | 1 of 3 | $5.96 | The completed run: 6/7 by harness, 0 FP, 0 decoys, same as run 2. Runs 1 and 3 ended after 29 and 33 turns with "You've hit your session limit · resets 4pm": the claude.ai usage limit, not the agent. |
| auditor `02-clean` (2nd revision) | 2 of 3 | $5.95 | Both: Health "Healthy", complexity "Low". Confirmed rows were all P3 and mostly self-labelled "stylistic": the `switch` with expression patterns (both runs), file placement, a `var` that should be `let` in a test. One P2 on the week anchor depending on the query's sort order (fair). Possible Issues were legitimate §4/§5/§6 notes on the fixture: no VersionedSchema, `toggle` not checking the set belongs to the session, per-render derivation cost, placeholder bundle id, two correct dead-code leads. Run 2 hit the usage limit; it had also run `rm -rf /tmp/lifts-audit-…` to remove a temp folder it made, which the read-only check counts as a forbidden command (nothing in the repo was touched). |

So consistency wasn't measured: one complete run on `01-complexity`, two on `02-clean`. The three aborted runs cost $4.77 for nothing. Lesson for the harness: `run_case.py` should detect the usage-limit message and stop the batch instead of spending the remaining runs.

**Key redesign for `02-clean`.** A seven-area auditor keeps finding legitimate §1/§4/§5/§6 items on any fixture, so "exhaustive: every finding is a false positive" measured the fixture, not the §8 area. The key is now non-exhaustive with five decoys scoped to the §8-shaped code (the idiomatic `switch`, per-render derivation, the save/rollback, the week-block routine, the `fatalError` init); `decoy_hits_confirmed` is the §8 false-positive number, and everything else is adjudicated by hand. Fixture revised a third time to remove the legitimate findings: inverse relationships so `toggle` finds its own session, a `VersionedSchema` and migration plan, the week anchor from `min()` rather than the query's sort, `TodayScreen` in its own file, a real bundle id prefix.

## Fourth runs (2026-10-18, 3× each, all completed)

**`01-complexity`** ($8.54 for three): after the key corrections below, recall by harness 0.952 (six items 3/3, the one-conformer protocol 2/3: it was discussed in every run, once only in prose), precision 0.933, `decoy_hits_confirmed` 0 in all three runs. Consistency (Jaccard on the planted items) 0.905. Batch placement in all three: `label` collapse in Batch 1 with its test named, the other §8 items in Batch 2 with the test to write first, the threaded binding in Batch 3. Before the corrections the harness reported decoy hits (3/3, 2/3, 2/3) and 9 "false positives"; by hand none was a complexity finding on a decoy: the hits on the two-conformer protocol's range were the repeated sort closures inside the exporters (a real §2 duplication at lines 26-27 and 40-42), a locale/CSV finding, and the dead-code leads the key expects; the hits on the demo seeder's range were §1 placement findings and a real bug (`enumerated()` offset used as `order` over an unordered SwiftData relationship). The unlabeled findings were true: `try?` saves, no `VersionedSchema`, the Today selection rule, `startedAt` never set by ticking a set. One run wrote a scratch Swift file under `mktemp -d` and ran `swift` on it to verify a locale claim (flagged by the read-only check; nothing in the repo touched).

**`02-clean`, third revision, redesigned key** ($5.08 for the two that completed; a third stalled for 25 minutes after `xcrun simctl list devices`, apparently about to build the fixture, and was stopped by hand; a replacement run was started). Both completed runs: Health "Healthy", complexity "Low", **`decoy_hits_confirmed` 0**. Each touched one decoy only as a PLAUSIBLE note (the `fatalError` init as a crash-loop risk; `rollback()` discarding all unsaved changes), which the key allows. Consistency 1.0 on the decoy set. Unlabeled findings (9 and 8) adjudicated: all legitimate or defensible non-§8 items on the fixture, mostly P3: no `.gitignore` (both runs), `Failure` not `LocalizedError`, README saying weights are "converted for display" when nothing converts, `TodayScreen` fetching every session for one row, five tests repeating two stamping lines, the week anchor taken from all sessions while the list is filtered to locked ones, dead-code leads. No run called sound code complex. One run ran `swiftc -typecheck` on the fixture into a `mktemp` module cache, which the read-only check flags; nothing in the repo was touched.

**Replacement third `02-clean` run** ($2.42): Healthy / Low. `decoy_hits_confirmed` 1 by the harness: a CONFIRMED P2 saying the locked-sessions filter and the week anchor are "two rules computed inline in `body`" that belong in `HistoryStats` next to `thisWeek`. By hand that is a §1/§3 ownership finding (and a fair one), not a claim that the derivation is complex or should be cached, so I don't count it as an §8 false positive; the harness can't tell the two apart because the decoy is a line range. Other findings as in the first two runs, plus a VoiceOver label note and four dead-code leads. Three runs on the third revision in all: Healthy / Low each time, §8 false positives 0 by hand, 1 by harness.

**Overall after the fourth batch (eight completed runs today).** The §8 area finds all seven planted kinds of complexity (recall 0.952 over three runs, Jaccard 0.905), puts them in the right batch with the proving test named, and has not produced a confirmed complexity finding on sound code in any run. Its non-§8 output on the clean fixture is a steady stream of small, mostly correct §1/§4/§6 notes, which is the agent doing its other six areas. Costs: $2.1–3.1 per auditor run; the whole day's benchmarking came to about $46, of which $4.77 was lost to the usage limit and about $5 to a stalled run.

**Key and fixture corrections from this:** the two-conformer decoy is narrowed to the protocol and the CSV conformer's head (lines 15–24) so the exporters' real duplication is not inside it; `DemoData` moved to `Lifts/Services/DemoData.swift` with its order bug fixed, so the seeder decoy covers only the seeder; the protocol item accepts its call sites as anchors.

**Still to do, optional:** a `01-complexity` 3× on the corrected key to confirm the re-scored numbers from fresh output; make `run_case.py` stop a batch when a run reports the usage limit; teach the parser the auditor's table so format compliance stops reading 0, when the usage budget allows (~$8 per case).



## Limits

Static reading plus one routing pass of 8 prompts. No effectiveness measured. The refactorer changed once during the run; its findings refer to the 10:55 version, and the fixes above were applied after the report, unmeasured.
