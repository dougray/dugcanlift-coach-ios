import XCTest
@testable import Coach

final class MealDBClientTests: XCTestCase {

    private let payload = """
    {"meals":[{"strMeal":"Beef Chilli","strInstructions":"Brown the mince.\\nAdd beans.",
    "strIngredient1":"Beef mince","strMeasure1":"500 g",
    "strIngredient2":"Garlic","strMeasure2":"2 cloves",
    "strIngredient3":"","strMeasure3":""}]}
    """

    private func client(_ body: String) -> MealDBClient {
        MealDBClient { _ in Data(body.utf8) }
    }

    func testMapsAMealIntoNameIngredientsAndSteps() async throws {
        let hits = try await client(payload).search("chilli")
        let recipe = try XCTUnwrap(hits.first)
        XCTAssertEqual(recipe.name, "Beef Chilli")
        XCTAssertEqual(recipe.ingredients, ["500 g Beef mince", "2 cloves Garlic"])
        XCTAssertEqual(recipe.steps, ["Brown the mince.", "Add beans."])
    }

    func testBlankIngredientSlotsAreSkipped() async throws {
        // TheMealDB always ships 20 slots and leaves the unused ones empty.
        let hits = try await client(payload).search("chilli")
        XCTAssertEqual(try XCTUnwrap(hits.first).ingredients.count, 2)
    }

    func testAnIngredientWithNoMeasureKeepsJustItsName() async throws {
        let body = """
        {"meals":[{"strMeal":"Toast","strInstructions":"Toast it.",
        "strIngredient1":"Bread","strMeasure1":"  "}]}
        """
        let hits = try await client(body).search("toast")
        let recipe = try XCTUnwrap(hits.first)
        XCTAssertEqual(recipe.ingredients, ["Bread"])
    }

    func testNoMatchesIsAnEmptyListNotAnError() async throws {
        let hits = try await client("{\"meals\":null}").search("asdfgh")
        XCTAssertTrue(hits.isEmpty)
    }

    func testANetworkFailurePropagatesSoTheScreenCanSayWhy() async {
        struct Offline: Error {}
        let client = MealDBClient { _ in throw Offline() }
        do {
            _ = try await client.search("chilli")
            XCTFail("expected the failure to reach the caller")
        } catch {
            // The screen shows this rather than an empty list, which would
            // read as "no such dish".
        }
    }

    func testTheQueryIsPercentEncodedIntoTheURL() async throws {
        var seen: URL?
        let client = MealDBClient { url in
            seen = url
            return Data("{\"meals\":null}".utf8)
        }
        _ = try await client.search("beef stew")
        XCTAssertEqual(try XCTUnwrap(seen).absoluteString,
                       "https://www.themealdb.com/api/json/v1/1/search.php?s=beef%20stew")
    }
}
