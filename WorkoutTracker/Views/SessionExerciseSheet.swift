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
    /// Called when the LAST set of this exercise is completed (so the workout UI
    /// can start the between-exercises cooldown).
    var onExerciseCompleted: () -> Void = {}

    @State private var editSettings = false
    @State private var expandedCompletedSetId: UUID?
    @State private var draftWeight: [UUID: Double] = [:]
    @State private var draftReps: [UUID: Int] = [:]
    @State private var editingSetting: SessionMachineSetting?
    @State private var showAddSetting = false
    @State private var didEdit = false
    @State private var showUpdatePrompt = false
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
                    Section("Sets") {
                        ForEach(exercise.orderedSets) { set in
                            setRow(set, proxy: proxy).id(set.id)
                        }
                    }
                    // Machine settings, then the photo/notes definition, below sets.
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
            .onAppear { syncDrafts(); loadDefinition() }
            .confirmationDialog("Apply the new reps/weights to…",
                                isPresented: $showUpdatePrompt, titleVisibility: .visible) {
                Button("This workout only") { finishExercise() }
                Button("Save as future default") { applyEditsToRoutineAndExercise(); finishExercise() }
            } message: {
                Text("You changed reps or weight. Save them as the routine's future default, or keep them just for this workout?")
            }
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
                    if let data = definition.photoData, let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable().scaledToFill()
                            .frame(maxWidth: .infinity).frame(height: 180).clipped()
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

    private var machineSettingsSection: some View {
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
                    SetActionButtonLabel(title: "Rest \(restTimer.formattedRemaining)",
                                         progress: restTimer.progress)
                }
                .buttonStyle(.plain)
                Text("Tap to skip rest").font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            // Timer expired or skipped: the action button for the next set.
            Button {
                complete(set, proxy: proxy)
            } label: {
                SetActionButtonLabel(title: "Complete Set", systemImage: "checkmark.circle.fill")
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
                finishExercise()
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

/// The big primary set button. It keeps ONE shape in every state so the rest
/// countdown and the Complete Set action look identical except for the progress
/// reveal:
///   • `progress == nil` → a solid accent action button (e.g. "Complete Set").
///   • `progress` set (0...1) → the between-reps rest countdown: a BRIGHT yellow
///     fill is revealed left-to-right (a hard mask edge) over a DARK yellow track,
///     advancing as time elapses.
struct SetActionButtonLabel: View {
    var title: String
    var systemImage: String? = nil
    /// nil = solid action button. 0...1 = rest countdown reveal.
    var progress: Double? = nil
    var tint: Color = .accentColor

    /// Rest-countdown colors.
    private static let darkYellow = Color(red: 0.60, green: 0.47, blue: 0.0)
    private static let brightYellow = Color(red: 1.0, green: 0.84, blue: 0.0)

    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        ZStack {
            if let progress {
                // Dark yellow track…
                shape.fill(Self.darkYellow)
                // …with the bright yellow fill revealed across it as time elapses.
                GeometryReader { geo in
                    shape.fill(Self.brightYellow)
                        .mask(alignment: .leading) {
                            Rectangle()
                                .frame(width: geo.size.width * min(max(progress, 0), 1))
                        }
                }
                .animation(.linear(duration: 0.25), value: progress)
            } else {
                shape.fill(tint)
            }

            BigActionLabel(title: title, systemImage: systemImage)
                .foregroundStyle(progress == nil ? .white : .black)
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
