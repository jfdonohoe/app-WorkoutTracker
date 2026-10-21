# Agent context: WorkoutTracker

Read by the user-level iOS agents (`~/.claude/agents/ios/`). The product rules themselves
are in `README.md` ("Design principles", "Protecting trust in the data"); this file holds
what agents need beyond them. Project state (bug statuses, test counts) belongs in
`_reports/regression-registry.md`, not here.

## Preserve list

A native SwiftUI workout tracker for iPhone, local-first, on SwiftData. Keep intact:

- Workout routines and exercises
- Scheduled workouts
- Workout-session creation when the user taps Start Workout
- Session states: scheduled, started, completed, partial, missed and abandoned
- Strength, cardio and stretching sections
- Sets, reps, weights, rest periods, durations, distance and related exercise values
- Shared machine settings across routines
- Routine-template versioning
- Completed workout-session history, immutable except for supported notes or corrections
- Soft deletes, audit events, event logs and migration behaviour

## Domain terms

- `SectionType` has only strength, cardio and stretching. There are no warm-up or
  cooldown sections; in this codebase "cooldown" means rest between sets.

## Known pitfalls

- A view holding a `WorkoutSession` directly (the workout runner) won't re-render on
  to-many relationship changes. The fix used here is to read `session.updatedAt` and bump it
  on every write.
- A locked or recorded `WorkoutSession` is never mutated. Recorded history is append-only:
  corrections are added, never overwritten.

## Extra stop conditions

Stop and ask before:

- changing Start Workout behaviour
- changing workout status transitions
- changing machine-setting persistence
- changing scheduling behaviour

## Build and test

```bash
xcodebuild -project WorkoutTracker.xcodeproj -scheme WorkoutTracker \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

`project.yml` generates the Xcode project (XcodeGen).

## Claude Code memory

`~/.claude/projects/-Users-john-Documents-Claude-Projects-WorkoutApp/memory/MEMORY.md` and
the files it links to: the developer's standing design and implementation rules.

This project has no `.claude/rules/`.
