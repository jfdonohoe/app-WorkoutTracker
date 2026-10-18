//
//  ExerciseEditorView.swift
//  WorkoutTracker
//
//  Create/edit a library Exercise. Name comes first and Notes last; between
//  them, the category (Strength · Stretch · Cardio) and subcategory
//  (ExerciseKind) decide which fields show — never a field the kind doesn't
//  use. Machine exercises have one block per machine (name, weight, settings,
//  photo); "Add another machine" adds a block, and the first machine is the
//  default. Other kinds keep one exercise-level photo, just above Notes.
//
//  Saving also writes the older fields (ExerciseLegacyFields) that routines
//  and workouts still read.
//
//  WHY this is presented as a SHEET (see ExerciseLibraryView):
//  A `ForEach` over a @State value array (the settings list) drove a 125% CPU
//  render loop that froze this screen when it was PUSHED onto Settings' stack
//  with no NavigationStack of its own. Presented as
//  `.sheet { NavigationStack { … } }`, those @State ForEach lists behave.
//  Uses Cancel/Save because a sheet has no back button.
//

import SwiftUI
import SwiftData
import UIKit

struct ExerciseEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(WeightUnit.storageKey) private var weightUnit: WeightUnit = .lb
    @AppStorage(DistanceUnit.storageKey) private var distanceUnit: DistanceUnit = .mi

    var existing: Exercise?
    /// When creating from a routine grouping, lock the new exercise to that category.
    var forcedGroup: SectionType? = nil
    /// Source of a NEW exercise: demo when created inside a demo routine or
    /// workout, so demo and user data never mix. An existing exercise keeps
    /// its own source.
    var newSource: DataSource = .user

    @State private var name = ""
    @State private var notes = ""
    @State private var category: SectionType = .strength
    @State private var kind: ExerciseKind = .machine
    @State private var reps = 10
    @State private var sets = 3
    @State private var perSide: PerSide = .single
    @State private var perSideCustom = ""
    @State private var weight: Double?
    @State private var implement: Implement?
    @State private var addedWeight: Double?
    @State private var holdSeconds = 30
    @State private var prop = ""
    /// Dynamic stretch: per-side timer for the guided flow; 0 = estimate.
    @State private var countTimerSeconds = 0
    @State private var durationMinutes = 20
    @State private var effort: Intensity = .moderate
    @State private var distance: Double?
    @State private var workSeconds = 30
    @State private var recoverySeconds = 30
    @State private var rounds = 8
    /// Strength: each set has its own weight and reps (MachineDraft.sets, or
    /// `plainSets` for Free weight / Bodyweight).
    @State private var varyBySet = false
    @State private var plainSets: [SetDraft] = []
    @State private var confirmSameEverySet = false
    /// One draft per machine (default first). Cardio kinds use at most one.
    @State private var machines: [MachineDraft] = [MachineDraft()]
    @State private var expandedSettings: Set<UUID> = []
    /// Machine whose rename dialog is showing.
    @State private var renamingMachine: UUID?
    @State private var nameDraft = ""
    @State private var photoData: Data?
    @State private var photoRequest: PhotoRequest?
    /// The photo block whose Camera / Choose Photo choice is showing.
    @State private var photoOptionsFor: PhotoTarget?
    @State private var showDeleteConfirm = false
    @State private var didLoad = false

    init(existing: Exercise? = nil, forcedGroup: SectionType? = nil, newSource: DataSource = .user) {
        self.existing = existing
        self.forcedGroup = forcedGroup
        self.newSource = newSource
    }

    private var isNew: Bool { existing == nil }

    struct SettingDraft: Identifiable, Equatable {
        let id = UUID()
        /// The stored definition this draft was loaded from, if any. Kept so a
        /// save UPDATES that definition instead of deleting and recreating it —
        /// session snapshots reference definitions by id.
        var definitionId: UUID? = nil
        var label = ""
        var useOther = false
        var numeric = 1
        var other = ""
        var isEmpty: Bool { label.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    struct SetDraft: Identifiable, Equatable {
        let id = UUID()
        var reps: Int
        var weight: Double
    }
    struct MachineDraft: Identifiable, Equatable {
        let id = UUID()
        /// The stored Machine this draft was loaded from (nil = new machine).
        var machineId: UUID? = nil
        var name = ""
        var weight: Double? = nil
        /// Vary by set: this machine's own sets.
        var sets: [SetDraft] = []
        var settings: [SettingDraft] = []
        var photoData: Data? = nil
    }
    /// ONE presentation for every photo source and target — a separate .sheet
    /// and .fullScreenCover on the same view conflict.
    struct PhotoTarget: Equatable {
        /// Machine draft that gets the photo; nil = the exercise itself.
        var machine: UUID?
    }

    struct PhotoRequest: Identifiable {
        enum Source { case library, camera }
        let id = UUID()
        var source: Source
        /// Machine draft that gets the photo; nil = the exercise itself.
        var machine: UUID?
    }

    /// Kinds whose machine block (name, settings, photo) shows. Machine is
    /// required; Steady and Intervals have one optional machine.
    private var showsMachineBlocks: Bool { [.machine, .steady, .intervals].contains(kind) }
    private var cardioMachineNamed: Bool {
        !(machines.first?.name.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }

    var body: some View {
        List {
            Section("Exercise") {
                LabeledContent("Name") {
                    TextField("e.g. Leg Press", text: $name)
                        .multilineTextAlignment(.trailing)
                }
                if isNew && forcedGroup == nil {
                    Picker("Category", selection: categorySelection) {
                        ForEach(SectionType.allCases) { Text($0.displayName).tag($0) }
                    }
                } else {
                    LabeledContent("Category", value: category.displayName)
                }
                Picker("Type", selection: kindSelection) {
                    ForEach(ExerciseKind.kinds(in: category)) { Text($0.displayName).tag($0) }
                }
            }

            kindFields

            if showsMachineBlocks {
                machineBlocks
            }
            if !showsMachineBlocks || (kind != .machine && !cardioMachineNamed) {
                Section("Photo") { photoRows(photo: photoData, machine: nil) }
            }

            Section("Notes") {
                TextField("Form cues, setup, how it felt", text: $notes, axis: .vertical)
                    .lineLimit(3...)
            }

            // Notes is the last field; Delete is an action, in its own card
            // below (approved Figma "Edit Exercise – v2").
            if !isNew {
                Section {
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Text("Delete exercise").frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(isNew ? "New Exercise" : "Edit Exercise")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .confirmationDialog("Delete this exercise?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete Exercise", role: .destructive) { deleteExercise() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will be removed from your library and your routines. Past workouts that used it are unaffected.")
        }
        .onAppear(perform: load)
        .confirmationDialog("Use the same for every set?", isPresented: $confirmSameEverySet, titleVisibility: .visible) {
            Button("Use set 1 for every set") { collapseToSameEverySet() }
            Button("Keep varying", role: .cancel) {}
        } message: {
            Text("Every set will be \(sameEverySetSummary).")
        }
        .alert("Rename machine",
               isPresented: Binding(get: { renamingMachine != nil }, set: { if !$0 { renamingMachine = nil } }),
               presenting: renamingMachine) { id in
            TextField("Machine name", text: $nameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let i = machines.firstIndex(where: { $0.id == id }) {
                    machines[i].name = nameDraft.trimmingCharacters(in: .whitespaces)
                }
            }
        } message: { _ in
            Text("A name is just a label, e.g. Y Circuit. Each exercise keeps its own machine.")
        }
        .fullScreenCover(item: $photoRequest) { request in
            switch request.source {
            case .library:
                PhotoLibraryPicker { data in setPhoto(data, machine: request.machine) }
            case .camera:
                CameraPicker { image in setPhoto(image.jpegData(compressionQuality: 0.8), machine: request.machine) }
                    .ignoresSafeArea()
            }
        }
    }

    /// The user picking a category or type starts it from that type's
    /// defaults. (Not onChange: loading an exercise sets these too, and must
    /// keep its saved values.)
    private var categorySelection: Binding<SectionType> {
        Binding(get: { category }, set: { new in
            guard new != category else { return }
            category = new
            kind = ExerciseKind.defaultKind(for: new)
            applyDefaults(for: kind)
        })
    }

    private var kindSelection: Binding<ExerciseKind> {
        Binding(get: { kind }, set: { new in
            guard new != kind else { return }
            kind = new
            applyDefaults(for: new)
            if varyBySet { carrySetsAcrossTypes() }
        })
    }

    // MARK: - Fields for each kind

    @ViewBuilder
    private var kindFields: some View {
        switch kind {
        case .machine:
            Section("Sets") {
                if !varyBySet {
                    repsPicker
                    setsPicker
                }
                perSideRow
                varyToggle
            }
        case .freeWeight:
            Section {
                if !varyBySet {
                    repsPicker
                    numberRow("Weight", value: $weight, step: 5, unit: weightUnit.rawValue)
                    setsPicker
                }
                perSideRow
                Picker("Implement", selection: $implement) {
                    Text("None").tag(Implement?.none)
                    ForEach(Implement.allCases) { Text($0.displayName).tag(Implement?.some($0)) }
                }
                varyToggle
            } header: {
                Text("Sets")
            } footer: {
                Text("For dumbbells, the weight is per hand.")
            }
            if varyBySet {
                Section { setRows($plainSets, weightTitle: "Weight") } header: { Text("Each set") }
            }
        case .bodyweight:
            Section {
                if !varyBySet {
                    repsPicker
                }
                perSideRow
                if !varyBySet {
                    setsPicker
                    numberRow("Added weight", value: $addedWeight, step: 5, unit: weightUnit.rawValue)
                }
                varyToggle
            } header: {
                Text("Sets")
            } footer: {
                Text("Added weight is optional, e.g. a vest or belt.")
            }
            if varyBySet {
                Section { setRows($plainSets, weightTitle: "Added weight") } header: { Text("Each set") }
            }
        case .hold:
            Section {
                secondsStepper("Hold time", $holdSeconds)
                repsPicker
                perSideRow
                setsPicker
            } footer: {
                Text("Reps is the number of holds in each set.")
            }
        case .staticStretch:
            Section {
                secondsStepper("Hold time", $holdSeconds)
                repsPicker
                perSideRow
                setsPicker
                LabeledContent("Prop") {
                    TextField("Optional: strap, wall…", text: $prop)
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text("Reps is holds per side. Sides cycle within a set, and more sets repeat the cycle. A different hold time needs its own exercise.")
            }
        case .dynamicStretch:
            Section {
                repsPicker
                perSideRow
                setsPicker
                Stepper("Timer per side: \(StretchTiming.resolvedCountSeconds(stored: countTimerSeconds, reps: reps)) s",
                        value: Binding(get: { StretchTiming.resolvedCountSeconds(stored: countTimerSeconds, reps: reps) },
                                       set: { countTimerSeconds = $0 }),
                        in: 5...600, step: 5)
            } footer: {
                Text("One full range of motion is one rep. The guided timer runs this long on each side (estimated from the reps until you change it).")
            }
        case .steady:
            Section {
                Stepper("Duration: \(durationMinutes) min", value: $durationMinutes, in: 5...300, step: 5)
                effortPicker
            }
        case .distance:
            Section {
                numberRow("Distance", value: $distance, step: distanceUnit.step, unit: distanceUnit.rawValue)
                effortPicker
                LabeledContent("Machine") {
                    TextField("Optional", text: machineNameBinding(0))
                        .multilineTextAlignment(.trailing)
                }
            }
        case .intervals:
            Section {
                secondsStepper("Work time", $workSeconds)
                secondsStepper("Recovery time", $recoverySeconds)
                Picker("Rounds", selection: $rounds) {
                    ForEach(PickRange.rounds, id: \.self) { Text("\($0)").tag($0) }
                }
                effortPicker
            } footer: {
                Text("Intensity applies to the work time.")
            }
        case .calisthenics:
            Section {
                repsPicker
                setsPicker
                perSideRow
            }
        }
    }

    /// Vary by set (strength only). On: today's Sets × Reps @ weight becomes
    /// that many sets to edit. Off: asks first, then every set takes set 1's
    /// values.
    private var varyToggle: some View {
        Toggle("Vary by set", isOn: Binding(
            get: { varyBySet },
            set: { on in
                if on { expandToSets(); varyBySet = true } else { confirmSameEverySet = true }
            }))
    }

    private func expandToSets() {
        let count = max(1, sets)
        func rows(_ w: Double) -> [SetDraft] { (0..<count).map { _ in SetDraft(reps: reps, weight: w) } }
        for i in machines.indices where machines[i].sets.isEmpty || !varyBySet {
            machines[i].sets = rows(machines[i].weight ?? 0)
        }
        plainSets = rows((kind == .bodyweight ? addedWeight : weight) ?? 0)
    }

    /// Changing Type while varying: an empty list (machine blocks after Free
    /// weight, or the plain list after Machine) takes the sets just shown.
    private func carrySetsAcrossTypes() {
        let shown = plainSets.isEmpty ? (machines.first?.sets ?? []) : plainSets
        guard !shown.isEmpty else { expandToSets(); return }
        func copy() -> [SetDraft] { shown.map { SetDraft(reps: $0.reps, weight: $0.weight) } }
        for i in machines.indices where machines[i].sets.isEmpty { machines[i].sets = copy() }
        if plainSets.isEmpty { plainSets = copy() }
    }

    /// Back to one Reps × weight: set 1's values, and the default list's count.
    private func collapseToSameEverySet() {
        let first = kind == .machine ? machines.first?.sets : plainSets
        if let list = first, let s1 = list.first {
            reps = min(max(s1.reps, PickRange.reps.lowerBound), PickRange.reps.upperBound)
            sets = min(max(list.count, PickRange.sets.lowerBound), PickRange.sets.upperBound)
        }
        for i in machines.indices {
            if let w = machines[i].sets.first?.weight { machines[i].weight = w > 0 ? w : nil }
        }
        if let w = plainSets.first?.weight {
            if kind == .bodyweight { addedWeight = w > 0 ? w : nil } else { weight = w > 0 ? w : nil }
        }
        varyBySet = false
    }

    private var sameEverySetSummary: String {
        let list = kind == .machine ? (machines.first?.sets ?? []) : plainSets
        guard let s1 = list.first else { return "the same" }
        guard s1.weight > 0 else { return "\(s1.reps) reps" }
        let plus = kind == .bodyweight ? "+" : ""
        return "\(plus)\(Self.number(s1.weight)) \(weightUnit.rawValue) × \(s1.reps)"
    }

    /// Numbered sets, each with its own weight and reps (approved v2 rows).
    @ViewBuilder
    private func setRows(_ list: Binding<[SetDraft]>, weightTitle: String) -> some View {
        ForEach(list) { $set in
            VStack(spacing: 8) {
                Stepper(value: $set.weight, in: 0...2000, step: 5) {
                    HStack(spacing: 12) {
                        SetNumberBadge(number: (list.wrappedValue.firstIndex { $0.id == set.id } ?? 0) + 1)
                        Text("\(weightTitle): \(Self.number(set.weight)) \(weightUnit.rawValue)")
                    }
                }
                Divider().padding(.leading, SetNumberBadge.size + 12)
                Stepper(value: $set.reps, in: PickRange.reps) {
                    Text("Reps: \(set.reps)").padding(.leading, SetNumberBadge.size + 12)
                }
            }
            .padding(.vertical, 2)
        }
        .onDelete { offsets in
            list.wrappedValue.remove(atOffsets: offsets)
            if list.wrappedValue.isEmpty { list.wrappedValue = [SetDraft(reps: reps, weight: 0)] }
        }
        Button {
            let last = list.wrappedValue.last ?? SetDraft(reps: reps, weight: 0)
            list.wrappedValue.append(SetDraft(reps: last.reps, weight: last.weight))
        } label: { Label("Add set (copies last)", systemImage: "plus.circle") }
        .disabled(list.wrappedValue.count >= PickRange.sets.upperBound)
    }

    private var repsPicker: some View {
        Picker("Reps", selection: $reps) {
            ForEach(PickRange.reps, id: \.self) { Text("\($0)").tag($0) }
        }
    }

    private var setsPicker: some View {
        Picker("Sets", selection: $sets) {
            ForEach(PickRange.sets, id: \.self) { Text("\($0)").tag($0) }
        }
    }

    @ViewBuilder
    private var perSideRow: some View {
        Picker("Per side", selection: $perSide) {
            ForEach(PerSide.allCases) { Text($0.displayName).tag($0) }
        }
        if perSide == .custom {
            TextField("Describe the sides", text: $perSideCustom)
        }
    }

    private var effortPicker: some View {
        Picker("Intensity", selection: $effort) {
            ForEach(Intensity.allCases) { Text($0.displayName).tag($0) }
        }
    }

    private func secondsStepper(_ title: String, _ value: Binding<Int>) -> some View {
        Stepper("\(title): \(value.wrappedValue) s", value: value, in: 5...600, step: 5)
    }

    /// An optional number in the approved stepper style ("Weight: 90 lb"),
    /// stepped by `step`. Blank ("—") until set; stepping below `step` clears it.
    private func numberRow(_ title: String, value: Binding<Double?>, step: Double, unit: String) -> some View {
        Stepper {
            Text("\(title): " + (value.wrappedValue.map { "\(Self.number($0)) \(unit)" } ?? "—"))
        } onIncrement: {
            value.wrappedValue = (value.wrappedValue ?? 0) + step
        } onDecrement: {
            guard let v = value.wrappedValue else { return }
            value.wrappedValue = v - step > 0 ? v - step : nil
        }
    }

    private static func number(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(v)
    }

    // MARK: - Machines

    @ViewBuilder
    private var machineBlocks: some View {
        // Binding-projected ForEach (not indices captured at render): deleting
        // a machine can't leave a row reading a stale, out-of-range index.
        ForEach($machines) { $draft in
            if kind == .machine || draft.id == machines.first?.id {
                Section {
                    if kind != .machine && !cardioMachineNamed {
                        // An optional cardio machine starts unnamed: name it here.
                        HStack {
                            TextField("Machine (optional)", text: $draft.name)
                            previousNamesMenu($draft)
                        }
                    }
                    if kind == .machine {
                        if varyBySet {
                            // Approved "Edit Exercise – v2": numbered sets.
                            HStack {
                                Text("Sets").fontWeight(.semibold)
                                Spacer()
                                Text("\(draft.sets.count)").foregroundStyle(.secondary)
                            }
                            setRows($draft.sets, weightTitle: "Weight")
                        } else {
                            numberRow("Weight", value: $draft.weight, step: 5, unit: weightUnit.rawValue)
                        }
                    }
                    if kind == .machine || cardioMachineNamed {
                        settingsRows($draft)
                        photoRows(photo: draft.photoData, machine: draft.id)
                    }
                    if kind == .machine && machines.count > 1 {
                        Button(role: .destructive) {
                            // Unlinked on save, never deleted (history may reference it).
                            let id = draft.id
                            machines.removeAll { $0.id == id }
                        } label: {
                            Text("Delete machine").frame(maxWidth: .infinity)
                        }
                    }
                } header: {
                    machineHeader(draft.id)
                }
            }
        }
        if kind == .machine {
            Section {
                Button {
                    // A new machine starts with the default machine's sets
                    // (weights usually differ, but the shape is the same).
                    var draft = MachineDraft(weight: machines.first?.weight)
                    draft.sets = (machines.first?.sets ?? []).map { SetDraft(reps: $0.reps, weight: $0.weight) }
                    machines.append(draft)
                    startRenaming(machines.count - 1)
                } label: { Label("Add another machine", systemImage: "plus.circle") }
            } footer: {
                Text("For when the usual machine is taken. Each machine keeps its own weight and settings; you pick one during the workout.")
            }
        }
    }

    /// Approved Figma machine header: the machine's name large and bold, a
    /// pencil to rename it (or pick a name used before), and DEFAULT /
    /// "Set as default" when there are several machines.
    @ViewBuilder
    private func machineHeader(_ id: UUID) -> some View {
        if kind != .machine && !cardioMachineNamed {
            Text("Machine")
        } else if let i = machines.firstIndex(where: { $0.id == id }) {
            machineTitleHeader(i)
        }
    }

    private func machineTitleHeader(_ i: Int) -> some View {
        HStack(spacing: 8) {
            Text(machineLabel(i))
                .font(.title3.bold())
                // Explicit: a section header otherwise greys its text.
                .foregroundStyle(Color(uiColor: .label))
                .lineLimit(1)
            Menu {
                Button("Rename…") { startRenaming(i) }
                if !previousMachineNames.isEmpty {
                    Section("Names used before") {
                        ForEach(previousMachineNames, id: \.self) { n in
                            Button(n) { machines[i].name = n }
                        }
                    }
                }
            } label: {
                Image(systemName: "pencil").font(.body.weight(.semibold))
            }
            .tint(Theme.accent)
            .accessibilityLabel("Rename machine")
            Spacer()
            if kind == .machine && machines.count > 1 {
                if i == 0 {
                    Text("DEFAULT")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.neutralBadge, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Button("Set as default") {
                        withAnimation { machines.move(fromOffsets: IndexSet(integer: i), toOffset: 0) }
                    }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .tint(Theme.accent)
                }
            }
        }
        .textCase(nil)
        .padding(.bottom, 4)
    }

    /// Display name, matching the fallback `save()` stores for an unnamed machine.
    private func machineLabel(_ i: Int) -> String {
        let n = machines[i].name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        let exercise = name.trimmingCharacters(in: .whitespaces)
        if exercise.isEmpty { return "Machine \(i + 1)" }
        return machines.count > 1 ? "\(exercise) \(i + 1)" : exercise
    }

    private func startRenaming(_ i: Int) {
        nameDraft = machines[i].name
        renamingMachine = machines[i].id
    }

    private func machineNameBinding(_ i: Int) -> Binding<String> {
        Binding(get: { machines.indices.contains(i) ? machines[i].name : "" },
                set: { if machines.indices.contains(i) { machines[i].name = $0 } })
    }

    /// Machine names used before, from the same demo/user side. A name is only
    /// a label: picking one doesn't link to that other exercise's machine.
    private var previousMachineNames: [String] {
        let source = existing?.sourceRaw ?? newSource.rawValue
        let all = (try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.deletedAt == nil && $0.sourceRaw == source }))) ?? []
        return Array(Set(all.map(\.name).filter { !$0.isEmpty })).sorted()
    }

    private func previousNamesMenu(_ draft: Binding<MachineDraft>) -> some View {
        Menu {
            ForEach(previousMachineNames, id: \.self) { n in
                Button(n) { draft.wrappedValue.name = n }
            }
        } label: {
            Image(systemName: "chevron.down.circle")
                .foregroundStyle(Theme.accent)
                .accessibilityLabel("Previous machine names")
        }
        .disabled(previousMachineNames.isEmpty)
    }

    @ViewBuilder
    private func settingsRows(_ draft: Binding<MachineDraft>) -> some View {
        let id = draft.wrappedValue.id
        Button {
            withAnimation { expandedSettings.formSymmetricDifference([id]) }
        } label: {
            HStack {
                Text("Settings").foregroundStyle(.primary)
                Spacer()
                Text("\(draft.wrappedValue.settings.filter { !$0.isEmpty }.count)").foregroundStyle(.secondary)
                Image(systemName: expandedSettings.contains(id) ? "chevron.down" : "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if expandedSettings.contains(id) {
            ForEach(draft.settings) { $setting in
                settingRow($setting)
            }
            .onDelete { draft.wrappedValue.settings.remove(atOffsets: $0) }
            if draft.wrappedValue.settings.count < Machine.maxSettings {
                Button { draft.wrappedValue.settings.append(SettingDraft()) } label: {
                    Label("Add setting", systemImage: "plus.circle")
                }
            }
        }
    }

    private func settingRow(_ setting: Binding<SettingDraft>) -> some View {
        HStack {
            TextField(kind == .machine ? "Label (Seat, Back…)" : "Label (Level, Incline…)", text: setting.label)
            Spacer()
            if setting.wrappedValue.useOther {
                TextField("Value", text: setting.other)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80)
            }
            Menu {
                ForEach(PickRange.settingValue, id: \.self) { n in
                    Button("\(n)") { setting.wrappedValue.useOther = false; setting.wrappedValue.numeric = n }
                }
                Button("Custom…") { setting.wrappedValue.useOther = true }
            } label: {
                Text(setting.wrappedValue.useOther ? "Custom" : "\(setting.wrappedValue.numeric)")
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    // MARK: - Photo

    @ViewBuilder
    private func photoRows(photo: Data?, machine: UUID?) -> some View {
        if let data = photo {
            // Whole image (no crop); animates + loops if it's a GIF.
            AnimatedImageView(data: data)
                .aspectRatio(AnimatedImageView.aspectRatio(of: data), contentMode: .fit)
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
        }
        // One button; Camera or Choose Photo is picked after (straight to the
        // library where there's no camera).
        Button {
            if CameraPicker.isAvailable { photoOptionsFor = PhotoTarget(machine: machine) }
            else { photoRequest = PhotoRequest(source: .library, machine: machine) }
        } label: {
            Label(photo == nil ? "Add photo" : "Replace photo", systemImage: "photo")
        }
        .confirmationDialog(photo == nil ? "Add photo" : "Replace photo",
                            isPresented: Binding(get: { photoOptionsFor?.machine == machine && photoOptionsFor != nil },
                                                 set: { if !$0 { photoOptionsFor = nil } }),
                            titleVisibility: .visible) {
            Button("Camera") { photoRequest = PhotoRequest(source: .camera, machine: machine) }
            Button("Choose Photo") { photoRequest = PhotoRequest(source: .library, machine: machine) }
        }
        if photo != nil {
            Button(role: .destructive) { setPhoto(nil, machine: machine) } label: {
                Label("Remove photo", systemImage: "trash")
            }
        }
    }

    private func setPhoto(_ data: Data?, machine: UUID?) {
        if let machine, let i = machines.firstIndex(where: { $0.id == machine }) {
            machines[i].photoData = data
        } else {
            photoData = data
        }
    }

    // MARK: - Defaults, load, save

    /// The spec's defaults for each kind, applied when the user picks it.
    private func applyDefaults(for kind: ExerciseKind) {
        switch kind {
        case .machine, .freeWeight, .bodyweight:
            reps = 10; sets = 3; perSide = .single
        case .hold:
            holdSeconds = 30; reps = 1; sets = 3; perSide = .single
        case .staticStretch:
            holdSeconds = 30; reps = 1; sets = 1; perSide = .leftRight
        case .dynamicStretch:
            reps = 10; sets = 1; perSide = .leftRight
        case .steady:
            durationMinutes = 20; effort = .moderate
        case .distance:
            effort = .moderate
        case .intervals:
            workSeconds = 30; recoverySeconds = 30; rounds = 8; effort = .hard
        case .calisthenics:
            reps = 15; sets = 3; perSide = .single
        }
    }

    private func load() {
        guard !didLoad else { return }
        defer { didLoad = true }
        guard let existing else {
            category = forcedGroup ?? .strength
            kind = ExerciseKind.defaultKind(for: category)
            applyDefaults(for: kind)
            return
        }
        // An exercise saved before the structure (e.g. just imported) gets
        // its kind first.
        if existing.kind == nil { ExerciseStructureMigration(context).run() }
        name = existing.name
        notes = existing.notes
        kind = existing.kind ?? ExerciseKind.defaultKind(for: existing.defaultSectionType)
        category = kind.section
        reps = existing.reps
        sets = existing.sets
        perSide = existing.perSide
        perSideCustom = existing.perSideCustom
        weight = existing.weight
        implement = existing.implement
        addedWeight = existing.addedWeight
        holdSeconds = existing.holdSeconds
        prop = existing.prop
        countTimerSeconds = existing.countTimerSeconds
        durationMinutes = existing.durationMinutes
        effort = existing.effort
        distance = existing.distance
        workSeconds = existing.workSeconds
        recoverySeconds = existing.recoverySeconds
        rounds = kind == .intervals ? existing.rounds : 8
        photoData = existing.photoData
        varyBySet = existing.varyBySet && kind.supportsVaryBySet
        plainSets = existing.defaultSets(for: nil).map { SetDraft(reps: $0.reps, weight: $0.weight) }
        let loaded: [MachineDraft] = existing.machineIds.compactMap { mid in
            guard let machine = try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == mid })).first
            else { return nil }
            var draft = MachineDraft(machineId: mid, name: machine.name, weight: machine.weight)
            draft.photoData = machine.photoData
            draft.sets = existing.defaultSets(for: mid).map { SetDraft(reps: $0.reps, weight: $0.weight) }
            draft.settings = machine.activeSettings.map {
                var d = SettingDraft(); d.definitionId = $0.id; d.label = $0.label
                if let n = $0.numericValue { d.numeric = n } else { d.useOther = true; d.other = $0.otherText ?? "" }
                return d
            }
            return draft
        }
        if varyBySet && plainSets.isEmpty && loaded.isEmpty { expandToSets() }
        if !loaded.isEmpty {
            machines = loaded
            // A photo saved on the exercise shows on its (default) machine, so
            // saving — which keeps machine exercises' photos on the machine —
            // doesn't drop it. Distance has no machine block, so it keeps its own.
            if machines[0].photoData == nil, kind != .distance { machines[0].photoData = existing.photoData }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let exercise = existing ?? Exercise(name: trimmed, source: newSource)
        if existing == nil { context.insert(exercise) }
        exercise.name = trimmed
        exercise.notes = notes
        exercise.kind = kind
        exercise.reps = reps
        exercise.sets = sets
        exercise.perSide = perSide
        exercise.perSideCustom = perSide == .custom ? perSideCustom : ""
        // Only the fields this kind uses are kept; the rest are cleared.
        exercise.weight = kind == .freeWeight ? weight : nil
        exercise.implement = kind == .freeWeight ? implement : nil
        exercise.addedWeight = kind == .bodyweight ? addedWeight : nil
        exercise.prop = kind == .staticStretch ? prop : ""
        exercise.distance = kind == .distance ? distance : nil
        exercise.holdSeconds = holdSeconds
        exercise.countTimerSeconds = countTimerSeconds
        exercise.durationMinutes = durationMinutes
        exercise.effort = effort
        exercise.workSeconds = workSeconds
        exercise.recoverySeconds = recoverySeconds
        exercise.rounds = kind == .intervals ? rounds : exercise.rounds
        exercise.updatedAt = .now

        // Machines: every block for a Machine exercise; one named machine for
        // cardio. Each belongs to this exercise and its demo/user side.
        let drafts: [MachineDraft]
        switch kind {
        case .machine: drafts = machines
        case .steady, .intervals, .distance: drafts = cardioMachineNamed ? Array(machines.prefix(1)) : []
        default: drafts = []
        }
        var saved: [Machine] = []
        for (i, draft) in drafts.enumerated() {
            let name = draft.name.trimmingCharacters(in: .whitespaces)
            let fallback = drafts.count > 1 ? "\(trimmed) \(i + 1)" : trimmed
            let machine: Machine
            if let mid = draft.machineId,
               let existingMachine = try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == mid })).first {
                machine = existingMachine
            } else {
                machine = Machine(name: fallback, source: exercise.source)
                context.insert(machine)
            }
            machine.name = name.isEmpty ? fallback : name
            machine.weight = kind == .machine ? draft.weight : nil
            // Distance shows only the machine's name: leave its photo and
            // settings as they are rather than clearing them.
            if kind != .distance {
                machine.photoData = draft.photoData
                applySettings(draft.settings, to: machine)
            }
            machine.updatedAt = .now
            saved.append(machine)
        }
        // Removed machines are just unlinked (never deleted — history may
        // still reference them).
        exercise.machineIds = saved.map(\.id)
        let photoBefore = exercise.photoData
        exercise.photoData = saved.isEmpty || kind == .distance ? photoData : nil
        // A photo picked or removed here is the user's choice: a sheet import
        // won't replace it or bring it back. (A machine exercise's photo
        // moving onto its machine isn't a choice.)
        if exercise.photoData != photoBefore {
            exercise.photoSetInApp = exercise.photoData != nil || saved.isEmpty || kind == .distance
        }

        // Vary by set: the sets as edited, per machine (or machine-less).
        exercise.varyBySet = varyBySet && kind.supportsVaryBySet
        if exercise.varyBySet {
            for d in exercise.defaultSets { context.delete(d) }
            exercise.defaultSets = []
            let lists: [(UUID?, [SetDraft])] = kind == .machine
                ? zip(saved, drafts).map { ($0.0.id, $0.1.sets) }
                : [(nil, plainSets)]
            let plainWeight = (kind == .bodyweight ? addedWeight : weight) ?? 0
            for (index, (machineId, edited)) in lists.enumerated() {
                // A list left empty gets Sets × Reps at its own weight, so it
                // never falls back to another machine's sets.
                let w = kind == .machine ? (drafts[index].weight ?? 0) : plainWeight
                let list = edited.isEmpty
                    ? (0..<max(1, sets)).map { _ in SetDraft(reps: reps, weight: w) }
                    : edited
                for (i, s) in list.enumerated() {
                    let row = ExerciseDefaultSet(order: i, reps: s.reps, weight: s.weight, machineId: machineId)
                    row.exercise = exercise
                    exercise.defaultSets.append(row)
                    context.insert(row)
                }
            }
        }

        ExerciseLegacyFields.write(exercise, machines: saved, context: context)
        // Push the change into every routine and workout in progress that uses it.
        CatalogSyncService(context).reconcileExercise(exercise.id)
        try? context.save()
        dismiss()
    }

    private func deleteExercise() {
        if let existing {
            existing.deletedAt = .now
            existing.updatedAt = .now
            RoutineRepository(context).removeExerciseFromAllRoutines(exerciseId: existing.id)
            WorkoutRepository(context).removeExerciseFromActiveSessions(exerciseId: existing.id)
            try? context.save()
        }
        dismiss()
    }

    /// Apply edited setting drafts to a machine's definitions.
    ///
    /// Definitions are UPDATED in place, not deleted and recreated: a recorded
    /// session's SessionMachineSetting points at a definition by id, and
    /// CatalogSyncService matches on that id. Removed settings are
    /// SOFT-deleted for the same reason.
    private func applySettings(_ drafts: [SettingDraft], to machine: Machine) {
        var existingById: [UUID: MachineSettingDefinition] = [:]
        for def in machine.settingDefinitions { existingById[def.id] = def }

        var keptIds = Set<UUID>()
        var order = 0
        for s in drafts where !s.isEmpty {
            let label = s.label.trimmingCharacters(in: .whitespaces)
            let numeric = s.useOther ? nil : s.numeric
            let other = s.useOther ? s.other : nil
            if let defId = s.definitionId, let def = existingById[defId] {
                def.label = label
                def.order = order
                def.numericValue = numeric
                def.otherText = other
                def.deletedAt = nil
                def.updatedAt = .now
                keptIds.insert(defId)
            } else {
                let def = MachineSettingDefinition(label: label, order: order,
                                                   numericValue: numeric, otherText: other,
                                                   source: machine.source)
                def.machine = machine
                machine.settingDefinitions.append(def)
                context.insert(def)
                keptIds.insert(def.id)
            }
            order += 1
        }
        for def in machine.settingDefinitions where !keptIds.contains(def.id) && def.deletedAt == nil {
            def.deletedAt = .now
            def.updatedAt = .now
        }
    }
}

/// Numbered set badge ("1", "2" … beside each set).
struct SetNumberBadge: View {
    static let size: CGFloat = 26
    var number: Int

    var body: some View {
        Text("\(number)")
            .font(.footnote.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: Self.size, height: Self.size)
            // Not tappable, so neutral gray rather than green.
            .background(Theme.neutralBadge, in: Circle())
            .accessibilityLabel("Set \(number)")
    }
}
