//
//  GuidedTimerService.swift
//  WorkoutTracker
//
//  Automated progression through a run of cardio or stretching exercises.
//
//  The user starts the FIRST exercise of a group by hand; from then on this
//  service walks a precomputed list of phases on its own:
//   • Cardio:    one work phase per Steady exercise (its full duration),
//                back to back — no rest after cardio. Intervals: work and
//                recovery for each round (recovery is part of the exercise).
//   • Stretches: one work phase per timed hold (rounds × sides) or, for a
//                count-based stretch, one per side using its per-side timer;
//                every work phase is separated by a 5 s transition.
//
//  Audio (foreground only):
//   • the last second of a work phase plays the completion chime;
//   • a transition's last seconds are a raceway countdown — low beep at 2 s,
//     low beep at 1 s, high beep as the next stretch starts.
//
//  Like RestTimerService, time is derived from absolute end dates, never from
//  accumulated ticks, so a locked/backgrounded phone catches up correctly on
//  return (each phase end is chained from the previous one's end, and stale
//  cues are not replayed). A local notification covers the end of the whole
//  run while backgrounded.
//
//  Session data is not touched here: the workout screen supplies
//  `onExerciseFinished` / `onSequenceFinished` and does the marking.
//

import Foundation
import Combine

/// One step of a guided run.
struct GuidedPhase: Identifiable, Equatable {
    let id = UUID()
    /// The exercise this phase belongs to. A transition belongs to the
    /// exercise it leads INTO, so the sheet can show "get ready" on it.
    let exerciseId: UUID
    let exerciseName: String
    /// A "get ready" countdown between stretch holds (or into the next stretch).
    let isTransition: Bool
    let seconds: Int
    /// e.g. "Hold · Side 1 of 2", "Work · Round 4 of 8".
    let detail: String
    /// The last work phase of its exercise — finishing it completes the exercise.
    let endsExercise: Bool
    /// Part of a stretch run (a hold, or the transition into one).
    var isStretch = false
    /// An interval's recovery — part of the Intervals exercise, not rest.
    var isRecovery = false
    /// The rest between two cardio exercises (Rest – Cardio ▸ Between
    /// exercises). A between phase like a transition, shown as the rest ring.
    var isRest = false
    /// A between phase into a different exercise (the next stretch, or the
    /// rest into the next cardio exercise) — vs one inside a stretch.
    var intoNewExercise = false
    /// Short label for the peek sheet's caption: "Side 2 of 2", "Round 3 of 8".
    var caption = ""

    /// A countdown between work phases (shown in the exercise card).
    var isBetween: Bool { isTransition || isRecovery }

    /// This phase with a different length or end flag.
    func with(seconds: Int? = nil, detail: String? = nil, endsExercise: Bool? = nil) -> GuidedPhase {
        GuidedPhase(exerciseId: exerciseId, exerciseName: exerciseName, isTransition: isTransition,
                    seconds: seconds ?? self.seconds, detail: detail ?? self.detail,
                    endsExercise: endsExercise ?? self.endsExercise,
                    isStretch: isStretch, isRecovery: isRecovery, isRest: isRest,
                    intoNewExercise: intoNewExercise, caption: caption)
    }
}

