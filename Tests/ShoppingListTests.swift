import XCTest
import SwiftData
import LiftCore
@testable import Coach

final class ShoppingListTests: XCTestCase {

    private func recipe(_ name: String, servings: Double, lines: [String]) -> Recipe {
        let recipe = Recipe(name: name, servings: servings)
        for (i, line) in lines.enumerated() {
            let ingredient = IngredientParser.parse(line, sortOrder: i)
            ingredient.recipe = recipe
        }
        return recipe
    }

    func testAmountsScaleByServingsAgainstTheRecipesOwnCount() throws {
        // Planning two servings of a four-serving recipe buys half.
        let chilli = recipe("Beef Chilli", servings: 4, lines: ["500 g lean beef mince"])
        let meal = PlannedMeal(recipe: chilli, mealType: .dinner,
                               plannedFor: try XCTUnwrap(DayKey.date(from: "2026-09-14")),
                               servings: 2)
        let lines = ShoppingList.build(from: [meal], recipes: [chilli.id: chilli])
        let mince = try XCTUnwrap(lines.first { $0.key.contains("mince") })
        XCTAssertEqual(try XCTUnwrap(mince.amounts["g"]), 250, accuracy: 0.001)
    }

    func testCountsAggregateSeparatelyFromUnitsAndPrintBare() throws {
        let dish = recipe("Eggs on toast", servings: 1, lines: ["2 eggs", "60 g butter"])
        let meal = PlannedMeal(recipe: dish, mealType: .breakfast,
                               plannedFor: try XCTUnwrap(DayKey.date(from: "2026-09-14")))
        let lines = ShoppingList.build(from: [meal], recipes: [dish.id: dish])
        let eggs = try XCTUnwrap(lines.first { $0.key == "eggs" })
        XCTAssertEqual(eggs.amounts[IngredientParser.countUnit], 2)
        let label = CookFormat.amountsLabel(eggs.amounts)
        XCTAssertEqual(label, "2", "two eggs, not '2 \u{0000}count eggs'")
    }

    func testTheSameItemAcrossTwoMealsSumsIntoOneLine() throws {
        let a = recipe("Chilli", servings: 1, lines: ["500 g lean beef mince"])
        let b = recipe("Bolognese", servings: 1, lines: ["300 g lean beef mince"])
        let day = try XCTUnwrap(DayKey.date(from: "2026-09-14"))
        let lines = ShoppingList.build(
            from: [PlannedMeal(recipe: a, mealType: .dinner, plannedFor: day),
                   PlannedMeal(recipe: b, mealType: .lunch, plannedFor: day)],
            recipes: [a.id: a, b.id: b])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(try XCTUnwrap(lines[0].amounts["g"]), 800, accuracy: 0.001)
    }

    func testAnUnparsedLineIsShownVerbatimRatherThanDropped() throws {
        let dish = recipe("Soup", servings: 1, lines: ["a handful of parsley"])
        let meal = PlannedMeal(recipe: dish, mealType: .dinner,
                               plannedFor: try XCTUnwrap(DayKey.date(from: "2026-09-14")))
        let lines = ShoppingList.build(from: [meal], recipes: [dish.id: dish])
        XCTAssertEqual(try XCTUnwrap(lines.first).unparsed, ["a handful of parsley"],
                       "nothing silently drops off the list you shop from")
    }

    func testCheckOffStateSurvivesTheListBeingRederived() throws {
        // The old version of this test inserted a ShoppingListCheck and
        // fetched it back -- true regardless of whether ShoppingList.build
        // ever ran again, so it could not fail no matter how rebuilding the
        // list behaved. Made real: derive the list, tick a line, derive the
        // list AGAIN from the same meals (nothing here is cached -- build()
        // recomputes from scratch every call), and assert the second build's
        // key still matches the tick.
        let schema = Schema([ShoppingListCheck.self])
        let ctx = ModelContext(try ModelContainer(
            for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))

        let chilli = recipe("Beef Chilli", servings: 4, lines: ["500 g lean beef mince"])
        let meal = PlannedMeal(recipe: chilli, mealType: .dinner,
                               plannedFor: try XCTUnwrap(DayKey.date(from: "2026-09-14")), servings: 2)

        let firstBuild = ShoppingList.build(from: [meal], recipes: [chilli.id: chilli])
        let mince = try XCTUnwrap(firstBuild.first { $0.key.contains("mince") })
        ctx.insert(ShoppingListCheck(itemKey: mince.key))
        try ctx.save()

        let secondBuild = ShoppingList.build(from: [meal], recipes: [chilli.id: chilli])
        let minceAgain = try XCTUnwrap(secondBuild.first { $0.key.contains("mince") })
        XCTAssertEqual(minceAgain.key, mince.key, "the derived key must be stable across rebuilds")

        let checks = try ctx.fetch(FetchDescriptor<ShoppingListCheck>())
        XCTAssertTrue(checks.contains { $0.itemKey == minceAgain.key },
                      "the tick made against the first build must still match the key the second build derives")
    }
}
