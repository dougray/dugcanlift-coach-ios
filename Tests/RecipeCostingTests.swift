import XCTest
import LiftCore
import LiftReference
@testable import Coach

final class RecipeCostingTests: XCTestCase {

    // `FoodRecord` (LiftKit 1.1.0) has no public memberwise initializer -- see
    // the identical note in `RecipeEditingTests.record(...)`, which this
    // copies: decoding through JSON (matching property names) is the only
    // cross-module construction route available without editing the package.
    private func record(_ calories: Double) -> FoodRecord {
        let json: [String: Any?] = [
            "id": "usda:test",
            "name": "Test",
            "brand": nil,
            "servingGrams": nil,
            "servingLabel": nil,
            "caloriesPer100g": calories,
            "proteinPer100g": 10,
            "carbsPer100g": 0,
            "fatPer100g": 2,
            "fiberPer100g": 0,
            "sugarPer100g": nil,
            "sodiumPer100g": nil,
            "source": "usda",
        ]
        let data = try! JSONSerialization.data(withJSONObject: json.compactMapValues { $0 })
        return try! JSONDecoder().decode(FoodRecord.self, from: data)
    }

    func testOnlyLinesThatConvertToAWeightAreCosted() async {
        let result = await RecipeCosting.cost(
            lines: ["500 g lean beef mince", "2 tbsp olive oil", "2 cloves garlic"],
            lookup: { _ in self.record(250) })
        XCTAssertEqual(result.tally.lines, 1)
        XCTAssertEqual(result.tally.total.calories, 1250, accuracy: 0.001)
        XCTAssertEqual(result.unpriced, ["2 tbsp olive oil", "2 cloves garlic"],
                       "pricing a tablespoon means inventing a density")
    }

    func testALineWithNoDatabaseMatchIsUnpricedNotZero() async {
        let result = await RecipeCosting.cost(lines: ["500 g unobtainium"], lookup: { _ in nil })
        XCTAssertEqual(result.tally.lines, 0)
        XCTAssertEqual(result.unpriced, ["500 g unobtainium"])
    }

    func testNothingCostableLeavesAnEmptyTallyRatherThanZeroMacros() async {
        let result = await RecipeCosting.cost(lines: ["a handful of parsley"], lookup: { _ in nil })
        XCTAssertEqual(result.tally.lines, 0)
        XCTAssertEqual(result.tally.total, .zero)
        XCTAssertEqual(result.unpriced.count, 1)
    }

    func testTheLookupIsGivenTheParsedItemNotTheWholeLine() async {
        var asked: [String] = []
        _ = await RecipeCosting.cost(lines: ["500 g lean beef mince"],
                                     lookup: { asked.append($0); return nil })
        XCTAssertEqual(asked, ["lean beef mince"],
                       "searching the full line with its quantity finds nothing")
    }
}
