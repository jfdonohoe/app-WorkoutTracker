//
//  TodayWorkoutView.swift
//  WorkoutTracker
//
//  Screen 1. Shows ALL of the day's workouts as a list of cards:
//   • scheduled-but-not-started routines → Start
//   • in-progress sessions → Resume
//   • completed sessions → View Summary
//
//  Cards are ordered with the oldest created workout at the top (a not-yet-
//  started scheduled routine sorts to the very top as the day's earliest slot).
//  Each card can be deleted; deletion asks whether to remove it just for this
//  day or also for future scheduled occurrences.
//

import SwiftUI
import SwiftData

struct TodayWorkoutView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var restTimer: RestTimerService

    @Query(filter: #Predicate<Routine> { $0.deletedAt == nil }, sort: \Routine.name) private var routines: [Routine]
    @Query(filter: #Predicate<ScheduleRule> { $0.deletedAt == nil }) private var schedules: [ScheduleRule]
    @Query private var sessions: [WorkoutSession]

    @State private var preEditVersionByRoutine: [UUID: UUID] = [:]
    @State private var editPlanned: RoutineExercise?
    @State private var editPlannedRoutineId: UUID?
    @State private var workoutSession: WorkoutSession?
    @State private var pendingSummary: WorkoutSession?
    @State private var summarySession: WorkoutSession?
    @State private var showSchedule = false
    @State private var newRoutineToEdit: Routine?
    @State private var pendingDelete: DeleteTarget?

    private let cal = Calendar.current
    private let scheduleService = ScheduleService()
    private var repo: RoutineRepository { RoutineRepository(context) }
    private var workouts: WorkoutRepository { WorkoutRepository(context) }

    // MARK: - Day model

    private struct DayItem: Identifiable {
        enum Kind { case planned(Routine), inProgress(WorkoutSession), completed(WorkoutSession) }
        let id: String
        let sortKey: Date
        let kind: Kind
    }

    private struct DeleteTarget: Identifiable {
        let id = UUID()
        let title: String
        let routineId: UUID?
        let session: WorkoutSession?
    }

    private enum DeleteScope { case thisDay, future }

    private func isToday(_ s: WorkoutSession) -> Bool {
        cal.isDateInToday(s.scheduledDate ?? s.startedAt ?? s.createdAt)
    }

    /// All of today's workouts as ordered cards.
    private var dayItems: [DayItem] {
        let todaysSessions = sessions
            .filter { $0.deletedAt == nil && $0.startedAt != nil && isToday($0) }
        let sessionRoutineIds = Set(todaysSessions.compactMap(\.routineId))

        let scheduledIds = Set(scheduleService.scheduledRoutineIds(on: .now, rules: schedules))
        let plannedRoutines = routines.filter { scheduledIds.contains($0.id) && !sessionRoutineIds.contains($0.id) }

        var items: [DayItem] = []
        // Not-yet-started scheduled routines sort to the top (earliest slot).
        let dayStart = cal.startOfDay(for: .now)
        for r in plannedRoutines {
            items.append(DayItem(id: "planned-\(r.id)", sortKey: dayStart, kind: .planned(r)))
        }
        // Created workouts ordered by creation time (oldest first).
        // Only a fully-completed workout shows the "complete" card; partial/
        // abandoned/in-progress ones stay resumable.
        for s in todaysSessions {
            let kind: DayItem.Kind = (s.isLocked && s.status == .completed) ? .completed(s) : .inProgress(s)
            items.append(DayItem(id: "session-\(s.id)", sortKey: s.createdAt, kind: kind))
        }
        return items.sorted { $0.sortKey < $1.sortKey }
    }

    var body: some View {
        NavigationStack {
            content
                .listStyle(.insetGrouped)
                .headerProminence(.increased)
                .navigationTitle("Today")
                .sheet(item: $workoutSession, onDismiss: presentSummaryIfNeeded) { s in
                    // Only show the summary for a fully completed workout; partial/
                    // abandoned ones just return to Today.
                    ActiveWorkoutView(session: s) { finished in
                        if finished.status == .completed { pendingSummary = finished }
                    }
                    .environmentObject(restTimer)
                }
                .sheet(item: $summarySession) { s in
                    NavigationStack {
                        WorkoutHistoryDetailView(session: s, isSummary: true, onClose: { summarySession = nil })
                    }
                }
                .sheet(isPresented: $showSchedule) { ScheduleWorkoutSheet() }
                .sheet(item: $newRoutineToEdit) { r in
                    NavigationStack {
                        // A routine created from Today is added to today's workout on Save.
                        RoutineEditorView(routine: r, isCreating: true, onCommit: { addRoutineToToday(r) })
                    }
                }
                .sheet(item: $editPlanned) { ex in
                    SetBuilderSheet(title: ex.displayName,
                                    machineId: ex.machineId,
                                    exerciseId: ex.exerciseId,
                                    defaultRest: ex.restBetweenSets,
                                    initialSets: ex.effectivePlannedSets,
                                    initialRest: ex.restBetweenSets) { sets, _ in
                        savePlannedSets(to: ex, sets: sets)
                    }
                }
                .confirmationDialog(pendingDelete.map { "Delete \($0.title)?" } ?? "Delete workout?",
                                    isPresented: Binding(get: { pendingDelete != nil },
                                                         set: { if !$0 { pendingDelete = nil } }),
                                    titleVisibility: .visible) {
                    Button("Delete for this day only", role: .destructive) { performDelete(.thisDay) }
                    Button("Delete this and future occurrences", role: .destructive) { performDelete(.future) }
                    Button("Cancel", role: .cancel) { pendingDelete = nil }
                } message: {
                    Text("Remove just today's workout, or also stop it recurring on future dates?")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        let items = dayItems
        if items.isEmpty {
            noWorkoutList
        } else {
            List {
                ForEach(items) { item in
                    switch item.kind {
                    case .planned(let routine): plannedSection(routine)
                    case .inProgress(let session): inProgressSection(session)
                    case .completed(let session): completedSection(session)
                    }
                }
                scheduleSection
            }
        }
    }

    // MARK: - Cards

    private func plannedSection(_ routine: Routine) -> some View {
        let version = preVersion(for: routine)
        // Show exercises from ALL groupings (strength, cardio, stretching, …),
        // ordered by section then position.
        let exercises = (version?.orderedSections ?? []).flatMap { $0.orderedExercises }

        return Section {
            // Exercise rows (with chevrons), then a full-width primary button as
            // the final row of the inset-grouped section (matches the mockup).
            ForEach(exercises) { ex in
                Button {
                    editPlannedRoutineId = routine.id
                    editPlanned = resolvePlanned(ex, in: routine)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ex.displayName).foregroundStyle(.primary)
                            Text("\(ex.section?.type.displayName ?? "") · \(ex.effectivePlannedSets.count) set\(ex.effectivePlannedSets.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .tint(.primary)
            }
            .onMove { offsets, dest in movePlanned(routine, offsets, dest) }

            Button { start(routine) } label: {
                BigActionLabel(title: "Start Workout", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
        } header: {
            cardHeader(routine.name,
                       target: DeleteTarget(title: routine.name, routineId: routine.id, session: nil))
        }
    }

    private func inProgressSection(_ session: WorkoutSession) -> some View {
        Section {
            let sets = session.exercises.flatMap(\.sets)
            let done = sets.filter(\.isCompleted).count
            let statusText = session.isLocked ? "\(session.status.displayName) — \(done)/\(sets.count) sets" : "In progress — \(done)/\(sets.count) sets"
            Label(statusText, systemImage: "clock")
                .font(.subheadline).foregroundStyle(.secondary)

            ForEach(session.orderedExercises) { ex in
                HStack {
                    Image(systemName: ex.isFullyCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(ex.isFullyCompleted ? .green : .secondary)
                    Text(ex.name)
                    Spacer()
                    Text("\(ex.sets.filter(\.isCompleted).count)/\(ex.sets.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Button { resume(session) } label: {
                BigActionLabel(title: "Resume Workout", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
        } header: {
            cardHeader(session.routineName,
                       target: DeleteTarget(title: session.routineName, routineId: session.routineId, session: session))
        }
    }

    private func completedSection(_ session: WorkoutSession) -> some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundStyle(.green)
                Text("Workout complete").font(.title3.bold())
                if let d = session.duration {
                    Text("\(session.status.displayName) · \(Int(d / 60)) min")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(session.status.displayName).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)

            Button { summarySession = session } label: {
                BigActionLabel(title: "View Summary", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
        } header: {
            cardHeader(session.routineName,
                       target: DeleteTarget(title: session.routineName, routineId: session.routineId, session: session))
        }
    }

    private func cardHeader(_ title: String, target: DeleteTarget) -> some View {
        HStack {
            Text(title)
            Spacer()
            Menu {
                Button(role: .destructive) { requestDelete(target) } label: {
                    Label("Delete workout", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - No workout

    private var noWorkoutList: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "calendar").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No workout scheduled today").font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                // Make the row separator span full width so it's symmetric under
                // the centered message instead of being left-inset.
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                addWorkoutMenu(title: "Add a Workout", prominent: true)
            }
        }
    }

    /// Shared add-workout menu: start an existing routine now, create a new
    /// routine, or schedule for later.
    @ViewBuilder
    private func addWorkoutMenu(title: String, prominent: Bool) -> some View {
        let menu = Menu {
            Section("Start now") {
                ForEach(routines) { routine in
                    Button(routine.name) { start(routine) }
                }
            }
            Button { createRoutineAndEdit() } label: { Label("Create new routine…", systemImage: "plus") }
            Button { showSchedule = true } label: { Label("Schedule for later…", systemImage: "calendar.badge.plus") }
        } label: {
            BigActionLabel(title: title, systemImage: "plus")
        }
        if prominent { menu.buttonStyle(.borderedProminent) } else { menu.buttonStyle(.bordered) }
    }

    private var scheduleSection: some View {
        Section {
            addWorkoutMenu(title: "Add / schedule a workout", prominent: false)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
    }

    // MARK: - Pre-start version safety (planned editing)

    private func preVersion(for routine: Routine) -> RoutineVersion? {
        if let id = preEditVersionByRoutine[routine.id] {
            return routines.flatMap(\.versions).first { $0.id == id }
        }
        return routine.activeVersion
    }
    private func ensurePreEditable(_ routine: Routine) {
        guard preEditVersionByRoutine[routine.id] == nil, let active = routine.activeVersion else { return }
        preEditVersionByRoutine[routine.id] = repo.isReferencedBySession(active)
            ? repo.makeNewVersion(of: routine).id : active.id
    }
    private func resolvePlanned(_ ex: RoutineExercise, in routine: Routine) -> RoutineExercise? {
        let all = preVersion(for: routine)?.sections.flatMap(\.exercises) ?? []
        return all.first { $0.id == ex.id } ?? all.first { $0.exerciseId == ex.exerciseId && $0.order == ex.order }
    }
    private func savePlannedSets(to ex: RoutineExercise, sets: [(reps: Int, weight: Double)]) {
        guard let rid = editPlannedRoutineId, let routine = routines.first(where: { $0.id == rid }) else { return }
        ensurePreEditable(routine)
        guard let target = resolvePlanned(ex, in: routine) else { return }
        let routineRest = preVersion(for: routine)?.defaultRestBetweenSets ?? target.restBetweenSets
        repo.setPlannedSets(target, sets: sets, restBetweenSets: routineRest)
        try? context.save()
    }
    private func movePlanned(_ routine: Routine, _ offsets: IndexSet, _ dest: Int) {
        ensurePreEditable(routine)
        guard let version = preVersion(for: routine) else { return }
        // Reorder across the flattened (all-groupings) list, then reassign each
        // exercise's order within its own section based on the new positions.
        var all = version.orderedSections.flatMap { $0.orderedExercises }
        all.move(fromOffsets: offsets, toOffset: dest)
        var perSectionIndex: [UUID: Int] = [:]
        for ex in all {
            guard let sid = ex.section?.id else { continue }
            let idx = perSectionIndex[sid] ?? 0
            ex.order = idx
            perSectionIndex[sid] = idx + 1
        }
        try? context.save()
    }

    // MARK: - Start / summary / delete

    private func start(_ routine: Routine) {
        let session = workouts.startWorkout(from: routine, scheduledDate: .now)
        try? context.save()
        workoutSession = session
    }

    /// Resume a workout. Finished-but-incomplete (partial/abandoned) sessions are
    /// reopened so they can be continued.
    private func resume(_ session: WorkoutSession) {
        if session.isLocked {
            workouts.reopen(session)
            try? context.save()
        }
        workoutSession = session
    }

    /// One-off schedule for today so a freshly created routine shows up now.
    private func addRoutineToToday(_ routine: Routine) {
        let day = cal.startOfDay(for: .now)
        let rule = ScheduleRule(routineId: routine.id, freq: .weekly, interval: 1,
                                weekdays: [cal.component(.weekday, from: day)],
                                startDate: day, untilDate: day, source: .user)
        context.insert(rule)
        try? context.save()
    }

    private func presentSummaryIfNeeded() {
        if let s = pendingSummary { pendingSummary = nil; summarySession = s }
    }

    /// True if this workout's routine has a RECURRING schedule firing today.
    private func isRecurringToday(_ target: DeleteTarget) -> Bool {
        guard let routineId = target.routineId else { return false }
        let day = Date()
        return schedules.contains { $0.routineId == routineId && $0.isRecurring && scheduleService.occurs($0, on: day) }
    }

    /// Decide whether to ask the day-vs-future question (recurring) or just
    /// delete that day (single instance / ad-hoc).
    private func requestDelete(_ target: DeleteTarget) {
        if isRecurringToday(target) {
            pendingDelete = target // show scope dialog
        } else {
            applyDelete(target, scope: .thisDay)
        }
    }

    /// From the scope confirmation dialog.
    private func performDelete(_ scope: DeleteScope) {
        guard let target = pendingDelete else { return }
        applyDelete(target, scope: scope)
        pendingDelete = nil
    }

    private func applyDelete(_ target: DeleteTarget, scope: DeleteScope) {
        let day = Date()
        if let session = target.session {
            workouts.softDeleteSession(session)
        }
        if let routineId = target.routineId {
            for rule in schedules where rule.routineId == routineId {
                switch scope {
                case .thisDay:
                    if scheduleService.occurs(rule, on: day) { rule.addException(on: day) }
                case .future:
                    // Stop recurring today and onward, preserving past markers.
                    let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: day)) ?? day
                    rule.untilDate = yesterday
                    rule.refreshRRULE()
                }
            }
        }
        try? context.save()
    }

    /// Create a new routine (unnamed — naming is the first step) and open the
    /// creation editor with Cancel/Save.
    private func createRoutineAndEdit() {
        let routine = repo.createRoutine(name: "")
        if let v = routine.activeVersion { repo.addSection(to: v, type: .strength) }
        try? context.save()
        newRoutineToEdit = routine
    }
}
