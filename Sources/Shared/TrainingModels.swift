import Foundation
import SwiftData
import LiftCore

/// One booking of a workout template onto one client's day.
///
/// Holds `clientID` and `routineID` as plain values rather than SwiftData
/// relationships, on purpose. A `Routine` is a template a coach reuses across
/// clients and weeks; a relationship would make deleting a client or a
/// template drag bookings around by cascade rules that do not match how a
/// coach thinks. Look-ups are by predicate on these two fields.
///
/// `clientID` matches `Client.id` — the lifter id from the share link, not a
/// SwiftData `PersistentIdentifier`, so it survives a backup round trip.
@Model
final class ScheduledSession {
    var id: UUID = UUID()
    var clientID: String = ""
    /// Local day, `yyyy-MM-dd`, via `LiftCore.DayKey`.
    var dayKey: String = ""
    var routineID: UUID = UUID()
    var createdAt: Date = Date.now

    init(clientID: String, dayKey: String, routineID: UUID) {
        self.id = UUID()
        self.clientID = clientID
        self.dayKey = dayKey
        self.routineID = routineID
        self.createdAt = .now
    }
}

extension ScheduledSession {
    /// Deletes a `Routine` and every `ScheduledSession` booked against it, in
    /// one action.
    ///
    /// `routineID` is a plain `UUID`, not a relationship (see this project's
    /// CLAUDE.md, "Train"), so SwiftData's delete rules do not reach these
    /// rows -- deleting a routine on its own orphans them silently. This is
    /// the reaper the ledger has been waiting on; call it from every place a
    /// `Routine` can be deleted rather than deleting the routine directly.
    static func deleteRoutineAndSessions(
        _ routine: Routine, from sessions: [ScheduledSession], in context: ModelContext
    ) {
        for session in sessions where session.routineID == routine.id {
            context.delete(session)
        }
        context.delete(routine)
    }

    /// How many bookings deleting `routine` would empty, across every client.
    static func bookingCount(of routine: Routine, in sessions: [ScheduledSession]) -> Int {
        sessions.filter { $0.routineID == routine.id }.count
    }

    /// The confirmation's message. Coach web and Coach Android both confirm a
    /// workout delete and say how many booked days it empties; this says the
    /// same, so a coach moving between them is never surprised by an empty
    /// week.
    static func deleteWarning(bookings: Int) -> String {
        guard bookings > 0 else { return "This cannot be undone." }
        let times = bookings == 1 ? "once" : "\(bookings) times"
        return "It is booked \(times) across your clients' weeks; those days will be "
             + "emptied too. A plan already sent to a client is unaffected — it left as a link."
    }
}
