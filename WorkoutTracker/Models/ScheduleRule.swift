//
//  ScheduleRule.swift
//  WorkoutTracker
//
//  RRULE-compatible recurrence stored from v1. The MVP UI only exposes simple
//  options (a weekday, "every N days/weeks"), but the model captures a full
//  RRULE string plus structured fields so richer recurrence editing can be
//  added later WITHOUT a data migration.
//

import Foundation
import SwiftData

@Model
final class ScheduleRule {
    var id: UUID
    /// Which routine this schedule assigns. Stored by id (soft-delete safe).
    var routineId: UUID

    var freqRaw: String
    /// "Every N" days or weeks. RRULE INTERVAL.
    var interval: Int
    /// RRULE BYDAY weekdays, stored as CSV of Calendar weekday ints (1=Sun...7=Sat).
    /// Empty for daily rules.
    var byWeekdaysRaw: String
    /// RRULE DTSTART anchor.
    var startDate: Date
    /// Optional end (RRULE UNTIL). Nil = open-ended.
    var untilDate: Date?
    /// Optional RRULE COUNT — total number of occurrences. Nil = unbounded.
    var count: Int?
    /// Optional RRULE BYMONTHDAY (1...31) for monthly rules. Nil = use the
    /// start date's day-of-month.
    var byMonthDay: Int?

    /// Canonical RRULE string (e.g. "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR").
    /// Future-proofing: stored even though the MVP derives it from the fields.
    var rruleString: String

    /// RRULE EXDATE — dates this rule should NOT fire on (per-occurrence delete).
    /// Stored as CSV of "yyyy-MM-dd" day keys.
    var exceptionDatesRaw: String = ""

    var sourceRaw: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    var freq: RecurrenceFrequency {
        get { RecurrenceFrequency(rawValue: freqRaw) ?? .weekly }
        set { freqRaw = newValue.rawValue }
    }
    var source: DataSource {
        get { DataSource(rawValue: sourceRaw) ?? .user }
        set { sourceRaw = newValue.rawValue }
    }
    var isSoftDeleted: Bool { deletedAt != nil }

    /// Whether this rule recurs (more than one occurrence) vs. a single-instance
    /// (individually created) schedule. A one-off is a rule bounded to its start
    /// day or COUNT == 1.
    var isRecurring: Bool {
        if let count { return count > 1 }
        if let untilDate {
            let cal = Calendar.current
            return cal.startOfDay(for: untilDate) > cal.startOfDay(for: startDate)
        }
        return true // open-ended
    }

    /// Day key formatter for exception dates (timezone-stable yyyy-MM-dd).
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayKeyFormatter.string(from: date) }

    /// True if this rule has an exception (deleted occurrence) on the given day.
    func hasException(on date: Date) -> Bool {
        exceptionDatesRaw.split(separator: ",").map(String.init).contains(Self.dayKey(date))
    }

    /// Add a per-occurrence exception so the rule no longer fires on `date`.
    func addException(on date: Date) {
        let key = Self.dayKey(date)
        var keys = exceptionDatesRaw.split(separator: ",").map(String.init)
        guard !keys.contains(key) else { return }
        keys.append(key)
        exceptionDatesRaw = keys.joined(separator: ",")
        updatedAt = .now
    }

    /// Weekday set as Calendar weekday integers (1=Sun ... 7=Sat).
    var weekdays: [Int] {
        get {
            byWeekdaysRaw
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        set {
            byWeekdaysRaw = newValue.sorted().map(String.init).joined(separator: ",")
        }
    }

    init(id: UUID = UUID(),
         routineId: UUID,
         freq: RecurrenceFrequency,
         interval: Int = 1,
         weekdays: [Int] = [],
         startDate: Date = .now,
         untilDate: Date? = nil,
         count: Int? = nil,
         byMonthDay: Int? = nil,
         source: DataSource = .user,
         createdAt: Date = .now) {
        self.id = id
        self.routineId = routineId
        self.freqRaw = freq.rawValue
        self.interval = max(1, interval)
        self.byWeekdaysRaw = weekdays.sorted().map(String.init).joined(separator: ",")
        self.startDate = startDate
        self.untilDate = untilDate
        self.count = count
        self.byMonthDay = byMonthDay
        self.sourceRaw = source.rawValue
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.deletedAt = nil
        self.rruleString = ScheduleRule.buildRRULE(freq: freq, interval: interval, weekdays: weekdays,
                                                   until: untilDate, count: count, byMonthDay: byMonthDay)
    }

    /// Recompute and store the canonical RRULE from the structured fields.
    func refreshRRULE() {
        rruleString = ScheduleRule.buildRRULE(freq: freq, interval: interval, weekdays: weekdays,
                                              until: untilDate, count: count, byMonthDay: byMonthDay)
        updatedAt = .now
    }

    /// A human-readable summary of the recurrence (e.g. "Every 2 weeks on Mon, Wed").
    var summaryText: String {
        let map = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
        let n = max(1, interval)
        var base: String
        switch freq {
        case .daily:
            base = n == 1 ? "Every day" : "Every \(n) days"
        case .weekly:
            let days = weekdays.sorted().compactMap { map[$0] }.joined(separator: ", ")
            base = (n == 1 ? "Weekly" : "Every \(n) weeks") + (days.isEmpty ? "" : " on \(days)")
        case .monthly:
            let dom = byMonthDay ?? Calendar.current.component(.day, from: startDate)
            base = (n == 1 ? "Monthly" : "Every \(n) months") + " on day \(dom)"
        }
        if let count { base += " · \(count) time\(count == 1 ? "" : "s")" }
        else if let untilDate { base += " · until " + untilDate.formatted(date: .abbreviated, time: .omitted) }
        return base
    }

    static func buildRRULE(freq: RecurrenceFrequency, interval: Int, weekdays: [Int],
                           until: Date?, count: Int?, byMonthDay: Int?) -> String {
        var parts = ["FREQ=\(freq.rruleToken)", "INTERVAL=\(max(1, interval))"]
        if freq == .weekly, !weekdays.isEmpty {
            let map = [1: "SU", 2: "MO", 3: "TU", 4: "WE", 5: "TH", 6: "FR", 7: "SA"]
            let days = weekdays.sorted().compactMap { map[$0] }.joined(separator: ",")
            if !days.isEmpty { parts.append("BYDAY=\(days)") }
        }
        if freq == .monthly, let byMonthDay { parts.append("BYMONTHDAY=\(byMonthDay)") }
        if let count {
            parts.append("COUNT=\(count)")
        } else if let until {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd"
            fmt.timeZone = TimeZone(identifier: "UTC")
            parts.append("UNTIL=\(fmt.string(from: until))")
        }
        return parts.joined(separator: ";")
    }
}
