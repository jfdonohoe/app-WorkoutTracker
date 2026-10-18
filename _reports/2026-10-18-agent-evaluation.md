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

## Limits

Static reading plus one routing pass of 8 prompts. No effectiveness measured. The refactorer changed once during the run; its findings refer to the 10:55 version, and the fixes above were applied after the report, unmeasured.
