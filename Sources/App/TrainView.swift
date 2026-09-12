import SwiftUI
import SwiftData
import LiftCore

struct TrainView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Routine.createdAt, order: .reverse) private var routines: [Routine]
    @Query(sort: \Client.name) private var clients: [Client]
    @State private var editing: Routine?
    @State private var section: Section = .workouts

    // Owned here, not by `TrainPlanView`, so switching to Workouts and back
    // to Plan does not lose the picked client -- see that view's doc comment.
    @State private var planClientID: String = ""
    @State private var planWeekStart: String = DayKey.today
    @State private var planShareLink: String = ""

    /// Matches how the PWA's Train tab splits the same two jobs: a library of
    /// templates to build, and a client's week to book them onto and send.
    private enum Section: String, CaseIterable, Identifiable {
        case workouts = "Workouts"
        case plan = "Plan"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $section) {
                    ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()
                .tint(Theme.accent)

                switch section {
                case .workouts: library
                case .plan: TrainPlanView(clientID: $planClientID, weekStart: $planWeekStart,
                                          shareLink: $planShareLink)
                }
            }
            // The floating tab bar draws over scroll content. A List or Form
            // reserves space for it automatically; a raw ScrollView does not,
            // so the last card sits half-covered without this.
            .safeAreaPadding(.bottom, 72)
            .liftScreen()
            .background(Theme.background)
            .navigationTitle("Train")
            .sheet(item: $editing) { WorkoutEditorView(routine: $0) }
        }
    }

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                if routines.isEmpty {
                    LiftCard(title: "Workouts") {
                        Text("No workouts yet. Build one and you can schedule it "
                             + "across a client's week as often as you like.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                ForEach(routines) { routine in
                    LiftCard(title: routine.name) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(summary(of: routine))
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                            ForEach(routine.orderedExercises) { exercise in
                                Text("\(exercise.displayName) — \(prescription(of: exercise))")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            Button("Edit") { editing = routine }
                                .tint(Theme.accent)
                        }
                    }
                }
                Button("New workout") {
                    let routine = Routine(name: "New workout")
                    context.insert(routine)
                    editing = routine
                }
                .tint(Theme.accent)

                // The only route to a "here is the programme, nothing
                // booked yet" send. `link()`/`fragment()` inline only
                // templates a session actually books, so a coach with
                // nothing booked yet had no way to send a library at all --
                // PLAN-FORMAT allows it (testALibrarySendCarriesWorkouts-
                // WithNoSessions), but no screen could reach that call.
                // Sends every current template; the constraints allow zero,
                // one, or many workouts with no sessions, and picking a
                // subset is more UI than this needs.
                if !routines.isEmpty {
                    Menu("Send programme") {
                        if clients.isEmpty {
                            Text("No clients yet")
                        } else {
                            ForEach(clients) { client in
                                ShareLink(item: programmeLink(for: client)) {
                                    Text(client.name)
                                }
                            }
                        }
                    }
                    .tint(Theme.accent)
                }
            }
            .padding()
        }
    }

    private func programmeLink(for client: Client) -> String {
        let fragment = PlanLinkEncoder.fragment(
            routines: routines, sessions: [], lifterID: client.id,
            coachName: PlanLinkEncoder.coachName(UserDefaults.standard.string(forKey: "coachName")))
        return "https://www.dugcanlift.com/lift/#" + fragment
    }

    private func summary(of routine: Routine) -> String {
        let exercises = routine.orderedExercises
        let sets = exercises.reduce(0) { $0 + $1.orderedSets.count }
        return "\(exercises.count) exercise\(exercises.count == 1 ? "" : "s") · "
             + "\(sets) set\(sets == 1 ? "" : "s")"
    }

    /// Collapses only when every set is identical — "3 × 5 @ 225". A ramp
    /// lists its sets, because 225/225/245 has no collapsed form.
    private func prescription(of exercise: RoutineExercise) -> String {
        let sets = exercise.orderedSets
        guard let first = sets.first else { return "no sets yet" }
        let texts = sets.map(text(for:))
        if sets.count > 1, Set(texts).count == 1 {
            return "\(sets.count) × \(text(for: first))"
        }
        return texts.joined(separator: ", ")
    }

    private func text(for set: RoutinePrescribedSet) -> String {
        var parts: [String] = []
        if let kg = set.targetWeightKg {
            parts.append("\(Int(PlanLinkEncoder.kgToLb(kg).rounded())) lb")
        }
        if let reps = set.targetReps { parts.append("\(reps)") }
        if let rpe = set.targetRPE { parts.append("RPE \(rpe.formatted())") }
        if let seconds = set.targetDurationSec { parts.append("\(seconds)s") }
        if let metres = set.targetDistanceMeters { parts.append("\(Int(metres))m") }
        return parts.isEmpty ? "—" : parts.joined(separator: " × ")
    }
}