/// Builds the phase list for a run of exercises. Pure, so it's unit-tested.
enum GuidedPlan {
    /// `rests`: the workout's rests per exercise type — the stretch
    /// get-readies and the rest between cardio exercises (0 = none).
    static func phases(for exercises: [WorkoutSessionExercise], rests: TypeRests = .standard) -> [GuidedPhase] {
        var work: [GuidedPhase] = []
        for ex in exercises {
            switch ex.sectionType {
            case .cardio:
                switch ex.kind {
                case .intervals?:
                    work.append(contentsOf: intervalPhases(ex))
                case .distance?, .calisthenics?:
                    continue   // logged by hand, not timed
                default:
                    guard ex.durationMinutes > 0 else { continue }
                    var detail = "\(ex.durationMinutes) min"
                    if let e = ex.effort { detail += " · \(e.displayName)" }
                    else if let i = ex.intensity { detail += " · \(i.displayName)" }
                    work.append(GuidedPhase(exerciseId: ex.id, exerciseName: ex.name, isTransition: false,
                                            seconds: ex.durationMinutes * 60, detail: detail, endsExercise: true))
                }
            case .stretching:
                work.append(contentsOf: stretchPhases(ex))
            case .strength:
                continue
            }
        }
        // Stretches get a get-ready before every work phase except the first
        // (Rest – Stretching: within a stretch / into the next one). Cardio
        // gets Rest – Cardio ▸ Between exercises from one exercise to the next.
        var out: [GuidedPhase] = []
        for (i, phase) in work.enumerated() {
            // Only between exercises of the same type: none from one type to the next.
            if i > 0, work[i - 1].isStretch == phase.isStretch {
                let newExercise = work[i - 1].exerciseId != phase.exerciseId
                if phase.isStretch {
                    let seconds = newExercise ? rests.stretchBetween : rests.stretchWithin
                    if seconds > 0 { out.append(transition(into: phase, intoNewStretch: newExercise, seconds: seconds)) }
                } else if newExercise, rests.cardioExercises > 0 {
                    out.append(rest(into: phase, seconds: rests.cardioExercises))
                }
            }
            out.append(phase)
        }
        return out
    }

    /// The between phase that leads into an exercise's first step, if any.
    static func leadIn(to first: GuidedPhase, rests: TypeRests) -> GuidedPhase? {
        if first.isStretch {
            return rests.stretchBetween > 0 ? transition(into: first, intoNewStretch: true, seconds: rests.stretchBetween) : nil
        }
        return rests.cardioExercises > 0 ? rest(into: first, seconds: rests.cardioExercises) : nil
    }

    /// The rest from one cardio exercise into the next (rest ring).
    static func rest(into phase: GuidedPhase, seconds: Int) -> GuidedPhase {
        GuidedPhase(exerciseId: phase.exerciseId, exerciseName: phase.exerciseName,
                    isTransition: true, seconds: seconds,
                    detail: "Next: \(phase.exerciseName) · \(phase.detail)",
                    endsExercise: false, isRest: true, intoNewExercise: true, caption: "Rest between exercises")
    }

    /// The get-ready before a stretch's work phase (5 s unless the routine
    /// says otherwise).
    static func transition(into phase: GuidedPhase, intoNewStretch: Bool,
                           seconds: Int = StretchTiming.transitionSeconds) -> GuidedPhase {
        GuidedPhase(exerciseId: phase.exerciseId, exerciseName: phase.exerciseName,
                    isTransition: true, seconds: seconds,
                    detail: intoNewStretch ? "\(phase.exerciseName) · \(phase.detail)"
                                           : "Next: \(phase.detail)",
                    endsExercise: false, isStretch: true, intoNewExercise: intoNewStretch,
                    caption: intoNewStretch ? "Next stretch" : phase.caption)
    }

    /// Work and recovery for each round; no recovery after the last.
    private static func intervalPhases(_ ex: WorkoutSessionExercise) -> [GuidedPhase] {
        let rounds = max(1, ex.rounds)
        let effort = ex.effort.map { " · \($0.displayName)" } ?? ""
        var out: [GuidedPhase] = []
        for r in 1...rounds {
            out.append(GuidedPhase(exerciseId: ex.id, exerciseName: ex.name, isTransition: false,
                                   seconds: max(1, ex.workSeconds),
                                   detail: "\(ex.workSeconds) s work\(effort)",
                                   endsExercise: r == rounds, caption: "Work · Round \(r) of \(rounds)"))
            if r < rounds {
                out.append(GuidedPhase(exerciseId: ex.id, exerciseName: ex.name, isTransition: false,
                                       seconds: max(1, ex.recoverySeconds),
                                       detail: "Next: Work \(ex.workSeconds) s · Round \(r + 1) of \(rounds)\(effort)",
                                       endsExercise: false, isRecovery: true,
                                       caption: "Round \(r) of \(rounds)"))
            }
        }
        return out
    }

