//
//  TodayWorkoutView.swift
//  WorkoutTracker
//
//  Screen 1, the Workout tab, titled "<date> Workout" (standard large title).
//  Assumes one workout a day:
//   • a workout scheduled today opens by default — it is started as soon as
//     the tab shows it, and the live workout list is shown inline
//   • an in-progress session → the live workout inline
//   • a finished session → "Workout complete" card with View Summary; a
//     stopped (partial) one → "Workout stopped" card. Both are locked history
//     and are never reopened, so current definitions can't change them.
//   • nothing → the "No workout scheduled today" empty state
//
//  Scrolling down minimizes the tab bar; scrolling up restores it (iOS 26,
//  set in RootView).
//
//  A workout can be deleted from the ••• menu; deletion asks whether to remove
//  it just for this day or also for future scheduled occurrences.
//

import SwiftUI
import SwiftData

struct TodayWorkoutView: View {
    @Environment(\.modelContext) private var context
    /// Only to stop them; not observed, so the tab doesn't re-render per tick.
    @Environment(\.timerCommands) private var timers
    /// A workout picked with Resume: shown as the live one (when there are
    /// several unfinished).
    @State private var resumedSessionId: UUID?
    /// Finishing a workout couldn't be saved (the reason).
    @State private var finishSaveFailure: String?

