# Backup export drops cardio/stretching results and the audit log

**Date:** 2026-09-08
**Scope:** `WorkoutTracker/Services/ExportImportService.swift`
**Evidence:** `~/Downloads/WorkoutBackup-2026-09-08T21-10-02Z.json` compared against the live SwiftData store pulled from John's iPhone
**Status:** fixed in the working tree (not committed); full suite green, 33/33

---

## Summary

The JSON backup written by `formatVersion` 1 could not reproduce the store it came from. Two omissions:

1. **`WorkoutSessionExercise` exported 11 of its 20 persisted properties.** The nine that were dropped are the entire recorded result of cardio and stretching exercises, which have no `WorkoutSessionSet` rows.
2. **`AuditEvent` was never exported at all** — a persisted model with no DTO and no array in the document.

Strength training data was never affected: it lives in `WorkoutSessionSet`, which exported correctly. This is why the gap went unnoticed.

## How it was found

Reading the most recent export and diffing its shape against the model definitions, then pulling the live container off the device to confirm the store actually holds the missing values:

```
xcrun devicectl device copy from --device "John's iPhone" \
  --domain-type appDataContainer --domain-identifier com.donohoeux.workouttracker \
  --source "Library/Application Support" --destination <dir>
```

The `-wal` sibling was 4.2 MB against a 3.4 MB main store, so a `default.store`-only copy would have been materially stale. Take the whole directory.

## Impact, measured against the real store

Every entity count in the export reconciles with the device store except one:

| entity | live store | export |
|---|---|---|
| WorkoutSession | 16 | 16 |
| WorkoutSessionExercise | 315 | 315 |
| WorkoutSessionSet | 270 | 270 |
| SessionMachineSetting | 159 | 159 |
| **AuditEvent** | **35** | **0** |

The dropped `WorkoutSessionExercise` fields hold real values, not defaults:

| section | rows | markedCompleteAt | startedAt | endedAt | duration≠0 | hold≠0 | rounds≠1 | sides≠1 | intensity set |
|---|---|---|---|---|---|---|---|---|---|
| cardio | 16 | 7 | 7 | 7 | 14 | 0 | 0 | 0 | 14 |
| stretching | 157 | 71 | 73 | 71 | 0 | 135 | 56 | 110 | 0 |
| strength | 142 | 0 | 73 | 67 | 0 | 0 | 0 | 0 | 0 |

**173 of 315 session exercises** (16 cardio + 157 stretching) had no recoverable outcome in the backup. Because `WorkoutSessionExercise.isFullyCompleted` returns `markedCompleteAt != nil` for a set-less exercise (`Models/WorkoutSession.swift:252`), restoring a v1 backup renders all of them as **skipped** — including inside the ten locked, completed sessions — and `allExercisesComplete` goes false for every one.

Concretely, the Sep 8 session as stored on the device versus as backed up:

| # | section | exercise | in the store | in the backup |
|---|---|---|---|---|
| 0 | cardio | Elliptical Warm-Up | 10 min, moderate, done 15:33:19 | *(nothing)* |
| 1 | stretching | Ankle Rocks | 5s × 2 sides × 10, done 15:34:38 | *(nothing)* |
| 5 | stretching | Standing Hamstring Stretch | 30s × 2 sides, done 15:38:27 | *(nothing)* |
| … | | *(7 more stretches, all complete)* | | *(nothing)* |
| 11–19 | strength | 9 machines | weight × reps + settings | **preserved** |

Per-exercise timing is also lost for strength: 73 rows carry `startedAt` and 67 carry `endedAt`, none of which were exported.

## Root cause

`SessionExerciseDTO` was written against the set-based flow and never extended when cardio and stretching sections were added. `AuditEvent` was added to `WorkoutModels.all` (`Persistence/Schema.swift`) and is written by `Audit.log` (`Persistence/RoutineRepository.swift:364-375`), but the export document was never given a matching array.

### A trap found while fixing it

Several existing DTOs carry default values (`var defaultRest: Int = 90`, `var restBetweenExercises: Int = 90`) that look like they provide backward compatibility for older backups. **They do not.** Swift's synthesized `Codable` decoder throws `keyNotFound` on a missing key and does not fall back to a property's default value — verified directly:

```swift
struct D: Codable { var id: Int; var newField: Int = 7 }
try JSONDecoder().decode(D.self, from: #"{"id": 1}"#.data(using: .utf8)!)
// DecodingError.keyNotFound: Key 'newField' not found
```

Only `Optional` properties decode leniently (via `decodeIfPresent`). The fix therefore adds every new field as an `Optional`, coalescing to the model default at import. Test 20 locks this in.

## The fix

`formatVersion` is now **2**. Both directions stay compatible: a v2 app reads a v1 file (missing keys → model defaults), and a v1 app reads a v2 file (unknown keys ignored by the decoder). Nothing in the codebase branches on `formatVersion`.

- `SessionExerciseDTO` gains `groupIndex`, `startedAt`, `endedAt`, `durationMinutes`, `intensity`, `holdSeconds`, `sides`, `rounds`, `markedCompleteAt` — all `Optional`.
- `BackupDocument` gains `auditEvents: [AuditEventDTO]?` (optional, not `= []`, for the same decoding reason).
- Export writes both; `restore` reads both, coalescing absent values to the model's own defaults.
- Audit events respect the `includeDemo` source filter like every other entity, and are restored before the import logs its own `import.performed` event.

New file `WorkoutTrackerTests/ExportCompletenessTests.swift`, tests 18–21:

| test | proves |
|---|---|
| 18 | cardio/stretching results survive a round trip; a restored completed session still reads as complete, with explicit non-nil guards so the assertions cannot pass vacuously |
| 19 | the audit log is exported and restored |
| 20 | a synthetic v1 backup (new keys stripped out) still imports, landing on model defaults |
| 21 | re-importing is still non-destructive — audit events are skipped, not duplicated |

**Full suite: 33 tests, 0 failures** (`xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 17' test`).

## Known gaps left open

Deliberately out of scope for this change; each is a one-line addition if wanted.

1. **`ScheduleRule.createdAt` / `updatedAt` are still not exported.** Cosmetic metadata; no behavior depends on it.
2. **Dates round-trip at one-second resolution.** `JSONEncoder.dateEncodingStrategy = .iso8601` emits no fractional seconds, so every timestamp in every backup — pre-existing, not introduced here — loses sub-second precision. Test 18 compares instants with 1s tolerance for this reason. Switching to `.iso8601WithFractionalSeconds` would fix it but makes new files unreadable by older builds.
3. **The existing non-optional DTO defaults remain misleading.** `SessionDTO.restBetweenExercises`, `VersionDTO.defaultRestSets`, `ExerciseDTO.defaultRest` and friends would throw on a backup that lacked those keys. No such file exists in practice (the app has always written them), so this is latent, not active.

## Recommended next step

**Take a fresh export from the phone once this ships.** The existing `WorkoutBackup-2026-09-08T21-10-02Z.json` is permanently missing the cardio/stretching history and the audit log — the fix cannot recover what was never written to the file. Until a v2 backup exists, the device store is the only complete copy of that data.
