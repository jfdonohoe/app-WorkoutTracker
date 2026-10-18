//
//  RestSettingsSections.swift
//  WorkoutTracker
//
//  Rest – Strength, Rest – Stretching and Rest – Cardio (approved Figma "Rests
//  per exercise type"), at the bottom of the routine editor and the workout
//  screens. Each change is handed back whole through `rests`.
//

import SwiftUI

struct RestSettingsSections: View {
    @Binding var rests: TypeRests
    /// Under the last section; says that changing types has no rest.
    var footer: String = "Rests apply within each type. Moving from one type to the next (e.g. strength into cardio) has no rest."

    var body: some View {
        Section("Rest – Strength") {
            stepper("Between sets", \.strengthSets, in: 0...600, step: 15)
            stepper("Between exercises", \.strengthExercises, in: 0...600, step: 15)
        }
        Section("Rest – Stretching") {
            stepper("Between sides and sets", \.stretchWithin, in: 0...30, step: 1)
            stepper("Between stretches", \.stretchBetween, in: 0...60, step: 1)
        }
        Section {
            stepper("Between sets", \.cardioSets, in: 0...600, step: 15)
            stepper("Between exercises", \.cardioExercises, in: 0...600, step: 15)
        } header: {
            Text("Rest – Cardio")
        } footer: {
            Text(footer)
        }
    }

    private func stepper(_ label: String, _ key: WritableKeyPath<TypeRests, Int>,
                         in range: ClosedRange<Int>, step: Int) -> some View {
        let value = rests[keyPath: key]
        return Stepper("\(label): \(value == 0 ? "None" : "\(value)s")",
                       value: Binding(get: { rests[keyPath: key] },
                                      set: { var r = rests; r[keyPath: key] = $0; rests = r }),
                       in: range, step: step)
    }
}
