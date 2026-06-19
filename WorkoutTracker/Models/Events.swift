//
//  Events.swift
//  WorkoutTracker
//
//  Append-only event records: corrections to past workouts and a general audit
//  log. These are the ONLY sanctioned way to "change" recorded history — by
//  layering new events on top, never by overwriting originals (principle #5).
//

import Foundation
import SwiftData

/// An append-only correction to a recorded workout. The original value stays in
/// place on the session/set; the corrected view is computed by applying the
/// latest correction event per (entity, field). Nothing is ever overwritten.
@Model
final class WorkoutCorrectionEvent {
    var id: UUID
    var session: WorkoutSession?
    var workoutSessionId: UUID

    /// Which entity & field this correction targets, e.g. "WorkoutSessionSet" /
    /// "actualWeight". Kept as strings so new correctable fields need no schema
    /// change.
    var targetEntity: String
    var targetEntityId: UUID?
    var field: String

    /// String-encoded previous and corrected values (preserves the original).
    var previousValue: String
    var correctedValue: String

    var createdAt: Date
    var note: String?
    var sourceRaw: String

    var source: DataSource {
        get { DataSource(rawValue: sourceRaw) ?? .user }
        set { sourceRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(),
         workoutSessionId: UUID,
         targetEntity: String,
         targetEntityId: UUID?,
         field: String,
         previousValue: String,
         correctedValue: String,
         note: String? = nil,
         source: DataSource = .user,
         createdAt: Date = .now) {
        self.id = id
        self.workoutSessionId = workoutSessionId
        self.targetEntity = targetEntity
        self.targetEntityId = targetEntityId
        self.field = field
        self.previousValue = previousValue
        self.correctedValue = correctedValue
        self.note = note
        self.sourceRaw = source.rawValue
        self.createdAt = createdAt
    }
}

/// A general append-only audit/data event log for important changes (routine
/// versioned, session locked, demo data deleted, import performed, ...). Useful
/// for debugging data-safety and for the Data Safety Check screen.
@Model
final class AuditEvent {
    var id: UUID
    var timestamp: Date
    var type: String
    // NOTE: named `entityName`, NOT `entity`. `entity` is a reserved member on
    // the persistent/managed-object backing (it returns an NSEntityDescription),
    // and a stored property of that name corrupts schema generation
    // ("Could not cast value of type 'NSEntityDescription' to 'NSString'").
    var entityName: String
    var entityId: UUID?
    var summary: String
    var sourceRaw: String

    var source: DataSource {
        get { DataSource(rawValue: sourceRaw) ?? .user }
        set { sourceRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(),
         type: String,
         entity: String,
         entityId: UUID? = nil,
         summary: String,
         source: DataSource = .user,
         timestamp: Date = .now) {
        self.id = id
        self.type = type
        self.entityName = entity
        self.entityId = entityId
        self.summary = summary
        self.sourceRaw = source.rawValue
        self.timestamp = timestamp
    }
}
