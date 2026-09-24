import Foundation
import SwiftData
import CryptoKit
import LiftCore

/// One row per send: the plan payload as JSON **exactly as it was encoded**,
/// with the canonical hash of it.
///
/// Coach built a plan link fresh on every render and handed it straight to a
/// `ShareLink`, so once a workout template was edited the store no longer said
/// what the client got -- and the client page could never put what was booked
/// beside what came back. `TrainView`'s own delete warning already admitted
/// it: "A plan already sent to a client is unaffected -- it left as a link."
///
/// **The payload, not the fragment.** A fragment needs inflating on every read
/// and a future `v` would make it unreadable; the decoded payload is a few
/// hundred bytes for a training week and survives a version bump. **The whole
/// payload, not the training half**: `r`, `m` and `rf` cost almost nothing and
/// leave "did they eat the plan?" open without a second migration.
///
/// Coach's own `@Model`, like `ScheduledSession` and `EachSideExercise`, and
/// for the same reason: nothing in LiftKit is touched, so this is a new entity
/// here and nothing at all for LIFT iOS. No cascade reaches a row carrying a
/// client id as a plain value, so `ClientRemoval` sweeps them itself.
///
/// Coach web stores the same five fields in `coach.sentPlans`; Coach Android
/// stores them in a Room entity; all three write them into a backup under
/// `sentPlans` (BACKUP-FORMAT.md), so one file moves between them.
@Model
final class SentPlan {
    var id: UUID = UUID()
    var clientID: String = ""
    /// Epoch seconds, as the backup carries it.
    var sentAtEpochSec: Int = 0
    /// SHA-256 over the payload's canonical form -- see `SentPlans.hash`.
    var payloadHash: String = ""
    /// The payload's JSON, byte for byte what went into the link.
    var payloadData: Data = Data()

    init(id: UUID = UUID(), clientID: String, sentAtEpochSec: Int,
         payloadHash: String, payloadData: Data) {
        self.id = id
        self.clientID = clientID
        self.sentAtEpochSec = sentAtEpochSec
        self.payloadHash = payloadHash
        self.payloadData = payloadData
    }
}

/// Recording a send, and the rules about which rows are kept.
///
/// A value-type surface with no view in it, for the reason `ClientRemoval`,
/// `LinkImportMacros` and `MacroFields` are: these decide what a coach is told
/// about a client's week, and a rule living in a view's `@State` cannot be
/// tested. A port of Coach web's `plan-log.js` -- `record`, `forClient`,
/// `mergeBackup`, `canonical` and `hash`, rule for rule.
enum SentPlans {

    /// The newest sends kept per client. A backup must not grow without limit,
    /// and a coach reading eight weeks back has never needed more than this.
    static let cap = 26

    // MARK: - Reading

    /// This client's rows, newest first.
    static func forClient(_ clientID: String, in context: ModelContext) -> [SentPlan] {
        let all = (try? context.fetch(FetchDescriptor<SentPlan>())) ?? []
        return forClient(clientID, in: all)
    }

    /// The same order, over rows already in hand.
    static func forClient(_ clientID: String, in rows: [SentPlan]) -> [SentPlan] {
        rows.filter { $0.clientID == clientID }
            .sorted { $0.sentAtEpochSec > $1.sentAtEpochSec }
    }

    // MARK: - Recording a send

    /// Records `payload` as sent to `clientID`, and returns the row it is in.
    ///
    /// A send whose hash matches this client's **newest** send replaces it,
    /// keeping its `id`: an abandoned share sheet is re-shared identically a
    /// moment later, and that is one plan, not two -- and a backup written
    /// before and one written after then merge as one row rather than as two.
    /// An older matching send is left alone: a coach who went back to last
    /// week's plan after a week of something else did send it again, and both
    /// dates are true.
    ///
    /// Pruned to the newest `cap` rows for this client, oldest first. Other
    /// clients' rows are never touched.
    @discardableResult
    static func record(payload: Data, clientID: String, in context: ModelContext,
                       now: Date = .now) -> SentPlan? {
        guard !clientID.isEmpty, !payload.isEmpty else { return nil }
        let digest = hash(payload: payload)
        let sentAt = Int(now.timeIntervalSince1970)
        let mine = forClient(clientID, in: context)

        let row: SentPlan
        if let newest = mine.first, newest.payloadHash == digest {
            newest.sentAtEpochSec = sentAt
            newest.payloadData = payload
            row = newest
        } else {
            row = SentPlan(clientID: clientID, sentAtEpochSec: sentAt,
                           payloadHash: digest, payloadData: payload)
            context.insert(row)
        }
        prune(clientID: clientID, in: context)
        return row
    }

    /// Keeps the newest `cap` rows for one client and deletes the rest.
    static func prune(clientID: String, in context: ModelContext) {
        let mine = forClient(clientID, in: context)
        guard mine.count > cap else { return }
        for row in mine.dropFirst(cap) { context.delete(row) }
    }

    // MARK: - The canonical form, and its hash

