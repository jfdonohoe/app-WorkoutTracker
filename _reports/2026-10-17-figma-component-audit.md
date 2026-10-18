# Figma component audit: "Sets – App Screens" (2026-10-17)

File `gZYXjlKrbasKtfgyWKafjr`. This was a read-only review and nothing in Figma was changed.

**Scope:** the 53 local components on 🧱Components (section "Sets – Local components", 15:4). I counted their instances on every page:

| Page | Screens | Instances |
|---|---|---|
| 🛳️ Production | 42 | 957 |
| 🗄️ Archive | 148 | 2,720 |
| ✅ Approved | 0 (one "Build" label) | 0 |
| 🚧 WIP | empty | 0 |

Counts include instances nested inside other instances. I did not check whether other Figma files use this library.

**Method:**
- "Unused" means no instances on any page. I also checked the instances nested inside component masters.
- The "needs updating" findings come from instance overrides. When most instances of a component override the same non-text property in the same way, the master no longer matches the design.
- New-component candidates are frames that are not components and repeat with the same structure on Production.

---

## 1. Components with no usage (candidates to remove)

| Component | Node | Production | Archive | App code | Recommendation |
|---|---|---|---|---|---|
| icon/doc.badge.plus | 171:6858 | 0 | 0 | ImportExportView.swift:140, "Create backup (JSON)" | **Don't remove.** Swap it into Import / Export (see 3.1). |
| icon/square.and.arrow.down | 171:6862 | 0 | 0 | ImportExportView.swift:85, :152 | **Don't remove.** Same as above. |
| icon/doc.text | 171:6866 | 0 | 0 | ImportExportView.swift:182, :212 | **Don't remove.** Same as above. |
| icon/tablecells.badge.ellipsis | 171:6873 | 0 | 0 | ImportExportView.swift:218 | **Don't remove.** Same as above. |
| icon/clock | 24:95 | 0 | 0 | TodayWorkoutView.swift:336, "In progress — n/n exercises" | Unused. Remove it, or keep it if an in-progress Today screen is planned. |
| icon/checkmark.shield.fill | 172:6958 | 0 | 0 | DataSafetyCheckView.swift:35, the all-pass state | Unused because no all-pass Data Safety frame exists. Keep it if that state will be drawn. |
| Photo Placeholder | 54:2079 | 0 | 7 | — | Used only on Archive. Removing it orphans those 7 instances. |
| icon/checkmark.shield | 15:19 | 0 | 1 | RoutineEditorView.swift:67 | Used only on Archive. |
| icon/play.fill | 24:98 | 0 placed directly | 0 | TodayWorkoutView.swift:298, :340 | **Keep.** It is the default icon nested in the Action Button master. |

**Possible duplicates to consolidate.** These are colour or padding copies of the same symbol:
- icon/checkmark.circle.fill and icon/checkmark.circle.fill (green).
- icon/info.circle (green), which has no non-green version.
- icon/play.fill and icon/play.fill (padded).

They could become one icon each with a colour override, or a variant. This is optional.

---

## 2. Main components that need updating

These are in priority order.

1. **Set Action Button (51:2009).** It has 20 instances with 31 fill overrides, and its 2 variants (Complete, Rest) don't cover the states that are drawn. The instances fake these states:
   - Start: green fill, 245×50, white icon (3).
   - Running/Pause: black fill, white pause glyph (3).
   - Rest: white with a dark-green 1.5 stroke, dark-green "Complete & Next" text (2).
   - Get ready: white with a black 1 stroke, black text (2).

   → Add these states as variants, plus a compact size (245×50) for use next to the forward.end button.

2. **Section Header (24:120).** 15 instances are restyled as the exercise-name header: black, 22/28, padding-bottom 8, hug height. This is the standard in `exercise-sheet-header-standard`. 6 more Section Headers on Production are detached frames:
   - "Start now" (177:7384) on the Add Workout sheet.
   - "Build" and "Units" (231:2878, 231:2884) on Settings, and 3 more.

   → Add a `Style = Section | Exercise name` variant and relink the 6 detached frames.

3. **Form Row (35:325).** It has 131 instances, 44 of which have structural overrides:
   - **12 "Delete exercise" rows** on Edit Exercise: red label, centred. → Add a destructive variant, or use Action Row with destructive styling.
   - **12 Notes rows**: 96 tall, top-aligned, padding-top 14, gray 30% placeholder "Form cues, setup, how it felt". → Add a multiline/notes variant with a placeholder state.

4. **Set Row (51:1983).** All 8 instances recolour the value to gray 30% and the label to gray 60%, and 4 recolour the status glyph. → The master no longer matches any drawn state. Add `State = Done | Current | Upcoming`.

