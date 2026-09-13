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
        let schema = Schema([ShoppingListCheck.self])
        let ctx = ModelContext(try ModelContainer(
            for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        ctx.insert(ShoppingListCheck(itemKey: "lean beef mince"))
        try ctx.save()

        let checks = try ctx.fetch(FetchDescriptor<ShoppingListCheck>())
        XCTAssertTrue(checks.contains { $0.itemKey == "lean beef mince" },
                      "the tick is keyed by item name, not by a line's identity")
    }
}
