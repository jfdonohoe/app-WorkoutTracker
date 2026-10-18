# CSV kind import: review findings

**Date:** 2026-10-16
**Scope:** CSV importers updated to the exercise structure (`kind` plus that kind's fields).
**Files reviewed:**
- `WorkoutTracker/Services/CSVExerciseFields.swift` (new)
- `WorkoutTracker/Services/CSVExerciseImporter.swift`
- `WorkoutTracker/Services/CSVRoutineImporter.swift`
- `WorkoutTracker/Views/ImportExportView.swift`
- `WorkoutTrackerTests/CSVKindImportTests.swift` (new)

**Reviewer:** the swift-reviewer subagent. **Verdict:** needs work. Items 1 to 6 and 10 are now fixed.

**Regression check after the fixes:** the full suite passes, 174 of 174 tests on the iPhone 17 Pro simulator.

| # | Finding | Status |
|---|---|---|
| 1 | Routine rows with a stretch kind accepted setK_reps/setK_weight and then silently dropped them. | Fixed: setK columns need a kind with sets (`ExerciseKind.usesSets`). Test: `testStretchRowInRoutineRejectsSetColumns`. |
| 2 | A steady routine row with a blank duration_min set the cardio section to 20 min, even when the exercise already existed. | Fixed: only a filled duration_min sets the section length. Test: `testSteadyRowWithBlankDurationLeavesSectionLengthUnset`. |
| 3 | A routine row whose kind differed from the library exercise's kind could drop its planned sets without saying so. | Fixed: the import is rejected with "already in your library as …". Test: `testRoutineKindMustMatchLibraryExercise`. |
| 4 | Rows with no kind ignored values in columns that only exist in the new structure. | Fixed: the import fails with "fill 'kind' to use 'X'". Test: `testRowWithoutKindRejectsCurrentColumns`. |
| 5 | When effort and intensity were both filled, intensity was silently ignored. | Fixed: filling both is an error. Test: `testEffortAndIntensityTogetherIsAnError`. |
| 6 | Unused setting columns on a stretch-kind row were reported twice. | Fixed: the stretching group no longer parses machine settings. |
| 7 | The CSV accepts some seconds and duration values the editor's steppers can't produce (the steppers go from 5 in steps of 5). It also stores a weight of 0 where the editor stores nil. | Not changed. Both import cleanly and display correctly. |
| 8 | On a steady or intervals exercise that has a machine, an imported photo is cleared the first time the exercise is edited. | Not changed. This already happened before this change; it is in the editor's save logic. |
| 9 | Matching existing data is limited to the user's own data (`sourceRaw == user`). | Intended: this came from the other session's demo-separation work and is kept. |
| 10 | The routines footer on the import screen listed only the older columns; the exercise footers left out per_side_custom. | Fixed. |
| 11 | ImportExportView has a second presentation modifier for the Data Safety sheet. | Not changed. This is outside the CSV change and belongs to other in-progress work. |

**Also changed, besides the review fixes:** on routine rows with a kind, a blank setK_weight now counts as 0, for kinds with no weight. Test: `testBlankSetWeightIsZeroForKindsWithoutWeight`.
