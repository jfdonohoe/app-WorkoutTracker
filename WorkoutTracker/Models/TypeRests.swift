//
//  TypeRests.swift
//  WorkoutTracker
//
//  Rests per exercise type (approved Figma "Rests per exercise type"), set on
//  the routine and copied into each workout:
//
//   • Strength: between sets, between exercises (the routine's two original
//     rests).
//   • Stretching: between sides and sets (every get-ready inside a stretch)
//     and between stretches (the get-ready into the next one). Default 5 s.
//   • Cardio: between sets (set-based cardio such as Calisthenics; Intervals
//     keep their own recovery) and between exercises (default 0: back to back).
//
//  Moving from one exercise type to the next has no rest.
//

import Foundation

struct TypeRests: Equatable {
    var strengthSets: Int
    var strengthExercises: Int
    var stretchWithin: Int
    var stretchBetween: Int
    var cardioSets: Int
    var cardioExercises: Int

    /// What a routine or workout saved before these settings starts with.
    static let standard = TypeRests(strengthSets: 60, strengthExercises: 60,
                                    stretchWithin: StretchTiming.transitionSeconds,
                                    stretchBetween: StretchTiming.transitionSeconds,
                                    cardioSets: 60, cardioExercises: 0)

    /// Rest between two sets of an exercise of this type.
    func betweenSets(_ type: SectionType) -> Int {
        switch type {
        case .strength: return strengthSets
        case .cardio: return cardioSets
        case .stretching: return stretchWithin
        }
    }

    /// Rest from one exercise to the next of the SAME type. (A stretch's is
    /// its get-ready, played by the guided run.)
    func betweenExercises(_ type: SectionType) -> Int {
        switch type {
        case .strength: return strengthExercises
        case .cardio: return cardioExercises
        case .stretching: return stretchBetween
        }
    }
}

extension RoutineVersion {
    var rests: TypeRests {
        get {
            TypeRests(strengthSets: defaultRestBetweenSets, strengthExercises: defaultRestBetweenExercises,
                      stretchWithin: stretchRestWithin, stretchBetween: stretchRestBetween,
                      cardioSets: cardioRestBetweenSetsOverride ?? defaultRestBetweenSets,
                      cardioExercises: cardioRestBetweenExercises)
        }
        set {
            defaultRestBetweenSets = newValue.strengthSets
            defaultRestBetweenExercises = newValue.strengthExercises
            stretchRestWithin = newValue.stretchWithin
            stretchRestBetween = newValue.stretchBetween
            cardioRestBetweenSetsOverride = newValue.cardioSets
            cardioRestBetweenExercises = newValue.cardioExercises
        }
    }
}

extension WorkoutSession {
    var rests: TypeRests {
        get {
            TypeRests(strengthSets: restBetweenSets, strengthExercises: restBetweenExercises,
                      stretchWithin: stretchRestWithin, stretchBetween: stretchRestBetween,
                      cardioSets: cardioRestBetweenSetsOverride ?? restBetweenSets,
                      cardioExercises: cardioRestBetweenExercises)
        }
        set {
            restBetweenSets = newValue.strengthSets
            restBetweenExercises = newValue.strengthExercises
            stretchRestWithin = newValue.stretchWithin
            stretchRestBetween = newValue.stretchBetween
            cardioRestBetweenSetsOverride = newValue.cardioSets
            cardioRestBetweenExercises = newValue.cardioExercises
        }
    }
}
