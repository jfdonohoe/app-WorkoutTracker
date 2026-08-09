//
//  ScheduleWorkoutSheet.swift
//  WorkoutTracker
//
//  Assign a routine to a recurrence. Supports an RFC 5545 (RRULE) style editor:
//  FREQ (daily/weekly/monthly), INTERVAL, BYDAY (weekly), BYMONTHDAY (monthly),
//  and an end condition (never / until date / after N occurrences → COUNT).
//
//  The chosen routine is previewable and editable inline; you can also create a
//  new routine. If the selected routine was edited, scheduling asks whether to
//  save the changes as a NEW routine (leaving the original intact).
//

import SwiftUI
import SwiftData

struct ScheduleWorkoutSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Routine> { $0.deletedAt == nil }, sort: \Routine.name) private var routines: [Routine]

    var initialDate: Date = .now

    enum EndMode: String, CaseIterable, Identifiable { case never, onDate, after; var id: String { rawValue } }

    @State private var selectedRoutineId: UUID?
    @State private var routineEditSnapshot: Date?
    @State private var startDate = Date()
    @State private var freq: RecurrenceFrequency = .weekly
    @State private var interval = 1
    @State private var weekdays: Set<Int> = []
    @State private var endMode: EndMode = .never
    @State private var untilDate = Date()
    @State private var count = 10
    @State private var didInit = false
    @State private var showSaveAsNew = false

    private var repo: RoutineRepository { RoutineRepository(context) }
    private var selectedRoutine: Routine? { routines.first { $0.id == selectedRoutineId } }

    private let weekdaySymbols = Calendar.current.shortWeekdaySymbols // index 0 = Sunday

    var body: some View {
        NavigationStack {
            Form {
                routineSection
                Section("Starts") {
                    DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                }
                recurrenceSection
                Section("Summary") {
                    Text(summaryText).font(.callout).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Schedule Workout")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") { onSchedule() }
                        .disabled(selectedRoutineId == nil)
                        .confirmationDialog("This routine was edited. Save changes as a new routine?",
                                            isPresented: $showSaveAsNew, titleVisibility: .visible) {
                            Button("Save as a new routine") { commit(saveAsNew: true) }
                            Button("Update the existing routine") { commit(saveAsNew: false) }
                            Button("Cancel", role: .cancel) {}
                        }
                }
            }
            .onAppear {
                if !didInit {
                    startDate = initialDate
                    untilDate = Calendar.current.date(byAdding: .month, value: 1, to: initialDate) ?? initialDate
                    weekdays = [Calendar.current.component(.weekday, from: initialDate)]
                    didInit = true
                }
            }
        }
    }

    // MARK: - Routine

    private var routineSection: some View {
        Section("Routine") {
            Menu {
                ForEach(routines) { r in
                    Button(r.name) { select(r) }
                }
                Divider()
                Button { createRoutine() } label: { Label("Create new routine…", systemImage: "plus") }
            } label: {
                HStack {
                    Text(selectedRoutine?.name ?? "Choose a routine")
                        .foregroundStyle(selectedRoutine == nil ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
            }
            .tint(.primary)

            if let routine = selectedRoutine, let version = routine.activeVersion {
                let exercises = version.orderedSections.first { $0.type == .strength }?.orderedExercises ?? []
                ForEach(exercises) { ex in
                    HStack {
                        Text(ex.displayName)
                        Spacer()
                        Text("\(ex.effectivePlannedSets.count) set\(ex.effectivePlannedSets.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    RoutineEditorView(routine: routine)
                } label: {
                    Label("Edit routine", systemImage: "pencil")
                }
            }
        }
    }

    // MARK: - Recurrence (RRULE)

    private var recurrenceSection: some View {
        Section("Repeat") {
            Picker("Frequency", selection: $freq) {
                ForEach(RecurrenceFrequency.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Stepper("Every \(interval) \(intervalUnit)", value: $interval, in: 1...52)

            if freq == .weekly {
                weekdayPicker
            }
            if freq == .monthly {
                Text("On day \(Calendar.current.component(.day, from: startDate)) of the month")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Picker("Ends", selection: $endMode) {
                Text("Never").tag(EndMode.never)
                Text("On date").tag(EndMode.onDate)
                Text("After N times").tag(EndMode.after)
            }
            if endMode == .onDate {
                DatePicker("Until", selection: $untilDate, displayedComponents: .date)
            } else if endMode == .after {
                Stepper("\(count) occurrence\(count == 1 ? "" : "s")", value: $count, in: 1...365)
            }
        }
    }

    private var intervalUnit: String {
        switch freq {
        case .daily: return interval == 1 ? "day" : "days"
        case .weekly: return interval == 1 ? "week" : "weeks"
        case .monthly: return interval == 1 ? "month" : "months"
        }
    }

    private var weekdayPicker: some View {
        HStack {
            ForEach(1...7, id: \.self) { wd in
                let on = weekdays.contains(wd)
                Button {
                    if on { weekdays.remove(wd) } else { weekdays.insert(wd) }
                } label: {
                    Text(weekdaySymbols[wd - 1].prefix(1))
                        .font(.subheadline.bold())
                        .frame(width: 36, height: 36)
                        .background(on ? Color.accentColor : Theme.fill,
                                    in: Circle())
                        .foregroundStyle(on ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var summaryText: String {
        buildRule(routineId: UUID()).summaryText // throwaway rule, summary only
    }

    // MARK: - Actions

    private func select(_ routine: Routine) {
        selectedRoutineId = routine.id
        routineEditSnapshot = routine.updatedAt
    }

    private func createRoutine() {
        let routine = repo.createRoutine(name: "New Routine")
        if let v = routine.activeVersion { repo.addSection(to: v, type: .strength) }
        try? context.save()
        selectedRoutineId = routine.id
        routineEditSnapshot = routine.updatedAt
    }

    private func onSchedule() {
        // If the selected routine was edited since selection, ask save-as-new.
        if let routine = selectedRoutine, let snap = routineEditSnapshot, routine.updatedAt != snap {
            showSaveAsNew = true
        } else {
            commit(saveAsNew: false)
        }
    }

    private func commit(saveAsNew: Bool) {
        guard let original = selectedRoutine else { return }
        let targetId: UUID
        if saveAsNew {
            let clone = repo.cloneRoutine(original, newName: original.name + " (edited)")
            targetId = clone.id
        } else {
            targetId = original.id
        }
        let rule = buildRule(routineId: targetId)
        context.insert(rule)
        try? context.save()
        dismiss()
    }

    private func buildRule(routineId: UUID) -> ScheduleRule {
        let cal = Calendar.current
        let day = cal.startOfDay(for: startDate)
        let wds: [Int] = freq == .weekly
            ? (weekdays.isEmpty ? [cal.component(.weekday, from: day)] : Array(weekdays))
            : []
        let until: Date? = endMode == .onDate ? cal.startOfDay(for: untilDate) : nil
        let cnt: Int? = endMode == .after ? count : nil
        let byMonthDay: Int? = freq == .monthly ? cal.component(.day, from: day) : nil
        return ScheduleRule(routineId: routineId, freq: freq, interval: interval,
                            weekdays: wds, startDate: day, untilDate: until,
                            count: cnt, byMonthDay: byMonthDay, source: .user)
    }
}
