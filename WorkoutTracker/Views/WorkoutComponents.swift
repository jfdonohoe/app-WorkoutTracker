//
//  WorkoutComponents.swift
//  WorkoutTracker
//
//  Reusable pieces for the active-workout flow: the rest-timer bar (Screen 3),
//  the add-unplanned-exercise sheet, and the machine-setting edit sheet with the
//  "this workout only / future default" choice.
//

import SwiftUI

// MARK: - Text prompt sheet

/// A tiny single-field entry sheet. Used instead of an alert-with-textfield,
/// which triggers a noisy (harmless) UIKit autolayout warning.
struct TextPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var placeholder: String = ""
    var saveLabel: String = "Save"
    var onSave: (String) -> Void

    @State private var text: String

    init(title: String, placeholder: String = "", initial: String = "",
         saveLabel: String = "Save", onSave: @escaping (String) -> Void) {
        self.title = title
        self.placeholder = placeholder
        self.saveLabel = saveLabel
        self.onSave = onSave
        _text = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(placeholder, text: $text)
                    .submitLabel(.done)
                    .onSubmit { commit() }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveLabel) { commit() }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.height(160)])
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}

// MARK: - Standard primary-action label

/// A full-width button label whose TEXT is truly centered, with an optional icon
/// pinned to the leading edge. The icon inherits the label's foreground color
/// (e.g. white on a prominent/green button — never the button's fill color), and
/// every primary action uses the same font (`.headline`) for consistency.
struct BigActionLabel: View {
    let title: String
    var systemImage: String? = nil
    var minHeight: CGFloat = 50

    var body: some View {
        ZStack {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
            if let systemImage {
                HStack {
                    Image(systemName: systemImage).font(.headline)
                    Spacer()
                }
                .padding(.leading, 6)
            }
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
    }
}

// MARK: - Rest Timer (Screen 3)

struct RestTimerBar: View {
    @EnvironmentObject private var restTimer: RestTimerService
    @State private var showOverride = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(restTimer.isFinished ? "Rest complete" : "Resting")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(restTimer.formattedRemaining)
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(restTimer.isFinished ? .green : .primary)
                }
                Spacer()
                if !restTimer.upcomingSummary.isEmpty {
                    Text(restTimer.upcomingSummary)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            ProgressView(value: min(max(restTimer.progress, 0), 1))

            HStack(spacing: 12) {
                if restTimer.isRunning {
                    timerButton("Pause", "pause.fill") { restTimer.pause() }
                } else if !restTimer.isFinished {
                    timerButton("Resume", "play.fill") { restTimer.resume() }
                }
                timerButton("Reset", "arrow.counterclockwise") { restTimer.reset() }
                timerButton("+30s", "goforward.30") { restTimer.override(seconds: restTimer.totalSeconds + 30) }
                timerButton("Done", "xmark") { restTimer.stop() }
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func timerButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Add unplanned exercise (name + set-by-set)

struct AddUnplannedExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss
    var defaultRest: Int = 90
    var onAdd: (_ name: String, _ sets: [(reps: Int, weight: Double)], _ rest: Int) -> Void

    struct Row: Identifiable { let id = UUID(); var reps: Int; var weight: Double }

    @State private var name = ""
    @State private var rows: [Row] = [Row(reps: 10, weight: 0)]
    @State private var rest = 90
    @State private var didInit = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Exercise") {
                    TextField("Name", text: $name)
                }
                Section("Sets") {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, _ in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Set \(i + 1)").font(.caption).foregroundStyle(.secondary)
                            Stepper("Weight: \(Int(rows[i].weight)) lb", value: $rows[i].weight, in: 0...2000, step: 5)
                            Stepper("Reps: \(rows[i].reps)", value: $rows[i].reps, in: 1...100)
                        }
                    }
                    .onDelete { rows.remove(atOffsets: $0); if rows.isEmpty { rows = [Row(reps: 10, weight: 0)] } }
                    Button {
                        let last = rows.last ?? Row(reps: 10, weight: 0)
                        rows.append(Row(reps: last.reps, weight: last.weight))
                    } label: { Label("Add set (copies last)", systemImage: "plus.circle") }
                }
                Section("Cooldown between sets") {
                    Stepper("\(rest)s", value: $rest, in: 0...600, step: 15)
                }
            }
            .navigationTitle("Add Exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(name, rows.map { ($0.reps, $0.weight) }, rest)
                        dismiss()
                    }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { if !didInit { rest = defaultRest; didInit = true } }
        }
    }
}

// MARK: - Machine setting edit

/// Editing a machine setting always saves to the exercise/machine definition
/// (shared everywhere) — there is no per-workout vs. future choice.
struct MachineSettingEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let setting: SessionMachineSetting
    var machineId: UUID?
    var onSave: (_ numeric: Int?, _ other: String?) -> Void

    @State private var useOther: Bool
    @State private var numeric: Int
    @State private var other: String

    init(setting: SessionMachineSetting, machineId: UUID?,
         onSave: @escaping (Int?, String?) -> Void) {
        self.setting = setting
        self.machineId = machineId
        self.onSave = onSave
        _useOther = State(initialValue: setting.numericValue == nil && (setting.otherText?.isEmpty == false))
        _numeric = State(initialValue: setting.numericValue ?? 1)
        _other = State(initialValue: setting.otherText ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(setting.label) {
                    Toggle("Use custom value", isOn: $useOther)
                    if useOther {
                        TextField("Custom value", text: $other)
                    } else {
                        Picker("Value", selection: $numeric) {
                            ForEach(1...15, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.wheel)
                    }
                }
            }
            .navigationTitle("Edit Setting")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(useOther ? nil : numeric, useOther ? other : nil)
                        dismiss()
                    }
                }
            }
        }
    }
}
