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

    @State private var workoutSession: WorkoutSession?
    @State private var pendingSummary: WorkoutSession?
    @State private var summarySession: WorkoutSession?
    @State private var newRoutineToEdit: Routine?
    @State private var pendingDelete: DeleteTarget?
    /// Catalog reconciliation is a defensive full-sweep safety net (drift can
    /// only enter via import/demo-seed, both handled at launch) — run it once
    /// per session, not on every tab-switch `onAppear`.
    @State private var hasSyncedCatalog = false
    /// What to do once a newly created routine is saved.
    private enum CreateMode { case startNow, laterToday }
    @State private var createMode: CreateMode = .laterToday

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
                .onAppear {
                    guard !hasSyncedCatalog else { return }
                    hasSyncedCatalog = true
                    let sync = CatalogSyncService(context)
                    for routine in routines { sync.reconcileRoutine(routine) }
                    for session in sessions { sync.reconcileSession(session) }
                    try? context.save()
                }
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
                .sheet(item: $newRoutineToEdit) { r in
                    NavigationStack {
                        // On Save: Start Now → start it; Later Today → add to today.
                        RoutineEditorView(routine: r, isCreating: true, onCommit: { handleCreatedRoutine(r) })
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
        // Title + exercise count live INSIDE the card (a row), not as a header.
        let count = exerciseCount(routine)
        return Section {
            titleRow(routine.name,
                     subtitle: "\(count) exercise\(count == 1 ? "" : "s")",
                     target: DeleteTarget(title: routine.name, routineId: routine.id, session: nil))
            Button { start(routine) } label: {
                BigActionLabel(title: "Start Workout", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// In-card title row with an optional subtitle and the delete menu.
    private func titleRow(_ title: String, subtitle: String?, target: DeleteTarget) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
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

    /// Total exercises across all of the routine's groupings.
    private func exerciseCount(_ routine: Routine) -> Int {
        (routine.activeVersion?.orderedSections ?? []).reduce(0) { $0 + $1.orderedExercises.count }
    }

    private func inProgressSection(_ session: WorkoutSession) -> some View {
        Section {
            // Progress counts EXERCISES (not sets); no exercise list on Today.
            let total = session.exercises.count
            let done = session.exercises.filter(\.isFullyCompleted).count
            let statusText = session.isLocked
                ? "\(session.status.displayName) — \(done)/\(total) exercises"
                : "In progress — \(done)/\(total) exercises"
            Label(statusText, systemImage: "clock")
                .font(.subheadline).foregroundStyle(.secondary)

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
                Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundStyle(Theme.statusGreen)
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
                    .foregroundStyle(.white)
            }
            .buttonStyle(.borderedProminent)
            // Secondary action → muted foreground fill (donohoeux styleguide).
            .tint(Theme.mutedForeground)
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

    /// Add-workout menu: "Start Now" runs a routine immediately; "Later Today"
    /// adds it to today's list to start later. Each offers the routine list plus
    /// "Create a Routine".
    @ViewBuilder
    private func addWorkoutMenu(title: String, prominent: Bool) -> some View {
        let menu = Menu {
            Menu("Start Now") {
                ForEach(routines) { routine in
                    Button(routine.name) { start(routine) }
                }
                Button { createRoutine(mode: .startNow) } label: { Label("Create a Routine", systemImage: "plus") }
            }
            Menu("Later Today") {
                ForEach(routines) { routine in
                    Button(routine.name) { addRoutineToToday(routine) }
                }
                Button { createRoutine(mode: .laterToday) } label: { Label("Create a Routine", systemImage: "plus") }
            }
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
    /// creation editor. `mode` decides what happens on Save.
    private func createRoutine(mode: CreateMode) {
        createMode = mode
        let routine = repo.createRoutine(name: "")
        if let v = routine.activeVersion { repo.addSection(to: v, type: .strength) }
        try? context.save()
        newRoutineToEdit = routine
    }

    /// After a created routine is saved: start it now, or add it to today.
    private func handleCreatedRoutine(_ routine: Routine) {
        switch createMode {
        case .startNow: start(routine)
        case .laterToday: addRoutineToToday(routine)
        }
    }
}