    private static func stretchPhases(_ ex: WorkoutSessionExercise) -> [GuidedPhase] {
        // Exercise structure: sides cycle within each rep and set.
        // The caption names the place ("Set 2 of 2 · Forward"); the detail is
        // the work itself ("10 reps", "Hold 30s").
        if let kind = ex.kind, kind == .staticStretch || kind == .dynamicStretch {
            let sides = ex.sideLabels
            let sets = max(1, ex.setCount)
            let reps = max(1, ex.reps)
            func sideText(_ s: Int) -> String? {
                guard sides.count > 1 else { return nil }
                let name = sides[s - 1]
                return name.isEmpty ? "Side \(s) of \(sides.count)" : name
            }
            var steps: [(seconds: Int, detail: String, caption: String)] = []
            for set in 1...sets {
                let setText = sets > 1 ? "Set \(set) of \(sets)" : nil
                if kind == .dynamicStretch {
                    for s in 1...sides.count {
                        steps.append((ex.resolvedCountTimerSeconds, "\(reps) rep\(reps == 1 ? "" : "s")",
                                      [setText, sideText(s)].compactMap { $0 }.joined(separator: " · ")))
                    }
                } else {
                    for r in 1...reps {
                        let repText = reps > 1 ? "Hold \(r) of \(reps)" : nil
                        for s in 1...sides.count {
                            steps.append((ex.holdSeconds, "Hold \(ex.holdSeconds)s",
                                          [setText, repText, sideText(s)].compactMap { $0 }.joined(separator: " · ")))
                        }
                    }
                }
            }
            return steps.enumerated().map { i, step in
                GuidedPhase(exerciseId: ex.id, exerciseName: ex.name, isTransition: false,
                            seconds: step.seconds, detail: step.detail, endsExercise: i == steps.count - 1,
                            isStretch: true, caption: step.caption)
            }
        }
        // Recorded before the structure: hold/sides/rounds.
        let sides = max(1, ex.sides)
        func sideText(_ s: Int) -> String? { sides > 1 ? "Side \(s) of \(sides)" : nil }
        var steps: [(seconds: Int, detail: String)] = []
        if ex.isCountBasedStretch {
            let reps = "\(ex.rounds) rep\(ex.rounds == 1 ? "" : "s")"
            for s in 1...sides {
                steps.append((ex.resolvedCountTimerSeconds, [reps, sideText(s)].compactMap { $0 }.joined(separator: " · ")))
            }
        } else {
            let rounds = max(1, ex.rounds)
            for r in 1...rounds {
                for s in 1...sides {
                    let round = rounds > 1 ? "Round \(r) of \(rounds)" : nil
                    let parts = [sideText(s), round].compactMap { $0 }
                    steps.append((ex.holdSeconds, parts.isEmpty ? "Hold \(ex.holdSeconds)s" : parts.joined(separator: " · ")))
                }
            }
        }
        return steps.enumerated().map { i, step in
            GuidedPhase(exerciseId: ex.id, exerciseName: ex.name, isTransition: false,
                        seconds: step.seconds, detail: step.detail, endsExercise: i == steps.count - 1,
                        isStretch: true)
        }
    }
}

@MainActor
final class GuidedTimerService: ObservableObject {
    @Published private(set) var phases: [GuidedPhase] = []
    @Published private(set) var index = 0
    @Published private(set) var remainingSeconds = 0
    /// Ticking right now.
    @Published private(set) var isRunning = false
    /// A run exists (running or paused).
    @Published private(set) var isActive = false