    @Query(filter: #Predicate<Routine> { $0.deletedAt == nil }, sort: \Routine.name) private var routines: [Routine]
    @Query(filter: #Predicate<ScheduleRule> { $0.deletedAt == nil }) private var schedules: [ScheduleRule]
    @Query private var sessions: [WorkoutSession]

    @State private var summarySession: WorkoutSession?
    @State private var sessionToEdit: WorkoutSession?
    @State private var newRoutineToEdit: Routine?
    @State private var pendingDelete: DeleteTarget?
    /// Catalog reconciliation is a defensive full-sweep safety net (drift can
    /// only enter via import/demo-seed, both handled at launch) — run it once
    /// per session, not on every tab-switch `onAppear`.
    @State private var hasSyncedCatalog = false
    @State private var showAddWorkout = false
    @State private var showSchedule = false
    /// What the Add Workout sheet asked for. Run from its onDismiss — presenting
    /// the next sheet in the same turn as this one's dismissal drops it.
    private enum AddAction { case start(Routine), schedule, create }
    @State private var pendingAddAction: AddAction?
    /// A just-created routine to start once its editor sheet has closed.
    @State private var pendingStartRoutine: Routine?

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
        /// Set by requestDelete: the routine recurs today, so ask day vs. future.
        var asksScope = false
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
        // Unfinished earlier workouts first: resume or finish them.
        for s in unfinishedEarlier {
            items.append(DayItem(id: "unfinished-\(s.id)", sortKey: s.startedAt ?? s.createdAt, kind: .inProgress(s)))
        }
        // Not-yet-started scheduled routines sort to the top (earliest slot).
        let dayStart = cal.startOfDay(for: .now)
        for r in plannedRoutines {
            items.append(DayItem(id: "planned-\(r.id)", sortKey: dayStart, kind: .planned(r)))
        }
        // Created workouts ordered by creation time (oldest first).
        // A locked workout (finished or stopped) is history: summary only.
        // (Abandoned ones are discarded.)
        for s in todaysSessions {
            let kind: DayItem.Kind = s.isLocked ? .completed(s) : .inProgress(s)
            items.append(DayItem(id: "session-\(s.id)", sortKey: s.createdAt, kind: kind))
        }
        return items.sorted { $0.sortKey < $1.sortKey }
    }

    /// The unlocked session shown inline as the live workout: one picked with
    /// Resume, else today's or one started in the last 12 hours (so a workout
    /// that runs past midnight stays on screen instead of being swapped for
    /// the next day's).
    private var activeSession: WorkoutSession? {
        if let id = resumedSessionId,
           let picked = sessions.first(where: { $0.id == id && $0.deletedAt == nil && !$0.isLocked }) {
            return picked
        }
        let recent = Date.now.addingTimeInterval(-12 * 60 * 60)
        return sessions
            .filter { s in
                guard s.deletedAt == nil, !s.isLocked, let started = s.startedAt else { return false }
                return isToday(s) || started > recent
            }
            .max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }

    /// Older workouts never finished but with work logged: listed (with
    /// Resume) at the top of the day, so they don't drop out of sight — and
    /// never take the place of today's.
    private var unfinishedEarlier: [WorkoutSession] {
        let recent = Date.now.addingTimeInterval(-12 * 60 * 60)
        return sessions.filter { s in
            guard s.deletedAt == nil, !s.isLocked, let started = s.startedAt,
                  !isToday(s), started <= recent else { return false }
            return s.hasAnythingDone
        }
    }

    /// The scheduled routine to open by default: planned today and with no
    /// session today at all — including a deleted one, so a workout deleted
    /// anywhere (e.g. from its summary or the Calendar) isn't restarted. It
    /// still shows as a planned card with Start.
    private var routineToAutoStart: Routine? {
        guard let routine = plannedRoutine else { return nil }
        let hadSessionToday = sessions.contains { $0.routineId == routine.id && isToday($0) }
        return hadSessionToday ? nil : routine
    }

    /// A routine scheduled today that hasn't been started yet.
    private var plannedRoutine: Routine? {
        for item in dayItems {
            if case .planned(let r) = item.kind { return r }
        }
        return nil
    }

    /// "Oct 8 Workout".
    private var screenTitle: String {
        "\(Date.now.formatted(.dateTime.month(.abbreviated).day())) Workout"
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(screenTitle)
                // A workout scheduled today opens by default: start it as soon
                // as the tab shows it, so the live workout appears inline.
                .task(id: routineToAutoStart?.id) { startScheduledWorkoutIfNeeded() }
                // If the live workout vanishes without being finished here
                // (e.g. deleted from the Calendar), don't leave its timers
                // running against it.
                .onChange(of: activeSession?.id) { old, new in
                    if old != nil, new == nil {
                        timers.stopAll()
                    }
                }
                .onAppear {
                    guard !hasSyncedCatalog else { return }
                    hasSyncedCatalog = true
                    let sync = CatalogSyncService(context)
                    for routine in routines { sync.reconcileRoutine(routine) }
                    for session in sessions { sync.reconcileSession(session) }
                    try? context.save()
                }
                .sheet(item: $sessionToEdit) { s in
                    SessionEditorView(session: s)
                }
                .sheet(item: $summarySession) { s in
                    NavigationStack {
                        WorkoutHistoryDetailView(session: s, isSummary: true, onClose: { summarySession = nil })
                    }
                }
                .sheet(item: $newRoutineToEdit, onDismiss: {
                    if let r = pendingStartRoutine { pendingStartRoutine = nil; start(r) }
                }) { r in
                    NavigationStack {
                        // On Save the new routine starts — once this sheet is gone.
                        RoutineEditorView(routine: r, isCreating: true, onCommit: { pendingStartRoutine = r })
                    }
                }
                .sheet(isPresented: $showAddWorkout, onDismiss: runPendingAddAction) {
                    AddWorkoutSheet(routines: routines,
                                    exerciseCount: exerciseCount,
                                    onStart: { pendingAddAction = .start($0) },
                                    onSchedule: { pendingAddAction = .schedule },
                                    onCreate: { pendingAddAction = .create })
                }
                .sheet(isPresented: $showSchedule) {
                    ScheduleWorkoutSheet(initialDate: .now)
                }
                .alert("Workout not saved", isPresented: Binding(get: { finishSaveFailure != nil },
                                                                 set: { if !$0 { finishSaveFailure = nil } })) {
                    Button("Try Again") {
                        do { try context.save() } catch {
                            // Show it again once this alert has closed.
                            let reason = error.localizedDescription
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(400))
                                finishSaveFailure = reason
                            }
                        }
                    }
                    Button("Later", role: .cancel) {}
                } message: {
                    Text("Your workout is finished on this device but couldn't be saved (\(finishSaveFailure ?? "")). Try again now; if the app closes first, it may come back unfinished.")
                }
                .confirmationDialog(pendingDelete.map { "Delete \($0.title)?" } ?? "Delete workout?",
                                    isPresented: Binding(get: { pendingDelete != nil },
                                                         set: { if !$0 { pendingDelete = nil } }),
                                    titleVisibility: .visible) {
                    if pendingDelete?.asksScope == true {
                        Button("Delete for this day only", role: .destructive) { performDelete(.thisDay) }
                        Button("Delete this and future occurrences", role: .destructive) { performDelete(.future) }
                    } else {
                        Button("Delete workout", role: .destructive) { performDelete(.thisDay) }
                    }
                    Button("Cancel", role: .cancel) { pendingDelete = nil }
                } message: {
                    if pendingDelete?.asksScope == true {
                        Text("Remove just today's workout, or also stop it recurring on future dates?")
                    } else {
                        Text(pendingDelete?.session == nil
                             ? "Today's planned workout will be skipped."
                             : "This workout will be deleted.")
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let session = activeSession {
            // Only a fully completed workout shows the summary; a stopped
            // (partial) one drops back to its "Workout stopped" card.
            WorkoutRunnerView(session: session,
                              listHeader: AnyView(routineHeader(session)),
                              stopsGuidedRunOnDisappear: false,
                              onSaveFailed: { finishSaveFailure = $0 }) {
                // The runner (and any sheet it has up) is torn down in this
                // same update; presenting now would be dropped, so wait for
                // that dismissal to finish.
                if session.status == .completed {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        summarySession = session
                    }
                }
            }
            .id(session.id)
        } else if dayItems.isEmpty {
            noWorkoutList
        } else {
            List {
                ForEach(dayItems) { item in
                    switch item.kind {
                    case .planned(let routine): plannedSection(routine)
                    case .inProgress(let session): inProgressSection(session)
                    case .completed(let session): completedSection(session)
                    }
                }
                scheduleSection
            }
            .listStyle(.insetGrouped)
            .headerProminence(.increased)
        }
    }

