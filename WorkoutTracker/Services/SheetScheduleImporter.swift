//
//  SheetScheduleImporter.swift
//  WorkoutTracker
//
//  The Google Sheet's Schedule tab: a two-week cycle that repeats every two
//  weeks from its start date.
//
//      start_date | 2026-10-19
//
//      day        | week_1    | week_2
//      Monday     | Upper     | Lower
//      Tuesday    |           |
//      …
//      Sunday     |           |
//
//  Week 1 is the Monday-to-Sunday week holding start_date. Each cell names a
//  routine (blank = no workout). Importing a filled grid REPLACES every
//  current and future scheduled workout — sheet-made or made in the app —
//  from today: rules that started before today end yesterday, rules starting
//  today or later are deleted (soft). Past days are never changed, and
//  sessions (history) aren't schedules, so they're never touched.
//
//  Each filled cell becomes one ScheduleRule: weekly, every 2 weeks, on that
//  weekday, starting on the cell's first date from today on. One rule per
//  cell keeps the 2-week rhythm exact even though ScheduleService counts
//  weeks Sunday to Saturday and the grid runs Monday to Sunday.
//

import Foundation
import SwiftData

@MainActor
struct SheetScheduleImporter {
    let context: ModelContext

    /// What an import did.
    struct Result: Equatable {
        /// Workouts in one two-week cycle (filled cells).
        var workoutsPerCycle: Int
        /// Monday of Week 1.
        var cycleStart: Date
        /// Existing schedules ended or removed.
        var replaced: Int
    }

    static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    init(_ context: ModelContext) { self.context = context }

