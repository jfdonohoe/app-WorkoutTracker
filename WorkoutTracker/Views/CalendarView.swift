//
//  CalendarView.swift
//  WorkoutTracker
//
//  Screen 7. A month grid marking past workouts (completed / partial / missed /
//  abandoned) and future scheduled days. Selecting a day shows its detail and a
//  link to the read-only history. Future sessions are NOT created here — only
//  when the user actually starts one (per spec).
//

import SwiftUI
import SwiftData

struct CalendarView: View {
    @Environment(\.modelContext) private var context
    @Query private var sessions: [WorkoutSession]
    @Query(filter: #Predicate<ScheduleRule> { $0.deletedAt == nil }) private var schedules: [ScheduleRule]
    @Query(filter: #Predicate<Routine> { $0.deletedAt == nil }, sort: \Routine.name) private var routines: [Routine]

    @State private var monthAnchor = Date()
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    @State private var showSchedule = false
    @State private var newRoutineToEdit: Routine?
    @State private var instanceEdit: InstanceEdit?
    @State private var pendingInstanceScope: InstanceEdit?
    @State private var pendingSchedDelete: SchedDelete?
    /// Catalog reconciliation is a defensive full-sweep safety net (drift can
    /// only enter via import/demo-seed, both handled at launch) — run it once
    /// per session, not on every tab-switch `onAppear`.
    @State private var hasSyncedCatalog = false

    private let cal = Calendar.current
    private let scheduleService = ScheduleService()

    /// A future scheduled routine being edited on a clone (so the original is
    /// untouched until the user chooses the scope).
    private struct InstanceEdit: Identifiable {
        let id = UUID()
        let clone: Routine
        let originalId: UUID
        let date: Date
    }
    private struct SchedDelete: Identifiable {
        let id = UUID()
        let routineId: UUID
        let date: Date
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    monthHeader
                    weekdayHeader
                    monthGrid
                    legend
                    dayDetail
                }
                .padding()
            }
            .navigationTitle("Calendar")
            .onAppear {
                guard !hasSyncedCatalog else { return }
                hasSyncedCatalog = true
                let sync = CatalogSyncService(context)
                for routine in routines { sync.reconcileRoutine(routine) }
                try? context.save()
            }
            .sheet(isPresented: $showSchedule) { ScheduleWorkoutSheet(initialDate: selectedDay) }
            .sheet(item: $newRoutineToEdit) { r in
                NavigationStack {
                    // On Save, add the new routine as a one-off on the selected day.
                    RoutineEditorView(routine: r, isCreating: true, onCommit: { addOne(r, on: selectedDay) })
                }
            }
            .sheet(item: $instanceEdit) { edit in
                NavigationStack {
                    // Edit a CLONE; Save asks scope, Cancel discards the clone.
                    // Recurrence edits apply LIVE to the original routine's schedule.
                    RoutineEditorView(routine: edit.clone, isCreating: true,
                                      onCommit: { pendingInstanceScope = edit },
                                      scheduleRoutineId: edit.originalId)
                }
            }
            .confirmationDialog("Apply changes to…",
                                isPresented: Binding(get: { pendingInstanceScope != nil },
                                                     set: { if !$0 { pendingInstanceScope = nil } }),
                                titleVisibility: .visible) {
                Button("Just this day") { commitInstanceEdit(thisInstanceOnly: true) }
                Button("All future recurrences") { commitInstanceEdit(thisInstanceOnly: false) }
                Button("Cancel", role: .cancel) { discardInstanceEdit() }
            }
            .confirmationDialog("Delete scheduled workout?",
                                isPresented: Binding(get: { pendingSchedDelete != nil },
                                                     set: { if !$0 { pendingSchedDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete for this day only", role: .destructive) { performSchedDelete(future: false) }
                Button("Delete this and future occurrences", role: .destructive) { performSchedDelete(future: true) }
                Button("Cancel", role: .cancel) { pendingSchedDelete = nil }
            }
        }
    }

    private func createRoutineAndEdit() {
        let repo = RoutineRepository(context)
        let routine = repo.createRoutine(name: "")
        if let v = routine.activeVersion { repo.addSection(to: v, type: .strength) }
        try? context.save()
        newRoutineToEdit = routine
    }

    /// Add a single (one-off) scheduled occurrence of a routine on the given day.
    private func addOne(_ routine: Routine, on day: Date) {
        let d = cal.startOfDay(for: day)
        let rule = ScheduleRule(routineId: routine.id, freq: .weekly, interval: 1,
                                weekdays: [cal.component(.weekday, from: d)],
                                startDate: d, untilDate: d, source: routine.source)
        context.insert(rule)
        try? context.save()
    }

    // MARK: - Header

    private var monthHeader: some View {
        HStack {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(monthTitle).font(.title2.bold())
            Spacer()
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
        }
    }

    private var weekdayHeader: some View {
        HStack {
            ForEach(Array(Self.weekdaySymbols(for: cal).enumerated()), id: \.offset) { _, s in
                Text(s).font(.caption).frame(maxWidth: .infinity).foregroundStyle(.secondary)
            }
        }
    }

    /// Weekday labels starting at the calendar's first weekday, matching the
    /// grid in monthDays (Monday-first regions start on Monday).
    static func weekdaySymbols(for cal: Calendar) -> [String] {
        let symbols = cal.shortWeekdaySymbols   // always Sunday-first
        let start = cal.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    private var monthGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
            ForEach(Array(monthDays.enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 44)
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let info = info(for: day)
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        return Button {
            selectedDay = day
        } label: {
            VStack(spacing: 4) {
                Text("\(cal.component(.day, from: day))")
                    .font(.callout)
                    .foregroundStyle(cal.isDateInToday(day) ? Color.accentColor : .primary)
                Circle().fill(info.color).frame(width: 7, height: 7).opacity(info.color == .clear ? 0 : 1)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendDot(.green, "Completed")
            legendDot(.orange, "Partial")
            legendDot(.red, "Missed")
            legendDot(.blue, "Scheduled")
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 7, height: 7); Text(label) }
    }

    // MARK: - Day detail

    private var dayDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(selectedDay.formatted(date: .complete, time: .omitted)).font(.headline)

            let daySessions = sessions.filter { sessionDate(for: $0).map { cal.isDate($0, inSameDayAs: selectedDay) } ?? false && $0.deletedAt == nil }
            if daySessions.isEmpty {
                let dayScheduled = scheduledRoutines(on: selectedDay)
                if !dayScheduled.isEmpty {
                    let isPast = cal.startOfDay(for: selectedDay) < cal.startOfDay(for: .now)
                    ForEach(dayScheduled) { routine in
                        HStack {
                            Label(isPast ? "Missed: \(routine.name)" : "Scheduled: \(routine.name)",
                                  systemImage: isPast ? "exclamationmark.circle" : "calendar")
                                .foregroundStyle(isPast ? Theme.statusRed : Theme.statusBlue)
                            Spacer()
                            Menu {
                                if !isPast {
                                    Button { beginEditScheduled(routine, on: selectedDay) } label: {
                                        Label("Edit routine", systemImage: "pencil")
                                    }
                                }
                                Button(role: .destructive) {
                                    requestSchedDelete(routine, on: selectedDay)
                                } label: { Label("Delete", systemImage: "trash") }
                            } label: {
                                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("No workouts.").foregroundStyle(.secondary)
                }
            } else {
                // Tap a workout to open its summary (delete lives there now).
                ForEach(daySessions) { session in
                    // Day details surface "Abandoned" sessions as "Partial".
                    let shown: SessionStatus = session.status == .abandoned ? .partial : session.status
                    NavigationLink {
                        WorkoutHistoryDetailView(session: session).toolbar(.hidden, for: .tabBar)
                    } label: {
                        HStack {
                            Circle().fill(statusColor(shown)).frame(width: 8, height: 8)
                            VStack(alignment: .leading) {
                                Text(session.routineName).foregroundStyle(.primary)
                                Text(shown.displayName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            // Anchored menu (popover) for the add action.
            Menu {
                Menu("Add one") {
                    ForEach(routines) { routine in
                        Button(routine.name) { addOne(routine, on: selectedDay) }
                    }
                    Button { createRoutineAndEdit() } label: { Label("Create a Routine", systemImage: "plus") }
                }
                Button { showSchedule = true } label: { Label("Schedule recurring…", systemImage: "calendar.badge.plus") }
            } label: {
                Label("Add a workout", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Edit a future scheduled routine

    private func beginEditScheduled(_ routine: Routine, on day: Date) {
        let repo = RoutineRepository(context)
        let clone = repo.cloneRoutine(routine, newName: routine.name)
        try? context.save()
        instanceEdit = InstanceEdit(clone: clone, originalId: routine.id, date: day)
    }

    private func commitInstanceEdit(thisInstanceOnly: Bool) {
        guard let edit = pendingInstanceScope else { return }
        let repo = RoutineRepository(context)
        let day = cal.startOfDay(for: edit.date)

        if thisInstanceOnly {
            // The clone applies only to this date: skip the original here and
            // schedule the (edited) clone as a one-off on this day.
            for rule in schedules where rule.routineId == edit.originalId && scheduleService.occurs(rule, on: day) {
                rule.addException(on: day)
            }
            let oneOff = ScheduleRule(routineId: edit.clone.id, freq: .weekly, interval: 1,
                                      weekdays: [cal.component(.weekday, from: day)],
                                      startDate: day, untilDate: day, source: edit.clone.source)
            context.insert(oneOff)
        } else {
            // Apply to all future recurrences: copy the clone's content into the
            // original routine (new version) and discard the clone. Move any
            // schedule set on the clone onto the original (replacing its own), so
            // it isn't orphaned when the clone is deleted.
            if let original = routines.first(where: { $0.id == edit.originalId }) {
                repo.replaceContent(of: original, with: edit.clone)
                let cloneId = edit.clone.id
                let cloneRules = schedules.filter { $0.routineId == cloneId && $0.deletedAt == nil }
                if !cloneRules.isEmpty {
                    for r in schedules where r.routineId == original.id && r.deletedAt == nil { r.deletedAt = .now }
                    for r in cloneRules { r.routineId = original.id; r.refreshRRULE() }
                }
            }
            context.delete(edit.clone)
        }
        try? context.save()
        pendingInstanceScope = nil
    }

    private func discardInstanceEdit() {
        if let edit = pendingInstanceScope {
            // Remove any schedule rules set on the clone so they aren't orphaned.
            for r in schedules where r.routineId == edit.clone.id { context.delete(r) }
            context.delete(edit.clone)
            try? context.save()
        }
        pendingInstanceScope = nil
    }

    // MARK: - Delete a scheduled occurrence

    private func requestSchedDelete(_ routine: Routine, on day: Date) {
        let recurring = schedules.contains {
            $0.routineId == routine.id && $0.isRecurring && scheduleService.occurs($0, on: day)
        }
        if recurring {
            pendingSchedDelete = SchedDelete(routineId: routine.id, date: day)
        } else {
            applySchedDelete(routineId: routine.id, day: day, future: false)
        }
    }

    private func performSchedDelete(future: Bool) {
        guard let target = pendingSchedDelete else { return }
        applySchedDelete(routineId: target.routineId, day: target.date, future: future)
        pendingSchedDelete = nil
    }

    private func applySchedDelete(routineId: UUID, day: Date, future: Bool) {
        for rule in schedules where rule.routineId == routineId && scheduleService.occurs(rule, on: day) {
            if future {
                let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: day)) ?? day
                rule.untilDate = yesterday
                rule.refreshRRULE()
            } else {
                rule.addException(on: day)
            }
        }
        try? context.save()
    }

    // MARK: - Data helpers

    private struct DayInfo { var color: Color }

    private func info(for day: Date) -> DayInfo {
        let daySessions = sessions.filter { sessionDate(for: $0).map { cal.isDate($0, inSameDayAs: day) } ?? false && $0.deletedAt == nil }
        if let best = daySessions.max(by: { statusRank($0.status) < statusRank($1.status) }) {
            return DayInfo(color: statusColor(best.status))
        }
        // Routine-aware: only routines that still exist count, so the dot can
        // never disagree with the day detail (no orphaned-rule phantom dots).
        let scheduled = !scheduledRoutines(on: day).isEmpty
        if scheduled {
            if cal.startOfDay(for: day) < cal.startOfDay(for: .now) {
                return DayInfo(color: .red) // missed
            }
            return DayInfo(color: .blue) // future scheduled
        }
        return DayInfo(color: .clear)
    }

    /// Routines BOTH scheduled on `day` and still present (non-deleted). The dot
    /// and the day detail both use this, so a ScheduleRule whose routine no longer
    /// exists draws no dot and shows no detail (instead of a dot with no detail).
    private func scheduledRoutines(on day: Date) -> [Routine] {
        let ids = Set(scheduleService.scheduledRoutineIds(on: day, rules: schedules))
        guard !ids.isEmpty else { return [] }
        return routines.filter { ids.contains($0.id) }
    }

    private func sessionDate(for s: WorkoutSession) -> Date? {
        s.completedAt ?? s.startedAt ?? s.scheduledDate
    }

    private func statusColor(_ status: SessionStatus) -> Color {
        switch status {
        case .completed: return .green
        case .partial: return .orange
        case .missed: return .red
        case .abandoned: return .gray
        case .started: return .yellow
        case .scheduled: return .blue
        }
    }

    private func statusRank(_ status: SessionStatus) -> Int {
        switch status {
        case .completed: return 5
        case .partial: return 4
        case .started: return 3
        case .abandoned: return 2
        case .missed: return 1
        case .scheduled: return 0
        }
    }

    // MARK: - Month math

    private var monthTitle: String {
        monthAnchor.formatted(.dateTime.month(.wide).year())
    }

    private func shiftMonth(_ delta: Int) {
        if let d = cal.date(byAdding: .month, value: delta, to: monthAnchor) { monthAnchor = d }
    }

    /// Days laid out with leading nil padding for the first weekday.
    private var monthDays: [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: monthAnchor) else { return [] }
        let firstWeekday = cal.component(.weekday, from: interval.start)
        let leading = firstWeekday - cal.firstWeekday
        let pad = (leading + 7) % 7
        var days: [Date?] = Array(repeating: nil, count: pad)
        var cursor = interval.start
        while cursor < interval.end {
            days.append(cursor)
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? interval.end
        }
        return days
    }
}
