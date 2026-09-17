import XCTest
@testable import Coach

/// The workout editor showed "175.002944" for a set a workout card showed as
/// "175 lb", because the field formatted the raw kg -> lb conversion. Rounding
/// the display fixes that and opens a second defect -- reading the rounded
/// text back would store a slightly different kilogram value -- which these
/// tests also pin.
final class PrescribedWeightFieldTests: XCTestCase {

    private let en = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")

    func testTheReportedValuesShowAsWholePounds() {
        // 79.38 kg and 61.23 kg are what rendered as 175.002944 and 134.989043.
        XCTAssertEqual(PrescribedWeightField.text(kilograms: 79.38, locale: en), "175")
        XCTAssertEqual(PrescribedWeightField.text(kilograms: 61.23, locale: en), "135")
    }

    func testAHalfPoundSurvivesAndIsLocaleAware() {
        let kg = PlanLinkEncoder.lbToKg(137.5)
        XCTAssertEqual(PrescribedWeightField.text(kilograms: kg, locale: en), "137.5")
        XCTAssertEqual(PrescribedWeightField.text(kilograms: kg, locale: de), "137,5")
    }

    func testNoGroupingSeparator() {
        let kg = PlanLinkEncoder.lbToKg(1000)
        XCTAssertEqual(PrescribedWeightField.text(kilograms: kg, locale: en), "1000")
        XCTAssertEqual(PrescribedWeightField.text(kilograms: kg, locale: de), "1000")
    }

    func testBlankStaysBlank() {
        XCTAssertEqual(PrescribedWeightField.text(kilograms: nil, locale: en), "")
        XCTAssertNil(PrescribedWeightField.kilograms(from: "", stored: 79.38, locale: en))
        XCTAssertNil(PrescribedWeightField.kilograms(from: "  ", stored: nil, locale: en))
    }

    func testAnUntouchedFieldWritesBackExactlyWhatWasStored() {
        for locale in [en, de] {
            for stored in [79.38, 61.23, 100.0, 0.5, 142.88, PlanLinkEncoder.lbToKg(137.5)] {
                let shown = PrescribedWeightField.text(kilograms: stored, locale: locale)
                XCTAssertEqual(PrescribedWeightField.kilograms(from: shown, stored: stored, locale: locale),
                               stored, "\(locale.identifier): \(stored) kg shown as \"\(shown)\"")
            }
        }
    }

    func testRetypingTheShownValueDifferentlyKeepsTheStoredValue() {
        XCTAssertEqual(PrescribedWeightField.kilograms(from: "175.0", stored: 79.38, locale: en), 79.38)
        XCTAssertEqual(PrescribedWeightField.kilograms(from: "175,0", stored: 79.38, locale: de), 79.38)
    }

    func testAnEditedValueIsConverted() {
        let kg = PrescribedWeightField.kilograms(from: "180", stored: 79.38, locale: en)
        XCTAssertEqual(kg, PlanLinkEncoder.lbToKg(180))
        XCTAssertEqual(PrescribedWeightField.text(kilograms: kg, locale: en), "180")
    }

    func testMorePrecisionThanShownCountsAsAnEdit() {
        // "175.02" is not what the field showed ("175"), so it is the coach's
        // number, not the stored one.
        XCTAssertEqual(PrescribedWeightField.kilograms(from: "175.02", stored: 79.38, locale: en),
                       PlanLinkEncoder.lbToKg(175.02))
    }

    func testANewWeightOnABlankSetIsConverted() {
        XCTAssertEqual(PrescribedWeightField.kilograms(from: "225", stored: nil, locale: en),
                       PlanLinkEncoder.lbToKg(225))
    }

    func testGarbageClearsRatherThanCorrupts() {
        XCTAssertNil(PrescribedWeightField.kilograms(from: "abc", stored: 79.38, locale: en))
        XCTAssertNotEqual(PrescribedWeightField.kilograms(from: "1.000", stored: nil, locale: de),
                          PlanLinkEncoder.lbToKg(1))
    }
}
