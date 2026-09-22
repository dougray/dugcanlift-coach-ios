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
    @State private var width: CGFloat = 0

    var body: some View {
        let sides = PrescriptionSides(eachSideRows: eachSideRows, sideRows: sideRows)
        let inline = AdaptiveLayout.showsSideControlInline(width: width)
        return NavigationStack {
            List {
                Section {
                    TextField("Name", text: $routine.name)
                }

                ForEach(routine.orderedExercises) { exercise in
                    let showsSides = sides.showsSides(exercise) || sidesAsked.contains(exercise.id)
                    Section {
                        // What the exercise asks for, in words: "3 × 30 lb × 8
                        // each side + 1 L".
                        Text(PrescriptionText.summary(exercise, sides: sides))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        // Every set on both sides: "3 × 8 each side" stays
                        // three rows. Starts ticked by the name, or as the
                        // coach last left this lift; the coach's answer sticks.
                        Toggle("Each side", isOn: Binding(
                            get: { sides.isEachSide(exercise) },
                            set: { setEachSide($0, for: exercise) }))
                            .tint(Theme.accent)
                        ForEach(exercise.orderedSets) { set in
                            PrescribedSetRow(set: set, side: sides.side(of: set),
                                             showsSide: showsSides, inline: inline) { side in
                                PrescriptionSides.setSide(side, for: set.id, in: context)
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
                        }
                        .buttonStyle(.borderless)
                        .tint(Theme.accent)
                    } header: {
                        Text(exercise.displayName)
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
    /// Beside the numbers when there is room, under them when there is not.
    var inline = false
    var setSide: (SetSide?) -> Void = { _ in }

    /// The weight as it was when this row appeared. An edit that returns the
    /// text to what was shown restores this exact value, not a reconversion.
    @State private var loadedWeightKg: Double?

    init(set: RoutinePrescribedSet, side: SetSide? = nil, showsSide: Bool = false,
         inline: Bool = false, setSide: @escaping (SetSide?) -> Void = { _ in }) {
        self.set = set
        self.side = side
        self.showsSide = showsSide
        self.inline = inline
        self.setSide = setSide
        _loadedWeightKg = State(initialValue: set.targetWeightKg)
    }

    var body: some View {
        if showsSide && !inline {
            VStack(alignment: .leading, spacing: 8) {
                numbers
                sidePicker
            }
        } else {
            HStack {
                numbers
                if showsSide { sidePicker }
            }
        }
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
        .tint(Theme.accent)
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
