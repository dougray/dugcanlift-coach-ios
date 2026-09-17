import SwiftUI
import SwiftData
import LiftCore

/// A client's week: which template is booked on which day, and the link that
/// sends it.
///
/// `clientID`/`weekStart`/`shareLink` are owned by `TrainView`, not this
/// view, and passed down as bindings. `TrainView`'s section switch gives
/// `.workouts` and `.plan` each their own branch, and only one branch exists
/// in the hierarchy at a time -- `@State` living here would be torn down the
/// moment a coach switches to Workouts and rebuilt from scratch on the way
/// back, silently losing the picked client.
struct TrainPlanView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Client.name) private var clients: [Client]
    @Query private var sessions: [ScheduledSession]
    @Query(sort: \Routine.name) private var routines: [Routine]

    @Binding var clientID: String
    @Binding var weekStart: String
    @Binding var shareLink: String

    private var days: [String] { PlanWeek(startDayKey: weekStart).days }

    var body: some View {
        AdaptiveScrollPage { width in
            let weekGrid = AdaptiveLayout.showsWeekGrid(width: width)
            let columns = AdaptiveLayout.columns(for: width, maxColumns: 3)

            PlanClientCard(clientID: $clientID, weekStart: $weekStart,
                           clients: clients, wide: columns > 1)

            if weekGrid {
                // The whole week at a glance, a column a day.
                AdaptiveGrid(days, id: \.self, columns: 7) { day in
                    LiftCard {
                        VStack(alignment: .leading, spacing: 8) {
                            DayColumnHeading(dayKey: day)
                            ForEach(booked(on: day)) { session in
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(name(of: session.routineID))
                                        .foregroundStyle(Theme.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    Button {
                                        context.delete(session)
                                    } label: {
                                        Image(systemName: "xmark.circle")
                                    }
                                    .accessibilityLabel("Remove \(name(of: session.routineID))")
                                    .tint(Theme.accent)
                                }
                                .font(.caption)
                            }
                            bookMenu(on: day, title: "Book")
                                .font(.caption)
                        }
                        .fillsGridCell()
                    }
                }
            } else {
                AdaptiveGrid(days, id: \.self, columns: columns) { day in
                    LiftCard(title: day) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(booked(on: day)) { session in
                                HStack {
                                    Text(name(of: session.routineID))
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Button("Remove") { context.delete(session) }
                                        .tint(Theme.accent)
                                }
                                .font(.caption)
                            }
                            bookMenu(on: day, title: "Book a workout")
                        }
                        .fillsGridCell()
                    }
                }
            }

            if !mineSessions.isEmpty {
                // `link` is computed into state, not called inline.
                // Inline, it re-ran the filter, a JSON encode and a
                // DEFLATE on every body evaluation -- including every
                // unrelated redraw of this screen.
                //
                // Gated on there being at least one booking this week --
                // previously this appeared as soon as a client was
                // picked, and tapping it with nothing booked shipped an
                // import prompt offering nothing. A programme with no
                // bookings yet is still sendable, via "Send programme"
                // on the Workouts section instead.
                ShareLink(item: shareLink) { Text("Send this week") }
                    .tint(Theme.accent)
            }
        }
        // The bottom inset for the floating tab bar is applied once, by the
        // parent `TrainView` (which every section shares). Applying it here
        // too nested the padding inside itself, so scrolling this section to
        // the end landed on an empty 72pt-plus-72pt gap.
        .coachScreen()
        .task(id: rebuildKey) {
            shareLink = link()
        }
        .background(Theme.background)
    }

    /// What the share link depends on. `.task(id:)` reruns when any of these
    /// changes and not otherwise.
    ///
    /// Keyed on the actual content that ends up on the wire, not counts --
    /// the old key was `sessionCount`/`routineCount`, which stayed the same
    /// across a routine rename or a weight edit, so the link kept shipping
    /// stale content, and `coachName` was not in the key at all, so setting
    /// it in Connect and coming back still sent the old name. `Routine`/
    /// `RoutinePrescribedSet` carry no modification timestamp to key on
    /// instead, so this mirrors the exact fields `link()` encodes.
    private struct RebuildKey: Equatable {
        let clientID: String
        let weekStart: String
        let coachName: String
        let bookings: [Booking]
        let templates: [Template]

        struct Booking: Equatable { let day: String; let routineID: UUID }
        struct Template: Equatable { let id: UUID; let name: String; let exercises: [Exercise] }
        struct Exercise: Equatable {
            let name: String, equipment: String, note: String?, sets: [SetValues]
        }
        struct SetValues: Equatable {
            let weightKg: Double?, reps: Int?, rpe: Double?
            let durationSec: Int?, distanceMeters: Double?
        }
    }

    private var rebuildKey: RebuildKey {
        RebuildKey(
            clientID: clientID, weekStart: weekStart, coachName: coachName,
            bookings: mineSessions.map { .init(day: $0.dayKey, routineID: $0.routineID) },
            templates: usedRoutines.map { routine in
                .init(id: routine.id, name: routine.name, exercises: routine.orderedExercises.map { exercise in
                    .init(name: exercise.name, equipment: exercise.equipment, note: exercise.note,
                          sets: exercise.orderedSets.map { set in
                              .init(weightKg: set.targetWeightKg, reps: set.targetReps, rpe: set.targetRPE,
                                    durationSec: set.targetDurationSec, distanceMeters: set.targetDistanceMeters)
                          })
                })
            })
    }

    private func bookMenu(on day: String, title: String) -> some View {
        Menu(title) {
            ForEach(routines) { routine in
                Button(routine.name) { book(routine, on: day) }
            }
        }
        .tint(Theme.accent)
        .disabled(clientID.isEmpty)
    }

    private func booked(on day: String) -> [ScheduledSession] {
        sessions.filter { $0.clientID == clientID && $0.dayKey == day }
    }

    private func name(of routineID: UUID) -> String {
        routines.first { $0.id == routineID }?.name ?? "Removed workout"
    }

    private func book(_ routine: Routine, on day: String) {
        context.insert(ScheduledSession(clientID: clientID, dayKey: day, routineID: routine.id))
    }

    private var coachName: String {
        PlanLinkEncoder.coachName(UserDefaults.standard.string(forKey: "coachName"))
    }

    /// This week's bookings for the picked client.
    private var mineSessions: [ScheduledSession] {
        sessions.filter { $0.clientID == clientID && days.contains($0.dayKey) }
    }

    /// Only the templates this week actually books are inlined, which is what
    /// keeps a week inside a link an email client will not mangle.
    private var usedRoutines: [Routine] {
        routines.filter { routine in mineSessions.contains { $0.routineID == routine.id } }
    }

    private func link() -> String {
        let fragment = PlanLinkEncoder.fragment(
            routines: usedRoutines, sessions: mineSessions,
            lifterID: clientID, coachName: coachName)
        return "https://www.dugcanlift.com/lift/#" + fragment
    }
}