    /// Read the tab and replace the schedule. Returns nil (and changes nothing)
    /// when the grid has no routines in it. Throws every problem found.
    func importText(_ text: String, today: Date = .now, calendar: Calendar = .current) throws -> Result? {
        let rows = CSVRoutineImporter.parse(text)
        var errors: [String] = []
        func cell(_ row: [String], _ i: Int) -> String {
            i < row.count ? row[i].trimmingCharacters(in: .whitespaces) : ""
        }

        // start_date, and the header row naming day / week_1 / week_2.
        var start: Date?
        var header: (row: Int, day: Int, weeks: [Int])?
        for (r, row) in rows.enumerated() {
            let first = Self.key(cell(row, 0))
            if first == "start_date" {
                let raw = cell(row, 1)
                start = Self.parseDate(raw)
                if start == nil { errors.append("Schedule row \(r + 1): start_date \"\(raw)\" isn't a date. Use YYYY-MM-DD.") }
            } else if header == nil, let day = row.map(Self.key).firstIndex(of: "day") {
                let keys = row.map(Self.key)
                if let w1 = keys.firstIndex(of: "week_1"), let w2 = keys.firstIndex(of: "week_2") {
                    header = (r, day, [w1, w2])
                }
            }
        }
        guard let header else {
            throw CSVImportError.invalidData(errors + ["Schedule tab: no header row with day, week_1 and week_2."])
        }
        if start == nil && errors.isEmpty {
            errors.append("Schedule tab: no start_date row. Add one with the date of a day in Week 1.")
        }

        // The grid: (week index 0/1, day offset 0 = Monday, routine).
        let routines = (try? context.fetch(FetchDescriptor<Routine>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        var cells: [(week: Int, day: Int, routine: Routine)] = []
        var seenDays = Set<Int>()
        for r in rows.indices where r > header.row {
            let row = rows[r]
            let dayRaw = cell(row, header.day)
            let names = header.weeks.map { cell(row, $0) }
            if dayRaw.isEmpty && names.allSatisfy(\.isEmpty) { continue }   // blank row
            guard let day = Self.dayOffset(dayRaw) else {
                errors.append("Schedule row \(r + 1): \"\(dayRaw)\" isn't a day of the week."); continue
            }
            if !seenDays.insert(day).inserted {
                errors.append("Schedule row \(r + 1): \(dayRaw) appears more than once.")
            }
            for (w, name) in names.enumerated() where !name.isEmpty {
                // The user's own routines first (demo only if none match); a
                // name shared by two routines is a problem, not a guess.
                let all = routines.filter { Self.key($0.name) == Self.key(name) }
                let mine = all.filter { $0.source == .user }
                let matches = mine.isEmpty ? all : mine
                guard let routine = matches.first else {
                    errors.append("Schedule row \(r + 1): no routine named \"\(name)\"."); continue
                }
                if matches.count > 1 {
                    errors.append("Schedule row \(r + 1): more than one routine is named \"\(name)\". Rename one in the app."); continue
                }
                cells.append((w, day, routine))
            }
        }
        guard errors.isEmpty, let start else { throw CSVImportError.invalidData(errors) }
        guard !cells.isEmpty else { return nil }

        // Week 1's Monday, and today.
        let today0 = calendar.startOfDay(for: today)
        let startDay = calendar.startOfDay(for: start)
        let back = (calendar.component(.weekday, from: startDay) + 5) % 7   // Mon 0 … Sun 6
        let monday = calendar.date(byAdding: .day, value: -back, to: startDay) ?? startDay

        // Replace every current and future schedule.
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today0) ?? today0
        var replaced = 0
        let existing = (try? context.fetch(FetchDescriptor<ScheduleRule>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        for rule in existing {
            if calendar.startOfDay(for: rule.startDate) >= today0 {
                rule.deletedAt = .now
                rule.updatedAt = .now
                replaced += 1
            } else if rule.untilDate.map({ calendar.startOfDay(for: $0) >= today0 }) ?? true {
                rule.untilDate = yesterday
                rule.refreshRRULE()
                replaced += 1
            }
        }

        // One every-2-weeks rule per filled cell, from its first date on or after today.
        for c in cells {
            let base = calendar.date(byAdding: .day, value: c.week * 7 + c.day, to: monday) ?? monday
            var first = base
            if base < today0 {
                let behind = calendar.dateComponents([.day], from: base, to: today0).day ?? 0
                first = calendar.date(byAdding: .day, value: (behind + 13) / 14 * 14, to: base) ?? base
            }
            let rule = ScheduleRule(routineId: c.routine.id, freq: .weekly, interval: 2,
                                    weekdays: [calendar.component(.weekday, from: first)],
                                    startDate: first, source: c.routine.source)   // a demo routine's schedule is demo (R-051)
            context.insert(rule)
        }

        let result = Result(workoutsPerCycle: cells.count, cycleStart: monday, replaced: replaced)
        Audit.log(context, type: "import.sheet", entity: "ScheduleRule",
                  summary: "Two-week cycle from \(Self.dayKey(monday)): \(cells.count) workouts; replaced \(replaced) schedules",
                  source: .user)
        return result
    }

    // MARK: - Parsing

    /// "Week 1" / "week_1" / "Start date" → "week_1" / "start_date".
    static func key(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
    }

    /// Monday = 0 … Sunday = 6, from a full or 3-letter name.
    static func dayOffset(_ s: String) -> Int? {
        let k = key(s)
        guard k.count >= 3 else { return nil }
        return weekdays.firstIndex { $0 == k || $0.hasPrefix(k) && k.count == 3 }
    }

    /// YYYY-MM-DD, or the US-style dates Sheets shows (10/19/2026, Oct 19, 2026).
    static func parseDate(_ s: String) -> Date? {
        let raw = s.trimmingCharacters(in: .whitespaces)
        for format in ["yyyy-MM-dd", "M/d/yyyy", "MMM d, yyyy", "MMMM d, yyyy", "EEE, MMM d, yyyy", "EEEE, MMMM d, yyyy"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = Calendar(identifier: .gregorian)
            f.timeZone = .current
            f.dateFormat = format
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }

    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
