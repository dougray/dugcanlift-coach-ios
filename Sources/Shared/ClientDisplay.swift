import Foundation

/// Pure display-formatting helpers for `ClientDetailView` and `RosterView` —
/// kept free of SwiftUI so they can be unit-tested directly.
///
/// Two rules, both of which were divergences from Coach Android before
/// (issue #7):
///
/// - **Weights are stored in pounds, always.** `Client.displayUnit` is a
///   rendering preference and nothing else. A converted value must never reach
///   storage, a statistic, or a comparison — the wire format, the backup file
///   and every calculation stay in pounds.
/// - **A lift's identity is name *and* equipment.** `SHARE-FORMAT.md` keys the
///   exercise dictionary as `"name|equipment"` precisely because a cable
///   pulldown and a machine pulldown are not the same lift.
enum ClientDisplay {

    /// 1 kg is this many pounds. Display only.
    static let lbPerKg = 2.2046226218

    /// Converts a stored pound weight for display in `unit` ("kg" or "lb").
    /// Never mutates stored data.
    static func weightValue(lb: Double, unit: String) -> Double {
        unit == "kg" ? lb / lbPerKg : lb
    }

    /// A stored pound weight formatted for `unit`, trimming a trailing ".0"
    /// but keeping one decimal otherwise. An absent weight renders as an em
    /// dash, never "0" — a set that was never logged is not a zero-weight set.
    static func weightText(lb: Double?, unit: String) -> String {
        guard let lb else { return "—" }
        return trimmed(weightValue(lb: lb, unit: unit))
    }

    /// `weightText` with the unit suffixed — "225 lb", "102.1 kg". An em dash
    /// is left bare rather than becoming "— kg".
    static func weightWithUnit(lb: Double?, unit: String) -> String {
        let value = weightText(lb: lb, unit: unit)
        return value == "—" ? value : "\(value) \(unit)"
    }

    /// The lift without its side -- `"name|equipment"`, which is how the
    /// share link's exercise dictionary spells a lift and what a chart card
    /// is titled with. Two sides of one lift share this.
    static func exerciseKey(name: String, equipment: String?) -> String {
        "\(name)|\(equipment ?? "")"
    }

    /// The key two lifts that must not be averaged together share nothing of:
    /// **name, equipment and side**.
    ///
    /// Equipment joined it because a cable pulldown and a machine pulldown are
    /// not the same lift, and charting them together produced one zig-zagging
    /// line that was the average of two honest trends. Side joins it for
    /// exactly the same reason (SHARE-FORMAT.md, "Tolerating the bits is not
    /// enough; Coach must group on side"): a left-arm row and a right-arm row
    /// are two lifts, and a Coach that reads the side bits and then charts as
    /// before has a *worse* chart than one that ignores them, because the two
    /// limbs are now genuinely interleaved.
    ///
    /// A two-sided lift keeps the key it always had -- the side part is empty,
    /// so one series, the same numbers, nothing to notice.
    static func liftKey(name: String, equipment: String?, side: SetSide? = nil) -> String {
        "\(exerciseKey(name: name, equipment: equipment))|\(side?.rawValue ?? "")"
    }

    /// Turns a key back into something a coach reads — "Back Squat
    /// (Barbell)", or the bare name when equipment is blank, matching an
    /// equipment-less exercise's empty string on the wire. A key carrying a
    /// side reads "Bulgarian Split Squat (Dumbbell) · Left".
    static func liftDisplayName(key: String) -> String {
        let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return key }
        let name = String(parts[0])
        let equipment = String(parts[1]).trimmingCharacters(in: .whitespaces)
        let base = equipment.isEmpty ? name : "\(name) (\(equipment))"
        guard parts.count > 2, let side = SetSide(rawValue: String(parts[2])) else { return base }
        return "\(base) · \(side.displayName)"
    }

    /// How the roster orders itself: quietest first, so the person who most
    /// needs attention is at the top and the list agrees with the silence
    /// banner above it. A client who has never logged is infinitely silent and
    /// sorts first, which is what the banner's own `?? Int.max` already assumed.
    ///
    /// Ties break on name so the order is stable rather than incidental.
    static func silenceRank(_ daysSinceLastLogged: Int?) -> Int {
        daysSinceLastLogged ?? Int.max
    }

    /// The days the session log lists: only those that actually hold sets or
    /// a run, walk or hike. Every stored day used to get a row, so a client
    /// who weighs in daily but trains elsewhere produced a run of rows that
    /// expanded to nothing. A day holding only an outdoor activity is still a
    /// session, as SHARE-FORMAT.md says it is still a day.
    static func sessionDays(_ days: [TrainingDay]) -> [TrainingDay] {
        days.filter { !$0.sets.isEmpty || !OutdoorDisplay.activities($0.outdoor).isEmpty }
            .sorted { $0.dayKey < $1.dayKey }
    }

    /// Quietest first, ties broken on name so the order is stable rather than
    /// incidental. `rank` is passed in so this stays free of the model's date
    /// handling and can be tested on its own.
    static func orderedBySilence<T>(_ items: [T],
                                    rank: (T) -> Int?,
                                    name: (T) -> String) -> [T] {
        items.sorted {
            let left = silenceRank(rank($0))
            let right = silenceRank(rank($1))
            if left != right { return left > right }
            return name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending
        }
    }

    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded(), abs(rounded) < 1e15 {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }
}
