//
//  WorkoutComponents.swift
//  WorkoutTracker
//
//  Reusable pieces for the active-workout flow: TextPromptSheet, BigActionLabel,
//  RestTimerBar (the between-exercises rest on the in-progress screen),
//  MachineSettingEditSheet (edits the machine's shared default) and
//  WorkoutCompletePrompt.
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
        let running = restTimer.isRunning
        let finished = restTimer.isFinished
        // Elapsed fraction (0 at the start of the rest → 1 when it ends). Driven
        // directly by the timer so the olive fill grows from the very beginning.
        let progress = CGFloat(min(max(restTimer.progress, 0), 1))

        VStack(spacing: 12) {
            // Countdown display: a faint container with an olive fill revealed
            // left→right. The type is dark over the container and flips to white
            // where the fill has passed.
            ZStack {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Theme.timerContainer
                        Theme.stripeA.frame(width: geo.size.width * progress, height: geo.size.height)
                    }
                }
                .animation(.linear(duration: 1), value: restTimer.progress)

                display(white: false)
                display(white: true)
                    .mask {
                        GeometryReader { geo in
                            Rectangle()
                                .frame(width: geo.size.width * progress, height: geo.size.height, alignment: .leading)
                        }
                        .animation(.linear(duration: 1), value: restTimer.progress)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 12) {
                if running {
                    timerButton("Pause", "pause.fill") { restTimer.pause() }
                } else if !finished {
                    timerButton("Resume", "play.fill") { restTimer.resume() }
                }
                timerButton("Reset", "arrow.counterclockwise") { restTimer.reset() }
                timerButton("+30s", "goforward.30") { restTimer.override(seconds: restTimer.totalSeconds + 30) }
                timerButton("Done", "xmark") { restTimer.stop() }
            }
        }
        .padding(12)
        // Rounded container so the bar's bottom radius matches its top radius.
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The countdown type. Rendered twice (dark base + white copy masked to the
    /// revealed region) so it reads on both the faint container and the olive fill.
    private func display(white: Bool) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(restTimer.isFinished ? "Rest complete" : "Resting")
                    .font(.caption)
                    .foregroundStyle(white ? Color.white : Theme.secondaryLabel)
                Text(restTimer.formattedRemaining)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(white ? Color.white : Color.primary)
            }
            Spacer()
            if !restTimer.upcomingSummary.isEmpty {
                Text(restTimer.upcomingSummary)
                    .font(.subheadline)
                    .foregroundStyle(white ? Color.white : Theme.secondaryLabel)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding()
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
        .tint(Theme.mutedForeground)
    }
}

// MARK: - Machine setting edit

/// Editing a machine setting always saves to the exercise/machine definition
/// (shared everywhere) — there is no per-workout vs. future choice.
struct MachineSettingEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let setting: SessionMachineSetting
    var machineId: UUID?
    var onSave: (_ label: String, _ numeric: Int?, _ other: String?) -> Void
    /// Called when the user deletes this setting; the sheet closes itself first.
    var onDelete: () -> Void = {}

    @State private var label: String
    @State private var useOther: Bool
    @State private var numeric: Int
    @State private var other: String
    @State private var confirmDelete = false

    init(setting: SessionMachineSetting, machineId: UUID?,
         onSave: @escaping (String, Int?, String?) -> Void,
         onDelete: @escaping () -> Void = {}) {
        self.setting = setting
        self.machineId = machineId
        self.onSave = onSave
        self.onDelete = onDelete
        _label = State(initialValue: setting.label)
        _useOther = State(initialValue: setting.numericValue == nil && (setting.otherText?.isEmpty == false))
        _numeric = State(initialValue: setting.numericValue ?? 0)
        _other = State(initialValue: setting.otherText ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Seat height", text: $label)
                        .submitLabel(.done)
                }
                Section("Value") {
                    Toggle("Use custom value", isOn: $useOther)
                    if useOther {
                        TextField("Custom value", text: $other)
                    } else {
                        Picker("Value", selection: $numeric) {
                            ForEach(MachineSettingDefinition.valueRange, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.wheel)
                    }
                }
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete setting", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Edit Setting")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: label) { _, _ in save() }
            .onChange(of: useOther) { _, _ in save() }
            .onChange(of: numeric) { _, _ in save() }
            .onChange(of: other) { _, _ in save() }
            .confirmationDialog("Delete \"\(setting.label)\"?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete setting", role: .destructive) { dismiss(); onDelete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the setting from this machine everywhere it's used. Finished workouts keep the value they recorded.")
            }
        }
    }

    private func save() {
        // An empty field mid-edit must not wipe the stored name; keep the last
        // good label until the user types a real one.
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        onSave(trimmed.isEmpty ? setting.label : trimmed,
               useOther ? nil : numeric, useOther ? other : nil)
    }
}

/// Shown over the lower third of the workout screen the moment the final
/// exercise is completed: confirm and lock the workout, or go back to it.
///
/// Saving is deliberately the prominent action but NOT the automatic one —
/// finishing locks the session permanently (principle #1), so it stays an
/// explicit choice the user makes, and "Keep going" is always available.
struct WorkoutCompletePrompt: View {
    let exerciseCount: Int
    /// Elapsed time so far, if the session has a start timecode.
    var duration: TimeInterval?
    var onSaveAndExit: () -> Void
    var onKeepGoing: () -> Void

    private var subtitle: String {
        var parts = ["All \(exerciseCount) exercise\(exerciseCount == 1 ? "" : "s") done"]
        if let duration, duration > 0 {
            let minutes = max(1, Int(duration / 60))
            parts.append("\(minutes) min")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.statusGreen)
                Text("Workout complete")
                    .font(.title3.bold())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

            VStack(spacing: 10) {
                Button(action: onSaveAndExit) {
                    SetActionButtonLabel(title: "Save & Exit Workout",
                                         systemImage: "flag.checkered",
                                         tint: Theme.accent)
                }
                .buttonStyle(.plain)

                Button(action: onKeepGoing) {
                    Text("Keep Going")
                        .font(.headline)
                        .foregroundStyle(Theme.mutedForeground)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
            }

            Text("Saving locks this workout as permanent history.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.groupedBackground)
    }
}
