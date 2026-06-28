//
//  SessionExerciseSheet.swift
//  WorkoutTracker
//
//  The per-exercise logging modal. Behavior:
//   • Machine settings and cooldown are STATIC text by default; an Edit toggle
//     turns on adjustment.
//   • Only the "active" set (the first not-yet-completed set, with all earlier
//     sets complete) shows the working controls. Upcoming sets show no Complete
//     button.
//   • Completing a set collapses it to a one-line row (weight × reps + check) and
//     scrolls down to the next set. Tapping a completed row reopens it to edit.
//   • The Complete-Set button slot doubles as the rest timer: it keeps the SAME
//     prominent-button shape throughout. While resting it shows a countdown with
//     the accent fill revealed left-to-right over a darker track; when the timer
//     expires or is skipped it morphs into the functional Complete Set button.
//
//  Title is just the exercise name — no dropdown.
//

import SwiftUI
import SwiftData
import UIKit
import PhotosUI

struct SessionExerciseSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var restTimer: RestTimerService

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
    @State private var didEdit = false
    @State private var showUpdatePrompt = false
    // Snapshot of the cardio/stretching values when the sheet opened, so an
    // adjustment can be detected on Mark Complete (strength uses planned vs actual).
    @State private var capturedOriginals = false
    @State private var origDuration = 0
    @State private var origIntensityRaw = ""
    @State private var origHold = 0
    @State private var origSides = 1
    @State private var origRounds = 1
    @State private var definition: Exercise?
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false

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
                    // Group-specific prescription: strength = sets; cardio and
                    // stretching = their own editable values + a Mark Complete button.
                    switch exercise.sectionType {
                    case .strength:
                        Section("Sets") {
                            ForEach(exercise.orderedSets) { set in
                                setRow(set, proxy: proxy).id(set.id)
                            }
                        }
                    case .cardio:
                        cardioSection
                    case .stretching:
                        stretchSection
                    }
                    // Machine settings (cardio/strength), then the photo/notes definition.
                    machineSettingsSection
                    definitionSection
                }
            }
            .navigationTitle(exercise.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !isLocked {
                        Button(editSettings ? "Done" : "Edit") { withAnimation { editSettings.toggle() } }
                    }
                }
                // Close is hidden while editing (use Done to finish editing).
                if !editSettings {
                    ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } }
                }
            }
            .sheet(item: $editingSetting) { setting in
                MachineSettingEditSheet(setting: setting, machineId: exercise.machineId) { numeric, other in
                    apply(setting: setting, numeric: numeric, other: other)
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
                }
            }
            .sheet(isPresented: $showAddSetting) {
                AddMachineSettingSheet { label, numeric, other, alsoMachine in
                    repo.addSessionSetting(to: exercise, label: label, numericValue: numeric,
                                           otherText: other, alsoAddToMachine: alsoMachine)
                    try? context.save()
                }
            }
            .onAppear { syncDrafts(); loadDefinition(); captureOriginals() }
            .confirmationDialog(promptTitle,
                                isPresented: $showUpdatePrompt, titleVisibility: .visible) {
                Button("This workout only") { finishAfterPrompt() }
                Button("Save as future default") { applyFutureDefault(); finishAfterPrompt() }
            } message: {
                Text(promptMessage)
            }
        }
    }

    // MARK: - Cardio / Stretching (no sets)

    @ViewBuilder
    private var cardioSection: some View {
        Section("Cardio") {
            if isLocked {
                detailRow("Duration", "\(exercise.durationMinutes) min")
                if let i = exercise.intensity { detailRow("Intensity", i.displayName) }
            } else {
                Stepper("Duration: \(exercise.durationMinutes) min",
                        value: intBinding(\.durationMinutes), in: 0...600, step: 5)
                Picker("Intensity", selection: intensityBinding) {
                    Text("Low").tag(CardioIntensity.low)
                    Text("Moderate").tag(CardioIntensity.moderate)
                    Text("High").tag(CardioIntensity.high)
                }
            }
            completeControl
        }
    }

    @ViewBuilder
    private var stretchSection: some View {
        Section("Stretching") {
            if isLocked {
                detailRow("Hold", "\(exercise.holdSeconds)s")
                detailRow("Sides", "\(exercise.sides)")
                detailRow("Rounds", "\(exercise.rounds)")
                if !exercise.notes.isEmpty { detailRow("Notes", exercise.notes) }
            } else {
                Stepper("Hold: \(exercise.holdSeconds)s", value: intBinding(\.holdSeconds), in: 0...600, step: 5)
                Stepper("Sides: \(exercise.sides)", value: intBinding(\.sides), in: 1...2)
                Stepper("Rounds: \(exercise.rounds)", value: intBinding(\.rounds), in: 1...20)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes").font(.caption).foregroundStyle(.secondary)
                    TextField("Notes", text: exerciseNotesBinding, axis: .vertical)
                }
            }
            completeControl
        }
    }

    /// Mark Complete / Mark not done for non-set exercises (cardio / stretching).
    @ViewBuilder
    private var completeControl: some View {
        if isLocked {
            Label(exercise.isFullyCompleted ? "Completed" : "Not completed",
                  systemImage: exercise.isFullyCompleted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(exercise.isFullyCompleted ? .green : .secondary)
        } else if exercise.isFullyCompleted {
            HStack {
                Label("Completed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
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
                SetActionButtonLabel(title: completeActionTitle, systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.plain)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary) }
    }

    /// Save-on-change binding to an Int field of the session exercise.
    private func intBinding(_ keyPath: ReferenceWritableKeyPath<WorkoutSessionExercise, Int>) -> Binding<Int> {
        Binding(get: { exercise[keyPath: keyPath] },
                set: { exercise[keyPath: keyPath] = $0; try? context.save() })
    }
    private var intensityBinding: Binding<CardioIntensity> {
        Binding(get: { exercise.intensity ?? .moderate },
                set: { exercise.intensity = $0; try? context.save() })
    }
    private var exerciseNotesBinding: Binding<String> {
        Binding(get: { exercise.notes },
                set: { exercise.notes = $0; try? context.save() })
    }

    private func markComplete() {
        repo.markExerciseComplete(exercise, in: session)
        try? context.save()
        // If the user adjusted this cardio/stretching exercise and it has a library
        // definition to update, ask whether to save the change as the future default.
        if cardioStretchEdited && exercise.exerciseId != nil {
            showUpdatePrompt = true
        } else {
            completeAndProceed()
        }
    }

    private func captureOriginals() {
        guard !capturedOriginals else { return }
        capturedOriginals = true
        origDuration = exercise.durationMinutes
        origIntensityRaw = exercise.intensityRaw
        origHold = exercise.holdSeconds
        origSides = exercise.sides
        origRounds = exercise.rounds
    }

    /// Whether the cardio/stretching values changed since the sheet opened.
    private var cardioStretchEdited: Bool {
        switch exercise.sectionType {
        case .cardio:
            return exercise.durationMinutes != origDuration || exercise.intensityRaw != origIntensityRaw
        case .stretching:
            return exercise.holdSeconds != origHold || exercise.sides != origSides || exercise.rounds != origRounds
        case .strength:
            return false
        }
    }

    // MARK: - Exercise definition (note + photo)

    @ViewBuilder
    private var definitionSection: some View {
        if let definition {
            let editing = editSettings && !isLocked
            // When not editing, only show the section if there's something to show.
            if editing || definition.photoData != nil || !definition.notes.isEmpty {
                Section {
                    if let data = definition.photoData {
                        // Whole image (no crop); animates + loops if it's a GIF.
                        AnimatedImageView(data: data)
                            .aspectRatio(AnimatedImageView.aspectRatio(of: data), contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .listRowInsets(EdgeInsets())
                    }
                    if editing {
                        HStack {
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                Label(definition.photoData == nil ? "Choose photo" : "Replace photo", systemImage: "photo")
                            }
                            if CameraPicker.isAvailable {
                                Spacer()
                                Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                                    .buttonStyle(.borderless)   // own tap target (don't fire on row tap)
                            }
                        }
                        if definition.photoData != nil {
                            Button(role: .destructive) { setDefinitionPhoto(nil) } label: {
                                Label("Remove photo", systemImage: "trash")
                            }
                        }
                        TextField("Notes", text: notesBinding, axis: .vertical)
                    } else if !definition.notes.isEmpty {
                        Text(definition.notes).font(.callout).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("About this exercise")
                } footer: {
                    if editing { Text("Photo and notes are saved to this exercise's definition everywhere.") }
                }
            }
        }
    }

    /// Notes binding that writes straight to the exercise definition.
    private var notesBinding: Binding<String> {
        Binding(get: { definition?.notes ?? "" },
                set: { definition?.notes = $0; definition?.updatedAt = .now; try? context.save() })
    }

    private func setDefinitionPhoto(_ data: Data?) {
        definition?.photoData = data
        definition?.updatedAt = .now
        try? context.save()
    }

    private func loadDefinition() {
        guard definition == nil, let exId = exercise.exerciseId else { return }
        definition = try? context.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exId })).first
    }

    // MARK: - Machine settings (static by default)

    @ViewBuilder
    private var machineSettingsSection: some View {
        // Stretching has no machine; cardio/strength show settings (and can add).
        if exercise.sectionType != .stretching {
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
            Text("Machine settings")
        }
        }
    }

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
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Set \(set.index + 1)")
                Spacer()
                Text("\(Int(set.actualWeight ?? set.plannedWeight)) lb × \(set.actualReps ?? set.plannedReps)")
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
            Text("Set \(set.index + 1)").foregroundStyle(.secondary)
            Spacer()
            Text("Planned \(Int(set.plannedWeight)) lb × \(set.plannedReps)")
                .font(.callout).foregroundStyle(.tertiary)
        }
    }

    private func activeSetEditor(_ set: WorkoutSessionSet, proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set \(set.index + 1) of \(exercise.sets.count)").font(.headline)
            Text("Planned: \(Int(set.plannedWeight)) lb × \(set.plannedReps)")
                .font(.caption).foregroundStyle(.secondary)
            stepperRow("Weight (lb)", value: bindingWeight(set), step: 5, range: 0...2000)
            stepperRow("Reps", value: bindingRepsAsDouble(set), step: 1, range: 0...100)
            completeButtonArea(set, proxy: proxy)
        }
        .padding(.vertical, 4)
    }

    private func reopenedCompletedEditor(_ set: WorkoutSessionSet) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Set \(set.index + 1)").font(.headline)
                Spacer()
                Label("Completed", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            stepperRow("Weight (lb)", value: bindingWeight(set), step: 5, range: 0...2000)
            stepperRow("Reps", value: bindingRepsAsDouble(set), step: 1, range: 0...100)
            HStack {
                Button("Save") {
                    repo.editActual(set, in: session,
                                    weight: draftWeight[set.id], reps: draftReps[set.id])
                    try? context.save()
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
        } else if restTimer.isRunning {
            // Resting: SAME button shape as Complete Set, with the accent fill
            // revealed left-to-right over a darker track as time elapses.
            // Tap to skip the rest and make Complete Set available immediately.
            VStack(spacing: 4) {
                Button { skipRest() } label: {
                    RestCountdownButton(title: "Rest \(restTimer.formattedRemaining)",
                                        endDate: restTimer.endInstant,
                                        totalSeconds: restTimer.totalSeconds,
                                        isRunning: restTimer.isRunning,
                                        isFinished: restTimer.isFinished)
                }
                .buttonStyle(.plain)
                Text("Tap to skip rest").font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            // Timer expired or skipped: the action button for the next set. On the
            // set that finishes the exercise, the label becomes the group-aware
            // "Complete & Next" / "Complete <Group>".
            let finishesExercise = exercise.sets.allSatisfy { $0.isCompleted || $0.id == set.id }
            Button {
                complete(set, proxy: proxy)
            } label: {
                SetActionButtonLabel(title: finishesExercise ? completeActionTitle : "Complete Set",
                                     systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.plain)
        }
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

    private func bindingWeight(_ set: WorkoutSessionSet) -> Binding<Double> {
        Binding(get: { draftWeight[set.id] ?? set.actualWeight ?? set.plannedWeight },
                set: { draftWeight[set.id] = $0 })
    }
    private func bindingRepsAsDouble(_ set: WorkoutSessionSet) -> Binding<Double> {
        Binding(get: { Double(draftReps[set.id] ?? set.actualReps ?? set.plannedReps) },
                set: { draftReps[set.id] = Int($0) })
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
        if w != set.plannedWeight || r != set.plannedReps { didEdit = true }
        repo.completeSet(set, in: session, actualWeight: w, actualReps: r)
        try? context.save()

        if let next = exercise.orderedSets.first(where: { !$0.isCompleted }) {
            // Between-sets cooldown uses the session-level setting.
            restTimer.start(seconds: session.restBetweenSets,
                            upcoming: "Next: \(Int(next.plannedWeight)) lb × \(next.plannedReps)")
            withAnimation { proxy.scrollTo(next.id, anchor: .center) }
        } else {
            // Exercise finished. If the user made edits and this exercise came
            // from a routine, offer to bake the changes into the routine + the
            // exercise definition; otherwise just close.
            let fromRoutine = session.routineId != nil && exercise.sourceRoutineExerciseId != nil
            if didEdit && fromRoutine {
                showUpdatePrompt = true
            } else {
                completeAndProceed()
            }
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
            restTimer.stop()
            onAdvance(next)
        } else {
            finishExercise()
        }
    }

    // MARK: - "This workout vs. future default" prompt (all groups)

    private var promptTitle: String {
        exercise.hasSets ? "Apply the new reps/weights to…" : "Apply the new values to…"
    }
    private var promptMessage: String {
        exercise.hasSets
            ? "You changed reps or weight. Save them as the routine's future default, or keep them just for this workout?"
            : "You changed this exercise's values. Save them as the exercise's future default, or keep them just for this workout?"
    }

    /// Save the performed values as the future default (strength → routine +
    /// exercise; cardio/stretching → the exercise definition).
    private func applyFutureDefault() {
        if exercise.hasSets { applyEditsToRoutineAndExercise() }
        else { applyCardioStretchDefault() }
    }

    /// Finish after the future-default prompt: advance to the next exercise in the
    /// group, or return to the workout screen if this was the last.
    private func finishAfterPrompt() {
        completeAndProceed()
    }

    /// Bake the adjusted cardio/stretching values into the library exercise so
    /// future workouts use them by default.
    private func applyCardioStretchDefault() {
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
        case .strength:
            break
        }
        def.updatedAt = .now
        try? context.save()
    }

    /// Bake the performed values into the routine (new version) and the library
    /// exercise's defaults.
    private func applyEditsToRoutineAndExercise() {
        let sets = exercise.orderedSets.map {
            (reps: $0.actualReps ?? $0.plannedReps, weight: $0.actualWeight ?? $0.plannedWeight)
        }
        let routineRepo = RoutineRepository(context)
        if let routineId = session.routineId,
           let srcId = exercise.sourceRoutineExerciseId,
           let routine = try? context.fetch(FetchDescriptor<Routine>(predicate: #Predicate { $0.id == routineId })).first {
            routineRepo.updateFutureDefault(routine: routine, sourceRoutineExerciseId: srcId) { re in
                routineRepo.setPlannedSets(re, sets: sets, restBetweenSets: re.restBetweenSets)
            }
        }
        if let exerciseId = exercise.exerciseId {
            routineRepo.updateExerciseDefaults(exerciseId: exerciseId, sets: sets)
        }
        try? context.save()
    }

    /// Skip the remaining rest: stop the timer so the Complete Set button shows.
    private func skipRest() {
        restTimer.reset()
    }

    /// Machine settings always save to the shared machine definition (everywhere)
    /// as well as this workout's snapshot — no per-workout choice, and this does
    /// NOT trigger the routine-update prompt (that's only for reps/weight).
    private func apply(setting: SessionMachineSetting, numeric: Int?, other: String?) {
        repo.updateSessionSetting(setting, numericValue: numeric, otherText: other)
        if let defId = setting.definitionId {
            repo.saveSettingAsFutureDefault(definitionId: defId, numericValue: numeric, otherText: other)
        }
        try? context.save()
    }
}

/// The big primary set action button — a solid accent button used for
/// "Complete Set" / "Mark Complete". The rest countdown uses `RestCountdownButton`
/// below, which shares the same shape and sizing so the two look identical apart
/// from the fill.
struct SetActionButtonLabel: View {
    var title: String
    var systemImage: String? = nil
    var tint: Color = .accentColor

    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        ZStack {
            shape.fill(tint)
            BigActionLabel(title: title, systemImage: systemImage)
                .foregroundStyle(.white)
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
    @State private var numeric = 1
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
                            ForEach(1...15, id: \.self) { Text("\($0)").tag($0) }
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