5. **Timer Row (24:138).** It has 60 instances:
   - 13 are inset (326 wide, 44 tall, 12 left padding) inside the Vary-by-set cards. → Add a compact variant.
   - 9 grey out a stepper half at its limit. → Add a disabled state.
   - 2 are dimmed to 45% opacity: Interval Rounds locked mid-run. → Add a locked state.

6. **Calendar Day (28:128).** 22 of its 62 instances override fills:
   - Red, blue and orange status dots (8, 8 and 2).
   - Today's day number in green Semi Bold (2).

   → Add a status variant property for the dot colour and a Today boolean, instead of overriding fills.

7. **Check Row (172:6972).** 10 of its 12 instances are resized to 74, 77 or 92 tall to fit wrapped detail text. → Set the master to hug its height.

8. **icon/pause.fill (padded) (114:3029).** All 7 instances recolour its rectangles (white, #0F5132 or black). Lower priority: chevron.right and icon/plus are also recoloured on most instances. → Consider changing the default fills to the most common colour. Optional.

9. **Tab icons (19:72, 19:75, 19:78).** Every instance is resized from 24 to 26 inside the kit Tab Bar. → This is likely a master-size mismatch. It's inferred, and the kit slot may be forcing the size.

10. **Toggle – Switch (kit).** 5 of its 7 instances are absolutely positioned over rows. → Form Row has no toggle accessory. Add a `Toggle` accessory option or a Toggle Row.

---

## 3. Repeated frames that should become components

Counts are for Production only, and each line gives the instance count, then an example node. The Archive repeats the same patterns at larger counts.

1. **The Import / Export screens are hand-built** (4 frames: Google Sheet Ready / Importing / Done / Problem):
   - 33 custom "Row" frames.
   - 25 "Separator" rectangles, 361 wide.
   - Section Header / Card / Footer stacks.
   - A "‹ Settings" nav bar.
   - Hand-drawn vector icons named icon/plus, icon/down, icon/doc, icon/table and icon/check.
   - "Include demo data in export" shown as the text "On" rather than a Toggle.

   → Rebuild them from Action Row, Form Row and Section Header, and use the 4 unused icons from section 1. The code uses those exact symbols. "Create backup" is drawn with plus, but the code uses doc.badge.plus.

2. **Sheet Navigation Bar.** 33 frames in 10 variations, and every button is a hand-built frame (Edit 15, Close 15, Cancel 14, Save 12, Done 1). Example 168:5888. The variations include:
   - Cancel / Title / Save (12, on Edit Exercise).
   - Edit / Type / Close (5 Cardio, 5 Stretching, 5 Strength).
   - Done / Close (edit mode).

   → Make one component, with a variant for the leading/trailing button pair and a title property.

3. **Up next peek.** 14 frames that differ only in text (231:2701). → A component with a Name property.

4. **Notes section.** 26 "Section – Notes" frames, built two ways:
   - Section Header plus a Form Row (12, on Edit Exercise).
   - Section Header plus a custom "Notes" text frame (14, on the workout sheets; 231:2588).

   → Make a Notes Card component with filled, placeholder and editing states.

5. **icon/forward.end.fill.** 10 identical loose vector groups named "Icon – forward.end.fill" (231:2639). → Make it an icon component. It's used in GuidedTimerPanel.swift:73, InCardTimers.swift:152 and SessionExerciseSheet.swift:425.

6. **In-card timer parts.**
   - "Controls" (Pause button plus Done button): 7, identical (231:2636).
   - "Done Button" (forward.end): 7.
   - "Rest" (Set Action Button plus "Tap to skip rest"): 5, identical (231:2576).
   - "Progress" bar: 5, identical.
   - "Guided Timer": 5 frames in 5 forms (rest ring, time left, interval recovery…).

   → Make a Timer Controls component and a Guided Timer set with type variants. These match RestRingTimer and GetReadyCountdown in InCardTimers.swift.

7. **Separator.** 58 loose frames, built 3 ways (361 Rectangle, 370 Line, 370 Rectangle). → Make one Separator component, or use the rows' existing Show Separator property.

8. **Section Footer.** 14 frames plus 24 "Footer" frames, all footnote text with different copy (168:6080). → A component with a Text property.

9. **Set number Badge.** 6 frames, 28×28, on the Vary-by-set editors (169:5874). → A component with a Number property.

10. **Start / Complete row.** 3 frames (Set Action Button plus a forward.end icon button; 231:2719). → Fold this into the Timer Controls component in item 6.

**Not recommended as components:** the 151 "Card" wrapper frames. They are inset-group containers around row instances with 66 different contents, so a component would add little. A shared fill/radius style or variable is enough.

---

## Caveats

- Removing a main component that Archive instances use (Photo Placeholder, icon/checkmark.shield) leaves those instances without a main.
- Override counts can't tell a deliberate one-off from drift. The items in section 2 are the ones where the same override repeats across many screens.

---

## Changes made (2026-10-17)

Done at the user's request: "do these changes". Decisions:
- Delete all 4 removal candidates.
- Rebuild Import / Export to match the app.
- Do both optional items.

### Verification

Before any change I took a render signature of every Production screen. For each screen it records every visible painted layer: position, size, fill, stroke, opacity, radius, and text with its font. After each step I compared against it, and some scripts rolled themselves back if the render changed.

Final result for the 42 Production screens:

| Result | Screens | What differs |
|---|---|---|
| Identical to the original | 23 | Nothing |
| Wider title text box | 15 | Exercise-sheet nav bars. Strength title moves from 4 px left of centre to centred; Stretching title shifts 0.5 px; Cardio unchanged. |
| Narrower label text box | 5 | Edit Exercise "Vary by set" rows, now that the toggle sits inside the row. Glyph positions unchanged. |
| Rebuilt (intended visual change) | 4 | Import / Export |

No Production instance is missing its main component.

### Components updated

| Component | Change | Instances moved |
|---|---|---|
| Set Action Button | States added: Start, Pause, Pause – Rest, Pause – Get ready (245 wide). | 10 |
| Section Header | Now a set: Style = Section \| Exercise name. | 15, plus 6 detached frames relinked |
| Form Row | Now a set: Style = Default \| Text field \| Notes \| Destructive. New "Show Toggle" accessory (exposed kit Toggle). | 38, plus 5 floating toggles moved into rows |
| Set Row | Now a set: State = Default \| Upcoming \| Done \| Done (muted). | 8 |
| Timer Row | Now a set: Size = Regular \| Compact × State = Default \| At minimum \| At maximum \| Locked. | 24 |
| Calendar Day | Now a set: Status = None \| Completed \| Partial \| Missed \| Scheduled × Selected. The Show Dot and Selected booleans were removed. | 22 |
| icon/checkmark.circle.fill | Set: Color = Default \| Green (merged the "(green)" copy). | — |
| icon/play.fill | Set: Padding = None \| Padded (merged the "(padded)" copy). | — |
| icon/pause.fill (padded) | Default fill changed to white. | — |
| Tab icons | Masters rescaled from 24 to 26 pt. | — |

### Components added

| Component | Replaces |
|---|---|
| icon/forward.end.fill | 10 loose vector groups |
| Separator | 30 frames |
| Set Number Badge | 6 frames |
| Section Footer | 14 frames |
| Up Next Peek | 14 frames |
| Timer Progress | 5 frames. Progress is set with right padding, because instance layers can't be resized from the API. |
| Notes Card (Filled \| Placeholder) | 14 frames |
| Complete Icon Button | 10 frames |
| Timer Controls | 7 frames |
| Guided Timer (Rest ring, Cardio countdown, Interval recovery, Interval work, Stretch hold) | 5 frames |
| Sheet Nav Bar (Edit + Close, Done, Cancel + Save; Title property) | 27 frames |

Added for the Import / Export rebuild:
- Prominent Button (Default \| Disabled).
- Status Row (Success \| Progress \| Error).
- icon/checkmark.circle, icon/progress and icon/exclamationmark.triangle.

### Import / Export

All 4 screens were rebuilt at 402 wide (they were 393) from library components. The headers are Section Header, the rows are Form Row and Action Row with the app's SF Symbol icons, and the demo-data setting is a real Toggle.

The footer copy is the existing Figma text. The CSV footers are older than the app's text in ImportExportView.swift.

The "Settings – Import / Export" section was resized to fit. The Production page has no overlapping sections.

### Deleted

- icon/clock
- icon/checkmark.shield.fill
- Photo Placeholder
- icon/checkmark.shield

The 8 Archive instances of the last two still render, but their main components are gone.

### Left as is

- The 2 Settings toggle rows: their structure differs (bottom stroke, 21 pt text), so converting them would change the render.
- The one-off nav bars: Add Workout, Schedule, the two list screens and Data Safety Check.
- 3 raw-rectangle separators with different colours.
- Check Row: it already hugs its height; the height overrides are only recorded sizes.
- The hidden "Rest" frames (all 5 hidden) and the 2 hidden stretch "Footer" frames. These look like leftovers that could be deleted.

### Archive side effect

Removing the Calendar Day booleans erased the Archive "Approved - Calendar" (70:2488) dot settings. I restored them by matching the Production calendar's day pattern (1, 5, 12, 15 missed; 8 partial; 19, 22, 26, 29 scheduled; 7 selected). This is inferred, not recovered. Figma version history from before this session holds the original.

### Components page

New components were placed below the original grid. The section was resized to 2276×2489, with no overlaps.
