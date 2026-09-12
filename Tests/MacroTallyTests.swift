import XCTest
import LiftCore
@testable import Coach

final class MacroTallyTests: XCTestCase {

    func testTallyAccumulatesAndDividesByServings() {
        var tally = MacroTally()
        tally.add(NutritionFacts(calories: 1200, proteinG: 100, carbsG: 60, fatG: 40))
        tally.add(NutritionFacts(calories: 552, proteinG: 44, carbsG: 64, fatG: 36))
        XCTAssertEqual(tally.lines, 2)
        XCTAssertEqual(tally.total.calories, 1752)
        XCTAssertEqual(tally.perServing(4).calories, 438)
    }

    func testPerServingSurvivesAZeroServingCount() {
        var tally = MacroTally()
        tally.add(NutritionFacts(calories: 400))
        XCTAssertTrue(tally.perServing(0).calories.isFinite,
                      "a servings field a coach has just cleared must not divide by zero")
    }

    func testComputedMacrosFillOnlyUntouchedFields() {
        var fields = MacroFields()
        fields.calories = "500"
        fields.markTyped(.calories)

        fields.applyComputed(NutritionFacts(calories: 438, proteinG: 36, carbsG: 31, fatG: 19))

        XCTAssertEqual(fields.calories, "500", "a looked-up figure must never overwrite a typed one")
        XCTAssertEqual(fields.protein, "36")
        XCTAssertEqual(fields.carbs, "31")
        XCTAssertEqual(fields.fat, "19")
    }

    func testReopeningARecipeWithMacrosCountsEveryFieldAsTyped() {
        // "A recipe already carrying macros counts as typed: reopening it to
        // add one more ingredient must not throw away numbers that were
        // already right."
        var fields = MacroFields()
        fields.loadExisting(NutritionFacts(calories: 500, proteinG: 40, carbsG: 30, fatG: 20))
        fields.applyComputed(NutritionFacts(calories: 438, proteinG: 36, carbsG: 31, fatG: 19))

        XCTAssertEqual(fields.calories, "500")
        XCTAssertEqual(fields.protein, "40")
        XCTAssertEqual(fields.carbs, "30")
        XCTAssertEqual(fields.fat, "20")
    }

    func testAnUntouchedFormEntersNilNotZero() {
        // A zero here becomes a zero-calorie dinner in the client's day total.
        XCTAssertNil(MacroFields().entered())
    }

    func testAPartlyFilledFormKeepsWhatWasTypedAndZeroesTheRest() {
        var fields = MacroFields()
        fields.calories = "438"
        let entered = fields.entered()
        XCTAssertEqual(entered?.calories, 438)
        XCTAssertEqual(entered?.proteinG, 0,
                       "once anything is entered the record exists; blanks in it read as zero")
    }

    func testLoadingNoMacrosLeavesEveryFieldBlankAndUntyped() {
        var fields = MacroFields()
        fields.loadExisting(nil)
        XCTAssertEqual(fields.calories, "")
        XCTAssertTrue(fields.typed.isEmpty)
    }
}
