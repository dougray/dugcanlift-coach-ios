import Foundation
import LiftCore

/// Reading and formatting rules for a client's runs, walks and hikes
/// (SHARE-FORMAT.md "Outdoor"). A port of Coach web's `coach/route.js`, kept
/// free of SwiftUI so the strings are tested rather than eyeballed.
///
/// Stored values are the wire's: metres and seconds. Miles or kilometres is
/// decided here, at the point of display, from the client's weight unit --
/// the same rule `ClientDisplay` follows for pounds.
enum OutdoorDisplay {

    static let metersPerMile = 1609.344

    /// Shown under the map. The sender trims the route; Coach never does.
    static let trimNote = "The first and last 200 m are left off by the client's app."

    /// "Run", "Walk", "Hike", or nil for a type no reader could label.
    static func typeLabel(_ type: Int) -> String? {
        switch type {
        case 0: return "Run"
        case 1: return "Walk"
        case 2: return "Hike"
        default: return nil
        }
    }

    // MARK: - Reading

    /// A day's activities, skipping any of an unknown type rather than
    /// guessing at a label.
    static func activities(_ stored: [WireOutdoorActivity]) -> [WireOutdoorActivity] {
        stored.filter { typeLabel($0.type) != nil }
    }

    /// Bests of a known type, or nil when none remain.
    static func bests(_ stored: [WireOutdoorBest]?) -> [WireOutdoorBest]? {
        let known = (stored ?? []).filter { typeLabel($0.type) != nil }
        return known.isEmpty ? nil : known
    }

    /// The route's points, or nil when it is absent, of an unknown type, or
    /// decodes to fewer than two points -- nothing a map could draw.
    static func routePoints(_ route: WireLastRoute?) -> [OutdoorShareCoordinate]? {
        guard let route, typeLabel(route.type) != nil else { return nil }
        let points = OutdoorShare.decodePolyline(route.polyline)
        return points.count >= 2 ? points : nil
    }

    // MARK: - Formatting

    /// Miles for a client who reads pounds, kilometres for one who reads kilograms.
    static func distanceUnit(weightUnit: String) -> String {
        weightUnit == "kg" ? "km" : "mi"
    }

    /// "28:40", or "1:02:10" past an hour.
    static func durationText(seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "6.21 mi". `String(format:)` is locale-invariant, as `toFixed` is.
    static func distanceText(meters: Double, unit: String) -> String {
        String(format: "%.2f %@", meters / unitMeters(unit), unit)
    }

    /// "8:03 /mi" from seconds per kilometre.
    static func paceText(secondsPerKm: Double, unit: String) -> String {
        let per = roundHalfUp(secondsPerKm / 1000 * unitMeters(unit))
        return String(format: "%d:%02d /%@", per / 60, per % 60, unit)
    }

    /// An activity's own pace, only from 1 km up -- shorter is mostly GPS
    /// noise, the same line LIFT draws for a best.
    static func activityPace(distanceMeters: Int, durationSec: Int, unit: String) -> String? {
        guard Double(distanceMeters) >= OutdoorShare.minimumPaceDistanceMeters, durationSec > 0 else { return nil }
        return paceText(secondsPerKm: Double(durationSec) / Double(distanceMeters) * 1000, unit: unit)
    }

    /// A duration, or an em dash for none. The wire has no null here, so a
    /// zero is the only "not measured" it can say, and blank stays blank.
    static func durationOrDash(_ seconds: Int) -> String {
        seconds > 0 ? durationText(seconds: seconds) : "—"
    }

    /// "Run · 2 activities".
    static func bestHeading(_ best: WireOutdoorBest) -> String {
        let label = typeLabel(best.type) ?? ""
        return "\(label) · \(best.count) \(best.count == 1 ? "activity" : "activities")"
    }

    /// Farthest, longest and fastest pace, an em dash for each best the client
    /// has none of. A best of zero is treated as none: it would read as a
    /// real, terrible record.
    static func bestStats(_ best: WireOutdoorBest, unit: String) -> (farthest: String, longest: String, fastest: String) {
        (positive(best.farthestMeters).map { distanceText(meters: Double($0), unit: unit) } ?? "—",
         positive(best.longestSec).map { durationText(seconds: $0) } ?? "—",
         positive(best.fastestSecPerKm).map { paceText(secondsPerKm: Double($0), unit: unit) } ?? "—")
    }

    /// Distance, time and pace for the last route's card.
    static func routeStats(_ route: WireLastRoute, unit: String) -> (distance: String, time: String, pace: String) {
        (distanceText(meters: Double(route.distanceMeters), unit: unit),
         durationOrDash(route.durationSec),
         activityPace(distanceMeters: route.distanceMeters, durationSec: route.durationSec, unit: unit) ?? "—")
    }

    /// "Run 6.21 mi, Walk 0.19 mi" -- a day's line in the session log.
    static func daySummary(_ stored: [WireOutdoorActivity], unit: String) -> String {
        activities(stored)
            .map { "\(typeLabel($0.type) ?? "") \(distanceText(meters: Double($0.distanceMeters), unit: unit))" }
            .joined(separator: ", ")
    }

    /// "6.21 mi · 50:00" -- one activity in the Recent list.
    static func activityLine(_ activity: WireOutdoorActivity, unit: String) -> String {
        "\(distanceText(meters: Double(activity.distanceMeters), unit: unit)) · \(durationOrDash(activity.durationSec))"
    }

    /// "Sep 20" -- the day a Recent row happened, as a person writes it.
    ///
    /// A port of Coach Android's `formatShortDay`, down to its fallback: a key
    /// that does not parse is printed as it stands rather than vanishing, so a
    /// row never loses its date. The day log and the Weeks table deliberately
    /// keep the raw key, because Android's do too -- a dense list of days reads
    /// as a column of keys in both, and that string changes in both builds or
    /// in neither.
    static func shortDayText(_ dayKey: String) -> String {
        guard let date = DayKey.date(from: dayKey) else { return dayKey }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private static func unitMeters(_ unit: String) -> Double {
        unit == "km" ? 1000 : metersPerMile
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    /// `Math.round`: halves go up.
    private static func roundHalfUp(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let floor = value.rounded(.down)
        return Int(value - floor >= 0.5 ? floor + 1 : floor)
    }
}
