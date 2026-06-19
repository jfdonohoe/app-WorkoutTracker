//
//  ExerciseEditorView.swift
//  WorkoutTracker
//
//  Create/edit a library Exercise with its FULL default prescription: name,
//  optional machine + settings, default sets (per-set reps/weight), and default
//  cooldown. The same name can exist many times with different defaults.
//
//  Used by the Settings ▸ Exercises library, the routine builder's picker, and
//  the in-workout "Add exercise" flow.
//

import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct ExerciseEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var existing: Exercise?

    @State private var name = ""
    @State private var notes = ""
    @State private var group: SectionType = .strength
    @State private var isMachine = true
    @State private var machineName = ""
    @State private var settings: [SettingDraft] = []
    @State private var sets: [SetDraft] = [SetDraft(reps: 10, weight: 0)]
    // Cardio
    @State private var durationMinutes = 20
    @State private var intensity: CardioIntensity = .moderate
    // Stretching
    @State private var holdSeconds = 30
    @State private var sides = 1
    @State private var rounds = 1
    @State private var showDeleteConfirm = false
    @State private var photoData: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var didLoad = false
    @State private var touched = false        // new-exercise: any field edited
    @State private var showLeaveConfirm = false

    init(existing: Exercise? = nil) { self.existing = existing }

    private var isNew: Bool { existing == nil }

    struct SettingDraft: Identifiable, Equatable {
        let id = UUID()
        var label = ""
        var useOther = false
        var numeric = 1
        var other = ""
        var isEmpty: Bool { label.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    struct SetDraft: Identifiable, Equatable { let id = UUID(); var reps: Int; var weight: Double }

    var body: some View {
        Form {
            exerciseSection
            groupSections
            // Photo & notes sit directly above the delete button.
            // (Strength & cardio include a photo; stretching is notes-only.)
            photoNotesSection
            deleteSection
        }
        .navigationTitle(isNew ? "New Exercise" : "Edit Exercise")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            // Custom Back: new exercise confirms unsaved edits; editing commits
            // on the way out (no Save button, and no per-change writes that would
            // churn the library's @Query and loop).
            ToolbarItem(placement: .topBarLeading) {
                Button { backTapped() } label: { Label("Back", systemImage: "chevron.left") }
            }
            if isNew {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear(perform: load)
        // Track edits (for new-exercise dirty state). Photo changes call
        // fieldChanged() directly.
        .onChange(of: changeToken) { _, _ in fieldChanged() }
        .confirmationDialog("Leave without saving?", isPresented: $showLeaveConfirm, titleVisibility: .visible) {
            Button("Leave without saving", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .confirmationDialog("Delete this exercise?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete exercise", role: .destructive) {
                if let existing { existing.deletedAt = .now; existing.updatedAt = .now; try? context.save() }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will be removed from your library. Past workouts that used it are unaffected.")
        }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    photoData = data
                    fieldChanged()
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                photoData = image.jpegData(compressionQuality: 0.8)
                fieldChanged()
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Top-level sections (split out to keep the body type-checkable)

    private var exerciseSection: some View {
        Section("Exercise") {
            TextField("Name (e.g. Leg Press)", text: $name)
            if isNew {
                Picker("Group", selection: $group) {
                    ForEach(SectionType.allCases) { Text($0.displayName).tag($0) }
                }
            } else {
                // Group can't change after creation (each group has its own
                // definition shape).
                HStack { Text("Group"); Spacer(); Text(group.displayName).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder
    private var groupSections: some View {
        switch group {
        case .strength:
            strengthSetsSection
            machineSection
        case .cardio:
            cardioSection
            machineSection
        case .stretching:
            stretchSection
        }
    }

    @ViewBuilder
    private var deleteSection: some View {
        if !isNew {
            Section {
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label("Delete exercise", systemImage: "trash").frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// A single value summarizing every editable field, so one .onChange can
    /// drive auto-save / dirty tracking. (Photo handled separately.)
    private var changeToken: String {
        let setsKey = sets.map { "\($0.reps)x\(Int($0.weight))" }.joined(separator: ",")
        let settingsKey = settings.map { "\($0.label):\($0.useOther):\($0.numeric):\($0.other)" }.joined(separator: ",")
        return [name, group.rawValue, "\(isMachine)", machineName, notes,
                "\(durationMinutes)", intensity.rawValue, "\(holdSeconds)", "\(sides)", "\(rounds)",
                setsKey, settingsKey].joined(separator: "|")
    }

    // MARK: - Group-specific sections

    private var strengthSetsSection: some View {
        Section("Default sets") {
            ForEach(Array(sets.enumerated()), id: \.element.id) { i, _ in
                VStack(alignment: .leading, spacing: 14) {
                    Text("Set \(i + 1)").font(.caption).foregroundStyle(.secondary)
                    Stepper("Weight: \(Int(sets[i].weight)) lb", value: $sets[i].weight, in: 0...2000, step: 5)
                    Stepper("Reps: \(sets[i].reps)", value: $sets[i].reps, in: 1...100)
                }
                .padding(.vertical, 6)
            }
            .onDelete { sets.remove(atOffsets: $0); if sets.isEmpty { sets = [SetDraft(reps: 10, weight: 0)] } }
            Button {
                let last = sets.last ?? SetDraft(reps: 10, weight: 0)
                sets.append(SetDraft(reps: last.reps, weight: last.weight))
            } label: { Label("Add set (copies last)", systemImage: "plus.circle") }
        }
    }

    private var cardioSection: some View {
        Section("Cardio") {
            Stepper("Duration: \(durationMinutes) min", value: $durationMinutes, in: 1...300, step: 5)
            Picker("Intensity", selection: $intensity) {
                ForEach(CardioIntensity.allCases) { Text($0.displayName).tag($0) }
            }
        }
    }

    private var stretchSection: some View {
        Section("Stretching") {
            Stepper("Hold: \(holdSeconds)s", value: $holdSeconds, in: 1...600, step: 5)
            Stepper("Sides: \(sides)", value: $sides, in: 1...2)
            Stepper("Rounds: \(rounds)", value: $rounds, in: 1...20)
        }
    }

    @ViewBuilder
    private var machineSection: some View {
        Section {
            Toggle("Machine-based", isOn: $isMachine)
            if isMachine { TextField("Machine name", text: $machineName) }
        } header: { Text("Machine") }

        if isMachine {
            Section("Machine settings (up to 4)") {
                ForEach(Array(settings.enumerated()), id: \.element.id) { index, _ in
                    settingRow(index)
                }
                .onDelete { settings.remove(atOffsets: $0) }
                if settings.count < 4 {
                    Button { settings.append(SettingDraft()) } label: {
                        Label("Add setting", systemImage: "plus.circle")
                    }
                }
            }
        }
    }

    // MARK: - Photo & notes

    /// Stretching has no photo (per its definition); strength & cardio do.
    private var allowsPhoto: Bool { group != .stretching }

    @ViewBuilder
    private var photoNotesSection: some View {
        Section {
            if allowsPhoto {
                if let data = photoData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                        .clipped()
                        .listRowInsets(EdgeInsets())
                }
                HStack {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(photoData == nil ? "Choose photo" : "Replace photo", systemImage: "photo")
                    }
                    if CameraPicker.isAvailable {
                        Spacer()
                        Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                    }
                }
                if photoData != nil {
                    Button(role: .destructive) { photoData = nil; photoItem = nil; fieldChanged() } label: {
                        Label("Remove photo", systemImage: "trash")
                    }
                }
            }
            TextField("Notes", text: $notes, axis: .vertical)
        } header: {
            Text(allowsPhoto ? "Photo & notes" : "Notes")
        }
    }

    // MARK: - Change tracking

    private func fieldChanged() {
        guard didLoad else { return } // ignore initial population
        touched = true
    }

    private func backTapped() {
        if isNew {
            // Confirm only if something was entered.
            if touched { showLeaveConfirm = true } else { dismiss() }
        } else {
            // Editing: commit on the way out (persists changes without a Save
            // button and without per-change writes that would loop the library).
            if touched { commit() }
            dismiss()
        }
    }

    // MARK: - Machine settings rows

    @ViewBuilder
    private func settingRow(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Setting label (e.g. Seat height)", text: $settings[index].label)
                .font(.headline)
            Toggle("Custom value", isOn: $settings[index].useOther)
            if settings[index].useOther {
                TextField("Custom value", text: $settings[index].other)
            } else {
                Picker("Value", selection: $settings[index].numeric) {
                    ForEach(1...15, id: \.self) { Text("\($0)").tag($0) }
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Load / Save

    private func load() {
        guard !didLoad else { return }
        defer { didLoad = true } // ignore the field changes from initial population
        guard let existing else { return }
        name = existing.name
        notes = existing.notes
        group = existing.defaultSectionType
        photoData = existing.photoData
        durationMinutes = existing.durationMinutes
        intensity = existing.intensity
        holdSeconds = existing.holdSeconds
        sides = existing.sides
        rounds = existing.rounds
        let ds = existing.effectiveDefaultSets
        if !ds.isEmpty { sets = ds.map { SetDraft(reps: $0.reps, weight: $0.weight) } }
        if let mid = existing.machineId,
           let machine = try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == mid })).first {
            isMachine = true
            machineName = machine.name
            settings = machine.activeSettings.map {
                var d = SettingDraft(); d.label = $0.label
                if let n = $0.numericValue { d.numeric = n } else { d.useOther = true; d.other = $0.otherText ?? "" }
                return d
            }
        } else {
            isMachine = false
        }
    }

    /// New-exercise Save button: commit then leave.
    private func save() {
        commit()
        dismiss()
    }

    /// Write the current state to the model. Used by Save (new) and by
    /// auto-save on every change (editing an existing exercise).
    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let exercise = existing ?? Exercise(name: trimmed, source: .user)
        if existing == nil { context.insert(exercise) }
        exercise.name = trimmed
        exercise.notes = notes
        exercise.defaultSectionType = group
        // Group-specific values.
        exercise.photoData = allowsPhoto ? photoData : nil
        exercise.durationMinutes = durationMinutes
        exercise.intensity = intensity
        exercise.holdSeconds = holdSeconds
        exercise.sides = sides
        exercise.rounds = rounds
        exercise.updatedAt = .now

        // Default sets only apply to strength; clear them otherwise.
        for d in exercise.defaultSets { context.delete(d) }
        exercise.defaultSets = []
        if group == .strength {
            for (i, s) in sets.enumerated() {
                let ds = ExerciseDefaultSet(order: i, reps: s.reps, weight: s.weight)
                ds.exercise = exercise
                exercise.defaultSets.append(ds)
                context.insert(ds)
            }
        }

        // Machine + settings (strength & cardio only).
        if isMachine && group != .stretching {
            let machine: Machine
            if let mid = exercise.machineId,
               let existingMachine = try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == mid })).first {
                machine = existingMachine
                machine.name = machineName.isEmpty ? trimmed : machineName
                for def in machine.settingDefinitions { context.delete(def) }
                machine.settingDefinitions = []
            } else {
                machine = Machine(name: machineName.isEmpty ? trimmed : machineName, source: .user)
                context.insert(machine)
                exercise.machineId = machine.id
            }
            var order = 0
            for s in settings where !s.isEmpty {
                let def = MachineSettingDefinition(label: s.label.trimmingCharacters(in: .whitespaces),
                                                   order: order,
                                                   numericValue: s.useOther ? nil : s.numeric,
                                                   otherText: s.useOther ? s.other : nil,
                                                   source: machine.source)
                def.machine = machine
                machine.settingDefinitions.append(def)
                context.insert(def)
                order += 1
            }
        } else {
            exercise.machineId = nil
        }

        try? context.save()
    }
}
