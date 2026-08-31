# Workout Tracker

A native iOS workout tracker designed around a simple principle:

> **What you did in the past should remain trustworthy, even when your plans change.**

Workout Tracker is a working product experiment exploring how interaction design, data modeling, and system behavior can reinforce that principle.

Built with SwiftUI and SwiftData.

---

## The product problem

Workout applications deal with two very different kinds of information:

**Plans** should be flexible.  
You should be able to change exercises, weights, schedules, and routines whenever you want.

**History** should be stable.  
Changing tomorrow's routine should not silently change the record of what you did three months ago.

That distinction became the foundation for the product.

Rather than treating workouts as editable records in a single database, Workout Tracker separates future intent from completed activity and makes that distinction visible throughout the experience.

---

## Design principles

### History is a record, not a template

Completed workouts are immutable.

If a routine changes later, previously completed sessions continue to reflect exactly what was planned and recorded at the time.

### Changes affect the future

Editing a routine creates a new version rather than modifying the version associated with past workouts.

This lets the product remain flexible without sacrificing historical accuracy.

### Corrections preserve what happened

Mistakes can be corrected, but corrections are append-only.

The original value remains part of the record rather than being silently overwritten.

### Destructive actions should be difficult

Workout history is intentionally protected from accidental deletion, destructive migrations, and routine edits that could rewrite past activity.

### The interface should stay out of the workout

During an active workout, interaction needs to be fast and low-friction.

The product emphasizes the next meaningful action, keeps frequently changed values close at hand, and reduces navigation while a workout is underway.

---

## Core experience

The MVP covers the full lifecycle of a workout:

### Plan

Create reusable routines containing exercises, machine settings, weights, repetitions, and scheduling information.

### Start

When a workout is scheduled for today, the app opens directly into that workout rather than requiring the user to find it.

### Perform

Move through exercises and sets with the current task, target values, and next action kept prominent.

A rest timer becomes part of the completion interaction rather than a separate mode that must be managed independently.

### Complete

Finishing a workout creates a historical snapshot.

From that point forward, changes to the underlying routine do not alter the completed session.

### Review

Calendar and history views make it possible to revisit past activity while maintaining a clear distinction between recorded history and future plans.

---

## A product decision that shaped the architecture

One of the more interesting parts of this project is that a UX principle required a corresponding system model.

A conventional approach might let a completed workout continue referencing the current version of a routine:

```text
Routine
   ↓
Workout history
```

That creates a subtle problem.

If the routine changes, the meaning of the historical record can change with it.

Workout Tracker instead uses versioned routine snapshots:

```text
Routine
   ↓
Routine Version A ─────→ Completed Workout A
   ↓
Routine Version B ─────→ Future Workout
```

Editing a routine creates a new version.

Past workouts continue referencing the version that existed when they were performed.

The implementation is more complex, but the user's mental model becomes simpler:

**The past stays the past.**

---

## Protecting trust in the data

Several behaviors reinforce that principle.

| Product principle | System behavior |
|---|---|
| Completed sessions should not change | Completed sessions are locked |
| Routine edits should affect the future | Edits create new routine versions |
| History should reflect what was planned then | Sessions retain independent snapshots |
| Corrections should be transparent | Corrections are append-only |
| Removing something should not destroy history | User-facing deletion is soft deletion |
| App upgrades should not erase activity | Persistence uses explicit versioned migrations |
| Demo content should never contaminate real history | Demo-origin data remains identifiable |

The point is not simply data integrity.

It is **product trust**.

A workout history becomes useful only if the user can believe that it still represents what actually happened.

---

## Interaction and visual system

The app uses a small design system built specifically around an active workout context.

The visual language favors:

- strong hierarchy for the current exercise and set
- large, reachable primary actions
- restrained use of semantic color
- warm neutral surfaces
- persistent status without excessive chrome
- tabular numbers where rapidly changing values need to remain visually stable

The design system is documented separately in `DesignSystem.html`.

---

## Rest as part of the interaction

Rest timing is a good example of treating a feature as part of a workflow rather than a destination.

Completing a set starts the rest period directly within the primary action.

The button itself becomes a visual countdown, allowing the user to understand both:

**what is happening now**  
and  
**when the next action becomes relevant**

without navigating to a separate timer screen.

This keeps attention on the workout rather than on operating the app.

---

## Product scope

The current MVP includes:

- Today's Workout
- Active Workout
- Rest Timer
- Routine List
- Routine Editor
- Exercise and Machine Editor
- Calendar
- Workout History
- Import / Export
- Demo Data
- Data Safety Check

The app is intentionally local-first and offline-only.

There is currently no account system, server, or iCloud dependency.

---

## Designed for extension

Some capabilities were deliberately deferred rather than added to the initial product:

- progression recommendations
- richer recurrence editing
- monthly statistics
- machine groupings
- multiple gym locations in the UI
- cloud synchronization

The underlying model anticipates several of these possibilities without requiring them to complicate the current experience.

That distinction matters to me when prototyping:

**design enough architecture to preserve future options, but do not expose future complexity to today's user.**

---

## Implementation

Workout Tracker is a native iPhone application built with:

- SwiftUI
- SwiftData
- versioned schemas and migrations
- repository-based data mutation
- local notifications
- RRULE schedule expansion
- local import / export

The codebase separates product state, persistence, services, and presentation:

```text
WorkoutTracker/
  App/
  Models/
  Persistence/
  Services/
  Views/

WorkoutTrackerTests/
```

Views read product state but do not directly own persistence behavior. Rules such as historical immutability and versioning live in a centralized data layer so they can be tested independently of the UI.

---

## Testing the product rules

The test suite focuses heavily on the behaviors that protect user trust.

Tests verify that:

- completed history remains unchanged when routines are edited
- future changes create new routine versions
- old sessions retain their original versions
- corrections do not overwrite original values
- deleting demo content does not remove user data
-
