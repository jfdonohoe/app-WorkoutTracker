//
//  ScheduleService.swift
//  WorkoutTracker
//
//  Expands ScheduleRules into concrete dates. Pure date math — no persistence,
//  no side effects. A future scheduled date is NEVER turned into a stored
//  WorkoutSession here; sessions are only created when the user starts one.
//

import Foundation

struct ScheduleService {
    var calendar: Calendar = {
        var c = Calendar.current
        c.firstWeekday = 1
        return c
    }()

    /// Does `rule` schedule a workout on `date`?
    func occurs(_ rule: ScheduleRule, on date: Date) -> Bool {
        if rule.isSoftDeleted { return false }
        if rule.hasException(on: date) { return false } // per-occurrence delete
        let day = calendar.startOfDay(for: date)
        let start = calendar.startOfDay(for: rule.startDate)
        if day < start { return false }
        if let until = rule.untilDate, day > calendar.startOfDay(for: until) { return false }
        guard baseMatches(rule, day: day, start: start) else { return false }

        // RRULE COUNT: only the first `count` occurrences fire.
        if let count = rule.count {
            return occurrenceIndex(rule, upTo: day, start: start, cap: count) <= count
        }
        return true
    }

    /// Whether `day` matches the rule's FREQ/INTERVAL/BYDAY/BYMONTHDAY (ignoring
    /// COUNT/UNTIL/exceptions).
    private func baseMatches(_ rule: ScheduleRule, day: Date, start: Date) -> Bool {
        let n = max(1, rule.interval)
        switch rule.freq {
        case .daily:
            let days = calendar.dateComponents([.day], from: start, to: day).day ?? 0
            return days % n == 0

        case .weekly:
            let weekday = calendar.component(.weekday, from: day)
            let days = rule.weekdays.isEmpty ? [calendar.component(.weekday, from: start)] : rule.weekdays
            guard days.contains(weekday) else { return false }
            let startWeek = calendar.dateInterval(of: .weekOfYear, for: start)?.start ?? start
            let dayWeek = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
            let weeks = calendar.dateComponents([.weekOfYear], from: startWeek, to: dayWeek).weekOfYear ?? 0
            return weeks % n == 0

        case .monthly:
            let dom = rule.byMonthDay ?? calendar.component(.day, from: start)
            guard calendar.component(.day, from: day) == dom else { return false }
            let months = calendar.dateComponents([.month], from: start, to: day).month ?? 0
            return months % n == 0
        }
    }

    /// 1-based index of `day` among the rule's occurrences (counts base matches
    /// from start through day). Capped to keep the scan bounded.
    private func occurrenceIndex(_ rule: ScheduleRule, upTo day: Date, start: Date, cap: Int) -> Int {
        var idx = 0
        var cursor = start
        var guardCounter = 0
        let maxScan = 4000 // ~10+ years of days; protects against runaways
        while cursor <= day && guardCounter < maxScan {
            if baseMatches(rule, day: cursor, start: start) {
                idx += 1
                if idx > cap { break }
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? day.addingTimeInterval(86_400)
            guardCounter += 1
        }
        return idx
    }

    /// Routine ids scheduled on a given date.
    func scheduledRoutineIds(on date: Date, rules: [ScheduleRule]) -> [UUID] {
        rules.filter { occurs($0, on: date) }.map(\.routineId)
    }
}