    /// Called when an exercise's last work phase ends (already advanced, so
    /// `current` is the next phase, if any).
    var onExerciseFinished: ((UUID) -> Void)?
    /// Called once after the final phase ends, with the last exercise's id.
    var onSequenceFinished: ((UUID) -> Void)?
    /// A run that doesn't complete its exercise (a stretch with Settings ▸
    /// Auto progress through stretches off) ended on this one: its timer is
    /// done and its sheet shows Complete & Next instead. Cleared by the next
    /// start or `clearTimerDone()`.
    @Published private(set) var timerDoneExerciseId: UUID?
    /// False: finishing doesn't call onExerciseFinished / onSequenceFinished;
    /// the run just ends and sets `timerDoneExerciseId`.
    private var completesExercises = true
    /// When the exercise just reported by `onExerciseFinished` actually ended
    /// (its last phase's end — earlier than now after a locked-phone catch-up).
    private(set) var lastExerciseEndedAt: Date?
    /// This run's rests per exercise type (for re-planning mid-run).
    private(set) var rests: TypeRests = .standard

    private var phaseEnd: Date?
    /// Title of the "run finished" notification ("Cardio complete", …).
    private var finishedTitle = ""
    private var pausedRemaining: TimeInterval?
    private var ticker: AnyCancellable?
    private let notifications: NotificationService
    private let notificationId = "guided-timer"

    init(notifications: NotificationService = .shared) {
        self.notifications = notifications
    }

    var current: GuidedPhase? { phases.indices.contains(index) ? phases[index] : nil }
    /// The next phase (the work a transition or recovery leads into).
    var next: GuidedPhase? { phases.indices.contains(index + 1) ? phases[index + 1] : nil }

    /// The exercise currently being worked or transitioned into.
    var currentExerciseId: UUID? { current?.exerciseId }

    func contains(_ exerciseId: UUID) -> Bool {
        isActive && phases[index...].contains { $0.exerciseId == exerciseId }
    }

    /// Fraction of the current phase elapsed (0…1).
    var progress: Double {
        guard let current, current.seconds > 0 else { return 0 }
        return 1 - Double(remainingSeconds) / Double(current.seconds)
    }

