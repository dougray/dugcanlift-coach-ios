import XCTest
import LiftCore
@testable import Coach

/// Bytes produced by the web Coach app, read by this code.
///
/// Captured by loading `https://www.dugcanlift.com/coach/` in a browser,
/// assigning the page's own script-scoped `clients`/`recipes`/`plans`/
/// `sessions`/`settings` from the console, and calling the page's own
/// `encodePlan('a1b2c3d4')`. Verified beforehand by diff that `encodePlan` is
/// byte-identical between the deployed site and `dugcanlift-coach` main -- the
/// v2 backup fix touched only the backup functions, not the encoder -- so the
/// live site was a valid source for this fixture despite lagging main
/// elsewhere. Do not regenerate this from Coach iOS's own encoder; that would
/// defeat its entire purpose.
final class PlanLinkMealInteropTests: XCTestCase {

    private static let lifterID = "a1b2c3d4"

    private func fixture() throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self)
            .url(forResource: "web-plan-meals", withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func web() throws -> PlanPayload {
        try PlanLinkCodec.decode(fragment: try fixture(), expectedLifterID: Self.lifterID)
    }

    func testDecodesAMealPlanTheWebAppProduced() throws {
        let payload = try web()
        let recipe = try XCTUnwrap(payload.r?.first)
        XCTAssertEqual(recipe.n, "Beef Chilli")
        XCTAssertEqual(recipe.s, 4)
        XCTAssertEqual(try XCTUnwrap(recipe.u), [438, 36, 31, 19, 9])
        XCTAssertEqual(recipe.i, ["500 g lean beef mince", "2 cloves garlic"])

        let meal = try XCTUnwrap(payload.m?.first)
        XCTAssertEqual(meal.d, "2026-09-14")
        XCTAssertEqual(meal.s, 2)
        XCTAssertEqual(meal.x, 0)
        XCTAssertEqual(meal.q, 2)
    }

    func testCoachProducesTheSameMealPlanTheWebAppDoes() throws {
        // Field by field, not byte equality: the web app builds its JSON in
        // object-literal order and Coach's JSONEncoder sorts keys, so the
        // bytes legitimately differ. Every value a client will see must match.
        let web = try web()

        let recipe = Recipe(name: "Beef Chilli", servings: 4,
                            steps: ["Brown the mince."],
                            nutritionPerServing: NutritionFacts(calories: 438, proteinG: 36,
                                                                carbsG: 31, fatG: 19, fiberG: 9))
        for (i, line) in ["500 g lean beef mince", "2 cloves garlic"].enumerated() {
            let ingredient = IngredientParser.parse(line, sortOrder: i)
            ingredient.recipe = recipe
        }
        let meal = PlannedMeal(recipe: recipe, mealType: .dinner,
                               plannedFor: try XCTUnwrap(DayKey.date(from: "2026-09-14")),
                               servings: 2)

        let mine = try PlanLinkCodec.decode(
            fragment: PlanLinkEncoder.fragment(recipes: [recipe], meals: [meal],
                                               lifterID: Self.lifterID, coachName: "Doug"),
            expectedLifterID: Self.lifterID)

        XCTAssertEqual(mine.r?.count, web.r?.count)
        let a = try XCTUnwrap(mine.r?.first), b = try XCTUnwrap(web.r?.first)
        XCTAssertEqual(a.n, b.n)
        XCTAssertEqual(a.s, b.s)
        XCTAssertEqual(a.i, b.i, "ingredient lines must survive verbatim on both sides")
        XCTAssertEqual(a.t, b.t)
        let mineU = try XCTUnwrap(a.u), webU = try XCTUnwrap(b.u)
        XCTAssertEqual(mineU.count, webU.count)
        for (x, y) in zip(mineU, webU) { XCTAssertEqual(x, y, accuracy: 0.5) }

        XCTAssertEqual(mine.m, web.m, "day, slot, index and servings must all agree")
    }

    func testTheFixtureIsNotSomethingThisCodeCouldHaveWritten() throws {
        // Coach's encoder sorts keys; the web app does not. If this fixture
        // ever starts decoding from sorted-key JSON, someone regenerated it
        // locally and the test stopped proving interoperability.
        let payload = try web()
        XCTAssertEqual(payload.t, "plan")
        XCTAssertEqual(payload.l, Self.lifterID)
        XCTAssertNotNil(payload.r)
    }
}
