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

        // The web app omits empty collections rather than sending `[]` --
        // the behaviour Coach's own encoder was changed to match in the
        // previous task. This fixture carries no training data at all, so
        // it is real evidence of that convention on the web side too.
        XCTAssertNil(payload.w, "the web app omits empty collections, never sends []")
        XCTAssertNil(payload.k, "the web app omits empty collections, never sends []")
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
        // `PlanPayload.t`/`.l` are already enforced by `PlanLinkCodec.decode`
        // itself -- it throws on a wrong `t` and throws
        // `notAddressedToThisDevice` on a wrong `l` -- so asserting them here
        // would prove nothing a passing `try web()` hadn't already proven.
        // And `Codable` discards key order entirely: nothing downstream of
        // `decode` can tell web JSON from Coach JSON, because both decode to
        // the identical `PlanPayload` value regardless of what order the
        // wire bytes had their keys in.
        //
        // The one property that actually distinguishes a fixture the web app
        // wrote from one this codebase wrote is upstream of decoding:
        // Coach's `JSONEncoder` sets `.sortedKeys`, so its top-level keys
        // always come out alphabetically -- `l` before `n` before `r` before
        // `t` before `v`. The web app builds an ordinary object literal, so
        // its keys come out in insertion order -- `v` first, per
        // PLAN-FORMAT's field order. Coach's encoder can never produce JSON
        // starting `{"v"`; it would have to start `{"l"`. That is checked
        // here, before decoding, because decoding is exactly the step that
        // throws the distinction away.
        let fragment = try fixture()
        XCTAssertTrue(fragment.hasPrefix("1z"), "expected the deflate-raw envelope, got: \(fragment.prefix(8))")
        let payloadString = String(fragment.dropFirst(2))
        let compressed = try XCTUnwrap(CompactEncoding.base64URLDecode(payloadString))
        let jsonData = try XCTUnwrap(CompactEncoding.inflateRaw(compressed))
        let json = try XCTUnwrap(String(data: jsonData, encoding: .utf8))

        XCTAssertTrue(json.hasPrefix("{\"v\""),
                      "web-app JSON preserves insertion order (v first); got: \(json.prefix(20))")
        XCTAssertFalse(json.hasPrefix("{\"l\""),
                       "Coach's .sortedKeys would put l first -- this shape means the fixture " +
                       "was regenerated from Coach's own encoder and no longer proves interop")
    }
}
