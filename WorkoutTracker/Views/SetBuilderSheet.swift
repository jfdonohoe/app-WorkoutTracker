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
//  unplanned exercise mid-workout. It returns the built sets + rest via onSave;
//  machine-setting edits are written straight to the shared Machine.
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
    var onSave: (_ sets: [(reps: Int, weight: Double)], _ rest: Int) -> Void

    struct SetDraft: Identifiable { let id = UUID(); var reps: Int; var weight: Double }

    @State private var sets: [SetDraft] = []
    @State private var rest: Int = 90
    @State private var machine: Machine?
    @State private var exercise: Exercise?
    @State private var showAddSetting = false
    @State private var otherEditDef: MachineSettingDefinition?
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            List {
                definitionSection
                setsSection
                if machine != nil { machineSection }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(sets.map { ($0.reps, $0.weight) }, rest)
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
        if let exercise, exercise.photoData != nil || !exercise.notes.isEmpty {
            Section {
                if let data = exercise.photoData {
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

    // MARK: - Sets

    private var setsSection: some View {
        Section {
            ForEach(Array(sets.enumerated()), id: \.element.id) { index, _ in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Set \(index + 1)").font(.subheadline.bold())
                    stepper("Weight (lb)", value: $sets[index].weight, step: 5, range: 0...2000)
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
                    Text(def.label)
                    Spacer()
                    Menu {
                        ForEach(1...15, id: \.self) { n in
                            Button("\(n)") { setDefValue(def, numeric: n, other: nil) }
                        }
                        Button("Other…") { otherEditDef = def }
                    } label: {
                        Text(def.displayValue).bold()
                    }
                }
            }
            if (machine?.activeSettings.count ?? 0) < 4 {
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
        if let machineId {
            machine = try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == machineId })).first
        }
        if let exerciseId {
            exercise = try? context.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exerciseId })).first
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
        try? context.save()
    }

    private func addMachineSetting(label: String, numeric: Int?, other: String?) {
        guard let machine, machine.activeSettings.count < 4 else { return }
        let order = (machine.settingDefinitions.map(\.order).max() ?? -1) + 1
        let def = MachineSettingDefinition(label: label, order: order,
                                           numericValue: numeric, otherText: other,
                                           source: machine.source)
        def.machine = machine
        machine.settingDefinitions.append(def)
        context.insert(def)
        try? context.save()
    }
}