    /// SHA-256 of the canonical form, hex -- the same digest LIFT iOS's
    /// `PlanImporter.hash(of:)` and Coach web's `CoachPlanLog.hash` compute,
    /// so the same plan has the same hash wherever it is recorded.
    ///
    /// Taken from the payload's canonical re-encode rather than from the
    /// bytes as they arrived, so a payload that has been through a backup
    /// file hashes the same as the one that was sent.
    static func hash(payload: Data) -> String {
        let bytes = Data(canonical(payload: payload).utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// JSON with every object's keys in sorted order, at every depth. Arrays
    /// keep their order: `k` is a list of bookings and reordering it would be
    /// a different plan. Unreadable JSON canonicalises to itself as a string,
    /// so a hash is always available and two identical payloads still match.
    static func canonical(payload: Data) -> String {
        guard let value = try? JSONSerialization.jsonObject(
            with: payload, options: [.fragmentsAllowed]) else {
            return String(decoding: payload, as: UTF8.self)
        }
        return canonical(value)
    }

    private static func canonical(_ value: Any) -> String {
        switch value {
        case let dictionary as [String: Any]:
            // JavaScript sorts keys by code unit; every key in a plan payload
            // is ASCII, where that and Swift's scalar order agree.
            let pairs = dictionary.keys
                .sorted { left, right in
                    left.unicodeScalars.map(\.value)
                        .lexicographicallyPrecedes(right.unicodeScalars.map(\.value))
                }
                .map { "\(quoted($0)):\(canonical(dictionary[$0] ?? NSNull()))" }
            return "{" + pairs.joined(separator: ",") + "}"
        case let array as [Any]:
            return "[" + array.map(canonical).joined(separator: ",") + "]"
        case let string as String:
            return quoted(string)
        case is NSNull:
            return "null"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return numberText(number.doubleValue)
        default:
            return "null"
        }
    }

    /// `JSON.stringify`'s number: an integral value carries no decimal point.
    private static func numberText(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    /// `JSON.stringify`'s string: the two mandatory escapes, the named control
    /// characters, `\u00xx` for the rest, and everything else literal --
    /// which is what `JSONEncoder` writes too.
    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// Arbitrary JSON, so a sent plan's payload rides in a backup file **as an
/// object** rather than as a string of escaped JSON -- the shape
/// BACKUP-FORMAT.md shows and the one Coach web and Coach Android write, so
/// one file moves between all three. Coach never looks inside it here: it is
/// stored as sent, and `PlanPayload` is what reads it.
enum AnyJSON: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AnyJSON])
    case object([String: AnyJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([AnyJSON].self) { self = .array(value); return }
        if let value = try? container.decode([String: AnyJSON].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "not JSON")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // An integral value is written without a decimal point, as every
            // other writer of this file writes one.
            if value == value.rounded(), abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// The JSON bytes this value stands for, keys sorted -- the canonical
    /// form a `SentPlan` stores and hashes.
    var data: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    init?(data: Data) {
        guard let value = try? JSONDecoder().decode(AnyJSON.self, from: data) else { return nil }
        self = value
    }
}

extension PlanLinkEncoder {

    /// Records what a share sheet is about to hand over, and returns the row.
    ///
    /// **Recorded when the coach opens the share sheet**, not when a client
    /// receives anything: `ShareLink` has no completion handler and no
    /// platform sees into a mail app. A plan a coach shared and then abandoned
    /// may be recorded, which is the accepted cost -- the card says so in its
    /// own words and never claims the link arrived, and an abandoned share is
    /// re-shared identically a moment later, which the hash reads as one plan
    /// rather than two.
    ///
    /// `fragment` and `json` stay side-effect-free: a size note and a
    /// `.task(id:)` re-encode on every render, and recording from there would
    /// file a plan nobody sent. This is the one call that writes, so a screen
    /// that sends a plan cannot forget to record it -- the rule `json` already
    /// follows for prescribed sides.
    ///
    /// The payload is re-encoded here from the same inputs the link was built
    /// from, so the bytes recorded are the bytes that went. A record that
    /// cannot be written must never stop a plan being sent.
    ///
    /// **A send that books no day is not recorded**, and a day is `k` or `m`:
    /// a session booked, or a meal booked. A library send -- recipes or
    /// workouts with nothing scheduled -- and a picks-only send book no day,
    /// show as no group on the card, and would take one of the 26 rows kept
    /// per client for nothing.
    ///
    /// `m` counts as of the day meals reached the Booked card. Before that
    /// this read `k` alone, which meant **Cook's send was never filed at
    /// all** -- so a coach who plans food had no record of what they sent,
    /// and the meal rows could never appear however the card was written.
    /// Coach iOS sends two links where Coach web sends one, Cook's week and
    /// Train's, so on this platform a group is meals or training and not
    /// both; the rule reads a payload either way.
    ///
    /// The guard lives here rather than at a call site for the reason `json`
    /// reads prescribed sides itself: a screen cannot get it wrong.
    @discardableResult
    static func recordSend(routines: [Routine] = [], sessions: [ScheduledSession] = [],
                           recipes: [Recipe] = [], meals: [PlannedMeal] = [],
                           sides: PrescriptionSides? = nil, roadPicks: [String] = [],
                           lifterID: String, coachName: String,
                           in context: ModelContext, now: Date = .now) -> SentPlan? {
        guard !lifterID.isEmpty,
              let payload = json(routines: routines, sessions: sessions, recipes: recipes,
                                 meals: meals, sides: sides, roadPicks: roadPicks,
                                 lifterID: lifterID, coachName: coachName),
              let decoded = try? JSONDecoder().decode(PlanPayload.self, from: payload),
              decoded.k?.isEmpty == false || decoded.m?.isEmpty == false
        else { return nil }
        let row = SentPlans.record(payload: payload, clientID: lifterID, in: context, now: now)
        try? context.save()
        return row
    }
}
