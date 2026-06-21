//
//  RoutineEditorView.swift
//  WorkoutTracker
//
//  Screen 5. Edits a routine's active version.
//
//  VERSION SAFETY: the moment the user makes their first edit, ensureEditable-
//  Version() decides whether to edit the active version in place (if not yet
//  referenced by any recorded session) or fork a NEW RoutineVersion (so past
//  sessions keep pointing at the old version).
//
//  When `isCreating` is true the editor is the new-routine flow: it shows
//  Cancel (discards the routine) and Save (keeps it) instead of plain back, and
//  Save is disabled until the routine has a name.
//

import SwiftUI
import SwiftData

struct RoutineEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var routine: Routine

    /// New-routine creation mode (Cancel/Save semantics).
    var isCreating: Bool = false
    /// Optional callback invoked after Save (used by the calendar instance-edit
    /// flow to ask "this instance vs. all future").
    var onCommit: (() -> Void)? = nil

    @State private var workingVersionId: UUID?
    @State private var didFork = false
    @State private var addExerciseSection: RoutineSection?
    @State private var editExercise: RoutineExercise?
    @State private var showDeleteConfirm = false
    // Schedule (one ScheduleRule per routine, drives Today/Calendar).
    @State private var scheduleEnabled = false
    @State private var recurrence = RecurrenceState()
    @State private var didLoadSchedule = false

    private var repo: RoutineRepository { RoutineRepository(context) }

    private var displayVersion: RoutineVersion? {
        if let id = workingVersionId { return routine.versions.first { $0.id == id } }
        return routine.activeVersion
    }

    private var nameIsEmpty: Bool {
        routine.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        List {
            Section("Routine name") {
                TextField("Name (e.g. YMCA Full Body A)", text: $routine.name)
            }

            if didFork {
                Section {
                    Label("Saving created a new version (v\(displayVersion?.versionNumber ?? 0)). Past workouts are unchanged.",
                          systemImage: "checkmark.shield")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else if isActiveReferenced {
                Section {
                    Label("This routine has recorded workouts. Editing will create a new version; history stays intact.",
                          systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            scheduleSection

            if let version = displayVersion {
                restSection(version)
                ForEach(version.orderedSections) { section in
                    sectionView(section)
                }
                .onDelete { offsets in removeSections(version, offsets) }
            }

            if !isCreating {
                Section {
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Label("Delete routine", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .onAppear(perform: loadSchedule)
        .onChange(of: scheduleEnabled) { _, _ in scheduleChanged() }
        .onChange(of: recurrence) { _, _ in scheduleChanged() }
        .confirmationDialog("Delete this routine?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete routine", role: .destructive) {
                repo.softDelete(routine)
                try? context.save()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will be removed from your routines. Past workouts are unaffected.")
        }
        .navigationTitle(isCreating ? "New Routine" : routine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isCreating {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { cancelCreation() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { finishCreation() }.disabled(nameIsEmpty)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(SectionType.allCases) { type in
                        Button(type.displayName) { addSection(type) }
                    }
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $addExerciseSection) { section in
            // Only exercises matching this grouping's type can be added.
            ExercisePickerSheet(group: section.type) { exercise in
                addExercise(exercise, to: section)
            }
        }
        .sheet(item: $editExercise) { ex in
            SetBuilderSheet(title: ex.displayName,
                            machineId: ex.machineId,
                            exerciseId: ex.exerciseId,
                            defaultRest: displayVersion?.defaultRestBetweenSets ?? 60,
                            initialSets: ex.effectivePlannedSets,
                            initialRest: ex.restBetweenSets) { sets, rest in
                saveSets(to: ex, sets: sets, rest: rest)
            }
        }
    }

    // MARK: - Schedule

    @ViewBuilder
    private var scheduleSection: some View {
        Section {
            Toggle("Repeat on a schedule", isOn: $scheduleEnabled)
            if scheduleEnabled {
                DatePicker("Starts", selection: $recurrence.startDate, displayedComponents: .date)
                RecurrenceEditor(state: $recurrence)
                Text(recurrence.summaryText).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Schedule")
        } footer: {
            Text(scheduleEnabled
                 ? "This routine will appear on Today and the Calendar on the matching days."
                 : "Turn on to repeat this routine automatically on Today and the Calendar.")
        }
    }

    /// Load the routine's existing schedule (if any) into the editor on appear.
    private func loadSchedule() {
        guard !didLoadSchedule else { return }
        defer { didLoadSchedule = true }
        let rid = routine.id
        let rules = (try? context.fetch(
            FetchDescriptor<ScheduleRule>(predicate: #Predicate { $0.routineId == rid && $0.deletedAt == nil })
        )) ?? []
        if let rule = rules.first {
            scheduleEnabled = true
            recurrence = RecurrenceState(rule: rule)
        } else {
            var seed = RecurrenceState()
            seed.weekdays = [Calendar.current.component(.weekday, from: Date())]
            seed.untilDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
            recurrence = seed
            scheduleEnabled = false
        }
    }

    private func scheduleChanged() {
        guard didLoadSchedule else { return } // ignore the initial load
        // During creation the routine may still be cancelled (discarded), so we
        // defer persistence to finishCreation(); persist live only when editing.
        guard !isCreating else { return }
        applySchedule()
    }

    /// Reconcile the routine's single ScheduleRule with the editor state.
    private func applySchedule() {
        let rid = routine.id
        let rules = (try? context.fetch(
            FetchDescriptor<ScheduleRule>(predicate: #Predicate { $0.routineId == rid && $0.deletedAt == nil })
        )) ?? []
        if scheduleEnabled {
            if let rule = rules.first {
                recurrence.apply(to: rule)
                for extra in rules.dropFirst() { extra.deletedAt = .now } // keep one
            } else {
                context.insert(recurrence.buildRule(routineId: rid))
            }
        } else {
            for rule in rules { rule.deletedAt = .now } // unschedule
        }
        try? context.save()
    }

    // MARK: - Sections

    private func restSection(_ version: RoutineVersion) -> some View {
        Section("Cooldowns (routine-level)") {
            Stepper("Between exercises: \(version.defaultRestBetweenExercises)s",
                    value: Binding(
                        get: { version.defaultRestBetweenExercises },
                        set: { newValue in
                            ensureEditableVersion()
                            displayVersion?.defaultRestBetweenExercises = newValue
                            save()
                        }),
                    in: 0...600, step: 15)
            Stepper("Between sets: \(version.defaultRestBetweenSets)s",
                    value: Binding(
                        get: { version.defaultRestBetweenSets },
                        set: { newValue in
                            ensureEditableVersion()
                            displayVersion?.defaultRestBetweenSets = newValue
                            save()
                        }),
                    in: 0...600, step: 15)
        }
    }

    private func sectionView(_ section: RoutineSection) -> some View {
        // Other groupings of the SAME type, available as move targets.
        let moveTargets = (displayVersion?.orderedSections ?? [])
            .filter { $0.type == section.type && $0.id != section.id }

        return Section {
            if section.type.isTimeBased {
                HStack {
                    Text("Duration")
                    Spacer()
                    Stepper("\(section.durationMinutes ?? 0) min",
                            value: Binding(
                                get: { section.durationMinutes ?? 0 },
                                set: { newValue in
                                    ensureEditableVersion()
                                    currentSection(section)?.durationMinutes = newValue
                                    save()
                                }),
                            in: 0...120, step: 5)
                }
            }

            ForEach(section.orderedExercises) { ex in
                HStack {
                    Button { editExercise = ex } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ex.displayName).font(.body).foregroundStyle(.primary)
                            Text("\(ex.effectivePlannedSets.count)×\(ex.plannedReps) @ \(Int(ex.plannedWeight)) lb")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                    Spacer()
                    if !moveTargets.isEmpty {
                        Menu {
                            ForEach(moveTargets) { target in
                                Button {
                                    moveExercise(ex, to: target)
                                } label: { Label("Move to \(target.title)", systemImage: "arrow.right") }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onMove { offsets, dest in reorderExercises(section, offsets, dest) } // reorder within grouping
            .onDelete { removeExercises(section, $0) }

            // Exercises can be added to ANY grouping (cardio, stretching, etc.).
            Button { addExerciseSection = section } label: {
                Label("Add exercise", systemImage: "plus.circle")
            }
        } header: {
            HStack {
                Text(section.title)
                Spacer()
                // SwiftUI lists can't drag whole sections, so groupings are
                // reordered with explicit up/down controls.
                Menu {
                    Button { moveSection(section, by: -1) } label: { Label("Move grouping up", systemImage: "arrow.up") }
                    Button { moveSection(section, by: 1) } label: { Label("Move grouping down", systemImage: "arrow.down") }
                    Button(role: .destructive) { deleteSection(section) } label: { Label("Delete grouping", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Versioning guard

    private var isActiveReferenced: Bool {
        guard let active = routine.activeVersion else { return false }
        return repo.isReferencedBySession(active)
    }

    private func ensureEditableVersion() {
        guard workingVersionId == nil else { return }
        guard let active = routine.activeVersion else { return }
        if repo.isReferencedBySession(active) {
            let newVersion = repo.makeNewVersion(of: routine)
            workingVersionId = newVersion.id
            didFork = true
        } else {
            workingVersionId = active.id
        }
    }

    private func currentSection(_ section: RoutineSection) -> RoutineSection? {
        guard let version = displayVersion else { return nil }
        if version.sections.contains(where: { $0.id == section.id }) { return section }
        return version.sections.first { $0.order == section.order && $0.typeRaw == section.typeRaw }
    }

    // MARK: - Mutations

    private func addSection(_ type: SectionType) {
        ensureEditableVersion()
        guard let version = displayVersion else { return }
        repo.addSection(to: version, type: type,
                        durationMinutes: type.isTimeBased ? 20 : nil)
        save()
    }

    /// Reorder a whole grouping up (-1) or down (+1) among the sections.
    private func moveSection(_ section: RoutineSection, by delta: Int) {
        ensureEditableVersion()
        guard let version = displayVersion, let sec = currentSection(section) else { return }
        var ordered = version.orderedSections
        guard let idx = ordered.firstIndex(where: { $0.id == sec.id }) else { return }
        let target = idx + delta
        guard target >= 0, target < ordered.count else { return }
        ordered.swapAt(idx, target)
        for (i, s) in ordered.enumerated() { s.order = i }
        save()
    }

    private func deleteSection(_ section: RoutineSection) {
        ensureEditableVersion()
        guard let sec = currentSection(section) else { return }
        context.delete(sec)
        save()
    }

    private func removeSections(_ version: RoutineVersion, _ offsets: IndexSet) {
        ensureEditableVersion()
        guard let v = displayVersion else { return }
        let ordered = v.orderedSections
        for i in offsets where i < ordered.count {
            if let target = currentSection(ordered[i]) { context.delete(target) }
        }
        save()
    }

    private func removeExercises(_ section: RoutineSection, _ offsets: IndexSet) {
        ensureEditableVersion()
        guard let sec = currentSection(section) else { return }
        let ordered = sec.orderedExercises
        for i in offsets where i < ordered.count { context.delete(ordered[i]) }
        save()
    }

    private func reorderExercises(_ section: RoutineSection, _ offsets: IndexSet, _ dest: Int) {
        ensureEditableVersion()
        guard let sec = currentSection(section) else { return }
        var ordered = sec.orderedExercises
        ordered.move(fromOffsets: offsets, toOffset: dest)
        for (i, e) in ordered.enumerated() { e.order = i }
        save()
    }

    /// Move an exercise into another grouping of the same type.
    private func moveExercise(_ ex: RoutineExercise, to targetSection: RoutineSection) {
        ensureEditableVersion()
        guard let movingEx = resolveExercise(ex), let target = currentSection(targetSection) else { return }
        movingEx.section = target
        movingEx.order = (target.exercises.map(\.order).max() ?? -1) + 1
        save()
    }

    private func addExercise(_ exercise: Exercise, to section: RoutineSection) {
        // Don't allow an exercise from a different group into this grouping.
        guard exercise.defaultSectionType == section.type else { return }
        ensureEditableVersion()
        guard let sec = currentSection(section) else { return }
        let defaults = exercise.effectiveDefaultSets
        let seedSets = defaults.isEmpty ? [(reps: 10, weight: 0.0)] : defaults
        let routineRest = displayVersion?.defaultRestBetweenSets ?? 60
        repo.addExercise(to: sec, exercise: exercise,
                         plannedSets: seedSets, restBetweenSets: routineRest)
        save()
    }

    private func saveSets(to exercise: RoutineExercise, sets: [(reps: Int, weight: Double)], rest: Int) {
        ensureEditableVersion()
        guard let target = resolveExercise(exercise) else { return }
        let routineRest = displayVersion?.defaultRestBetweenSets ?? rest
        repo.setPlannedSets(target, sets: sets, restBetweenSets: routineRest)
        save()
    }

    private func resolveExercise(_ ex: RoutineExercise) -> RoutineExercise? {
        guard let version = displayVersion else { return nil }
        let all = version.sections.flatMap(\.exercises)
        if let direct = all.first(where: { $0.id == ex.id }) { return direct }
        return all.first { $0.exerciseId == ex.exerciseId && $0.order == ex.order }
    }

    private func save() {
        routine.updatedAt = .now
        try? context.save()
    }

    // MARK: - Create flow

    private func cancelCreation() {
        // Discard the freshly created routine entirely.
        context.delete(routine)
        try? context.save()
        dismiss()
    }

    private func finishCreation() {
        routine.name = routine.name.trimmingCharacters(in: .whitespaces)
        save()
        applySchedule() // persist the schedule now that the routine is kept
        onCommit?()
        dismiss()
    }
}
