import Foundation

/// The rule for a prescribed set's weight field: stored in kilograms, shown
/// and typed in pounds.
///
/// Two defects lived in the view's inline binding before this existed.
///
/// 1. **The field showed the raw conversion.** A set stored as 79.38 kg
///    rendered `kgToLb(79.38)` with six fraction digits -- "175.002944" -- beside
///    a workout card reading "175 lb". The field now shows pounds to one
///    decimal, trimmed ("175", "137.5"), through `OptionalNumberField`'s
///    locale-aware formatter so the text reads back with its own parser.
///
/// 2. **Rounding for display must not write back.** Once the text is rounded,
///    reading it back and converting to kilograms gives a different number
///    than the one stored: 175 lb is 79.3786 kg, not 79.38. `kilograms(from:
///    stored:)` keeps the stored value whenever the text still says what
///    `text(kilograms:)` showed, so opening the editor and closing it changes
///    nothing. A value the coach actually changed is converted as typed.
enum PrescribedWeightField {

    /// Pounds are shown to this many decimals: a 2.5 lb plate or a 137.5 lb
    /// prescription reads exactly, and conversion noise never does.
    static let fractionDigits = 1

    /// The pounds a stored weight is shown as, already rounded.
    static func displayedPounds(kilograms: Double) -> Double {
        let scale = pow(10, Double(fractionDigits))
        return (PlanLinkEncoder.kgToLb(kilograms) * scale).rounded() / scale
    }

    /// The field's text for a stored weight. Blank stays blank.
    static func text(kilograms: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        OptionalNumberField.string(from: kilograms.map(displayedPounds(kilograms:)), locale: locale)
    }

    /// The kilograms to store for the field's text.
    ///
    /// Returns `stored` untouched when the text parses to exactly the pounds
    /// the field showed for it -- including "175.0" for a field showing "175".
    /// Blank or unparseable text is nil, as `OptionalNumberField` has it.
    static func kilograms(from text: String, stored: Double?,
                          locale: Locale = .autoupdatingCurrent) -> Double? {
        guard let pounds = OptionalNumberField.value(from: text, locale: locale) else { return nil }
        if let stored, pounds == displayedPounds(kilograms: stored) {
            return stored
        }
        return PlanLinkEncoder.lbToKg(pounds)
    }
}
