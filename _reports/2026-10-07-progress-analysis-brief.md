# Brief: Progress & analysis — 2026-10-07

## Goal
Answer four questions from the user's own workout history:
1. **Am I getting stronger?**
2. **Am I consistent?**
3. **When should I go heavier?**
4. **Where have I plateaued, and what should I do about it?** (actionable recommendations)

## Placement
A new **Progress** tab (fourth tab, after Calendar). Today stays focused on
working out. Default view: **weekly trends** over the last 3–12 months.

## Data available today (verified in the models)
| Source | Fields used |
|---|---|
| `WorkoutSession` | `startedAt`, `endedAt`, `status`, `routineId`, `scheduledDate`, `corrections` |
| `WorkoutSessionExercise` | `exerciseId`, `machineId`, `sectionType`, `startedAt`/`endedAt`, cardio minutes/intensity, stretch hold/sides/rounds |
| `WorkoutSessionSet` | `plannedWeight`/`plannedReps` vs `actualWeight`/`actualReps`, `isCompleted`, `completedAt` |
| `ScheduleRule` | scheduled days + exception dates (for adherence) |
| `WorkoutCorrectionEvent` | corrections to recorded actuals — must be layered on before analysis |

## New data to capture
1. **Effort per set — optional quick tap.** Four small buttons (Easy / Moderate /
   Hard / Too hard) on the active set, before Complete. Skippable; never blocks
   completing a set. Field already exists (`WorkoutSessionSet.perceivedEffort`)
   but is never filled — `completeSet` is called without it
   (`WorkoutRepository.swift:207`). No schema change.
2. **Actual rest taken.** New optional field on `WorkoutSessionSet` (e.g.
   `restTakenSeconds: Int?`, additive/lightweight): seconds from the previous
   set's completion to this set's completion start, or from rest-timer start to
   the tap on Complete. Note: an approximation (gap between consecutive
   `completedAt` values) is already derivable for history recorded so far.
3. Nothing else is required by the chosen features.

## Metrics & rules

**Grouping key: exercise + machine.** Weights differ per machine, so every
strength metric, record, recommendation and plateau is computed per
(exercise, machine), with a combined exercise view on top.

**Strength progress**
- Top working weight per session.
- Estimated 1-rep max per set (Epley: `weight × (1 + reps / 30)`), best per session.
- Volume per session = Σ completed sets (reps × weight).
- Only completed sets count, from any recorded session (completed / partial / abandoned), with corrections applied.
- Personal records: best e1RM, top weight, best volume — flagged when set.

**Go heavier — "hit all reps 2 sessions"**
Recommend increasing weight when, in **2 consecutive sessions** on the same
exercise + machine:
- every planned set was completed at ≥ planned weight, and
- every set's actual reps ≥ planned reps, and
- no set rated Hard or Too hard (sets with no effort rating don't block).

Increment: **+5 lb** on every set.
**Accepting** the recommendation updates that exercise's default sets for that
machine (`RoutineRepository.updateExerciseDefaults(exerciseId:machineId:sets:)`
then `CatalogSyncService.reconcileExercise`), so every routine and every
not-yet-started set uses the new weight. Locked history is untouched.
Dismissing it hides it until the rule fires again.

**Plateau — "no gain in 3 weeks"**
An exercise + machine is plateaued when its best e1RM has not improved for
**3+ weeks** while it was performed at least once a week in that span (no
plateau is reported for exercises simply not being done).
Each plateau shows a recommendation, e.g.:
- reps consistently hit + low effort → go heavier;
- reps missed / effort Hard → hold weight, add a set or a rep, or take a lighter week;
- rest taken well under planned → rest longer (once rest data exists).

**Consistency — against the schedule**
- Adherence = completed ÷ scheduled workouts per week (exceptions excluded).
- Missed scheduled days count against adherence; unscheduled extra workouts
  are shown but don't raise it above 100%.
- Current and longest streak of weeks at 100% adherence.
- Which routines / weekdays are most often missed.

## Scope
**Strength and consistency only.** Cardio and stretching are excluded from
Progress for now (they still count toward consistency, since adherence is
per workout).

## During a workout — "vs. last time"
On the strength exercise sheet, under the active set:
- **Last time** on this exercise + machine: weight × reps per set, and effort
  if rated (e.g. "Last time: 80 lb × 10, 10, 9 · Moderate").
- A **new record** badge when a completed set beats the best e1RM / top weight.
- A pending **go-heavier** recommendation for this exercise appears here too,
  with the same Accept action as in Progress.

## Progress tab — proposed sections
1. **This week** — adherence, workouts done/scheduled, streak.
2. **Recommendations** — go-heavier and plateau cards, each with one action.
3. **Strength** — per-exercise list with sparkline (e1RM, weekly); tap for
   detail: e1RM / top weight / volume charts, records, machine filter.
4. **Consistency** — weekly adherence chart, missed days.

## Constraints
- Read-only over history: analysis never writes to locked sessions (existing
  immutability rules). Corrections are layered on, not applied.
- Demo data (`source == .seedDemo`) excluded unless only demo data exists.
- Works offline; computed on device from SwiftData.

## Decisions (2026-10-07)
1. Accepting a go-heavier recommendation **updates the default weights** for
   that exercise + machine.
2. Weight step: **5 lb**.
3. Scope: **strength and consistency only**.
4. **Yes** — "vs. last time" and recommendations also show on the exercise
   sheet during a workout.
