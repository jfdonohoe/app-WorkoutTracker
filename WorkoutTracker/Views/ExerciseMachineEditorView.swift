//
//  ExerciseMachineEditorView.swift
//  WorkoutTracker
//
//  Screen 6. Create/edit an exercise and (for machine-based strength work) its
//  machine with up to 4 labeled settings.
//
//  Machine-setting UX per spec:
//   • Start with one setting field; when it has a label, reveal the next empty
//     field, up to 4.
//   • Empty fields are not shown when viewing the exercise later (the model only
//     stores defined settings).
//   • Each setting has a user label and a value picker 1...15, then "Other"
//     which reveals a free-text field.
//

import SwiftUI
import SwiftData

struct ExerciseMachineEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// Optional existing exercise to edit. Nil = creating a new one.
    var existing: Exercise?

    @State private var name = ""
    @State private var notes = ""
    @State private var isMachine = true
    @State private var machineName = ""
    @State private var settings: [SettingDraft] = [SettingDraft()]

    init(existing: Exercise? = nil) {
        self.existing = existing
    }

    struct SettingDraft: Identifiable {
        let id = UUID()
        var label = ""
        var useOther = false
        var numeric = 1
        var other = ""
        var isEmpty: Bool { label.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        Form {
            Section("Exercise") {
                TextField("Name (e.g. Leg Press)", text: $name)
                TextField("Notes", text: $notes, axis: .vertical)
            }

            Section {
                Toggle("Machine-based", isOn: $isMachine)
                if isMachine {
                    TextField("Machine name", text: $machineName)
                }
            } header: {
                Text("Machine")
            } footer: {
                if isMachine {
                    Text("Machine settings are shared across every routine that uses this machine, and are snapshotted into each workout.")
                }
            }

            if isMachine {
                machineSettingsSection
            }
        }
        .navigationTitle(existing == nil ? "New Exercise" : "Edit Exercise")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear(perform: loadExisting)
    }

    private var machineSettingsSection: some View {
        Section("Settings (up to 4)") {
            ForEach(Array(settings.enumerated()), id: \.element.id) { index, _ in
                if shouldShow(index) {
                    settingRow(index)
                }
            }
        }
    }

    /// Reveal a row if it's the first row, or the previous row has a label.
    private func shouldShow(_ index: Int) -> Bool {
        if index == 0 { return true }
        guard index <= 3 else { return false }
        return !settings[index - 1].isEmpty
    }

    @ViewBuilder
    private func settingRow(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Setting label (e.g. Seat height)", text: Binding(
                get: { settings[index].label },
                set: { newValue in
                    settings[index].label = newValue
                    ensureTrailingField()
                }))
            .font(.headline)

            if !settings[index].isEmpty {
                Toggle("Custom value", isOn: $settings[index].useOther)
                if settings[index].useOther {
                    TextField("Custom value", text: $settings[index].other)
                } else {
                    Picker("Value", selection: $settings[index].numeric) {
                        ForEach(1...15, id: \.self) { Text("\($0)").tag($0) }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Keep exactly one trailing empty field available (until 4 are defined).
    private func ensureTrailingField() {
        let defined = settings.filter { !$0.isEmpty }.count
        // Drop extra empties.
        settings.removeAll { $0.isEmpty }
        // Re-add up to one trailing empty if under the cap.
        if defined < 4 {
            settings.append(SettingDraft())
        }
        if settings.isEmpty { settings = [SettingDraft()] }
    }

    private func loadExisting() {
        guard let existing else { return }
        name = existing.name
        notes = existing.notes
        if let mid = existing.machineId,
           let machine = try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == mid })).first {
            isMachine = true
            machineName = machine.name
            settings = machine.activeSettings.map {
                var d = SettingDraft()
                d.label = $0.label
                if let n = $0.numericValue { d.numeric = n } else { d.useOther = true; d.other = $0.otherText ?? "" }
                return d
            }
            settings.append(SettingDraft())
        } else {
            isMachine = false
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        var machineId: UUID?
        if isMachine {
            let machine = Machine(name: machineName.isEmpty ? trimmedName : machineName, source: .user)
            context.insert(machine)
            var order = 0
            for s in settings where !s.isEmpty {
                let def = MachineSettingDefinition(
                    label: s.label.trimmingCharacters(in: .whitespaces),
                    order: order,
                    numericValue: s.useOther ? nil : s.numeric,
                    otherText: s.useOther ? s.other : nil,
                    source: .user)
                def.machine = machine
                machine.settingDefinitions.append(def)
                context.insert(def)
                order += 1
            }
            machineId = machine.id
        }

        if let existing {
            existing.name = trimmedName
            existing.notes = notes
            if let machineId { existing.machineId = machineId }
            existing.updatedAt = .now
        } else {
            let exercise = Exercise(name: trimmedName, machineId: machineId, notes: notes, source: .user)
            context.insert(exercise)
        }
        try? context.save()
        dismiss()
    }
}
