//
//  Enums.swift
//  WorkoutTracker
//
//  Shared value types used across the data model.
//  All raw values are STABLE strings — never rename a case's rawValue, because
//  persisted records store the rawValue. Add new cases instead of renaming.
//

import Foundation

/// Marks where a record originated.
///
/// IMPORTANT (data-safety principle #6 / #7): once a record is created as
/// `.seedDemo` it stays `.seedDemo` for life, even after the user edits it.
/// "Delete Demo Data" removes everything whose source is `.seedDemo`, including
/// edited demo records (which we treat as QA/test data, never real history).
/// User-created records are `.user` and are never touched by demo cleanup.
enum DataSource: String, Codable, CaseIterable, Sendable {
    case user
    case seedDemo
}

/// A workout grouping. Each group now has its own exercise definition shape
/// (strength = sets/reps/weight, cardio = duration/intensity, stretching =
/// hold/sides/rounds). Backed by stable raw strings.
enum SectionType: String, Codable, CaseIterable, Identifiable, Sendable {
    case strength
    case cardio
    case stretching

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .strength: return "Strength"
        case .cardio: return "Cardio"
        case .stretching: return "Stretching"
        }
    }

    /// Whether this group is time-based rather than set-based.
    var isTimeBased: Bool {
        switch self {
        case .cardio, .stretching: return true
        case .strength: return false
        }
    }

    /// Canonical ordering used when laying out a routine.
    var sortIndex: Int {
        switch self {
        case .strength: return 0
        case .cardio: return 1
        case .stretching: return 2
        }
    }
}

/// Cardio exercise intensity.
enum CardioIntensity: String, Codable, CaseIterable, Identifiable, Sendable {
    case low, moderate, high

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .low: return "Low"
        case .moderate: return "Moderate"
        case .high: return "High"
        }
    }
}

/// Lifecycle status of a workout session.
enum SessionStatus: String, Codable, CaseIterable, Sendable {
    /// Planned by a schedule rule but not yet started by the user.
    case scheduled
    /// User tapped Start; a real WorkoutSession exists.
    case started
    /// All planned sets completed.
    case completed
    /// At least one set completed, but not all.
    case partial
    /// A scheduled date passed with no user-supplied data.
    case missed
    /// Started but no sets completed.
    case abandoned

    var displayName: String {
        switch self {
        case .scheduled: return "Scheduled"
        case .started: return "In Progress"
        case .completed: return "Completed"
        case .partial: return "Partial"
        case .missed: return "Missed"
        case .abandoned: return "Abandoned"
        }
    }

    /// A "completed" session in the immutability sense: history that must never
    /// be overwritten when a routine changes. Both completed and partial count
    /// as real recorded history.
    var isRecordedHistory: Bool {
        switch self {
        case .completed, .partial, .abandoned: return true
        case .scheduled, .started, .missed: return false
        }
    }
}

/// Perceived effort scale for a set.
enum PerceivedEffort: String, Codable, CaseIterable, Identifiable, Sendable {
    case easy
    case moderate
    case hard
    case tooHard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .easy: return "Easy"
        case .moderate: return "Moderate"
        case .hard: return "Hard"
        case .tooHard: return "Too hard"
        }
    }
}

/// RRULE-compatible recurrence frequency. Stored from v1 so richer recurrence
/// UI can be added later without a data migration.
enum RecurrenceFrequency: String, Codable, CaseIterable, Sendable {
    case daily   // RRULE FREQ=DAILY
    case weekly  // RRULE FREQ=WEEKLY
    case monthly // RRULE FREQ=MONTHLY

    var rruleToken: String {
        switch self {
        case .daily: return "DAILY"
        case .weekly: return "WEEKLY"
        case .monthly: return "MONTHLY"
        }
    }

    var displayName: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }
}
