# Agent drift and consistency review — 2026-10-17

Scope: the three project agents (`.claude/agents/swift-reviewer.md`, `ios-codebase-auditor.md`, `ios-codebase-refactorer.md`) and the two global agents used on this project (`~/.claude/agents/dead-code-finder.md`, `review-agent-evaluator.md`). I left out the six `senstream-ringkit2-*` agents because they belong to another project. I did this review by hand with no subagent, checking each agent's claims against the code and against the 14 reports in `_reports/`. No files were changed apart from this report.

## Drift: agent text vs. the code

| # | Where | Finding | Evidence |
|---|---|---|---|
| D1 | `ios-codebase-auditor.md:33`, `ios-codebase-refactorer.md:37` | Both list "warm-up, cooldown, and workout sections" as behaviour to preserve. Those sections don't exist. The only section types are strength, cardio and stretching. In the code, "cooldown" means rest between sets. | `Enums.swift:27-30`; `Routine.swift:182` |
| D2 | `ios-codebase-auditor.md:55-57`, `ios-codebase-refactorer.md:53-55` | Both say to read `CLAUDE.md`, `.claude/CLAUDE.md` and `.claude/rules/` first. None of these exist in the repo. The project's real rules are in `README.md` ("Design principles", "Protecting trust in the data") and in auto-memory (green = actionable, the sheet header standard, the splash standard). Neither agent is pointed at either one. | `ls` of the repo root and `.claude/` |
| D3 | `.claude/agents/README.md:31-32` | The README says to commit agents so the team shares them, but `.gitignore:37` ignores all of `.claude/`. The agent definitions have no history, so you can't see or revert drift in them. | `git check-ignore -v` |
| D4 | `ios-codebase-refactorer.md:198` | The example simulator is `iPhone 16`. Every test run in the reports since 10-16 used iPhone 17 Pro. This is minor, because line 202 says to use what is actually found. | `_reports/2026-10-16-*` |
| D5 | `swift-reviewer.md:16-24` | **No drift.** All four project-specific pitfalls still match the code: the `updatedAt` dependency (`WorkoutRunnerView.swift:51`), `lockedAt`/corrections (`WorkoutSession.swift:16-20, 66`), `unicodeScalars` CSV parsing (`CSVRoutineImporter.swift:737`). | — |
| D6 | `dead-code-finder.md` | **No drift.** It is byte-identical to the benchmarked snapshot `agent-evals/dead-code-finder/snapshots/2026-09-14-after-fixes.md`. | `diff` |

## Inconsistent analysis across agents and runs

| # | Finding | Evidence |
|---|---|---|
| I1 | **There is no shared severity scale.** `swift-reviewer` defines only PASS / NEEDS-WORK (`swift-reviewer.md:30`), yet its reports carry High/Medium/Low, so severity is invented on each run. `ios-codebase-auditor` requires P0–P3 (`:235-240`), but the 10-17 audit came out as H/M/L. `dead-code-finder` emits CONFIRMED/PLAUSIBLE (`dead-code-finder.md:107`), which the 10-17 report turned into "Confidence: High". Three vocabularies are translated by hand, so findings can't be compared between reports. | `_reports/2026-10-17-codebase-audit.md`, `2026-10-08-workout-tab-review.md`, etc. |
| I2 | **Evidence standards differ.** `dead-code-finder` must state the searches that prove each finding (`:104`). The auditor only has to "verify with searches" (`:79`). `swift-reviewer` has no standard at all. Verification in the reports varies too: most say "findings verified before fixing", but the 10-17 audit says "everything else is as reported by the agents". | `2026-10-17-codebase-audit.md:6-7` |
| I3 | **Dead code is covered by two agents.** The auditor's brief includes dead code (`:115-120`), so the 10-17 report mixes "High" rows from dead-code-finder with "High (auditor)" rows, and those were reached under different evidence rules (I2). | `2026-10-17-codebase-audit.md`, Dead code table |
| I4 | **"PASS" means different things.** `swift-reviewer` verifies only statically (`:7, 27-28`), and its balance check counts braces inside strings and comments (`:13-15`). The refactorer requires a build and tests (`:182-189`), and your global rule requires full regression testing after agent-driven fixes. A swift-reviewer PASS doesn't mean the code builds or the tests pass. | — |
| I5 | **Gaps in swift-reviewer's checklist.** Some problems keep coming up in reports but aren't on its list: timer-driven `body` re-runs and fetches in `body` (M1/M2), silent `try? context.save()` (72 sites), hard-coded "lb" (L3), and demo/user data separation. Unless the checklist is updated, each run finds these by chance or misses them. | `2026-10-17-codebase-audit.md` M1, M2, L3, L6 |
| I6 | **The project agents are never evaluated.** `review-agent-evaluator` only covers `~/.claude/agents/*` (`review-agent-evaluator.md:32`), and only dead-code-finder has a benchmark. `swift-reviewer` produced 11 of the 14 reports, yet it has no benchmark and no consistency measurement. | `~/.claude/agent-evals/` |

## Lower-confidence notes

- **Malformed frontmatter.** In the auditor and refactorer, line 2 is blank and the frontmatter closes with `-------------` / `------------` instead of `---`. This looks like a Markdown formatter turned the closing `---` into a horizontal rule. The tool lists load correctly (the agent registry shows the right tools). **I could not verify** whether `permissionMode`, `effort` and `color` are honoured with that delimiter.
- **The refactorer commits on its own** (`:204-217`). With about 110 uncommitted files in the tree, its rule against including unrelated user changes is hard to follow safely.

## Suggested fixes (not applied)

1. Fix D1 and D2 in both long agents: use the real section types, and point them at `README.md` and the project rules instead of files that don't exist.
2. Give all agents one severity and verdict scheme: P0–P3 plus CONFIRMED/PLAUSIBLE, with the dead-code-finder field contract.
3. Remove dead code from the auditor's brief, or make it follow dead-code-finder's evidence rule.
4. Add the I5 pitfalls to swift-reviewer, and say plainly that PASS is static-only.
5. Un-ignore `.claude/agents/` in `.gitignore`.
6. Restore the `---` frontmatter delimiters.
7. Optionally, build a small benchmark for swift-reviewer.

## Fixes applied (2026-10-17)

- **D1:** both long agents now list only strength, cardio and stretching sections, and explain what "cooldown" means here.
- **D2:** both now read `README.md`, the project memory index, recent `_reports/` and `project.yml`/the `.xcodeproj` instead of files that don't exist.
- **D4:** the refactorer's example simulator is now iPhone 17 Pro.
- **I1:** one scale everywhere: P0–P3 plus CONFIRMED/PLAUSIBLE. The auditor maps "Confirmed" to CONFIRMED and "Requiring verification" to PLAUSIBLE. `swift-reviewer` gives every finding a severity and verdict and has a NEEDS-WORK rule (any CONFIRMED P0/P1). `.claude/agents/README.md` explains how `dead-code-finder` output is merged.
- **I4 (partly):** `swift-reviewer` now says PASS is static-only.
- **Frontmatter:** the closing `---` is restored in the auditor and refactorer, and the blank line after the opening one is removed. Re-parsed, all keys present.
- **Not done:** D3 (`.gitignore`), I3 (dead-code overlap), I5 (checklist gaps), I6 (benchmark). Backups of the pre-fix files are in the session scratchpad.
