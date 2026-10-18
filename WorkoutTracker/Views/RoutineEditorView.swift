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
    /// When set (Calendar edit flow), show a Schedule section that edits this
    /// routine's recurrence live. Nil elsewhere — routine definition has no schedule.
    var scheduleRoutineId: UUID? = nil

    @State private var workingVersionId: UUID?
    @State private var didFork = false
    @State private var addExerciseSection: RoutineSection?
    /// The library exercise being edited from a routine row. A routine only
    /// lists which exercises, in what order; sets, reps, weight, machines and
    /// settings all belong to the exercise.
    @State private var editDefinition: Exercise?
    @State private var showDeleteConfirm = false
    // Schedule (Calendar edit only).
    @State private var scheduleEnabled = false
    @State private var recurrence = RecurrenceState()
    @State private var didLoadSchedule = false
    /// The schedule as loaded. Until the user changes it, nothing is written,
    /// so merely opening the editor can't rewrite or remove any rule.
    @State private var loadedSchedule: (enabled: Bool, recurrence: RecurrenceState)?

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
                TextField("Name (e.g. Gym Full Body A)", text: $routine.name)
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

            if scheduleRoutineId != nil { scheduleSection }

            if let version = displayVersion {
                ForEach(version.orderedSections) { section in
                    sectionView(section)
                }
                .onDelete { offsets in removeSections(version, offsets) }
                // Rests per exercise type, after the exercises; Delete stays last.
                restSection(version)
            }

            if !isCreating {
                Section {
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Label("Delete routine", systemImage: "trash").frame(maxWidth: .infinity)
                    }
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
                }
            }
        }
        .onAppear {
            loadSchedule()
            syncWithLibrary()
        }
        .onChange(of: scheduleEnabled) { _, _ in scheduleChanged() }
        .onChange(of: recurrence) { _, _ in scheduleChanged() }
        .navigationTitle(isCreating ? "New Routine" : routine.name)
        // A new routine (or calendar clone) is saved before this opens; only
        // Cancel discards it, so a swipe-down mustn't leave it behind.
        .interactiveDismissDisabled(isCreating)
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
            // Only exercises matching this grouping's type — and the
            // routine's demo/user source — can be added.
            ExercisePickerSheet(group: section.type, source: section.version?.source ?? .user) { exercise in
                addExercise(exercise, to: section)
            }
        }
        .sheet(item: $editDefinition, onDismiss: {
            syncWithLibrary()
        }) { exercise in
            NavigationStack { ExerciseEditorView(existing: exercise) }
        }
    }

    // MARK: - Sections

    private func restSection(_ version: RoutineVersion) -> some View {
        // Rest is set per routine (never per exercise), per exercise type. It
        // can also be changed on the workout screen, which updates this.
        RestSettingsSections(rests: Binding(
            get: { version.rests },
            set: { newValue in
                ensureEditableVersion()
                displayVersion?.rests = newValue
                save()
            }))
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
                    // Tap to edit the exercise itself; changes apply to every
                    // routine that uses it.
                    Button { editDefinition = definition(ex.exerciseId) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ex.displayName).font(.body).foregroundStyle(.primary)
                            Text(definition(ex.exerciseId)?.summary ?? section.type.displayName)
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

    /// The library exercise behind a routine exercise (for its group-specific
    /// characteristics — cardio/stretching don't store those on RoutineExercise).
    private func definition(_ exId: UUID) -> Exercise? {
        (try? context.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exId })))?.first
    }

    // MARK: - Schedule (Calendar edit only; edits live on scheduleRoutineId)

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
                 ? "This routine will appear on the Workout tab and the Calendar on the matching days."
                 : "Turn on to repeat this routine automatically.")
        }
    }

    private func loadSchedule() {
        guard let rid = scheduleRoutineId, !didLoadSchedule else { return }
        defer { didLoadSchedule = true }
        let rules = (try? context.fetch(
            FetchDescriptor<ScheduleRule>(predicate: #Predicate { $0.routineId == rid && $0.deletedAt == nil },
                                          sortBy: [SortDescriptor(\.createdAt)])
        )) ?? []
        if let rule = rules.first(where: { $0.isRecurring }) {
            // Already on a recurring schedule → toggle on, show its recurrence.
            scheduleEnabled = true
            recurrence = RecurrenceState(rule: rule)
        } else {
            // No schedule, or only a one-off occurrence → toggle OFF by default.
            let base = rules.first?.startDate ?? Date()
            var seed = RecurrenceState()
            seed.startDate = base
            seed.weekdays = [Calendar.current.component(.weekday, from: base)]
            seed.untilDate = Calendar.current.date(byAdding: .month, value: 1, to: base) ?? base
            recurrence = seed
            scheduleEnabled = false
        }
        loadedSchedule = (scheduleEnabled, recurrence)
    }

    private func scheduleChanged() {
        guard scheduleRoutineId != nil, didLoadSchedule else { return }
        if let loaded = loadedSchedule, loaded.enabled == scheduleEnabled, loaded.recurrence == recurrence { return }
        loadedSchedule = nil   // edited: from here on, every change is applied
        applySchedule()
    }

    /// Reconcile the routine's RECURRING schedule with the editor state (live).
    /// The editor shows and edits the first recurring rule. Other recurring
    /// rules (another weekday pattern, a sheet-imported schedule) and one-off
    /// occurrences are left alone; turning the schedule off ends them all.
    private func applySchedule() {
        guard let rid = scheduleRoutineId else { return }
        let rules = (try? context.fetch(
            FetchDescriptor<ScheduleRule>(predicate: #Predicate { $0.routineId == rid && $0.deletedAt == nil },
                                          sortBy: [SortDescriptor(\.createdAt)])
        )) ?? []
        let recurring = rules.filter { $0.isRecurring }
        if scheduleEnabled {
            if let rule = recurring.first {
                recurrence.apply(to: rule)
            } else {
                context.insert(recurrence.buildRule(routineId: rid, source: routine.source))
            }
        } else {
            for rule in recurring { rule.deletedAt = .now } // only recurring; keep one-offs
        }
        try? context.save()
    }

    // MARK: - Versioning guard

    private var isActiveReferenced: Bool {
        guard let active = routine.activeVersion else { return false }
        return repo.isReferencedBySession(active)
    }

    /// Bring the routine up to date with the library. That can move the
    /// update into a new version (when a workout used this one), so stop
    /// editing a version that is no longer active.
    private func syncWithLibrary() {
        CatalogSyncService(context).reconcileRoutine(routine)
        if let id = workingVersionId, routine.activeVersion?.id != id { workingVersionId = nil }
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
        // Match the library now, while no workout uses this version, so a
        // later sync doesn't need a new version for it.
        CatalogSyncService(context).reconcileExercise(exercise.id)
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
        onCommit?()
        dismiss()
    }
}
