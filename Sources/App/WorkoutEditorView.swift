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
                        .onChange(of: query) { _, text in
                            Task { matches = (try? await ReferenceDatabase.shared
                                .searchExercises(text, limit: 20)) ?? [] }
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

    var body: some View {
        HStack {
            optionalField("lb", value: Binding(
                get: { set.targetWeightKg.map { PlanLinkEncoder.kgToLb($0) } },
                set: { set.targetWeightKg = $0.map { PlanLinkEncoder.lbToKg($0) } }))
            optionalField("reps", value: Binding(
                get: { set.targetReps.map(Double.init) },
                set: { set.targetReps = $0.map { Int($0) } }))
            optionalField("RPE", value: $set.targetRPE)
        }
    }

    private func optionalField(_ label: String, value: Binding<Double?>) -> some View {
        TextField(label, text: Binding(
            get: { value.wrappedValue.map { $0.formatted() } ?? "" },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                value.wrappedValue = trimmed.isEmpty ? nil : Double(trimmed)
            }))
        .keyboardType(.decimalPad)
    }
}
