# Project subagents

WorkoutApp has no project-specific agents. It uses the user-level iOS agents
(`~/.claude/agents/ios/`, from the process repo's `agents/ios/`): swift-reviewer,
regression-reviewer, ios-codebase-auditor, ios-codebase-refactorer, schema-migration-reviewer,
design-sync-reviewer, release-readiness-checker and accessibility-reviewer.

They read this project's facts from `README.md` and `.claude/agent-context.md`. Put a
project rule there, not in a copy of an agent: an agent file in this folder with the same
name replaces the shared one here, and stops getting its improvements.
