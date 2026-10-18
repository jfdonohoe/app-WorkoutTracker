//
//  WorkoutPeekSheet.swift
//  WorkoutTracker
//
//  The sheet peeking up from the bottom of an exercise during a workout
//  (approved Figma Active Exercise frames): "Up next" and the name of the
//  next exercise in the workout, nothing more. Rest, recovery and get-ready
//  countdowns are in the exercise card (InCardTimers). `summary` is still
//  the one-line description the workout lists use.
//
//  White, top corners 26, and a soft shadow.
//

import SwiftUI

struct WorkoutPeekSheet: View {
    let session: WorkoutSession
    /// The exercise on screen; "Up next" is the one after it.
    let current: WorkoutSessionExercise

    var body: some View {
        // No grabber: the sheet can't be dragged, so it doesn't suggest it.
        VStack(alignment: .leading, spacing: 6) {
            content
        }
        .padding(.top, 16)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.12), radius: 16, y: -2)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let next = upNext {
            Text("Up next")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.secondaryLabel)
                .textCase(.uppercase)
            Text(next.name).font(.headline)
        } else {
            Text("Last exercise")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.secondaryLabel)
                .textCase(.uppercase)
            Text("Nothing after this one").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    /// The next unfinished exercise after this one in the workout's order.
    private var upNext: WorkoutSessionExercise? {
        let ordered = session.orderedExercises.filter { !$0.isFullyCompleted && $0.id != current.id }
        return ordered.first { $0.order > current.order } ?? ordered.first
    }

    /// One line describing an exercise in a workout.
    static func summary(_ ex: WorkoutSessionExercise) -> String {
        let side = ex.perSide == .single ? nil : (ex.perSide == .custom ? ex.perSideCustom : ex.perSide.displayName)
        if ex.hasSets {
            // Once per set, not per side; sets may vary ("90–110 lb × 6–10").
            let firstSide = ex.orderedSets.first?.side ?? ""
            let planned = ex.orderedSets.filter { $0.side == firstSide }
                .map { (reps: $0.plannedReps, weight: $0.plannedWeight) }
            let unit = WeightUnit.current.rawValue
            var parts = [ex.kind == .hold
                ? "\(planned.count) × \(planned.first?.reps ?? 1) · hold \(ex.holdSeconds)s"
                : SetRangeText.text(planned, unit: unit, addedWeight: ex.kind == .bodyweight)]
            if let side { parts.append(side) }
            return parts.joined(separator: " · ")
        }
        switch ex.kind {
        case .staticStretch?:
            return ["Hold \(ex.holdSeconds)s", side].compactMap { $0 }.joined(separator: " · ")
        case .dynamicStretch?:
            return [side, "\(ex.reps) reps"].compactMap { $0 }.joined(separator: " · ")
        case .intervals?:
            return "\(ex.rounds) × \(ex.workSeconds)s / \(ex.recoverySeconds)s" + (ex.effort.map { " · \($0.displayName)" } ?? "")
        case .distance?:
            let unit = UserDefaults.standard.string(forKey: DistanceUnit.storageKey) ?? DistanceUnit.mi.rawValue
            return (ex.plannedDistance.map { "\($0.formatted()) \(unit)" } ?? "Distance") + (ex.effort.map { " · \($0.displayName)" } ?? "")
        case .steady?:
            return "\(ex.durationMinutes) min" + (ex.effort.map { " · \($0.displayName)" } ?? "")
        default:
            switch ex.sectionType {
            case .cardio: return "\(ex.durationMinutes) min"
            case .stretching: return ex.stretchSummary
            case .strength: return ""
            }
        }
    }
}