    // MARK: - Routine header

    /// Above the live workout: the routine name with its ••• menu.
    private func routineHeader(_ session: WorkoutSession) -> some View {
        HStack {
            Text(session.routineName).font(.headline)
            Spacer()
            Menu {
                Button { sessionToEdit = session } label: {
                    Label("Edit workout", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    requestDelete(DeleteTarget(title: session.routineName,
                                               routineId: session.routineId,
                                               session: session))
                } label: {
                    Label("Delete workout", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
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
            Label(isToday(session) ? "In progress — \(done)/\(total) exercises"
                  : "Unfinished from \((session.startedAt ?? session.createdAt).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) — \(done)/\(total) exercises",
                  systemImage: "clock")
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
                if session.status == .completed {
                    Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundStyle(Theme.statusGreen)
                    Text("Workout complete").font(.title3.bold())
                } else {
                    Image(systemName: "stop.circle.fill").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Workout stopped").font(.title3.bold())
                }
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

                addWorkoutButton(prominent: true)
            }
        }
        .listStyle(.insetGrouped)
        .headerProminence(.increased)
    }

    /// Opens the Add Workout sheet: every routine (tap to start now), plus
    /// "Schedule for later" and "Create a routine".
    @ViewBuilder
    private func addWorkoutButton(prominent: Bool) -> some View {
        let button = Button { showAddWorkout = true } label: {
            BigActionLabel(title: "Add Workout", systemImage: "plus")
        }
        if prominent { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
    }

    private var scheduleSection: some View {
        Section {
            addWorkoutButton(prominent: false)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
    }

    private func runPendingAddAction() {
        guard let action = pendingAddAction else { return }
        pendingAddAction = nil
        switch action {
        case .start(let routine): start(routine)
        case .schedule: showSchedule = true
        case .create: createRoutine()
        }
    }

    // MARK: - Start / summary / delete

    /// Starting a workout shows it inline (it becomes `activeSession`).
    private func start(_ routine: Routine) {
        resumedSessionId = nil   // the new workout is the live one
        _ = workouts.startWorkout(from: routine, scheduledDate: .now)
        try? context.save()
    }

    /// The day's scheduled workout opens by default. Runs from `.task`, never
    /// from `body`. A deleted workout doesn't come back (see
    /// `routineToAutoStart`).
    private func startScheduledWorkoutIfNeeded() {
        guard activeSession == nil, let routine = routineToAutoStart else { return }
        start(routine)
    }

    /// Resume a workout: it becomes the live one shown inline. Only unlocked
    /// workouts get the Resume card (one that isn't already the live one); a
    /// stopped workout is locked history and is never reopened.
    private func resume(_ session: WorkoutSession) {
        guard !session.isLocked else { return }
        resumedSessionId = session.id
    }

    /// True if this workout's routine has a RECURRING schedule firing today.
    private func isRecurringToday(_ target: DeleteTarget) -> Bool {
        guard let routineId = target.routineId else { return false }
        let day = Date()
        return schedules.contains { $0.routineId == routineId && $0.isRecurring && scheduleService.occurs($0, on: day) }
    }

    /// Always confirm. A routine recurring today also gets the day-vs-future
    /// question; anything else (single instance, ad-hoc) a plain confirmation.
    private func requestDelete(_ target: DeleteTarget) {
        var target = target
        // A workout from an earlier day (an unfinished one listed here) only
        // deletes that workout: today's schedule isn't its to change.
        target.asksScope = isRecurringToday(target) && (target.session.map(isToday) ?? true)
        pendingDelete = target
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
            // Deleting the live workout ends its timers too.
            if !session.isLocked {
                timers.stopAll()
            }
            workouts.softDeleteSession(session)
        }
        if let routineId = target.routineId, target.session.map(isToday) ?? true {
            // Only the rules that put this workout on today, as Calendar does:
            // the routine's other schedules aren't this workout's to end.
            for rule in schedules where rule.routineId == routineId && scheduleService.occurs(rule, on: day) {
                switch scope {
                case .thisDay:
                    rule.addException(on: day)
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
    /// creation editor. Saving it starts the workout.
    private func createRoutine() {
        let routine = repo.createRoutine(name: "")
        if let v = routine.activeVersion { repo.addSection(to: v, type: .strength) }
        try? context.save()
        newRoutineToEdit = routine
    }
}

/// The Workout tab's "Add Workout" sheet: tap a routine to start it right
/// away, or schedule one for later / create a new one.
struct AddWorkoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    let routines: [Routine]
    let exerciseCount: (Routine) -> Int
    var onStart: (Routine) -> Void
    var onSchedule: () -> Void
    var onCreate: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if routines.isEmpty {
                        Text("No routines yet. Create one below.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(routines) { routine in
                        Button {
                            onStart(routine)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(routine.name).font(.headline).foregroundStyle(.primary)
                                    let count = exerciseCount(routine)
                                    Text("\(count) exercise\(count == 1 ? "" : "s")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "play.fill").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                } header: {
                    Text("Start now")
                } footer: {
                    Text("Tapping a routine starts the workout immediately.")
                }

                Section {
                    Button {
                        onSchedule()
                        dismiss()
                    } label: {
                        Label("Schedule for later", systemImage: "calendar.badge.plus")
                    }
                    Button {
                        onCreate()
                        dismiss()
                    } label: {
                        Label("Create a routine", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Add Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
