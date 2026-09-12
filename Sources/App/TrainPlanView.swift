import SwiftUI
import SwiftData
import LiftCore

/// A client's week: which template is booked on which day, and the link that
/// sends it.
struct TrainPlanView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Client.name) private var clients: [Client]
    @Query private var sessions: [ScheduledSession]
    @Query(sort: \Routine.name) private var routines: [Routine]

    @State private var clientID: String = ""
    @State private var weekStart: String = DayKey.today

    private var days: [String] {
        (0..<7).compactMap { DayKey.adding(days: $0, to: weekStart) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                LiftCard(title: "Client") {
                    Picker("Client", selection: $clientID) {
                        Text("Pick a client").tag("")
                        ForEach(clients) { Text($0.name).tag($0.id) }
                    }
                    .tint(Theme.accent)
                }

                ForEach(days, id: \.self) { day in
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
                            Menu("Book a workout") {
                                ForEach(routines) { routine in
                                    Button(routine.name) { book(routine, on: day) }
                                }
                            }
                            .tint(Theme.accent)
                            .disabled(clientID.isEmpty)
                        }
                    }
                }

                if !clientID.isEmpty {
                    ShareLink(item: link()) { Text("Send this week") }
                        .tint(Theme.accent)
                }
            }
            .padding()
        }
        .liftScreen()
        .background(Theme.background)
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

    /// Only the templates this week actually books are inlined, which is what
    /// keeps a week inside a link an email client will not mangle.
    private func link() -> String {
        let mine = sessions.filter { $0.clientID == clientID && days.contains($0.dayKey) }
        let used = routines.filter { routine in mine.contains { $0.routineID == routine.id } }
        let fragment = PlanLinkEncoder.fragment(
            routines: used, sessions: mine,
            lifterID: clientID,
            coachName: UserDefaults.standard.string(forKey: "coachName") ?? "Your coach")
        return "https://www.dugcanlift.com/lift/#" + fragment
    }
}
