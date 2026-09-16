import Foundation
import LiftCore

/// Text for a client's saturated fat, sugar and sodium, kept free of SwiftUI so
/// it can be tested. Tracked, never targeted (SHARE-FORMAT.md "Saturated fat,
/// sugar and sodium"): no goals, bars or colours anywhere in it.
///
/// A port of Coach Android's `NutrientDisplay.kt` and `Stats.nutrientAverages`,
/// so the two apps say the same thing about the same client. A nutrient nobody
/// recorded produces no line at all rather than a zero or a dash -- a column of
/// dashes for three values most clients never log is noise.
enum NutrientDisplay {

    enum Nutrient: CaseIterable {
        case saturatedFat, sugar, sodium

        var label: String {
            switch self {
            case .saturatedFat: return "Saturated fat"
            case .sugar: return "Sugar"
            case .sodium: return "Sodium"
            }
        }

        var unit: String { self == .sodium ? "mg" : "g" }

        /// This nutrient's total on a day, or nil when no food that day recorded it.
        func total(_ totals: WireNutrientTotals) -> Double? {
            let value: Double?
            switch self {
            case .saturatedFat: value = totals.saturatedFatG
            case .sugar: value = totals.sugarG
            case .sodium: value = totals.sodiumMg
            }
            return value.flatMap { $0.isFinite ? $0 : nil }
        }

        /// How many of the day's `foods` this nutrient's total covers.
        func covered(_ totals: WireNutrientTotals) -> Int {
            switch self {
            case .saturatedFat: return totals.withSaturatedFat
            case .sugar: return totals.withSugar
            case .sodium: return totals.withSodium
            }
        }
    }

    /// A mean daily total over `days` days that recorded the nutrient,
    /// `partialDays` of them covering only some of that day's foods.
    struct Average: Equatable {
        let nutrient: Nutrient
        let perDay: Double
        let days: Int
        let partialDays: Int
    }

    /// True when at least one of the three totals is known.
    static func hasAnyTotal(_ totals: WireNutrientTotals) -> Bool {
        Nutrient.allCases.contains { $0.total(totals) != nil }
    }

    /// Grams to one decimal with a trailing ".0" dropped; milligrams whole and
    /// grouped: "21.5 g", "4 g", "1,840 mg".
    static func amount(_ value: Double, _ nutrient: Nutrient, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.roundingMode = .halfUp
        formatter.minimumFractionDigits = 0
        if nutrient == .sodium {
            formatter.usesGroupingSeparator = true
            formatter.maximumFractionDigits = 0
        } else {
            formatter.maximumFractionDigits = 1
        }
        let text = formatter.string(from: NSNumber(value: value)) ?? String(value)
        return "\(text) \(nutrient.unit)"
    }

    /// One line per recorded nutrient: "Sodium 1,840 mg", or "Sodium 1,840 mg ·
    /// from 3 of 5 foods" when the total covers only some of the day's foods --
    /// a partial total is a floor, not a day, and reading it as a day is exactly
    /// the mistake the counts exist to prevent.
    static func dayLines(_ totals: WireNutrientTotals?, locale: Locale = .autoupdatingCurrent) -> [String] {
        guard let totals else { return [] }
        return Nutrient.allCases.compactMap { nutrient in
            guard let total = nutrient.total(totals) else { return nil }
            let base = "\(nutrient.label) \(amount(total, nutrient, locale: locale))"
            let covered = nutrient.covered(totals)
            return covered < totals.foods ? "\(base) · from \(covered) of \(totals.foods) foods" : base
        }
    }

    /// The mean daily total of each nutrient over the `windowDays` days ending
    /// on `endKey` (inclusive), counting **only days that recorded it** -- a day
    /// with no sodium is not a zero-sodium day, and dividing by the window would
    /// say it was. A nutrient no day in the window recorded is left out, not
    /// averaged to zero. A partial day still counts, as the floor it is, and
    /// `partialDays` says how many there were.
    static func averages(_ days: [(dayKey: String, totals: WireNutrientTotals?)],
                         windowDays: Int, endKey: String) -> [Average] {
        guard windowDays > 0 else { return [] }
        let inWindow = days.compactMap { day -> WireNutrientTotals? in
            guard let totals = day.totals,
                  let distance = DayKey.daysBetween(day.dayKey, endKey),
                  distance >= 0, distance < windowDays else { return nil }
            return totals
        }
        return Nutrient.allCases.compactMap { nutrient in
            let recorded = inWindow.compactMap { totals in nutrient.total(totals).map { (totals, $0) } }
            guard !recorded.isEmpty else { return nil }
            return Average(nutrient: nutrient,
                           perDay: recorded.reduce(0) { $0 + $1.1 } / Double(recorded.count),
                           days: recorded.count,
                           partialDays: recorded.filter { nutrient.covered($0.0) < $0.0.foods }.count)
        }
    }

    /// "Sodium 2,105 mg a day · 4 days" -- how many days is always said, because
    /// an average of two days and of seven otherwise read the same. Partial days
    /// are named too: "· 4 days, 1 from only some foods".
    static func averageLine(_ average: Average, locale: Locale = .autoupdatingCurrent) -> String {
        let days = average.days == 1 ? "1 day" : "\(average.days) days"
        let partial = average.partialDays > 0 ? ", \(average.partialDays) from only some foods" : ""
        return "\(average.nutrient.label) \(amount(average.perDay, average.nutrient, locale: locale)) a day · \(days)\(partial)"
    }
}
