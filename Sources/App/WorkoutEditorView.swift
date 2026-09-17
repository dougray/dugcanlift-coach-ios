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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name", text: $routine.name)
                }

                ForEach(routine.orderedExercises) { exercise in
                    Section(exercise.displayName) {
                        ForEach(exercise.orderedSets) { set in
                            PrescribedSetRow(set: set)
                        }
                        Button("Add a set") {
                            let next = RoutinePrescribedSet(orderIndex: exercise.orderedSets.count)
                            next.exercise = exercise
                            context.insert(next)
                        }
                        .tint(Theme.accent)
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
        query = ""
        matches = []
    }
}

/// One prescribed set. Every field is optional on purpose: "five reps, you
/// pick the weight" is a real prescription, and so is a ten-minute row with
/// no reps at all. A blank field must stay blank rather than becoming zero.
struct PrescribedSetRow: View {
    @Bindable var set: RoutinePrescribedSet

    /// The weight as it was when this row appeared. An edit that returns the
    /// text to what was shown restores this exact value, not a reconversion.
    @State private var loadedWeightKg: Double?

    init(set: RoutinePrescribedSet) {
        self.set = set
        _loadedWeightKg = State(initialValue: set.targetWeightKg)
    }

    var body: some View {
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