    var formattedRemaining: String {
        String(format: "%d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    // MARK: - Control

    func start(phases: [GuidedPhase], finishedTitle: String, completesExercises: Bool = true,
               rests: TypeRests = .standard, now: Date = .now) {
        guard let first = phases.first else { return }
        self.phases = phases
        self.rests = rests
        self.finishedTitle = finishedTitle
        self.completesExercises = completesExercises
        timerDoneExerciseId = nil
        index = 0
        isActive = true
        isRunning = true
        pausedRemaining = nil
        phaseEnd = now.addingTimeInterval(TimeInterval(first.seconds))
        remainingSeconds = first.seconds
        scheduleTick()
        scheduleEndNotification(now: now)
    }

    func pause(now: Date = .now) {
        guard isRunning, let phaseEnd else { return }
        pausedRemaining = max(0, phaseEnd.timeIntervalSince(now))
        isRunning = false
        ticker?.cancel()
        notifications.cancel(id: notificationId)
    }

    func resume(now: Date = .now) {
        guard isActive, !isRunning, let paused = pausedRemaining else { return }
        phaseEnd = now.addingTimeInterval(paused)
        pausedRemaining = nil
        isRunning = true
        scheduleTick()
        scheduleEndNotification(now: now)
    }

    /// End the current phase now, silently (finishing its exercise if it was
    /// that exercise's last work phase).
    func skipPhase(now: Date = .now) {
        guard isActive else { return }
        finishCurrentPhase(at: now, playCue: false)
        if isActive, !isRunning, let current {
            // Skipping while paused: stay paused at the start of the next phase.
            pausedRemaining = TimeInterval(current.seconds)
            remainingSeconds = current.seconds
        }
        if isRunning { scheduleEndNotification(now: now) }
    }

    /// The exercise's reps / sets / sides / timer (or a cardio's length or
    /// intensity) changed mid-run: rebuild
    /// its steps that haven't started, keeping the ones already done. The
    /// step now playing keeps its remaining time (and its detail, which
    /// describes that time). If the new plan has no step left to get ready
    /// for, the exercise finishes now; if the playing step is past the new
    /// plan, it becomes the last step.
    func replan(_ exercise: WorkoutSessionExercise, now: Date = .now) {
        guard isActive, let lo = phases.firstIndex(where: { $0.exerciseId == exercise.id }),
              let hi = phases.lastIndex(where: { $0.exerciseId == exercise.id }), hi >= index else { return }
        let freshWork = GuidedPlan.phases(for: [exercise], rests: rests)
        guard let first = freshWork.first else { return }
        var fresh = freshWork
        // Its lead-in (get-ready into a stretch, or the rest into a cardio
        // exercise) stays in front of it.
        if phases[lo].isTransition, let lead = GuidedPlan.leadIn(to: first, rests: rests) { fresh.insert(lead, at: 0) }
        let workLo = phases[lo].isTransition ? lo + 1 : lo
        let workPositions = fresh.indices.filter { !fresh[$0].isTransition }
        defer { if isRunning { scheduleEndNotification(now: now) } }

        // Steady cardio playing: one timed step. A new length moves its end
        // (the time already done stays done); a new intensity only changes
        // its detail. A length shorter than the time done finishes it now.
        if index == workLo, workLo == hi, freshWork.count == 1, exercise.sectionType == .cardio {
            let delta = TimeInterval(first.seconds - phases[index].seconds)
            phases[index] = first
            if isRunning, let end = phaseEnd {
                let newEnd = end.addingTimeInterval(delta)
                if newEnd <= now {
                    skipPhase(now: now)
                } else {
                    phaseEnd = newEnd
                    remainingSeconds = Int(ceil(newEnd.timeIntervalSince(now)))
                }
            } else if let paused = pausedRemaining {
                let left = paused + delta
                if left <= 0 {
                    skipPhase(now: now)
                } else {
                    pausedRemaining = left
                    remainingSeconds = Int(ceil(left))
                }
            }
            return
        }

        // Not reached yet: swap the whole block.
        guard index >= lo else {
            phases.replaceSubrange(lo...hi, with: fresh)
            return
        }

        let done = phases[lo..<index].filter { !$0.isTransition }.count
        let playing = phases[index]
        if !playing.isTransition {
            // Playing work step `done`: keep its time, re-plan what follows.
            // Past the new plan: label it as the same side in the last set.
            let n = workPositions.count
            let sides = max(1, exercise.sideLabels.count)
            let k = done < n ? done : min(n - 1, max(0, n - sides + done % sides))
            let q = workPositions[k]
            let ends = done >= n - 1
            let kept = fresh[q].with(seconds: playing.seconds, detail: playing.detail, endsExercise: ends)
            phases.replaceSubrange(index...hi, with: [kept] + (ends ? [] : Array(fresh[(q + 1)...])))
        } else if done < workPositions.count {
            // Getting ready for work step `done`.
            let q = workPositions[done]
            let lead = q > 0 ? fresh[q - 1] : playing
            phases.replaceSubrange(index...hi, with: [lead.with(seconds: playing.seconds)] + fresh[q...])
        } else {
            // Nothing left to get ready for: this exercise is done now.
            phases.removeSubrange(index...hi)
            if let next = current {
                remainingSeconds = next.seconds
                if isRunning {
                    phaseEnd = now.addingTimeInterval(TimeInterval(next.seconds))
                } else {
                    pausedRemaining = TimeInterval(next.seconds)
                }
                exerciseEnded(exercise.id, at: now)
            } else {
                exerciseEnded(exercise.id, at: now)
                runEnded(lastId: exercise.id)
            }
        }
    }

    /// The workout's rests changed mid-run: the get-readies and rests not
    /// started yet take the new lengths (one set to 0 is dropped). A rest
    /// turned on from none applies from the next run — it isn't in this plan.
    func updateRests(_ new: TypeRests, now: Date = .now) {
        rests = new
        guard isActive, index + 1 < phases.count else { return }
        var updated = Array(phases[...index])
        for p in phases[(index + 1)...] {
            guard p.isTransition else { updated.append(p); continue }
            let seconds = p.isRest ? new.cardioExercises
                : p.intoNewExercise ? new.stretchBetween : new.stretchWithin
            if seconds > 0 { updated.append(p.with(seconds: seconds)) }
        }
        phases = updated
        if isRunning { scheduleEndNotification(now: now) }
    }

    /// Abandon the run. Nothing further is marked complete.
    func stop() {
        ticker?.cancel()
        phases = []
        index = 0
        remainingSeconds = 0
        isRunning = false
        isActive = false
        phaseEnd = nil
        pausedRemaining = nil
        notifications.cancel(id: notificationId)
    }

    // MARK: - Ticking

    private func scheduleTick() {
        ticker?.cancel()
        ticker = Timer.publish(every: 0.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    /// Exposed for tests: advance the clock to `now`.
    func tick(now: Date = .now) {
        guard isRunning else { return }
        // Catch up across every phase that has ended (several, if the phone
        // was locked). Only a boundary crossed in the last ~1.5 s gets its cue.
        while isRunning, let end = phaseEnd, now >= end {
            finishCurrentPhase(at: end, playCue: now.timeIntervalSince(end) < 1.5)
        }
        guard isRunning, let end = phaseEnd, let current else { return }
        let remaining = max(0, Int(ceil(end.timeIntervalSince(now))))
        guard remaining != remainingSeconds else { return }
        remainingSeconds = remaining
        playCountdownCue(for: current, remaining: remaining)
    }

    private func playCountdownCue(for phase: GuidedPhase, remaining: Int) {
        if phase.isBetween {
            if remaining == 2 || remaining == 1 { SoundCues.shared.lowBeep() }
        } else if remaining == 1 && phase.seconds > 1 {
            SoundCues.shared.endChime()   // last second of a work timer
        }
    }

    /// Move past the current phase. `endedAt` is when it ended, so the next
    /// phase's end is chained from it (keeps the timeline exact after a
    /// background catch-up).
    private func finishCurrentPhase(at endedAt: Date, playCue: Bool) {
        guard let finished = current else { stop(); return }
        index += 1
        let next = current

        if let next {
            phaseEnd = endedAt.addingTimeInterval(TimeInterval(next.seconds))
            remainingSeconds = next.seconds
            // A transition ending = the next stretch starting: the high "go" beep.
            if playCue && finished.isBetween { SoundCues.shared.highBeep() }
        }
        if finished.endsExercise { exerciseEnded(finished.exerciseId, at: endedAt) }
        if next == nil { runEnded(lastId: finished.exerciseId) }
    }

    /// An exercise's last work phase is done: completed, unless this run
    /// leaves that to the user.
    private func exerciseEnded(_ id: UUID, at time: Date) {
        lastExerciseEndedAt = time
        if completesExercises { onExerciseFinished?(id) }
    }

    /// The final phase is done.
    private func runEnded(lastId: UUID) {
        stop()
        if completesExercises { onSequenceFinished?(lastId) } else { timerDoneExerciseId = lastId }
    }

    /// The user completed (or moved past) the exercise whose timer was done.
    func clearTimerDone() { timerDoneExerciseId = nil }

    private func scheduleEndNotification(now: Date) {
        guard let phaseEnd else { return }
        let rest = phases.dropFirst(index + 1).reduce(0) { $0 + $1.seconds }
        let total = Int(phaseEnd.timeIntervalSince(now).rounded()) + rest
        notifications.schedule(id: notificationId, after: total,
                               title: finishedTitle,
                               body: "Open the app to continue your workout.")
    }
}
