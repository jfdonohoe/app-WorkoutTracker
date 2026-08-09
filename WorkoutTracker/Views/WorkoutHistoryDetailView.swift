//
//  WorkoutHistoryDetailView.swift
//  WorkoutTracker
//
//  Screen 8. Read-only summary of a recorded workout. Correction mode lets the
//  user fix a recorded value WITHOUT overwriting it: corrections are appended as
//  WorkoutCorrectionEvent records and shown layered on top (principle #5).
//

import SwiftUI
import SwiftData

struct WorkoutHistoryDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: WorkoutSession

    /// When shown as the post-workout summary, display a success header and a
    /// Close button instead of acting as a pushed history detail.
    var isSummary: Bool = false
    var onClose: () -> Void = {}

    @State private var correctionMode = false
    @State private var correcting: WorkoutSessionSet?
    @State private var showDeleteConfirm = false

    private var service: CorrectionService { CorrectionService(context) }

    var body: some View {
        List {
            if isSummary { successSection }
            summarySection
            ForEach(session.orderedExercises) { ex in
                exerciseSection(ex)
            }
            if !session.corrections.isEmpty {
                correctionsSection
            }
            // Delete lives at the very bottom, under all the details.
            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete workout", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .confirmationDialog("Delete this workout?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                    Button("Delete workout", role: .destructive) {
                        WorkoutRepository(context).softDeleteSession(session)
                        try? context.save()
                        if isSummary { onClose() } else { dismiss() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes the workout from your calendar and history.")
                }
            }
        }
        .navigationTitle(session.routineName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(correctionMode ? "Done" : "Edit") { correctionMode.toggle() }
            }
            if isSummary {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { onClose() }
                }
            }
        }
        .sheet(item: $correcting) { set in
            CorrectionSheet(session: session, set: set, service: service)
        }
    }

    private var successSection: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(Theme.statusGreen)
                Text("Workout complete!").font(.title2.bold())
                Text(successMessage).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var successMessage: String {
        let sets = session.orderedExercises.flatMap(\.sets).filter(\.isCompleted).count
        var parts = ["Nice work — \(sets) set\(sets == 1 ? "" : "s") logged"]
        if let d = session.duration { parts.append("in \(Int(d / 60)) min") }
        return parts.joined(separator: " ") + "."
    }

    private var summarySection: some View {
        Section {
            row("Date", (session.completedAt ?? session.startedAt ?? .now).formatted(date: .abbreviated, time: .shortened))
            if let started = session.startedAt {
                row("Started", started.formatted(date: .omitted, time: .shortened))
            }
            if let ended = session.endedAt {
                row("Ended", ended.formatted(date: .omitted, time: .shortened))
            }
            row("Status", session.status.displayName)
            let exs = session.orderedExercises
            row("Completed", "\(exs.filter(\.isFullyCompleted).count)")
            row("Partial", "\(exs.filter(\.isPartiallyIncomplete).count)")
            row("Skipped", "\(exs.filter(\.isSkipped).count)")
            let sets = exs.flatMap(\.sets)
            row("Sets completed", "\(sets.filter(\.isCompleted).count) / \(sets.count)")
            if session.source == .seedDemo {
                Label("Demo data", systemImage: "testtube.2").font(.caption).foregroundStyle(Theme.statusOrange)
            }
            if session.isLocked {
                Label("Locked history — immutable", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("Summary") }
    }

    private func exerciseSection(_ ex: WorkoutSessionExercise) -> some View {
        Section {
            if let started = ex.startedAt {
                row("Started", started.formatted(date: .omitted, time: .shortened))
            }
            if let ended = ex.endedAt {
                row("Ended", ended.formatted(date: .omitted, time: .shortened))
            }
            if !ex.machineSettings.isEmpty {
                ForEach(ex.machineSettings.sorted { $0.order < $1.order }) { s in
                    row(s.label, s.displayValue)
                }
            }
            // Show the prescription that matches the exercise's group.
            switch ex.sectionType {
            case .strength:
                ForEach(ex.orderedSets) { set in
                    setRow(ex, set)
                }
            case .cardio:
                row("Duration", "\(ex.durationMinutes) min")
                if let i = ex.intensity { row("Intensity", i.displayName) }
            case .stretching:
                row("Hold", "\(ex.holdSeconds)s")
                row("Sides", "\(ex.sides)")
                row("Rounds", "\(ex.rounds)")
            }
            if !ex.notes.isEmpty { row("Notes", ex.notes) }
        } header: {
            HStack {
                Text(ex.name)
                Spacer()
                if ex.isSkipped { Text("Skipped").foregroundStyle(Theme.statusRed) }
                else if ex.isPartiallyIncomplete { Text("Partial").foregroundStyle(Theme.statusOrange) }
                else if ex.isFullyCompleted { Text("Done").foregroundStyle(Theme.statusGreen) }
            }
        }
    }

    private func setRow(_ ex: WorkoutSessionExercise, _ set: WorkoutSessionSet) -> some View {
        let effW = CorrectedView.effectiveActualWeight(set, in: session)
        let effR = CorrectedView.effectiveActualReps(set, in: session)
        let wCorrected = CorrectedView.isCorrected(set, field: "actualWeight", in: session)
        let rCorrected = CorrectedView.isCorrected(set, field: "actualReps", in: session)
        return Button {
            if correctionMode && set.isCompleted { correcting = set }
        } label: {
            HStack {
                Image(systemName: set.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(set.isCompleted ? Theme.statusGreen : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set \(set.index + 1)")
                    Text("Planned \(Int(set.plannedWeight)) lb × \(set.plannedReps)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if set.isCompleted {
                        Text("\(Int(effW ?? 0)) lb × \(effR ?? 0)")
                            .foregroundStyle(wCorrected || rCorrected ? Theme.statusBlue : .primary)
                        if let delta = Self.deltaText(actualWeight: effW, actualReps: effR,
                                                      plannedWeight: set.plannedWeight, plannedReps: set.plannedReps) {
                            Text(delta).font(.caption2).foregroundStyle(Theme.statusOrange)
                        }
                        if let e = set.perceivedEffort {
                            Text(e.displayName).font(.caption2).foregroundStyle(.secondary)
                        }
                        if wCorrected || rCorrected {
                            Text("corrected").font(.caption2).foregroundStyle(Theme.statusBlue)
                        }
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                if correctionMode && set.isCompleted {
                    Image(systemName: "pencil.circle").foregroundStyle(Theme.statusBlue)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var correctionsSection: some View {
        Section("Corrections") {
            ForEach(session.corrections.sorted { $0.createdAt < $1.createdAt }) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(c.field): \(c.previousValue.isEmpty ? "—" : c.previousValue) → \(c.correctedValue)")
                    HStack {
                        Text(c.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if let note = c.note, !note.isEmpty { Text("· \(note)") }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary) }
    }

    /// Signed weight/reps difference from what was planned, e.g. "+10 lb, -2 reps".
    /// `nil` when the set matches the plan exactly (nothing to call out).
    static func deltaText(actualWeight: Double?, actualReps: Int?,
                          plannedWeight: Double, plannedReps: Int) -> String? {
        var parts: [String] = []
        if let w = actualWeight {
            let d = Int(w - plannedWeight)
            if d != 0 { parts.append("\(d > 0 ? "+" : "")\(d) lb") }
        }
        if let r = actualReps {
            let d = r - plannedReps
            if d != 0 { parts.append("\(d > 0 ? "+" : "")\(d) reps") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Sheet to enter a correction for a recorded set.
struct CorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: WorkoutSession
    let set: WorkoutSessionSet
    let service: CorrectionService

    @State private var weight: Double
    @State private var reps: Int
    @State private var note = ""

    init(session: WorkoutSession, set: WorkoutSessionSet, service: CorrectionService) {
        self.session = session
        self.set = set
        self.service = service
        _weight = State(initialValue: CorrectedView.effectiveActualWeight(set, in: session) ?? set.plannedWeight)
        _reps = State(initialValue: CorrectedView.effectiveActualReps(set, in: session) ?? set.plannedReps)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Weight: \(Int(weight)) lb", value: $weight, in: 0...2000, step: 5)
                    Stepper("Reps: \(reps)", value: $reps, in: 0...100)
                    TextField("Reason (optional)", text: $note)
                } footer: {
                    Text("Original values are preserved. This adds an append-only correction event.")
                }
            }
            .navigationTitle("Correct Set \(set.index + 1)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { apply() }
                }
            }
        }
    }

    private func apply() {
        let n = note.isEmpty ? nil : note
        if weight != (CorrectedView.effectiveActualWeight(set, in: session) ?? set.plannedWeight) {
            service.correctActualWeight(set, in: session, to: weight, note: n)
        }
        if reps != (CorrectedView.effectiveActualReps(set, in: session) ?? set.plannedReps) {
            service.correctActualReps(set, in: session, to: reps, note: n)
        }
        dismiss()
    }
}
