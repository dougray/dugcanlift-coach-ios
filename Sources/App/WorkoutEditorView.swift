import SwiftUI
import SwiftData
import LiftCore
import LiftReference

/// Edits one template. Exercises come from the bundled reference database,
/// searched offline — the same 873 the LIFT app picks from, so a
/// prescription names an exercise the client's app recognises.
struct WorkoutEditorView: View {
    @Bindable var routine: Routine
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var matches: [ExerciseRecord] = []

    @Query private var eachSideRows: [EachSideExercise]
    @Query private var sideRows: [PrescribedSetSide]
    /// Exercises whose coach tapped "Set a side". Not stored: once a set names
    /// a side the control stays because of that, and an untouched tap is
    /// nothing -- Coach web's `sidesAsked`.
    @State private var sidesAsked: Set<UUID> = []
    @Query private var groupRows: [ExerciseGroup]
    @Query private var kindRows: [PrescribedSetKind]
    /// Exercises whose coach tapped "Drop / rest-pause". Not stored, for the
    /// reason `sidesAsked` is not -- Coach web's `kindsAsked`.
    @State private var kindsAsked: Set<UUID> = []
    @State private var width: CGFloat = 0

    var body: some View {
        let sides = PrescriptionSides(eachSideRows: eachSideRows, sideRows: sideRows)
        let types = PrescriptionTypes(groupRows: groupRows, kindRows: kindRows)
        let exercises = routine.orderedExercises
        // "Superset A · A1" over a grouped exercise; nothing over any other.
        let labels = types.labels(exercises)
        return NavigationStack {
            List {
                Section {
                    TextField("Name", text: $routine.name)
                }

                ForEach(Array(exercises.enumerated()), id: \.element.id) { index, exercise in
                    let showsSides = sides.showsSides(exercise) || sidesAsked.contains(exercise.id)
                    let showsKinds = types.showsKinds(exercise) || kindsAsked.contains(exercise.id)
                    let kinds = types.kinds(of: exercise)
                    let sets = exercise.orderedSets
                    Section {
                        // What the exercise asks for, in words: "3 × 30 lb × 8
                        // each side + 1 L", "70 lb × 12, 50 lb × 10 drop".
                        Text(PrescriptionText.summary(exercise, sides: sides, types: types))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        // Every set on both sides: "3 × 8 each side" stays
                        // three rows. Starts ticked by the name, or as the
                        // coach last left this lift; the coach's answer sticks.
                        Toggle("Each side", isOn: Binding(
                            get: { sides.isEachSide(exercise) },
                            set: { setEachSide($0, for: exercise) }))
                            .tint(Theme.accent)
                        // Beside each side, on every exercise but the last,
                        // which has no next to join. Joining onto a superset
                        // makes a circuit; turning it off splits the group
                        // here. The rules are `ExerciseGrouping`'s.
                        if index + 1 < exercises.count {
                            Toggle("Superset with next", isOn: Binding(
                                get: { types.groupedWithNext(exercises, at: index) },
                                set: { PrescriptionTypes.setGroupedWithNext(
                                    $0, at: index, in: routine, context: context) }))
                                .tint(Theme.accent)
                                .accessibilityHint(types.groupedWithNext(exercises, at: index)
                                    ? "Done round by round with the next exercise, then the rest"
                                    : "Do this and the next exercise back to back, then rest")
                        }
                        ForEach(Array(sets.enumerated()), id: \.element.id) { setIndex, set in
                            // The first set has no kind control: there is no
                            // set before it to drop from or pause after.
                            let showsKind = showsKinds && setIndex > 0
                            let controls = (showsSides ? 1 : 0) + (showsKind ? 1 : 0)
                            PrescribedSetRow(set: set, side: sides.side(of: set),
                                             showsSide: showsSides,
                                             kind: kinds[setIndex], showsKind: showsKind,
                                             inline: AdaptiveLayout.showsSetControlsInline(
                                                width: width, controls: controls),
                                             setSide: { side in
                                PrescriptionSides.setSide(side, for: set.id, in: context)
                            }, setKind: { kind in
                                PrescriptionTypes.setKind(kind, for: set.id, in: context)
                            })
                        }
                        // Swipe a set away. Read from the same ordered list
                        // the rows were drawn from, so an offset is the set
                        // the coach swiped. The swipe animation finishes on a
                        // row that is already out of the list; the roster's
                        // swipe crash was a relationship read mid-animation,
                        // which this does not do.
                        .onDelete { offsets in
                            let sets = exercise.orderedSets
                            for set in offsets.map({ sets[$0] }) {
                                PrescriptionSides.removeSet(set, in: context)
                            }
                        }
                        HStack(spacing: 24) {
                            Button("Add a set") {
                                let next = RoutinePrescribedSet(orderIndex: exercise.orderedSets.count)
                                next.exercise = exercise
                                context.insert(next)
                            }
                            // A bench press editor looks exactly as it always
                            // did; the asymmetric case is one tap away.
                            if !showsSides {
                                Button("Set a side") { sidesAsked.insert(exercise.id) }
                                    .accessibilityHint("Mark a set as left or right only")
                            }
                            // Only from a second set: the first can never be
                            // a drop or rest-pause. Out of sight until asked
                            // for, so a straight-sets editor is unchanged.
                            if !showsKinds && sets.count > 1 {
                                Button("Drop / rest-pause") { kindsAsked.insert(exercise.id) }
                                    .accessibilityHint("Mark a set as a drop set or rest-pause")
                            }
                        }
                        .buttonStyle(.borderless)
                        .tint(Theme.accentText)
                        // Its own row, apart from Add a set, so a mis-tap
                        // there never removes the exercise.
                        Button("Remove \(exercise.displayName)", role: .destructive) {
                            PrescriptionSides.removeExercise(exercise, in: context)
                        }
                        .buttonStyle(.borderless)
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            if let label = labels[index] {
                                Text(label.text)
                                    .foregroundStyle(Theme.accentText)
                            }
                            Text(exercise.displayName)
                        }
                    }
                }

                Section("Add an exercise") {
                    TextField("Search", text: $query)
                        // `.task(id:)` cancels the previous search when the
                        // query changes, so a slower earlier keystroke cannot
                        // land after a faster later one and overwrite the
                        // results with stale matches. The sleep debounces a
                        // burst of typing into one query; it is cancelled
                        // along with everything else.
                        .task(id: query) {
                            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                                matches = []
                                return
                            }
                            try? await Task.sleep(for: .milliseconds(200))
                            guard !Task.isCancelled else { return }
                            let results = (try? await ReferenceDatabase.shared
                                .searchExercises(query, limit: 20)) ?? []
                            // Re-check after the await: cancellation can land
                            // during the search itself, not just during the
                            // debounce sleep, and a cancelled task must not
                            // assign stale results over a newer query's.
                            guard !Task.isCancelled else { return }
                            matches = results
                        }
                    ForEach(matches, id: \.id) { record in
                        Button(record.name) { add(record) }
                            .tint(Theme.textPrimary)
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .navigationTitle("Workout")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func add(_ record: ExerciseRecord) {
        let exercise = RoutineExercise(name: record.name,
                                       equipment: record.equipment ?? "",
                                       orderIndex: routine.orderedExercises.count)
        exercise.routine = routine
        context.insert(exercise)
        // Pre-ticked when the name reads unilateral, or as the coach last left
        // this lift. Absent when not, as it is stored and sent.
        if EachSideChoices.startsEachSide(name: exercise.name, equipment: exercise.equipment) {
            PrescriptionSides.setEachSide(true, for: exercise.id, in: context)
        }
        query = ""
        matches = []
    }

    private func setEachSide(_ on: Bool, for exercise: RoutineExercise) {
        PrescriptionSides.setEachSide(on, for: exercise.id, in: context)
        EachSideChoices.record(on, name: exercise.name, equipment: exercise.equipment)
    }
}

/// One prescribed set. Every field is optional on purpose: "five reps, you
/// pick the weight" is a real prescription, and so is a ten-minute row with
/// no reps at all. A blank field must stay blank rather than becoming zero.
struct PrescribedSetRow: View {
    @Bindable var set: RoutinePrescribedSet
    /// The side this set names; nil is both.
    var side: SetSide?
    /// Whether the Both / L / R control shows at all. Off for an exercise that
    /// is not each side and has no sided set, so a bench press row is the
    /// three number fields it always was.
    var showsSide = false
    /// This set's kind; nil is straight.
    var kind: SetKind?
    /// Whether the Straight / Drop / Rest-pause control shows. Never on an
    /// exercise's first set, and off until a set has a kind or the coach asks.
    var showsKind = false
    /// Beside the numbers when there is room, under them when there is not.
    var inline = false
    var setSide: (SetSide?) -> Void = { _ in }
    var setKind: (SetKind?) -> Void = { _ in }

    /// The weight as it was when this row appeared. An edit that returns the
    /// text to what was shown restores this exact value, not a reconversion.
    @State private var loadedWeightKg: Double?

    init(set: RoutinePrescribedSet, side: SetSide? = nil, showsSide: Bool = false,
         kind: SetKind? = nil, showsKind: Bool = false,
         inline: Bool = false, setSide: @escaping (SetSide?) -> Void = { _ in },
         setKind: @escaping (SetKind?) -> Void = { _ in }) {
        self.set = set
        self.side = side
        self.showsSide = showsSide
        self.kind = kind
        self.showsKind = showsKind
        self.inline = inline
        self.setSide = setSide
        self.setKind = setKind
        _loadedWeightKg = State(initialValue: set.targetWeightKg)
    }

    var body: some View {
        let controls = showsSide || showsKind
        if controls && !inline {
            VStack(alignment: .leading, spacing: 8) {
                numbers
                // Side by side under the numbers when the pair fits the row,
                // one above the other when it does not.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { pickers }
                    VStack(alignment: .leading, spacing: 8) { pickers }
                }
            }
        } else {
            HStack {
                numbers
                pickers
            }
        }
    }

    @ViewBuilder private var pickers: some View {
        if showsSide { sidePicker }
        if showsKind { kindPicker }
    }

    private var numbers: some View {
        HStack {
            // Pounds on screen, kilograms in storage. `PrescribedWeightField`
            // rounds the display and keeps the stored value when the text
            // still says what it showed, so an untouched field never writes a
            // kg -> lb -> kg drift back.
            DraftNumberField(
                label: "lb",
                load: { PrescribedWeightField.text(kilograms: set.targetWeightKg) },
                commit: {
                    set.targetWeightKg = PrescribedWeightField.kilograms(
                        from: $0, stored: loadedWeightKg)
                })
            // Format and parse both go through `OptionalNumberField`, one
            // locale-aware pair -- see its doc comment for why a `.formatted()`
            // getter paired with a `Double(trimmed)` setter is not safe here.
            DraftNumberField(
                label: "reps",
                load: { OptionalNumberField.string(from: set.targetReps.map(Double.init)) },
                commit: { set.targetReps = OptionalNumberField.value(from: $0).map { Int($0) } })
            DraftNumberField(
                label: "RPE",
                load: { OptionalNumberField.string(from: set.targetRPE) },
                commit: { set.targetRPE = OptionalNumberField.value(from: $0) })
        }
    }

    /// Both / L / R. A set that names a side is done on that side once,
    /// whether or not its exercise is each side.
    private var sidePicker: some View {
        Picker("Side", selection: Binding(get: { side }, set: { setSide($0) })) {
            Text("Both").tag(SetSide?.none).accessibilityLabel("Both sides")
            Text("L").tag(SetSide?.some(.left)).accessibilityLabel("Left")
            Text("R").tag(SetSide?.some(.right)).accessibilityLabel("Right")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 180)
        .tint(Theme.accentText)
    }

    /// Straight / Drop / Rest-pause: how this set follows the one before it.
    private var kindPicker: some View {
        Picker("Type", selection: Binding(get: { kind }, set: { setKind($0) })) {
            Text("Straight").tag(SetKind?.none).accessibilityLabel("Straight set")
            Text(SetKind.drop.displayName).tag(SetKind?.some(.drop))
                .accessibilityLabel("Drop set: no rest before it")
            Text(SetKind.restPause.displayName).tag(SetKind?.some(.restPause))
                .accessibilityLabel("Rest-pause: a short pause before it")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 280)
        .tint(Theme.accentText)
    }
}

/// A numeric text field that keeps the coach's own text while they type.
///
/// Bound straight through a formatter, every keystroke was re-rendered from
/// the stored number: "175." became "175" before the "5" could follow, and a
/// rounded display rewrote whatever extra precision had just been typed. The
/// text is loaded once, and each edit is committed to the model -- the model
/// never writes back into the text.
private struct DraftNumberField: View {
    let label: String
    let load: () -> String
    let commit: (String) -> Void

    @State private var text = ""
    /// The text last loaded or committed; nil until the field has loaded.
    @State private var committed: String?

    var body: some View {
        TextField(label, text: $text)
            .keyboardType(.decimalPad)
            .onAppear {
                guard committed == nil else { return }
                let initial = load()
                committed = initial
                text = initial
            }
            .onChange(of: text) { _, new in
                guard let committed, new != committed else { return }
                self.committed = new
                commit(new)
            }
    }
}
