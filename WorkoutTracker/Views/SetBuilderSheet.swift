//
//  SetBuilderSheet.swift
//  WorkoutTracker
//
//  Set-by-set exercise plan editor. The plan starts by defining the first set
//  (reps + weight). "Add set" copies the last defined set so the user can tweak
//  it. Cooldown between sets defaults to the routine's default. If the exercise
//  is machine-based, the machine's shared settings can be defined here too.
//
//  Used both when adding/editing an exercise in a routine and when adding an
//  unplanned exercise mid-workout. It returns the built sets + rest + chosen
//  machine via onSave; machine-setting edits are written straight to the
//  shared Machine.
//
//  When `allowsMachineChoice` is set and the exercise has more than one
//  machine, a Machine picker chooses which one (the routine editor uses this
//  to pick the routine's machine). Switching loads that machine's own default
//  sets and settings.
//

import SwiftUI
import SwiftData
import UIKit

struct SetBuilderSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let title: String
    /// Machine whose shared settings can be defined here (optional).
    let machineId: UUID?
    /// The library exercise this routine exercise references (for its note/photo).
    var exerciseId: UUID? = nil
    /// Routine default cooldown, used to seed the rest field for a new exercise.
    let defaultRest: Int
    var initialSets: [(reps: Int, weight: Double)] = []
    var initialRest: Int? = nil
    /// Show a Machine picker when the exercise has several machines.
    var allowsMachineChoice = false
    var onSave: (_ sets: [(reps: Int, weight: Double)], _ rest: Int, _ machineId: UUID?) -> Void

    struct SetDraft: Identifiable { let id = UUID(); var reps: Int; var weight: Double }

    @State private var sets: [SetDraft] = []
    @State private var rest: Int = 90
    @State private var machine: Machine?
    @State private var selectedMachineId: UUID?
    @State private var exercise: Exercise?
    @State private var showAddSetting = false
    @State private var otherEditDef: MachineSettingDefinition?
    @State private var renamingDef: MachineSettingDefinition?
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            List {
                definitionSection
                machinePickerSection
                setsSection
                if machine != nil { machineSection }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(sets.map { ($0.reps, $0.weight) }, rest, selectedMachineId)
                        dismiss()
                    }.disabled(sets.isEmpty)
                }
            }
            .sheet(isPresented: $showAddSetting) {
                AddMachineSettingSheet { label, numeric, other, _ in
                    addMachineSetting(label: label, numeric: numeric, other: other)
                }
            }
            .onAppear(perform: load)
        }
    }

    // MARK: - Exercise definition (note + photo)

    @ViewBuilder
    private var definitionSection: some View {
        let photo = exercise?.photo(on: selectedMachineId ?? exercise?.machineId, in: context)
        if let exercise, photo != nil || !exercise.notes.isEmpty {
            Section {
                if let data = photo {
                    // Whole image (no crop); animates + loops if it's a GIF.
                    AnimatedImageView(data: data)
                        .aspectRatio(AnimatedImageView.aspectRatio(of: data), contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets())
                }
                if !exercise.notes.isEmpty {
                    Text(exercise.notes).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("About this exercise")
            }
        }
    }

    // MARK: - Machine choice

    @ViewBuilder
    private var machinePickerSection: some View {
        if allowsMachineChoice, let exercise, exercise.machineIds.count > 1, let current = selectedMachineId {
            Section {
                Picker("Machine", selection: Binding(get: { current }, set: { selectMachine($0) })) {
                    ForEach(exercise.machineIds, id: \.self) { id in
                        Text(machineName(id)).tag(id)
                    }
                }
            } footer: {
                Text("Each machine keeps its own weights and settings.")
            }
        }
    }

    private func machineName(_ id: UUID) -> String {
        (try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == id })).first?.name) ?? "Machine"
    }

    /// Switch to another of the exercise's machines: load its sets + settings.
    private func selectMachine(_ id: UUID) {
        guard id != selectedMachineId else { return }
        selectedMachineId = id
        machine = try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == id })).first
        if let exercise {
            let planned = exercise.defaultSets(for: id)
            sets = planned.isEmpty ? [SetDraft(reps: 10, weight: 0)] : planned.map { SetDraft(reps: $0.reps, weight: $0.weight) }
        }
    }

    // MARK: - Sets

    private var setsSection: some View {
        Section {
            ForEach(Array(sets.enumerated()), id: \.element.id) { index, _ in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Set \(index + 1)").font(.subheadline.bold())
                    stepper("Weight (\(WeightUnit.current.rawValue))", value: $sets[index].weight, step: 5, range: 0...2000)
                    stepperInt("Reps", value: $sets[index].reps, step: 1, range: 1...100)
                }
                .padding(.vertical, 2)
            }
            .onDelete { offsets in
                sets.remove(atOffsets: offsets)
                if sets.isEmpty { sets = [SetDraft(reps: 10, weight: 0)] }
            }

            Button {
                // Add a set that copies the last defined set.
                let last = sets.last ?? SetDraft(reps: 10, weight: 0)
                sets.append(SetDraft(reps: last.reps, weight: last.weight))
            } label: {
                Label("Add set (copies last)", systemImage: "plus.circle")
            }
            .disabled(sets.count >= 15)
        } header: {
            Text("Sets")
        }
    }

    // MARK: - Machine settings

    private var machineSection: some View {
        Section {
            ForEach(machine?.activeSettings ?? []) { def in
                HStack {
                    Button { renamingDef = def } label: {
                        HStack(spacing: 4) {
                            Text(def.label)
                            Image(systemName: "pencil").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                    Spacer()
                    Menu {
                        ForEach(MachineSettingDefinition.valueRange, id: \.self) { n in
                            Button("\(n)") { setDefValue(def, numeric: n, other: nil) }
                        }
                        Button("Other…") { otherEditDef = def }
                    } label: {
                        Text(def.displayValue).bold()
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { deleteDef(def) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            if (machine?.activeSettings.count ?? 0) < Machine.maxSettings {
                Button { showAddSetting = true } label: {
                    Label("Add machine setting", systemImage: "plus")
                }
            }
        } header: {
            Text("Machine settings (shared)")
        } footer: {
            Text("These values are shared by every routine using this machine and are snapshotted into each workout.")
        }
        .sheet(item: $otherEditDef) { def in
            TextPromptSheet(title: "Custom value", placeholder: "Value",
                            initial: def.otherText ?? "") { value in
                setDefValue(def, numeric: nil, other: value)
            }
        }
        .sheet(item: $renamingDef) { def in
            TextPromptSheet(title: "Setting name", placeholder: "e.g. Seat height",
                            initial: def.label) { newLabel in
                renameDef(def, to: newLabel)
            }
        }
    }

    // MARK: - Helpers

    private func stepper(_ title: String, value: Binding<Double>, step: Double, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title); Spacer()
            Button { value.wrappedValue = max(range.lowerBound, value.wrappedValue - step) } label: {
                Image(systemName: "minus.circle.fill").font(.title2)
            }.buttonStyle(.plain)
            Text("\(Int(value.wrappedValue))").font(.title3.bold().monospacedDigit()).frame(minWidth: 54)
            Button { value.wrappedValue = min(range.upperBound, value.wrappedValue + step) } label: {
                Image(systemName: "plus.circle.fill").font(.title2)
            }.buttonStyle(.plain)
        }
    }

    private func stepperInt(_ title: String, value: Binding<Int>, step: Int, range: ClosedRange<Int>) -> some View {
        stepper(title, value: Binding(get: { Double(value.wrappedValue) },
                                      set: { value.wrappedValue = Int($0) }),
                step: Double(step), range: Double(range.lowerBound)...Double(range.upperBound))
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        if let exerciseId {
            exercise = try? context.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exerciseId })).first
        }
        // A machine no longer linked to the exercise falls back to its default.
        if let exercise, let id = machineId, !exercise.machineIds.isEmpty, !exercise.machineIds.contains(id) {
            selectedMachineId = exercise.machineId
        } else {
            selectedMachineId = machineId
        }
        if let machineId = selectedMachineId {
            machine = try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == machineId })).first
        }
        if initialSets.isEmpty {
            sets = [SetDraft(reps: 10, weight: 0)]
        } else {
            sets = initialSets.map { SetDraft(reps: $0.reps, weight: $0.weight) }
        }
        rest = initialRest ?? defaultRest
    }

    private func setDefValue(_ def: MachineSettingDefinition, numeric: Int?, other: String?) {
        def.numericValue = numeric
        def.otherText = other
        def.updatedAt = .now
        if let machineId = machine?.id { CatalogSyncService(context).reconcileMachine(machineId) }
        try? context.save()
    }

    /// Rename a shared setting. `reconcileMachine` pushes the new label into
    /// every routine and not-yet-locked session using this machine; locked
    /// history keeps the label it was recorded under.
    private func renameDef(_ def: MachineSettingDefinition, to newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        def.label = trimmed
        def.updatedAt = .now
        if let machineId = machine?.id { CatalogSyncService(context).reconcileMachine(machineId) }
        try? context.save()
    }

    /// Soft-delete, never hard-delete: recorded sessions reference this
    /// definition by id, so the row has to stay resolvable (principle #4).
    private func deleteDef(_ def: MachineSettingDefinition) {
        def.deletedAt = .now
        def.updatedAt = .now
        if let machineId = machine?.id { CatalogSyncService(context).reconcileMachine(machineId) }
        try? context.save()
    }

    private func addMachineSetting(label: String, numeric: Int?, other: String?) {
        guard let machine, machine.activeSettings.count < Machine.maxSettings else { return }
        let order = (machine.settingDefinitions.map(\.order).max() ?? -1) + 1
        let def = MachineSettingDefinition(label: label, order: order,
                                           numericValue: numeric, otherText: other,
                                           source: machine.source)
        def.machine = machine
        machine.settingDefinitions.append(def)
        context.insert(def)
        CatalogSyncService(context).reconcileMachine(machine.id)
        try? context.save()
    }
}

