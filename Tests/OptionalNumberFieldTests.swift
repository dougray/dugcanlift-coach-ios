import XCTest
@testable import Coach

/// `PrescribedSetRow`'s weight/reps/RPE fields used to format with
/// `Double.formatted()` (locale-aware) and parse with `Double(trimmed)`
/// (US-only). The two were not inverses: `1000.formatted()` in `en_US`
/// renders `"1,000"`, which reparses to `nil` (the prescription silently
/// clears), and in `de_DE`/`fr_FR` renders `"1.000"`, which reparses as
/// `1.0` — a silent 1000 lb to 1 lb corruption with nothing failing.
///
/// `OptionalNumberField` is the extracted, testable replacement. These tests
/// are the actual regression coverage: run the same round trip across three
/// locales including the two that broke.
final class OptionalNumberFieldTests: XCTestCase {

    private let locales: [Locale] = [
        Locale(identifier: "en_US"),
        Locale(identifier: "de_DE"),
        Locale(identifier: "fr_FR"),
    ]

    func testRoundTripSurvivesEveryLocaleForOrdinaryValues() throws {
        for locale in locales {
            for value in [1000.0, 225.5, 7.5, 0.5] {
                let text = OptionalNumberField.string(from: value, locale: locale)
                let parsed = try XCTUnwrap(OptionalNumberField.value(from: text, locale: locale),
                                           "\(locale.identifier): \(value) -> \"\(text)\" -> nil")
                XCTAssertEqual(parsed, value, accuracy: 0.0001,
                                "\(locale.identifier): \(value) -> \"\(text)\" -> \(parsed)")
            }
        }
    }

    func testThousandNeverSilentlyBecomesOne() {
        // THE regression: en_US's grouped "1,000" and de_DE/fr_FR's grouped
        // "1.000" both used to reparse wrong (nil, then 1.0). Grouping is
        // off, so the formatted text for 1000 is plain "1000" everywhere,
        // and parsing it back must give 1000, never 1.
        for locale in locales {
            let text = OptionalNumberField.string(from: 1000, locale: locale)
            XCTAssertFalse(text.contains(","), "\(locale.identifier): \"\(text)\" should not group")
            XCTAssertFalse(text.contains("."), "\(locale.identifier): \"\(text)\" should not group")
            XCTAssertEqual(OptionalNumberField.value(from: text, locale: locale), 1000)
        }
    }

    func testGermanAndFrenchAcceptTheirOwnDecimalComma() {
        // The `.decimalPad` keyboard shows "," in these regions. A coach
        // must be able to type "225,5" or "7,5" directly, not just the
        // US-formatted string.
        for locale in [Locale(identifier: "de_DE"), Locale(identifier: "fr_FR")] {
            XCTAssertEqual(OptionalNumberField.value(from: "225,5", locale: locale), 225.5)
            XCTAssertEqual(OptionalNumberField.value(from: "7,5", locale: locale), 7.5)
        }
    }

    func testAGroupingSeparatorTypedByHandFailsRatherThanCorrupts() {
        // If a coach types "1.000" in de_DE trying to mean one thousand, the
        // old code silently produced 1.0. The fix must not parse this back
        // into a wrong number -- nil (an empty field the coach will notice
        // and retype) is the safe failure, not silent corruption.
        let de = Locale(identifier: "de_DE")
        XCTAssertNotEqual(OptionalNumberField.value(from: "1.000", locale: de), 1.0)
    }

    func testEmptyStringIsNilNotZero() {
        for locale in locales {
            XCTAssertNil(OptionalNumberField.value(from: "", locale: locale))
            XCTAssertNil(OptionalNumberField.value(from: "   ", locale: locale))
        }
    }

    func testGarbageInputIsNil() {
        for locale in locales {
            XCTAssertNil(OptionalNumberField.value(from: "abc", locale: locale))
            XCTAssertNil(OptionalNumberField.value(from: "12abc", locale: locale))
        }
    }

    func testNilValueFormatsAsEmptyString() {
        for locale in locales {
            XCTAssertEqual(OptionalNumberField.string(from: nil, locale: locale), "")
        }
    }
}
