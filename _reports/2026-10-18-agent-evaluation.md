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

**To do before the numbers mean anything:** fix the two real issues in `02-clean`, re-run `01-complexity` with root-relative paths (expect the harness to agree with the hand count), and run each case 3× for consistency.

## Limits

Static reading plus one routing pass of 8 prompts. No effectiveness measured. The refactorer changed once during the run; its findings refer to the 10:55 version, and the fixes above were applied after the report, unmeasured.
