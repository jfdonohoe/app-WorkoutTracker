//
//  ExerciseEditorView.swift
//  WorkoutTracker
//
//  Create/edit a library Exercise: name, group, the group's default
//  prescription (strength = per-set reps/weight, cardio = duration/intensity,
//  stretching = hold/sides/rounds), an optional machine + up to 4 shared
//  settings, a reference photo (any group), and notes.
//
//  WHY this is presented as a SHEET (see ExerciseLibraryView):
//  A `ForEach` over a @State value array (the per-set list, the settings list)
//  drove a 125% CPU render loop that froze this screen when it was PUSHED onto
//  Settings' stack with no NavigationStack of its own. Presented as
//  `.sheet { NavigationStack { … } }` (like SetBuilderSheet / RoutineListView's
//  new-routine editor), those @State ForEach lists behave. Uses Cancel/Save
//  because a sheet has no back button.
//

import SwiftUI
import SwiftData
import UIKit

struct ExerciseEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var existing: Exercise?
    /// When creating from a routine grouping, lock the new exercise to that group.
    var forcedGroup: SectionType? = nil

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
    // Photo
    @State private var photoData: Data?
    private enum PhotoSource: Int, Identifiable { case library, camera; var id: Int { rawValue } }
    @State private var photoSource: PhotoSource?
    @State private var showDeleteConfirm = false
    @State private var didLoad = false

    init(existing: Exercise? = nil, forcedGroup: SectionType? = nil) {
        self.existing = existing
        self.forcedGroup = forcedGroup
    }

    private var isNew: Bool { existing == nil }

    struct SetDraft: Identifiable, Equatable { let id = UUID(); var reps: Int; var weight: Double }
    struct SettingDraft: Identifiable, Equatable {
        let id = UUID()
        var label = ""
        var useOther = false
        var numeric = 1
        var other = ""
        var isEmpty: Bool { label.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        List {
            Section("Exercise") {
                TextField("Name (e.g. Leg Press)", text: $name)
                if isNew && forcedGroup == nil {
                    Picker("Group", selection: $group) {
                        Text(SectionType.strength.displayName).tag(SectionType.strength)
                        Text(SectionType.cardio.displayName).tag(SectionType.cardio)
                        Text(SectionType.stretching.displayName).tag(SectionType.stretching)
                    }
                } else {
                    // Locked: editing keeps the existing group; creating from a
                    // routine grouping is fixed to that group.
                    HStack { Text("Group"); Spacer(); Text(group.displayName).foregroundStyle(.secondary) }
                }
            }

            groupSections

            photoSection   // every group can have a reference photo

            Section("Notes") {
                TextField("Notes", text: $notes, axis: .vertical)
            }

            if !isNew {
                Section {
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Label("Delete exercise", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(isNew ? "New Exercise" : "Edit Exercise")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear(perform: load)
        // ONE presentation for both sources — a separate .sheet and .fullScreenCover
        // on the same view conflict (wrong one fires / flashes shut on first use).
        .fullScreenCover(item: $photoSource) { source in
            switch source {
            case .library:
                PhotoLibraryPicker { data in photoData = data }
            case .camera:
                CameraPicker { image in photoData = image.jpegData(compressionQuality: 0.8) }
                    .ignoresSafeArea()
            }
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
    }

    // MARK: - Group-specific sections

    @ViewBuilder
    private var groupSections: some View {
        switch group {
        case .strength:
            Section("Default sets") {
                ForEach(Array(sets.enumerated()), id: \.element.id) { index, _ in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Set \(index + 1)").font(.subheadline.bold())
                        Stepper("Weight: \(Int(sets[index].weight)) lb",
                                value: $sets[index].weight, in: 0...2000, step: 5)
                        Stepper("Reps: \(sets[index].reps)",
                                value: $sets[index].reps, in: 1...100)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { offsets in
                    sets.remove(atOffsets: offsets)
                    if sets.isEmpty { sets = [SetDraft(reps: 10, weight: 0)] }
                }
                Button {
                    let last = sets.last ?? SetDraft(reps: 10, weight: 0)
                    sets.append(SetDraft(reps: last.reps, weight: last.weight))
                } label: { Label("Add set (copies last)", systemImage: "plus.circle") }
                .disabled(sets.count >= 15)
            }
            machineSection
        case .cardio:
            Section("Cardio") {
                Stepper("Duration: \(durationMinutes) min", value: $durationMinutes, in: 1...300, step: 5)
                Picker("Intensity", selection: $intensity) {
                    Text(CardioIntensity.low.displayName).tag(CardioIntensity.low)
                    Text(CardioIntensity.moderate.displayName).tag(CardioIntensity.moderate)
                    Text(CardioIntensity.high.displayName).tag(CardioIntensity.high)
                }
            }
            machineSection
        case .stretching:
            Section("Stretching") {
                Stepper("Hold: \(holdSeconds)s", value: $holdSeconds, in: 1...600, step: 5)
                Stepper("Sides: \(sides)", value: $sides, in: 1...2)
                Stepper("Rounds: \(rounds)", value: $rounds, in: 1...20)
            }
        }
    }

    @ViewBuilder
    private var machineSection: some View {
        Section("Machine") {
            Toggle("Machine-based", isOn: $isMachine)
            if isMachine { TextField("Machine name", text: $machineName) }
        }
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

    // MARK: - Photo

    @ViewBuilder
    private var photoSection: some View {
        Section("Photo") {
            if let data = photoData {
                // Whole image (no crop); animates + loops if it's a GIF.
                AnimatedImageView(data: data)
                    .aspectRatio(AnimatedImageView.aspectRatio(of: data), contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
            }
            HStack {
                // .borderless gives each button its own tap target — otherwise a
                // tap on this List row fires BOTH buttons (Choose photo opened the
                // camera because the camera action fired too).
                Button { photoSource = .library } label: {
                    Label(photoData == nil ? "Choose photo" : "Replace photo", systemImage: "photo")
                }
                .buttonStyle(.borderless)
                if CameraPicker.isAvailable {
                    Spacer()
                    Button { photoSource = .camera } label: { Label("Camera", systemImage: "camera") }
                        .buttonStyle(.borderless)
                }
            }
            if photoData != nil {
                Button(role: .destructive) { photoData = nil } label: {
                    Label("Remove photo", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Load / Save

    private func load() {
        guard !didLoad else { return }
        defer { didLoad = true }
        if let forcedGroup { group = forcedGroup } // new exercise locked to a group
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

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let exercise = existing ?? Exercise(name: trimmed, source: .user)
        if existing == nil { context.insert(exercise) }
        exercise.name = trimmed
        exercise.notes = notes
        exercise.defaultSectionType = group
        exercise.photoData = photoData
        exercise.durationMinutes = durationMinutes
        exercise.intensity = intensity
        exercise.holdSeconds = holdSeconds
        exercise.sides = sides
        exercise.rounds = rounds
        exercise.updatedAt = .now

        // Per-set defaults apply to strength only.
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

        // Machine + its shared settings (strength & cardio only).
        if isMachine && group != .stretching {
            let machine: Machine
            if let mid = exercise.machineId,
               let existingMachine = try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == mid })).first {
                machine = existingMachine
                machine.name = machineName.isEmpty ? trimmed : machineName
            } else {
                machine = Machine(name: machineName.isEmpty ? trimmed : machineName, source: .user)
                context.insert(machine)
                exercise.machineId = machine.id
            }
            // Replace the machine's setting definitions with the edited drafts.
            for def in machine.settingDefinitions { context.delete(def) }
            machine.settingDefinitions = []
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
        dismiss()
    }
}
