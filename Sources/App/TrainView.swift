import SwiftUI
import SwiftData
import LiftCore

struct TrainView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Routine.createdAt, order: .reverse) private var routines: [Routine]
    @Query(sort: \Client.name) private var clients: [Client]
    @Query private var sessions: [ScheduledSession]
    @Query private var eachSideRows: [EachSideExercise]
    @Query private var sideRows: [PrescribedSetSide]
    @State private var editing: Routine?
    @State private var confirmingDelete: Routine?
    @State private var section: Section = .workouts

    // Owned here, not by `TrainPlanView`, so switching to Workouts and back
    // to Plan does not lose the picked client -- see that view's doc comment.
    // Scene storage rather than @State: switching the top tabs tears this
    // whole view down, and @State went with it, so the picked client reset
    // every time the coach looked at another tab. Shared by Cook and Train, so
    // planning one client's meals and then their training keeps the same pick.
    @SceneStorage("planClientID") private var planClientID: String = ""
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
                // Capped so the segments do not spread across an iPad;
                // narrower than any iPhone, so no change there.
                .frame(maxWidth: AdaptiveLayout.readableWidth)
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
            .coachScreen()
            .background(Theme.background)
            // The tab row above already names this screen, and the browser build
            // goes straight from its tabs into the content.
            .navigationBarTitleDisplayMode(.inline)
            .regularWidthTitle("Train")
            .focusedSceneValue(\.coachNewItem, section == .workouts
                               ? CoachNewItem(title: "New Workout", action: newWorkout) : nil)
            .sheet(item: $editing) { WorkoutEditorView(routine: $0) }
            .alert(confirmingDelete.map { "Delete \($0.name)?" } ?? "",
                   isPresented: Binding(get: { confirmingDelete != nil },
                                        set: { if !$0 { confirmingDelete = nil } }),
                   presenting: confirmingDelete) { routine in
                Button("Delete", role: .destructive) {
                    ScheduledSession.deleteRoutineAndSessions(routine, from: sessions, in: context)
                    confirmingDelete = nil
                }
                Button("Keep", role: .cancel) { confirmingDelete = nil }
            } message: { routine in
                Text(ScheduledSession.deleteWarning(
                    bookings: ScheduledSession.bookingCount(of: routine, in: sessions)))
            }
        }
    }

    private var library: some View {
        let sides = PrescriptionSides(eachSideRows: eachSideRows, sideRows: sideRows)
        return AdaptiveScrollPage { width in
            let columns = AdaptiveLayout.columns(for: width, maxColumns: 3)
            if routines.isEmpty {
                LiftCard(title: "Workouts") {
                    Text("No workouts yet. Build one and you can schedule it "
                         + "across a client's week as often as you like.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            // Above the grid when there is one, for the reason Cook's library
            // does the same.
            if columns > 1 { HStack(spacing: 28) { libraryActions; Spacer(minLength: 0) } }

            if !routines.isEmpty {
                AdaptiveGrid(routines, columns: columns) { routine in
                    LiftCard(title: routine.name) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(summary(of: routine))
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                            ForEach(routine.orderedExercises) { exercise in
                                Text("\(exercise.displayName) — "
                                     + PrescriptionText.summary(exercise, sides: sides))
                                    .font(.caption)
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            Spacer(minLength: 0)
                            HStack {
                                Button("Edit") { editing = routine }
                                    .tint(Theme.accent)
                                Spacer()
                                // Confirms first, saying how many booked
                                // days it empties, as Coach web and Android
                                // do; the delete itself sweeps this routine's
                                // `ScheduledSession` rows in the same action --
                                // see `ScheduledSession.deleteRoutineAndSessions`.
                                // Also the way to discard a "New workout"
                                // stub left behind by dismissing the editor
                                // without changing anything.
                                Button("Delete", role: .destructive) {
                                    confirmingDelete = routine
                                }
                            }
                        }
                        .fillsGridCell()
                    }
                }
            }

            if columns == 1 { libraryActions }
        }
    }

    @ViewBuilder
    private var libraryActions: some View {
        Button("New workout", action: newWorkout)
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

    private func newWorkout() {
        section = .workouts
        let routine = Routine(name: "New workout")
        context.insert(routine)
        editing = routine
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
}
