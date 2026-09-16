import XCTest
import LiftCore
@testable import Coach

final class LinkImportMacrosTests: XCTestCase {

    private func imported(nutrition: NutritionFacts? = nil,
                          lines: [String] = [],
                          transcript: String = "{json-ld}") -> ImportedRecipe {
        ImportedRecipe(name: "Lasagne",
                       ingredientLines: lines,
                       nutritionPerServing: nutrition,
                       sourceTranscript: transcript)
    }

    private func costing(total: NutritionFacts, lines: Int, unpriced: [String]) -> CostingResult {
        var tally = MacroTally()
        for _ in 0 ..< lines { tally.add(total.scaled(by: 1 / Double(max(lines, 1)))) }
        return CostingResult(tally: tally, unpriced: unpriced)
    }

    // MARK: - Which path runs

    func testCostingRunsOnlyWhenThePagePublishedNoMacros() {
        XCTAssertTrue(LinkImportMacros.needsCosting(imported()))
        XCTAssertFalse(LinkImportMacros.needsCosting(
            imported(nutrition: NutritionFacts(calories: 844))))
    }

    func testAPublishedFigureIsTakenAsIsAndNotRecomputed() {
        // Costing over the top would replace a whole-dish measurement with a
        // partial one built from whichever lines happened to be weighable.
        let published = NutritionFacts(calories: 844, proteinG: 37, carbsG: 54, fatG: 52)
        let outcome = LinkImportMacros.resolve(imported: imported(nutrition: published),
                                               servings: 6,
                                               costed: nil)
        XCTAssertEqual(outcome.nutritionPerServing, published)
        XCTAssertTrue(outcome.isEstimated, "the site's figure is not a database lookup")
        XCTAssertTrue(outcome.transcript.contains("site's own figures"))
        XCTAssertFalse(outcome.transcript.contains("could not be weighed"))
    }

    // MARK: - The costing path

    func testEveryIngredientCostedSaysSoAndDividesByServings() {
        let costed = costing(total: NutritionFacts(calories: 1200, proteinG: 60),
                             lines: 3, unpriced: [])
        let outcome = LinkImportMacros.resolve(
            imported: imported(lines: ["500 g mince", "100 g cheese", "200 g pasta"]),
            servings: 4,
            costed: costed)

        // Per serving, never pre-scaled -- the invariant the half-calories bug
        // came from breaking.
        XCTAssertEqual(outcome.nutritionPerServing?.calories ?? 0, 300, accuracy: 0.001)
        XCTAssertEqual(outcome.nutritionPerServing?.proteinG ?? 0, 15, accuracy: 0.001)
        XCTAssertTrue(outcome.isEstimated)
        XCTAssertTrue(outcome.transcript.contains("Every ingredient was costed"))
    }

    func testAPartialCostingStatesTheGapInWordsWithACount() {
        let costed = costing(total: NutritionFacts(calories: 1000), lines: 1,
                             unpriced: ["2 tbsp olive oil", "a handful of basil"])
        let outcome = LinkImportMacros.resolve(
            imported: imported(lines: ["500 g mince", "2 tbsp olive oil", "a handful of basil"]),
            servings: 2,
            costed: costed)

        XCTAssertEqual(outcome.nutritionPerServing?.calories ?? 0, 500, accuracy: 0.001)
        XCTAssertTrue(outcome.transcript.contains("2 of 3 ingredients could not be weighed"),
                      "a coach has to see how short the number is before sending it")
        XCTAssertTrue(outcome.transcript.contains("2 tbsp olive oil"))
        XCTAssertTrue(outcome.transcript.contains("a handful of basil"))
    }

    func testNothingCostableLeavesTheMacrosNilRatherThanZero() {
        // A zero here becomes a zero-calorie dinner in a client's day total --
        // the same failure MacroFields prevents on the typed side.
        let costed = costing(total: .zero, lines: 0, unpriced: ["a handful of parsley"])
        let outcome = LinkImportMacros.resolve(
            imported: imported(lines: ["a handful of parsley"]),
            servings: 4,
            costed: costed)

        XCTAssertNil(outcome.nutritionPerServing)
        XCTAssertFalse(outcome.isEstimated, "there is no number, so there is nothing to warn about")
        XCTAssertTrue(outcome.transcript.contains("nothing here could be weighed"))
        XCTAssertTrue(outcome.transcript.contains("Add them by hand"))
    }

    // MARK: - The transcript

    func testTheSourceJSONLDStaysAtTheTopOfTheTranscript() {
        // It is what a misread quantity is checked against before saving.
        let costed = costing(total: NutritionFacts(calories: 100), lines: 1, unpriced: [])
        let outcome = LinkImportMacros.resolve(
            imported: imported(lines: ["100 g rice"], transcript: "{\"name\":\"Lasagne\"}"),
            servings: 1,
            costed: costed)
        XCTAssertTrue(outcome.transcript.hasPrefix("{\"name\":\"Lasagne\"}"))
    }

    func testServingsOfZeroDoesNotProduceInfiniteMacros() {
        // MacroTally.perServing clamps; this pins that the clamp is reached
        // through this path too rather than dividing by a cleared field.
        let costed = costing(total: NutritionFacts(calories: 1000), lines: 1, unpriced: [])
        let outcome = LinkImportMacros.resolve(imported: imported(lines: ["500 g mince"]),
                                               servings: 0,
                                               costed: costed)
        XCTAssertTrue((outcome.nutritionPerServing?.calories ?? 0).isFinite)
    }
}
