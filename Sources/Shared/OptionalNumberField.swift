import Foundation

/// The format/parse pair for an optional numeric text field (a set's weight,
/// reps, RPE). Pulled out of `WorkoutEditorView` so it is testable without
/// SwiftUI, and — the actual point — so the two directions cannot drift
/// apart the way `Double.formatted()` (locale-aware) and `Double(trimmed)`
/// (US-only) did.
///
/// Both directions go through one `NumberFormatter` built from the same
/// locale, with grouping switched off. Grouping is what made the old pair
/// non-invertible: `1000.formatted()` in `en_US` renders `"1,000"`, which
/// `Double("1,000")` cannot parse (silently clears the prescription), and in
/// `de_DE` renders `"1.000"`, which `Double("1.000")` parses as `1.0` — a
/// silent 1000 lb to 1 lb corruption. With grouping off, `format` never
/// emits a separator `parse` doesn't expect, so the pair is an exact inverse
/// in every locale. A locale's own decimal separator (`,` in `de_DE`/`fr_FR`)
/// still round-trips correctly, and unparseable text (including a
/// deliberately-typed grouping separator like `"1.000"` in `de_DE`) comes
/// back `nil` rather than a corrupted value.
enum OptionalNumberField {
    private static func formatter(locale: Locale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        return formatter
    }

    static func string(from value: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let value else { return "" }
        return formatter(locale: locale).string(from: NSNumber(value: value)) ?? ""
    }

    static func value(from text: String, locale: Locale = .autoupdatingCurrent) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return formatter(locale: locale).number(from: trimmed)?.doubleValue
    }
}
