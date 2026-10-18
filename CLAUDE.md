# WorkoutApp project rules

These add to the global `~/.claude/CLAUDE.md`. This project follows `~/.claude/ios-project-standard.md` (adopted 2026-10-18).

## Versioning

Semantic Versioning, as set out in §10 of the iOS project standard: full release = X.0.0, point release = x.Y.0, dot release = x.y.Z.

- **Before every release push, TestFlight or App Store build,** run `/ios-version`. It suggests the number from the changes since the last release. I approve the number before anything changes.
- **Approved numbers** go in all 4 build configurations in `project.pbxproj` *and* in `project.yml`, plus a `CHANGELOG.md` entry and an annotated `vX.Y.Z` tag on the release commit.
- **The current `1.1` becomes three-part** (`1.x.0`) at the next release. The first release under this rule creates `CHANGELOG.md` and the first tag. Until then the baseline is the last commit that changed `MARKETING_VERSION`.
- **Device or TestFlight builds of an unchanged version** bump only `CURRENT_PROJECT_VERSION`.

## Release push: include the Figma file

A **full release push to git** is not complete until the commit includes a fresh `.fig` export of the design file.

- **Source:** "Sets – App Screens" (fileKey `gZYXjlKrbasKtfgyWKafjr`).
- **Path in repo:** `design/Sets-App-Screens.fig`. Always the same path, overwritten each release; git history holds the old versions.

Steps:

1. **Export.** Neither the Figma MCP/plugin API nor the REST API can produce a `.fig`. It comes only from the Figma app's **File → Save local copy…**. Before committing, stop and ask me to save it to `design/Sets-App-Screens.fig`. Don't skip this step or substitute a PNG/PDF export.
2. **Verify before staging.** Check that the file:
   - exists;
   - was modified within the last hour;
   - is non-trivial in size;
   - starts with a `.fig` signature (`fig-kiwi`, or `PK` for the zipped format).

   If any check fails, say so and ask again. Don't commit a stale or wrong file.
3. **Size check.**
   - Over 50 MB: tell me before committing (GitHub warns at 50 MB).
   - Over 100 MB: don't commit at all, because GitHub rejects the push. Raise Git LFS instead.
4. **Commit it with the release.** Stage the `.fig` in the same release commit, not a separate follow-up. Name it in the commit message (e.g. "Design: Sets-App-Screens.fig exported YYYY-MM-DD"). The same commit carries the approved version number and its CHANGELOG entry (see Versioning), and the `vX.Y.Z` tag goes on it.
5. **Report.** In the release summary, give the version and build, the `.fig` file's size and its export time.
