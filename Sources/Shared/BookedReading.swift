import Foundation
import SwiftData
import LiftCore

/// Where the Booked card's two halves come from: `SentPlan` rows for what was
/// asked, and the client's own days for what came back.
///
/// Separate from `PlanAndLog` itself, which holds the rule and knows nothing
/// about SwiftData -- the split `OutdoorDisplay` and `ClientRemoval` already
/// follow, so the rule can be tested on values alone.
extension PlanAndLog {

    /// Every plan sent to this client, decoded. A row whose payload no longer
    /// decodes is skipped rather than failing the card: it is a record of
    /// something already sent, and the rest of the card is still true.
    static func storedPlans(for clientID: String, in context: ModelContext) -> [StoredPlan] {
        SentPlans.forClient(clientID, in: context).compactMap(stored)
    }

    static func stored(_ row: SentPlan) -> StoredPlan? {
        guard let payload = try? JSONDecoder().decode(PlanPayload.self, from: row.payloadData)
        else { return nil }
        return StoredPlan(id: row.id.uuidString, clientID: row.clientID,
                          sentAtEpochSec: row.sentAtEpochSec, payload: payload)
    }

    /// The client's days, keyed by day key.
    static func loggedDays(of client: Client) -> [String: LoggedDay] {
        Dictionary(client.trainingDays.map { ($0.dayKey, loggedDay($0)) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// One day's sets, **in the order the client logged them** and grouped
    /// into lifts.
    ///
    /// `day.sets` is an unordered to-many, so the order comes from
    /// `ExerciseSet.orderIndex`, which the importer records off the wire. A
    /// set written before that existed has none and sorts last, keeping the
    /// order the store hands back: nothing is aligned against the asked row
    /// either way, so an old day prints both rows and claims no pairing.
    static func loggedDay(_ day: TrainingDay) -> LoggedDay {
        let ordered = day.sets.enumerated()
            .sorted { left, right in
                let a = left.element.orderIndex ?? Int.max
                let b = right.element.orderIndex ?? Int.max
                return a == b ? left.offset < right.offset : a < b
            }
            .map(\.element)

        var order: [String] = []
        var byKey: [String: Exercise] = [:]
        for set in ordered {
            let equipment = set.equipment ?? ""
            let key = matchKey(name: set.exerciseName, equipment: equipment)
            if byKey[key] == nil {
                byKey[key] = Exercise(key: key, name: set.exerciseName, equipment: equipment,
                                      eachSide: false, sets: [])
                order.append(key)
            }
            byKey[key]?.sets.append(SetValues(
                weightLb: set.weightLb,
                reps: set.reps.map(Double.init),
                rpe: set.rpe,
                durationSec: set.durationSec,
                distanceM: set.distanceMeters,
                side: set.side,
                isWarmup: set.isWarmup))
        }
        return LoggedDay(name: day.sessionName ?? "", exercises: order.compactMap { byKey[$0] })
    }

    /// The whole card for one client: what was sent, what came back, and the
    /// window they chose to send.
    static func compare(client: Client, in context: ModelContext,
                        today: String = DayKey.string(from: .now),
                        weeks: Int = 8, locale: Locale = .current) -> Result {
        compare(clientID: client.id,
                sentPlans: storedPlans(for: client.id, in: context),
                days: loggedDays(of: client),
                coverage: client.covered,
                unit: client.displayUnit,
                today: today,
                weeks: weeks,
                locale: locale)
    }
}
