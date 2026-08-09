# Workout Tracker

A native, iPhone-only SwiftUI app for tracking gym machine-based workouts.
Local-first, offline-only, SwiftData persistence. **No server, no iCloud sync**
in this version. The number-one design priority is **data safety**: completed
workout history is immutable and protected from accidental edits, deletion, and
destructive migrations.

---

## Open & run

1. Open `WorkoutTracker.xcodeproj` in **Xcode 16 or newer**.
2. Select an iPhone simulator (e.g. iPhone 15) and press **Run** (⌘R).
3. On first launch the app seeds sample gym routines + a little history so you
   can try it immediately.
4. Run the tests with **⌘U**.

The project uses Xcode 16 **file-system synchronized groups**, so every `.swift`
file under `WorkoutTracker/` and `WorkoutTrackerTests/` is compiled
automatically — just add files to the folders, no manual project edits.

> Fallback: if the `.xcodeproj` ever won't open on your machine, a `project.yml`
> is included. Run `brew install xcodegen && xcodegen generate` to regenerate it.

Targets: iPhone only · iOS 17+ · pounds only · exact reps only.

---

## Development reset vs. production safety

Data protection is split by the `DEBUG` compile flag — on when you build from
Xcode, compiled out of Release/App Store builds — so iteration is fast in dev
while production history stays untouchable:

| | Debug (Xcode) | Release (production) |
|---|---|---|
| Store fails to open after a model change | wipes the disposable dev store and retries automatically | **never deletes** — fails loudly so the user can back up first |
| Force a clean store | add `--reset-store` to the scheme's Run ▸ Arguments | not available |
| In-app full wipe | **Data ▸ Demo Data ▸ "DEV: Erase ALL data & reseed"** | button is compiled out |

So during development you rarely need to hand-delete the app: change the model,
re-run, and the old store is rebuilt for you. The three production guarantees
(`makeLive()` never auto-deletes, no force `--reset-store`, no in-app wipe) are
all behind `#if DEBUG` / `#else` and cannot be reached in a shipped build.

> Want to keep dev data across schema changes instead of wiping? Add a real
> migration stage in `WorkoutMigrationPlan` — the debug auto-wipe only triggers
> when the store is genuinely incompatible.

---

## Architecture

Clean separation of concerns:

```
WorkoutTracker/
  App/           App entry point
  Models/        SwiftData @Model entities + enums
  Persistence/   Versioned schema, migration plan, container, repositories
  Services/      Rest timer, notifications, seed, export/import, integrity, schedule
  Views/         The 11 MVP screens + reusable components
WorkoutTrackerTests/   17 data-safety tests
```

- **Models** — pure SwiftData entities with stable `UUID` ids, `createdAt` /
  `updatedAt` / `deletedAt`, and a `source` marker (`user` / `seedDemo`).
- **Repositories** (`RoutineRepository`, `WorkoutRepository`,
  `CorrectionService`, `DemoDataManager`) — the *only* place that mutates data,
  so the safety rules live in one auditable layer.
- **Services** — `RestTimerService` (lock-safe countdown + local notification),
  `SeedDataService`, `ExportImportService`, `DataIntegrityService`,
  `ScheduleService` (RRULE expansion).
- **Views** — SwiftUI screens; they read via `@Query` and write only through the
  repositories.

---

## How the data-safety rules are enforced

| Principle | Where |
|---|---|
| 1. Completed sessions are immutable | `WorkoutSession.lockedAt`; repositories refuse direct mutation of locked sessions |
| 2. Past sessions never overwritten on routine change | Sessions store an independent **snapshot** of all planned values + machine settings; they reference a `RoutineVersion` by id |
| 3. Future-affecting edits create a new version | `RoutineRepository.makeNewVersion` / `updateFutureDefault` deep-clone into a new `RoutineVersion`; old versions stay |
| 4. Soft deletes | `deletedAt` on routines, exercises, machines, schedules; never hard-deleted from the UI |
| 5. Corrections are append-only | `WorkoutCorrectionEvent` records; originals preserved, corrected view computed by `CorrectedView` |
| 6/7. Demo data separated & one-click deletable | `source == .seedDemo` is set once and never flipped; `DemoDataManager` removes all demo-origin data, even edited demo records |
| 8. No destructive migrations | `WorkoutSchemaV1` + `WorkoutMigrationPlan` force explicit, reviewable, additive-first migrations; container refuses to auto-delete the store |

### Versioning model (do not simplify)

A `Routine` is a stable identity + name. Its content lives in immutable
`RoutineVersion` snapshots. Editing a routine that any recorded session
references **forks a new version**; past sessions keep pointing at their original
version. This is the heart of "past workouts stay historically accurate."

### Migration safety

`Persistence/Schema.swift` pins a `VersionedSchema` (v1.0.0) and a
`SchemaMigrationPlan` from day one. When you add `WorkoutSchemaV2` later:

- Prefer **additive** changes (new optional properties) → lightweight stage.
- Never delete `WorkoutSession` / `WorkoutSessionExercise` /
  `WorkoutSessionSet`, and never overwrite their snapshot fields.
- For any transform, use a `.custom` stage that backs up rows in `willMigrate`
  and asserts session counts in `didMigrate`, and add a test in
  `MigrationIntegrityTests`.

---

## Screens (MVP)

Today's Workout · Active Workout · Rest Timer · Routine List · Routine Editor ·
Exercise/Machine Editor · Calendar · Workout History Detail · Import/Export ·
Demo Data · Data Safety Check.

The app opens to **Today's Workout** when something is scheduled today, otherwise
to the **Calendar**.

---

## Tests (⌘U) — 17 data-safety guarantees

`ImmutabilityAndVersioningTests` (1–12), `DemoExportImportTests` (13–16),
`MigrationIntegrityTests` (17 + integrity). They prove, among other things, that
completed history does not change when routines are edited, that future-default
edits create new versions while past sessions keep the old one, that corrections
never overwrite originals, that demo deletion removes only demo-origin data, and
that import is non-destructive.

---

## Intentionally deferred (designed-for, not built)

Advanced progression suggestions, advanced recurrence editing UI, monthly stats,
machine groupings, multi-location UI, iCloud sync. The data model already
supports RRULE recurrence, multiple gym locations, and append-only auditing so
these can be added without breaking history.
