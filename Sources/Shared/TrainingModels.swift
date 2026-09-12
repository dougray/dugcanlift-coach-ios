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
