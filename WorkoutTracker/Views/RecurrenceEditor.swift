//
//  RecurrenceEditor.swift
//  WorkoutTracker
//
//  Reusable RRULE-style recurrence editor (frequency, interval, weekday picker,
//  end condition) plus a value model that converts to/from a ScheduleRule.
//  Used by the routine create/edit screen to set the routine's schedule.
//
//  The editor's ForEach uses only STATIC ranges (RecurrenceFrequency.allCases,
//  1...7), never a @State collection, so it's safe to embed in a pushed view
//  (see the ForEach/@State freeze note for this project).
//

import SwiftUI

/// Captures the recurrence fields the UI edits, and converts to/from ScheduleRule.
struct RecurrenceState: Equatable {
    enum EndMode: String, CaseIterable, Identifiable { case never, onDate, after; var id: String { rawValue } }

    var startDate: Date = Date()
    var freq: RecurrenceFrequency = .weekly
    var interval: Int = 1
    var weekdays: Set<Int> = []          // Calendar weekday ints, 1=Sun … 7=Sat
    var endMode: EndMode = .never
    var untilDate: Date = Date()
    var count: Int = 10

    init() {}

    /// Load from an existing rule (for editing).
    init(rule: ScheduleRule) {
        startDate = rule.startDate
        freq = rule.freq
        interval = rule.interval
        weekdays = Set(rule.weekdays)
        if let until = rule.untilDate {
            endMode = .onDate
            untilDate = until
        } else if let c = rule.count {
            endMode = .after
            count = c
        } else {
            endMode = .never
        }
    }

    var intervalUnit: String {
        switch freq {
        case .daily: return interval == 1 ? "day" : "days"
        case .weekly: return interval == 1 ? "week" : "weeks"
        case .monthly: return interval == 1 ? "month" : "months"
        }
    }

    // MARK: - Normalized RRULE fields

    private var normalizedStart: Date { Calendar.current.startOfDay(for: startDate) }
    private var resolvedWeekdays: [Int] {
        guard freq == .weekly else { return [] }
        return weekdays.isEmpty ? [Calendar.current.component(.weekday, from: normalizedStart)] : Array(weekdays)
    }
    private var resolvedUntil: Date? { endMode == .onDate ? Calendar.current.startOfDay(for: untilDate) : nil }
    private var resolvedCount: Int? { endMode == .after ? count : nil }
    private var resolvedMonthDay: Int? { freq == .monthly ? Calendar.current.component(.day, from: normalizedStart) : nil }

    /// Build a brand-new ScheduleRule for the given routine.
    func buildRule(routineId: UUID) -> ScheduleRule {
        ScheduleRule(routineId: routineId, freq: freq, interval: interval,
                     weekdays: resolvedWeekdays, startDate: normalizedStart,
                     untilDate: resolvedUntil, count: resolvedCount,
                     byMonthDay: resolvedMonthDay, source: .user)
    }

    /// Update an existing ScheduleRule in place (preserves its id + exceptions).
    func apply(to rule: ScheduleRule) {
        rule.freq = freq
        rule.interval = interval
        rule.weekdays = resolvedWeekdays
        rule.startDate = normalizedStart
        rule.untilDate = resolvedUntil
        rule.count = resolvedCount
        rule.byMonthDay = resolvedMonthDay
        rule.refreshRRULE()
        rule.updatedAt = .now
    }

    /// Human-readable summary (e.g. "Every 2 weeks on Mon, Wed").
    var summaryText: String { buildRule(routineId: UUID()).summaryText }
}

/// The recurrence editor rows. Embed inside a `Section`.
struct RecurrenceEditor: View {
    @Binding var state: RecurrenceState
    private let weekdaySymbols = Calendar.current.shortWeekdaySymbols // index 0 = Sunday

    var body: some View {
        Picker("Frequency", selection: $state.freq) {
            ForEach(RecurrenceFrequency.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        Stepper("Every \(state.interval) \(state.intervalUnit)", value: $state.interval, in: 1...52)

        if state.freq == .weekly { weekdayPicker }
        if state.freq == .monthly {
            Text("On day \(Calendar.current.component(.day, from: state.startDate)) of the month")
                .font(.caption).foregroundStyle(.secondary)
        }

        Picker("Ends", selection: $state.endMode) {
            Text("Never").tag(RecurrenceState.EndMode.never)
            Text("On date").tag(RecurrenceState.EndMode.onDate)
            Text("After N times").tag(RecurrenceState.EndMode.after)
        }
        if state.endMode == .onDate {
            DatePicker("Until", selection: $state.untilDate, displayedComponents: .date)
        } else if state.endMode == .after {
            Stepper("\(state.count) occurrence\(state.count == 1 ? "" : "s")", value: $state.count, in: 1...365)
        }
    }

    private var weekdayPicker: some View {
        HStack {
            ForEach(1...7, id: \.self) { wd in
                let on = state.weekdays.contains(wd)
                Button {
                    if on { state.weekdays.remove(wd) } else { state.weekdays.insert(wd) }
                } label: {
                    Text(weekdaySymbols[wd - 1].prefix(1))
                        .font(.subheadline.bold())
                        .frame(width: 36, height: 36)
                        .background(on ? Color.accentColor : Color(.secondarySystemFill), in: Circle())
                        .foregroundStyle(on ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
