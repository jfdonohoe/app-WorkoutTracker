//
//  SessionExerciseSheet.swift
//  WorkoutTracker
//
//  The per-exercise logging modal. Behavior:
//   • The sheet is titled by the exercise's type (Strength / Cardio /
//     Stretching); the exercise name heads the first section.
//   • Machine settings are STATIC text by default; an Edit toggle turns on
//     adjustment. An exercise with more than one machine gets a machine menu.
//   • Only the "active" set (the first not-yet-completed set, with all earlier
//     sets complete) shows the working controls. Upcoming sets show no Complete
//     button.
//   • Completing a set collapses it to a one-line row (weight × reps + check) and
//     scrolls down to the next set. Tapping a completed row reopens it to edit.
//   • Rest between sets and between exercises runs in the card as a ring
//     (RestRingTimer, InCardTimers.swift) using the workout's TypeRests; when it
//     ends or is skipped the Complete Set button returns.
//

import SwiftUI
import SwiftData
import UIKit
import PhotosUI

struct SessionExerciseSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var restTimer: RestTimerService
    @EnvironmentObject private var guidedTimer: GuidedTimerService

    @Bindable var session: WorkoutSession
    @Bindable var exercise: WorkoutSessionExercise
    /// Called when this exercise is completed AND it was the last incomplete one
    /// in its group (so the workout UI can start the between-exercises cooldown).
    var onExerciseCompleted: () -> Void = {}
    /// Called when this exercise is completed but other exercises in its group
    /// remain — the workout UI switches the sheet to the given next exercise.
    var onAdvance: (WorkoutSessionExercise) -> Void = { _ in }

    @State private var editSettings = false
    @State private var expandedCompletedSetId: UUID?
    @State private var draftWeight: [UUID: Double] = [:]
    @State private var draftReps: [UUID: Int] = [:]
    @State private var editingSetting: SessionMachineSetting?
    @State private var showAddSetting = false
    @State private var definition: Exercise?
    /// Machines and photos, read when the sheet opens and after a machine
    /// switch or photo change (loadMachinesAndPhotos) — not fetched again on
    /// every render: the rest and guided timers re-render this sheet each second.
    @State private var liveMachines: [UUID] = []
    @State private var machineNames: [UUID: String] = [:]
    /// The structured stretch card's photo (the exercise's own) and the photo
    /// section's (the machine in use first).
    @State private var cardPhoto: Data?
    @State private var definitionPhoto: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoOptions = false
    @State private var showPhotoLibrary = false
    /// Typing a note: the keyboard shows Done, and Up next steps aside.
    @FocusState private var notesFocused: Bool
    @State private var showCamera = false
    /// Bodyweight exercise where the user chose to log added weight (e.g. a vest).
    @State private var addingWeight = false

    private var repo: WorkoutRepository { WorkoutRepository(context) }
    private var isLocked: Bool { session.isLocked }

    /// The set currently being worked on: the first incomplete set.
    private var activeSetId: UUID? {
        exercise.orderedSets.first { !$0.isCompleted }?.id
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    // Machine dropdown first, only when the exercise has several.
                    machineSection
                    // Group-specific prescription: strength = sets; cardio and
                    // stretching = their own editable values + a Mark Complete button.
                    // Set-based exercises (strength, and cardio Calisthenics) log sets;
                    // the others have their own section.
                    if exercise.hasSets || exercise.sectionType == .strength {
                        Section {
                            ForEach(exercise.orderedSets) { set in
                                setRow(set, proxy: proxy).id(set.id)
                            }
                        } header: {
                            if switchableMachine == nil { nameHeader(label: "Sets") } else { Text("Sets") }
                        }
                    } else if exercise.sectionType == .cardio {
                        cardioSection
                    } else {
                        stretchSection
                    }
                    // Machine settings (cardio/strength), then the photo/notes definition.
                    machineSettingsSection
                    definitionSection
                    // Notes always last, typed into directly (no Edit needed).
                    notesSection
                }
                // Typing a note: keep its last line above the Done bar, when
                // editing starts (after the keyboard is up) and as it grows.
                .onChange(of: notesFocused) { _, focused in
                    guard focused else { return }
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        withAnimation { proxy.scrollTo(Self.notesRowID, anchor: .bottom) }
                    }
                }
                .onChange(of: notesBinding.wrappedValue) { _, _ in
                    if notesFocused { proxy.scrollTo(Self.notesRowID, anchor: .bottom) }
                }
            }
            // The bottom bar: Up next (approved Figma peek sheet; the timers are
            // in the card) — or, while a note is typed, the Done bar, which rides
            // on top of the keyboard (a .keyboard toolbar item didn't show in
            // this sheet). Up next isn't lifted onto the keyboard.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if notesFocused {
                    noteDoneBar
                } else if !isLocked {
                    WorkoutPeekSheet(session: session, current: exercise)
                }
            }
            // The sheet is titled by the exercise's type, in the list-header
            // gray; the exercise name heads the first section (nameHeader).
            .navigationTitle(exercise.sectionType.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(exercise.sectionType.displayName)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarLeading) {
                    if !isLocked {
                        Button(editSettings ? "Done" : "Edit") { withAnimation { editSettings.toggle() } }
                    }
                }
                // Close is hidden while editing (use Done to finish editing).
                if !editSettings {
                    ToolbarItem(placement: .confirmationAction) { Button("Close") { close() } }
                }
            }
            // Closing pauses a running timer (close()); a swipe-down can't be
            // told apart from the app moving on, so it's off while one runs.
            .interactiveDismissDisabled(timerRunningHere)
            .sheet(item: $editingSetting) { setting in
                MachineSettingEditSheet(setting: setting, machineId: exercise.machineId) { label, numeric, other in
                    apply(setting: setting, label: label, numeric: numeric, other: other)
                } onDelete: {
                    repo.deleteSetting(setting, from: exercise)
                    try? context.save()
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    setDefinitionPhoto(image.jpegData(compressionQuality: 0.8))
                }
                .ignoresSafeArea()
            }
            .onChange(of: photoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                        setDefinitionPhoto(data)
                    }
                    photoItem = nil   // so picking the same photo again still fires
                }
            }
            .sheet(isPresented: $showAddSetting) {
                AddMachineSettingSheet { label, numeric, other, alsoMachine in
                    repo.addSessionSetting(to: exercise, label: label, numericValue: numeric,
                                           otherText: other, alsoAddToMachine: alsoMachine)
                    try? context.save()
                }
            }
            .onAppear {
                syncDrafts(); loadDefinition()
                repo.recordExerciseStarted(exercise, in: session)
                CatalogSyncService(context).reconcileSession(session)
                try? context.save()
                // After the reconcile, which can change the machine in use.
                loadMachinesAndPhotos()
            }
        }
    }

    /// A timer counting down in this card: the guided run on this exercise,
    /// or a rest (the card shows any rest in progress).
    private var timerRunningHere: Bool {
        (guidedTimer.isRunning && guidedTimer.contains(exercise.id)) || restTimer.isRunning
    }

    /// Close by hand: a timer running in the card is paused, not left running
    /// out of sight. (Moving on by completing or skipping never pauses.)
    private func close() {
        if guidedTimer.isRunning && guidedTimer.contains(exercise.id) { guidedTimer.pause() }
        if restTimer.isRunning { restTimer.pause() }
        dismiss()
    }

    /// The exercise name above the first section (approved Figma: black,
    /// Title 2, 8 pt above the card or the section's own label).
    private func nameHeader(label: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(exercise.name)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
            if let label { Text(label) }
        }
        .padding(.bottom, label == nil ? 2 : 0)
    }

    // MARK: - Cardio / Stretching (no sets)

    @ViewBuilder
    private var cardioSection: some View {
        if let kind = exercise.kind {
            structuredCardioSection(kind)
        } else {
            legacyCardioSection
        }
    }

    /// Cardio from the exercise structure: Steady (duration, intensity),
    /// Intervals (rounds of work/recovery, intensity) or Distance (logged).
    @ViewBuilder
    private func structuredCardioSection(_ kind: ExerciseKind) -> some View {
        Section {
            Group {
                switch kind {
                case .intervals:
                    if isLocked {
                        detailRow("Rounds", "\(exercise.rounds) (\(exercise.workSeconds) s on / \(exercise.recoverySeconds) s off)")
                    } else {
                        Stepper("Rounds: \(exercise.rounds) (\(exercise.workSeconds) s on / \(exercise.recoverySeconds) s off)",
                                value: structureInt(\.rounds, \.rounds), in: PickRange.rounds)
                            // Rounds wait until the run is done; only length and intensity change mid-run.
                            .disabled(guidedTimer.contains(exercise.id))
                    }
                case .distance:
                    if let planned = exercise.plannedDistance {
                        detailRow("Distance", "\(planned.formatted()) \(distanceUnit.rawValue)")
                    }
                    if isLocked {
                        if let done = exercise.actualDistance {
                            detailRow("Done", "\(done.formatted()) \(distanceUnit.rawValue)")
                        }
                    } else {
                        Stepper("Done: \((exercise.actualDistance ?? 0).formatted()) \(distanceUnit.rawValue)",
                                value: Binding(get: { exercise.actualDistance ?? 0 },
                                               set: { exercise.actualDistance = $0 > 0 ? $0 : nil; try? context.save() }),
                                in: 0...500, step: distanceUnit.step)
                    }
                default:
                    if isLocked {
                        detailRow("Duration", "\(exercise.durationMinutes) min")
                    } else {
                        Stepper("Duration: \(exercise.durationMinutes) min",
                                value: structureInt(\.durationMinutes, \.durationMinutes), in: 5...300, step: 5)
                    }
                }
                if isLocked {
                    if let e = exercise.effort { detailRow("Intensity", e.displayName) }
                } else {
                    Picker("Intensity", selection: effortBinding) {
                        ForEach(Intensity.allCases) { Text($0.displayName).tag($0) }
                    }
                }
            }
            // Editable mid-run (running or paused): a new length moves the
            // timer's end, a new intensity its label (GuidedTimerService.replan).
            if kind != .distance { guidedControl }
            completeControl
        } header: {
            if switchableMachine == nil { nameHeader() }   // else it heads the Machine section
        }
    }

    @ViewBuilder
    private var legacyCardioSection: some View {
        Section {
            if isLocked {
                detailRow("Duration", "\(exercise.durationMinutes) min")
                if let i = exercise.intensity { detailRow("Intensity", i.displayName) }
            } else {
                Group {
                    Stepper("Duration: \(exercise.durationMinutes) min",
                            value: intBinding(\.durationMinutes),
                            in: (guidedTimer.contains(exercise.id) ? 5 : 0)...600, step: 5)   // 0 min would leave nothing to time
                    Picker("Intensity", selection: intensityBinding) {
                        Text("Low").tag(CardioIntensity.low)
                        Text("Moderate").tag(CardioIntensity.moderate)
                        Text("High").tag(CardioIntensity.high)
                    }
                }
            }
            guidedControl
            completeControl
        } header: {
            if switchableMachine == nil { nameHeader() }   // else it heads the Machine section
        }
    }

    @ViewBuilder
    private var stretchSection: some View {
        if let kind = exercise.kind, kind == .staticStretch || kind == .dynamicStretch {
            structuredStretchSection(kind)
        } else {
            legacyStretchSection
        }
    }

    /// Stretch from the exercise structure (approved Figma "Stretch sheet:
    /// timer first"): the photo at the top, then Start / the timer, then
    /// Hold (Static), Reps, Per side and Sets — so if anything is pushed below
    /// the peek sheet, it's the details. Notes are in their own section at
    /// the bottom of the sheet.
    @ViewBuilder
    private func structuredStretchSection(_ kind: ExerciseKind) -> some View {
        Section {
            if let data = cardPhoto {
                AnimatedImageView(data: data)
                    .aspectRatio(AnimatedImageView.aspectRatio(of: data), contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 220)
            }
            guidedControl
            if isLocked {
                if kind == .staticStretch { detailRow("Hold", "\(exercise.holdSeconds)s") }
                detailRow("Reps", "\(exercise.reps)")
                detailRow("Per side", exercise.perSide == .custom ? exercise.perSideCustom : exercise.perSide.displayName)
                detailRow("Sets", "\(exercise.setCount)")
            } else {
                Group {
                    if kind == .staticStretch {
                        Stepper("Hold: \(exercise.holdSeconds)s", value: structureInt(\.holdSeconds, \.holdSeconds),
                                in: 5...600, step: 5)
                    }
                    Stepper("Reps: \(exercise.reps)", value: structureInt(\.reps, \.reps), in: PickRange.reps)
                    Picker("Per side", selection: perSideBinding) {
                        ForEach(PerSide.allCases.filter { $0 != .custom || exercise.perSide == .custom }) {
                            Text($0 == .custom ? exercise.perSideCustom : $0.displayName).tag($0)
                        }
                    }
                    Stepper("Sets: \(exercise.setCount)", value: structureInt(\.setCount, \.sets), in: PickRange.sets)
                    if kind == .dynamicStretch {
                        Stepper("Timer per side: \(exercise.resolvedCountTimerSeconds)s",
                                value: countTimerBinding, in: 5...600, step: 5)
                    }
                }
                // Editable mid-run (running or paused): each change re-plans
                // the steps not yet played (GuidedTimerService.replan).
                // Notes are in their own section at the bottom (notesSection).
            }
            completeControl
        } header: {
            if switchableMachine == nil { nameHeader() }   // else it heads the Machine section
        }
    }

    @ViewBuilder
    private var legacyStretchSection: some View {
        let countBased = exercise.isCountBasedStretch
        Section {
            guidedControl   // timer first, as in the structured stretch
            if isLocked {
                detailRow("Hold", countBased ? "Untimed (reps)" : "\(exercise.holdSeconds)s")
                detailRow("Sides", "\(exercise.sides)")
                detailRow(countBased ? "Reps" : "Rounds", "\(exercise.rounds)")
                if countBased { detailRow("Timer per side", "\(exercise.resolvedCountTimerSeconds)s") }
            } else {
                Group {
                    Stepper(countBased ? "Hold: untimed (reps)" : "Hold: \(exercise.holdSeconds)s",
                            value: holdBinding, in: 0...600, step: 5)
                    Stepper("Sides: \(exercise.sides)", value: intBinding(\.sides), in: 1...2)
                    Stepper(countBased ? "Reps: \(exercise.rounds)" : "Rounds: \(exercise.rounds)",
                            value: intBinding(\.rounds), in: 1...(countBased ? 100 : 20))
                    if countBased {
                        Stepper("Timer per side: \(exercise.resolvedCountTimerSeconds)s",
                                value: countTimerBinding, in: 5...600, step: 5)
                    }
                }
                .disabled(guidedTimer.contains(exercise.id))
            }
            completeControl
        } header: {
            if switchableMachine == nil { nameHeader() }   // else it heads the Machine section
        } footer: {
            if countBased && !isLocked {
                Text("No hold time, so this stretch is done by count. The timer is estimated from the reps; a change here is saved for this stretch from now on.")
            }
        }
    }

    /// Start button for a guided cardio/stretch run, or its live timer panel
    /// while this exercise is part of the run.
    @ViewBuilder
    private var guidedControl: some View {
        if !isLocked {
            // A strength rest still counting down when a cardio/stretch
            // exercise opens shows here, above Start.
            if restTimer.isActive && !guidedTimer.contains(exercise.id) {
                restRing.listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
            if guidedTimer.contains(exercise.id) {
                GuidedTimerPanel(compact: guidedTimer.currentExerciseId != exercise.id)
                    .environmentObject(guidedTimer)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            } else if !exercise.isFullyCompleted && guidedTimer.timerDoneExerciseId != exercise.id {
                // Also while a run is on another exercise (e.g. this one was
                // just marked not done): Start takes over from that run.
                // (Timer done with auto progress off: Complete & Next shows instead.)
                HStack(spacing: 12) {
                    Button { startGuided() } label: {
                        SetActionButtonLabel(title: exercise.sectionType == .cardio ? "Start Cardio" : "Start Stretches",
                                             systemImage: "play.fill", tint: Theme.accent)
                    }
                    .buttonStyle(.borderless)   // two buttons in one row
                    // Skip: move on without doing this one (it stays not done).
                    Button { skipToNext() } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 50)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Skip this exercise")
                }
            }
        }
    }

    /// Start the automated run: this exercise, then the rest of its group's
    /// unfinished exercises in list order. Only the first is started by hand.
    private func startGuided() {
        let others = session.orderedExercises.filter {
            $0.sectionType == exercise.sectionType && $0.groupIndex == exercise.groupIndex
                && $0.id != exercise.id && !$0.isFullyCompleted
        }
        // Settings ▸ Auto progress through stretches off: just this stretch,
        // and its timer ending leaves Complete & Next to the user.
        let stopsAfterThis = exercise.sectionType == .stretching && !WorkoutSettings.autoProgressStretches
        let run = stopsAfterThis ? [exercise]
            : [exercise] + others.filter { $0.order > exercise.order } + others.filter { $0.order < exercise.order }
        let phases = GuidedPlan.phases(for: run, rests: session.rests)
        guard !phases.isEmpty else { return }
        restTimer.reset()
        guidedTimer.stop()   // a run still going on another exercise ends here
        guidedTimer.start(phases: phases,
                          finishedTitle: exercise.sectionType == .cardio ? "Cardio complete"
                              : stopsAfterThis ? "Stretch timer done" : "Stretches complete",
                          completesExercises: !stopsAfterThis,
                          rests: session.rests)
    }

    /// Hold time. Going from untimed (reps) back to timed caps the count at
    /// the timed-rounds limit, so 40 reps don't become 40 rounds of holds.
    private var holdBinding: Binding<Int> {
        Binding(get: { exercise.holdSeconds },
                set: { newValue in
                    exercise.holdSeconds = newValue
                    if newValue > 0 { exercise.rounds = min(exercise.rounds, 20) }
                    syncCardioStretchToCatalog(); try? context.save()
                })
    }

    /// Per-side timer for a count-based stretch; saved to the stretch's
    /// definition so it's used every time from now on.
    private var countTimerBinding: Binding<Int> {
        Binding(get: { exercise.resolvedCountTimerSeconds },
                set: { exercise.countTimerSeconds = $0; syncCardioStretchToCatalog(); try? context.save()
                       guidedTimer.replan(exercise) })
    }

    /// Mark Complete / Mark not done for non-set exercises (cardio / stretching).
    @ViewBuilder
    private var completeControl: some View {
        if isLocked {
            Label(exercise.isFullyCompleted ? "Completed" : "Not completed",
                  systemImage: exercise.isFullyCompleted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(exercise.isFullyCompleted ? Theme.statusGreen : .secondary)
        } else if guidedTimer.contains(exercise.id) {
            EmptyView()   // the guided run completes it
        } else if guidedTimer.timerDoneExerciseId == exercise.id && !exercise.isFullyCompleted {
            // Auto progress off: the timer has ended; completing is the
            // user's, as after a strength rest (approved Figma).
            Button { markComplete() } label: {
                SetActionButtonLabel(title: completeActionTitle, systemImage: "checkmark.circle.fill",
                                     tint: Theme.completeExerciseButton)
            }
            .buttonStyle(.plain)
        } else if isTimedByGuide && !exercise.isFullyCompleted {
            // Approved "not started" frames: Start (the timer completes it)
            // and Skip only.
            EmptyView()
        } else if exercise.isFullyCompleted {
            HStack {
                Label("Completed", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.statusGreen)
                Spacer()
                Button(role: .destructive) {
                    repo.unmarkExerciseComplete(exercise, in: session); try? context.save()
                } label: { Text("Mark not done") }
                .buttonStyle(.borderless)
            }
        } else {
            // Same presentation as the strength Complete Set button: a full-width
            // button as its own row with the standard section gutters/spacing.
            Button { markComplete() } label: {
                SetActionButtonLabel(title: completeActionTitle, systemImage: "checkmark.circle.fill",
                                     tint: Theme.completeExerciseButton)
            }
            .buttonStyle(.plain)
        }
    }

    /// Exercises the guided timer runs and completes (cardio Steady and
    /// Intervals, and stretches). Distance is logged and marked by hand.
    private var isTimedByGuide: Bool {
        switch exercise.kind {
        case .distance?, .calisthenics?: return false
        case nil: return false   // recorded before the structure: as before
        case .steady?: return exercise.durationMinutes > 0   // 0 min has nothing to time
        default: return !exercise.hasSets
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary) }
    }

    /// Save-on-change binding to an Int field of the session exercise. Also
    /// writes through to the exercise's catalog definition (single source of
    /// truth) and reconciles every other routine/in-progress session that
    /// references it.
    private func intBinding(_ keyPath: ReferenceWritableKeyPath<WorkoutSessionExercise, Int>) -> Binding<Int> {
        Binding(get: { exercise[keyPath: keyPath] },
                set: { exercise[keyPath: keyPath] = $0; syncCardioStretchToCatalog(); try? context.save()
                       guidedTimer.replan(exercise) })
    }
    private var intensityBinding: Binding<CardioIntensity> {
        Binding(get: { exercise.intensity ?? .moderate },
                set: { exercise.intensity = $0; syncCardioStretchToCatalog(); try? context.save()
                       guidedTimer.replan(exercise) })
    }

    /// Units for Distance (Settings).
    private var distanceUnit: DistanceUnit { .current }

    /// Edit an exercise-structure field from the workout: this workout, and
    /// the exercise itself (it's the one source of its settings), then every
    /// routine and workout in progress that uses it.
    private func structureInt(_ sessionKey: ReferenceWritableKeyPath<WorkoutSessionExercise, Int>,
                              _ exerciseKey: ReferenceWritableKeyPath<Exercise, Int>) -> Binding<Int> {
        Binding(get: { exercise[keyPath: sessionKey] },
                set: { v in
                    exercise[keyPath: sessionKey] = v
                    definition?[keyPath: exerciseKey] = v
                    saveStructureToCatalog()
                })
    }

    private var effortBinding: Binding<Intensity> {
        Binding(get: { exercise.effort ?? .moderate },
                set: { exercise.effortRaw = $0.rawValue; definition?.effort = $0; saveStructureToCatalog() })
    }

    private var perSideBinding: Binding<PerSide> {
        Binding(get: { exercise.perSide },
                set: { exercise.perSideRaw = $0.rawValue; definition?.perSide = $0; saveStructureToCatalog() })
    }

    private func saveStructureToCatalog() {
        // Only cardio/stretch kinds edit here; never rebuild a set-based
        // exercise's default sets (that needs its machines).
        if let def = definition, let id = exercise.exerciseId, def.kind?.usesSets != true {
            def.updatedAt = .now
            ExerciseLegacyFields.write(def, machines: [], context: context)
            CatalogSyncService(context).reconcileExercise(id)
        }
        try? context.save()
        guidedTimer.replan(exercise)   // no-op unless it's in the running run
    }

    /// Leave this exercise not done and go to the next one (or back to the
    /// workout, with no rest or finish prompt — nothing was done).
    private func skipToNext() {
        if guidedTimer.timerDoneExerciseId == exercise.id { guidedTimer.clearTimerDone() }
        if let next = nextInGroup() {
            onAdvance(next)
        } else {
            dismiss()
        }
    }

    private func markComplete() {
        if guidedTimer.timerDoneExerciseId == exercise.id { guidedTimer.clearTimerDone() }
        repo.markExerciseComplete(exercise, in: session)
        try? context.save()
        completeAndProceed()
    }

    /// Push the current cardio/stretching values through to the exercise's
    /// catalog definition, then reconcile every routine/in-progress session
    /// that references it.
    private func syncCardioStretchToCatalog() {
        guard let exId = exercise.exerciseId,
              let def = try? context.fetch(
                FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exId })
              ).first else { return }
        switch exercise.sectionType {
        case .cardio:
            def.durationMinutes = exercise.durationMinutes
            if let i = exercise.intensity { def.intensity = i }
        case .stretching:
            def.holdSeconds = exercise.holdSeconds
            def.sides = exercise.sides
            def.rounds = exercise.rounds
            def.countTimerSeconds = exercise.countTimerSeconds
        case .strength:
            return
        }
        def.updatedAt = .now
        CatalogSyncService(context).reconcileExercise(exId)
    }

    // MARK: - Exercise definition (photo) and notes

    /// The photo, and while editing its controls. A structured stretch shows
    /// its photo in its card instead.
    @ViewBuilder
    private var definitionSection: some View {
        if let definition {
            let editing = editSettings && !isLocked
            let structuredStretch = exercise.kind == .staticStretch || exercise.kind == .dynamicStretch
            let photo = structuredStretch && !editing ? nil : definitionPhoto
            if editing || photo != nil {
                Section {
                    if let data = photo {
                        // Whole image (no crop); animates + loops if it's a GIF.
                        AnimatedImageView(data: data)
                            .aspectRatio(AnimatedImageView.aspectRatio(of: data), contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .listRowInsets(EdgeInsets())
                    }
                    if editing {
                        // One button; Camera or Choose Photo is picked after
                        // (straight to the library where there's no camera).
                        Button {
                            if CameraPicker.isAvailable { showPhotoOptions = true } else { showPhotoLibrary = true }
                        } label: {
                            Label(photo == nil ? "Add photo" : "Replace photo", systemImage: "photo")
                        }
                        .confirmationDialog(photo == nil ? "Add photo" : "Replace photo",
                                            isPresented: $showPhotoOptions, titleVisibility: .visible) {
                            Button("Camera") { showCamera = true }
                            Button("Choose Photo") { showPhotoLibrary = true }
                        }
                        .photosPicker(isPresented: $showPhotoLibrary, selection: $photoItem, matching: .images)
                        if photo != nil {
                            Button(role: .destructive) { setDefinitionPhoto(nil) } label: {
                                Label("Remove photo", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    if editing { Text("Photo") }
                } footer: {
                    if editing { Text("The photo is saved to this exercise everywhere.") }
                }
            }
        }
    }

    /// Notes at the very bottom of every exercise: one tap to type, no Edit.
    /// A finished workout shows its own notes read-only (only if there are any).
    @ViewBuilder
    private var notesSection: some View {
        if isLocked {
            // What this workout recorded, not the exercise's notes today.
            if !exercise.notes.isEmpty {
                Section("Notes") { Text(exercise.notes).font(.callout) }
            }
        } else {
            Section("Notes") {
                TextField("Add a note", text: notesBinding, axis: .vertical)
                    .font(.callout)
                    .focused($notesFocused)
                    .id(Self.notesRowID)
            }
        }
    }

    static let notesRowID = "notes-field"

    /// Above the keyboard while a note is typed: Done ends it (Return adds a
    /// line in the multi-line field).
    private var noteDoneBar: some View {
        HStack {
            Spacer()
            Button("Done") { notesFocused = false }
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// Notes are the exercise's own (saved to its definition everywhere); this
    /// workout's copy follows. An exercise with no definition keeps its own.
    private var notesBinding: Binding<String> {
        Binding(get: { definition?.notes ?? exercise.notes },
                set: { v in
                    definition?.notes = v
                    definition?.updatedAt = .now
                    if !isLocked { exercise.notes = v }
                    try? context.save()
                })
    }

    /// The photo belongs to the machine in use when there is one (per-machine
    /// photos); otherwise to the exercise definition.
    private func setDefinitionPhoto(_ data: Data?) {
        if let mid = exercise.machineId,
           let machine = try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == mid })).first {
            machine.photoData = data
            machine.updatedAt = .now
            // Removing: also clear an exercise-level photo it was falling back to.
            if data == nil { definition?.photoData = nil; definition?.photoSetInApp = true }
        } else {
            definition?.photoData = data
            // Set or removed here, it's the user's choice: a sheet import
            // won't replace (or bring back) the photo.
            definition?.photoSetInApp = true
        }
        definition?.updatedAt = .now
        try? context.save()
        loadMachinesAndPhotos()
    }

    private func loadDefinition() {
        guard definition == nil, let exId = exercise.exerciseId else { return }
        definition = try? context.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exId })).first
    }

    // MARK: - Machine settings (static by default)

    @ViewBuilder
    private var machineSettingsSection: some View {
        // Stretching has no machine; cardio/strength show settings (and can add).
        // An exercise with no machine and no settings skips the section unless
        // editing, where "Add setting" stays reachable.
        if exercise.sectionType != .stretching,
           exercise.machineId != nil || !exercise.machineSettings.isEmpty || (editSettings && !isLocked) {
        Section {
            if exercise.machineSettings.isEmpty {
                Text("No machine settings").foregroundStyle(.secondary)
            } else {
                ForEach(exercise.machineSettings.sorted { $0.order < $1.order }) { setting in
                    if editSettings && !isLocked {
                        Button { editingSetting = setting } label: {
                            HStack {
                                Text(setting.label)
                                Spacer()
                                Text(setting.displayValue).bold().foregroundStyle(.secondary)
                                Image(systemName: "pencil").foregroundStyle(.tertiary)
                            }
                        }
                        .tint(.primary)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                repo.deleteSetting(setting, from: exercise)
                                try? context.save()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    } else {
                        HStack {
                            Text(setting.label)
                            Spacer()
                            Text(setting.displayValue).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if editSettings && !isLocked {
                Button { showAddSetting = true } label: { Label("Add setting", systemImage: "plus") }
            }
        } header: {
            // Name the machine when there's a choice, so it's clear whose settings these are.
            if let current = switchableMachine {
                Text("Machine settings – \(machineName(current))")
            } else {
                Text("Machine settings")
            }
        }
        }
    }

    /// The current machine, when the exercise has more than one to choose from.
    private var switchableMachine: UUID? {
        let ids = liveMachineIds
        guard let current = exercise.machineId, ids.count > 1, ids.contains(current) else { return nil }
        return current
    }

    /// The exercise's machines, minus soft-deleted ones (switchMachine refuses those).
    private var liveMachineIds: [UUID] { liveMachines }

    /// Read the machines (ids and names) and the photos once.
    private func loadMachinesAndPhotos() {
        let live = (try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        let liveIds = Set(live.map(\.id))
        liveMachines = (definition?.machineIds ?? []).filter(liveIds.contains)
        var names: [UUID: String] = [:]
        for m in live where liveMachines.contains(m.id) { names[m.id] = m.name }
        // The machine in use may be gone (a finished workout): still named.
        if let current = exercise.machineId, names[current] == nil,
           let m = try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == current })).first {
            names[current] = m.name
        }
        machineNames = names
        cardPhoto = definition?.photo(on: nil, in: context)
        definitionPhoto = definition?.photo(on: exercise.machineId, in: context)
    }

    /// The machine in use, switchable among the exercise's machines for this
    /// workout via a dropdown at the top of the sheet. Switching keeps completed
    /// sets and re-plans the rest from that machine's weights; its settings
    /// replace the old machine's.
    @ViewBuilder
    private var machineSection: some View {
        if let current = switchableMachine {
            Section {
                if isLocked {
                    Text(machineName(current))
                } else {
                    Menu {
                        Picker("Machine", selection: Binding(
                            get: { current },
                            set: { newId in
                                repo.switchMachine(exercise, to: newId, in: session)
                                try? context.save()
                                syncDrafts()   // incomplete sets now show the new machine's weights
                                loadMachinesAndPhotos()   // and its photo
                            })) {
                            ForEach(liveMachineIds, id: \.self) { Text(machineName($0)).tag($0) }
                        }
                    } label: {
                        HStack {
                            Text(machineName(current)).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        .contentShape(Rectangle())
                    }
                }
            } header: {
                nameHeader(label: "Machine")
            }
        }
    }

    private func machineName(_ id: UUID) -> String { machineNames[id] ?? "Machine" }

    // MARK: - Set rows

    @ViewBuilder
    private func setRow(_ set: WorkoutSessionSet, proxy: ScrollViewProxy) -> some View {
        let isActive = set.id == activeSetId
        let isReopened = set.isCompleted && expandedCompletedSetId == set.id

        if set.isCompleted && !isReopened {
            collapsedCompletedRow(set)
        } else if isReopened {
            reopenedCompletedEditor(set)
        } else if isActive {
            activeSetEditor(set, proxy: proxy)
        } else {
            upcomingRow(set)
        }
    }

    private func collapsedCompletedRow(_ set: WorkoutSessionSet) -> some View {
        Button {
            draftWeight[set.id] = set.actualWeight ?? set.plannedWeight
            draftReps[set.id] = set.actualReps ?? set.plannedReps
            withAnimation { expandedCompletedSetId = set.id }
        } label: {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.statusGreen)
                Text(setTitle(set))
                Spacer()
                Text(setSummary(weight: set.actualWeight ?? set.plannedWeight, reps: set.actualReps ?? set.plannedReps))
                    .foregroundStyle(.secondary)
                if !isLocked { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
            }
        }
        .tint(.primary)
        .disabled(isLocked)
    }

    private func upcomingRow(_ set: WorkoutSessionSet) -> some View {
        HStack {
            Image(systemName: "circle").foregroundStyle(.tertiary)
            Text(setTitle(set)).foregroundStyle(.secondary)
            Spacer()
            Text("Planned \(setSummary(weight: set.plannedWeight, reps: set.plannedReps))")
                .font(.callout).foregroundStyle(.tertiary)
        }
    }

    private func activeSetEditor(_ set: WorkoutSessionSet, proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(setTitle(set, ofTotal: true)).font(.headline)
            Text("Planned: \(setSummary(weight: set.plannedWeight, reps: set.plannedReps))")
                .font(.caption).foregroundStyle(.secondary)
            if exercise.kind == .hold {
                HoldCountdown(seconds: exercise.holdSeconds, holds: max(1, set.plannedReps))
            }
            weightRow(set)
            stepperRow(exercise.kind == .hold ? "Holds" : "Reps", value: bindingRepsAsDouble(set), step: 1, range: 0...100)
            completeButtonArea(set, proxy: proxy)
        }
        .padding(.vertical, 4)
    }

    private func reopenedCompletedEditor(_ set: WorkoutSessionSet) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(setTitle(set)).font(.headline)
                Spacer()
                Label("Completed", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(Theme.statusGreen)
            }
            weightRow(set)
            stepperRow("Reps", value: bindingRepsAsDouble(set), step: 1, range: 0...100)
            HStack {
                Button("Done") {
                    withAnimation { expandedCompletedSetId = nil }
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button(role: .destructive) {
                    repo.uncompleteSet(set, in: session)
                    try? context.save()
                    withAnimation { expandedCompletedSetId = nil }
                } label: { Text("Mark not done") }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Complete button / rest timer slot

    @ViewBuilder
    private func completeButtonArea(_ set: WorkoutSessionSet, proxy: ScrollViewProxy) -> some View {
        if isLocked {
            EmptyView()
        } else if restTimer.isActive {
            // Resting: the countdown takes the button's place; Complete Set
            // returns when it ends or is skipped.
            restRing
        } else {
            // Timer expired or skipped: the action button for the next set. On the
            // set that finishes the exercise, the label becomes the group-aware
            // "Complete & Next" / "Complete <Group>".
            let finishesExercise = exercise.sets.allSatisfy { $0.isCompleted || $0.id == set.id }
            Button {
                complete(set, proxy: proxy)
            } label: {
                SetActionButtonLabel(title: finishesExercise ? completeActionTitle : "Complete Set",
                                     systemImage: "checkmark.circle.fill",
                                     tint: finishesExercise ? Theme.completeExerciseButton : Theme.completeSetButton)
            }
            .buttonStyle(.plain)
        }
    }

    /// The between-sets / between-exercises rest, in the exercise card.
    private var restRing: some View {
        RestRingTimer(caption: restTimer.title,
                      time: restTimer.formattedRemaining,
                      progress: restTimer.progress,
                      // No "Next: Set 2 of 2 · …": the card shows that set (or,
                      // between exercises, the name) right above the ring.
                      detail: "",
                      isRunning: restTimer.isRunning,
                      onPauseResume: { if restTimer.isRunning { restTimer.pause() } else { restTimer.resume() } },
                      onSkip: skipRest)
    }

    // MARK: - Weight display

    /// Bodyweight exercises (no machine, nothing planned on the bar) are reps-only:
    /// no Weight stepper, and sets read "8 reps" instead of "0 lb × 8".
    private var tracksWeight: Bool {
        exercise.machineId != nil || exercise.sets.contains { $0.plannedWeight > 0 || ($0.actualWeight ?? 0) > 0 }
    }

    /// Weight stepper, or for bodyweight exercises an "Add weight" button that reveals it.
    @ViewBuilder
    private func weightRow(_ set: WorkoutSessionSet) -> some View {
        if tracksWeight || addingWeight {
            stepperRow("Weight (\(WeightUnit.current.rawValue))", value: bindingWeight(set), step: 5, range: 0...2000)
        } else if !isLocked {
            Button { withAnimation { addingWeight = true } } label: {
                Label("Add weight", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .tint(Theme.accent)
        }
    }

    /// "Set 2", "Set 2 of 3", and the side for a per-side exercise
    /// ("Set 1 · Left"). Sides cycle within a set.
    private func setTitle(_ set: WorkoutSessionSet, ofTotal: Bool = false) -> String {
        let sides = max(1, exercise.sideLabels.count)
        let number = set.index / sides + 1
        let total = max(1, exercise.sets.count / sides)
        var title = ofTotal ? "Set \(number) of \(total)" : "Set \(number)"
        if !set.side.isEmpty { title += " · \(set.side)" }
        return title
    }

    private func setSummary(weight: Double, reps: Int) -> String {
        tracksWeight ? "\(Int(weight)) \(WeightUnit.current.rawValue) × \(reps)" : "\(reps) reps"
    }

    // MARK: - Steppers

    private func stepperRow(_ title: String, value: Binding<Double>, step: Double, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button { value.wrappedValue = max(range.lowerBound, value.wrappedValue - step) } label: {
                Image(systemName: "minus.circle.fill").font(.title2)
            }.buttonStyle(.plain)
            Text("\(Int(value.wrappedValue))").font(.title3.bold().monospacedDigit()).frame(minWidth: 54)
            Button { value.wrappedValue = min(range.upperBound, value.wrappedValue + step) } label: {
                Image(systemName: "plus.circle.fill").font(.title2)
            }.buttonStyle(.plain)
        }
    }

    /// Weight binding shared by the active-set editor (drafts only, applied on
    /// Complete Set) and the reopened-completed-set editor (already recorded —
    /// changes save immediately, no separate Save step).
    private func bindingWeight(_ set: WorkoutSessionSet) -> Binding<Double> {
        Binding(get: { draftWeight[set.id] ?? set.actualWeight ?? set.plannedWeight },
                set: { newValue in
                    draftWeight[set.id] = newValue
                    if set.isCompleted {
                        repo.editActual(set, in: session, weight: newValue)
                        syncStrengthEditsToCatalog()
                        try? context.save()
                    }
                })
    }
    private func bindingRepsAsDouble(_ set: WorkoutSessionSet) -> Binding<Double> {
        Binding(get: { Double(draftReps[set.id] ?? set.actualReps ?? set.plannedReps) },
                set: { newValue in
                    let reps = Int(newValue)
                    draftReps[set.id] = reps
                    if set.isCompleted {
                        repo.editActual(set, in: session, reps: reps)
                        syncStrengthEditsToCatalog()
                        try? context.save()
                    }
                })
    }

    // MARK: - Actions

    private func syncDrafts() {
        for set in exercise.sets {
            draftWeight[set.id] = set.actualWeight ?? set.plannedWeight
            draftReps[set.id] = set.actualReps ?? set.plannedReps
        }
    }

    private func complete(_ set: WorkoutSessionSet, proxy: ScrollViewProxy) {
        let w = draftWeight[set.id] ?? set.plannedWeight
        let r = draftReps[set.id] ?? set.plannedReps
        repo.completeSet(set, in: session, actualWeight: w, actualReps: r)
        try? context.save()

        if let next = exercise.orderedSets.first(where: { !$0.isCompleted }) {
            // Between sets: the workout's rest for this exercise type
            // (strength, or set-based cardio).
            restTimer.start(seconds: session.rests.betweenSets(exercise.sectionType),
                            upcoming: "Next: \(setTitle(next, ofTotal: true)) · \(setSummary(weight: next.plannedWeight, reps: next.plannedReps))",
                            title: "Rest between sets")
            withAnimation { proxy.scrollTo(next.id, anchor: .center) }
        } else {
            // Exercise finished — bake the performed values into the catalog
            // exercise's defaults (single source of truth) and reconcile.
            syncStrengthEditsToCatalog()
            completeAndProceed()
        }
    }

    /// Close the exercise sheet and hand off to the workout UI to start the
    /// between-exercises cooldown.
    private func finishExercise() {
        restTimer.stop()
        onExerciseCompleted()
        dismiss()
    }

    // MARK: - Complete & advance within an exercise-type group

    /// The next still-incomplete exercise in THIS exercise's group, in list order
    /// (preferring one after the current; otherwise the first remaining). Excludes
    /// the current exercise. `nil` ⇒ completing this finishes the group.
    private func nextInGroup() -> WorkoutSessionExercise? {
        let others = session.orderedExercises.filter {
            $0.sectionType == exercise.sectionType && $0.groupIndex == exercise.groupIndex
                && $0.id != exercise.id && !$0.isFullyCompleted
        }
        return others.first(where: { $0.order > exercise.order }) ?? others.first
    }

    /// True when completing this exercise finishes its group.
    private var completesGroup: Bool { nextInGroup() == nil }

    /// Group-aware label for the complete action.
    private var completeActionTitle: String {
        completesGroup ? "Complete \(exercise.sectionType.displayName)" : "Complete & Next"
    }

    /// After the exercise is complete: jump to the next one in the group, or — if
    /// it was the last — return to the workout screen and start the cooldown.
    private func completeAndProceed() {
        if let next = nextInGroup() {
            // Between exercises of this type (the next is in the same group;
            // a new group gets no rest). It shows in the SAME slot as the
            // between-sets rest, on the exercise we're advancing to. A
            // stretch's is its get-ready, played when the run starts it.
            let rest = exercise.sectionType == .stretching ? 0 : session.rests.betweenExercises(exercise.sectionType)
            if rest > 0 {
                restTimer.start(seconds: rest, upcoming: "Next: \(next.name)",
                                title: "Rest between exercises")
            } else {
                restTimer.stop()
            }
            onAdvance(next)
        } else {
            finishExercise()
        }
    }

    /// Push this exercise's current sets (actual where recorded, else planned)
    /// through to the catalog Exercise as its new default prescription, then
    /// reconcile every routine/in-progress session that references it.
    private func syncStrengthEditsToCatalog() {
        guard exercise.hasSets, let exerciseId = exercise.exerciseId else { return }
        // One entry per set, not per side: a per-side exercise's sets are
        // stored once and repeated for each side.
        let firstSide = exercise.orderedSets.first?.side ?? ""
        let sets = exercise.orderedSets.filter { $0.side == firstSide }.map {
            (reps: $0.actualReps ?? $0.plannedReps, weight: $0.actualWeight ?? $0.plannedWeight)
        }
        RoutineRepository(context).updateExerciseDefaults(exerciseId: exerciseId, machineId: exercise.machineId, sets: sets)
        if let def = try? context.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exerciseId })).first {
            ExerciseLegacyFields.readBackSets(def, machineId: exercise.machineId, context: context)
        }
        CatalogSyncService(context).reconcileExercise(exerciseId)
    }

    /// Skip the remaining rest: stop the timer so the Complete Set button shows.
    private func skipRest() {
        restTimer.reset()
    }

    /// Machine settings always save to the shared machine definition (everywhere)
    /// as well as this workout's snapshot, and reconcile every OTHER in-progress
    /// session sharing the same machine.
    private func apply(setting: SessionMachineSetting, label: String, numeric: Int?, other: String?) {
        repo.updateSessionSetting(setting, numericValue: numeric, otherText: other)
        if label != setting.label {
            repo.renameSetting(setting, to: label, in: exercise)
        }
        if let defId = setting.definitionId {
            repo.saveSettingAsFutureDefault(definitionId: defId, numericValue: numeric, otherText: other)
            if let machineId = exercise.machineId {
                CatalogSyncService(context).reconcileMachine(machineId)
            }
        }
        try? context.save()
    }
}

/// The big primary set action button — a solid accent button used for
/// "Complete Set" / "Mark Complete". While resting, the card shows the rest
/// ring (`RestRingTimer`, InCardTimers) in its place.
struct SetActionButtonLabel: View {
    var title: String
    var systemImage: String? = nil
    var tint: Color = .accentColor
    /// Label color — defaults to white for dark fills; pass `.black` for pale
    /// fills like `Theme.completeSetButton` so the text stays legible.
    var foreground: Color = .white

    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        ZStack {
            shape.fill(tint)
            BigActionLabel(title: title, systemImage: systemImage)
                .foregroundStyle(foreground)
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .clipShape(shape)
        .contentShape(shape)
    }
}

/// Add a brand-new machine setting during a workout (label + value + scope).
struct AddMachineSettingSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onAdd: (_ label: String, _ numeric: Int?, _ other: String?, _ alsoMachine: Bool) -> Void

    @State private var label = ""
    @State private var useOther = false
    @State private var numeric = 0
    @State private var other = ""
    @State private var alsoMachine = true

    var body: some View {
        NavigationStack {
            Form {
                Section("New setting") {
                    TextField("Label (e.g. Seat height)", text: $label)
                    Toggle("Custom value", isOn: $useOther)
                    if useOther {
                        TextField("Custom value", text: $other)
                    } else {
                        Picker("Value", selection: $numeric) {
                            ForEach(MachineSettingDefinition.valueRange, id: \.self) { Text("\($0)").tag($0) }
                        }
                    }
                    Toggle("Also save to this machine", isOn: $alsoMachine)
                }
            }
            .navigationTitle("Add Setting")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(label, useOther ? nil : numeric, useOther ? other : nil, alsoMachine)
                        dismiss()
                    }.disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// A countdown for one hold of a Hold exercise, inside its set: Start runs
/// the hold time once; each finished hold counts toward the set's holds.
/// Completing the set is still the user's tap.
struct HoldCountdown: View {
    let seconds: Int
    let holds: Int

    @State private var done = 0
    @State private var end: Date?

    var body: some View {
        // Ticks only while a hold runs.
        TimelineView(.periodic(from: .now, by: end == nil ? 3600 : 0.2)) { context in
            let remaining = end.map { max(0, Int(ceil($0.timeIntervalSince(context.date)))) } ?? seconds
            HStack {
                Text(done >= holds ? "Holds done" : "Hold \(done + 1) of \(holds)")
                Spacer()
                Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                    .font(.title3.bold().monospacedDigit())
                Button(end == nil ? "Start" : "Stop") {
                    end = end == nil ? Date().addingTimeInterval(TimeInterval(seconds)) : nil
                }
                .buttonStyle(.borderedProminent)
                .tint(end == nil ? Theme.accent : Theme.statusBlack)
                .disabled((done >= holds && end == nil) || seconds <= 0)
            }
            .onChange(of: remaining) { _, left in
                if left == 0, end != nil {
                    end = nil
                    done += 1
                    SoundCues.shared.endChime()
                }
            }
        }
    }
}
