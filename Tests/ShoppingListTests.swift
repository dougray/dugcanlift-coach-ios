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
        // The old version of this test inserted a check and fetched it back --
        // true regardless of whether ShoppingList.build ever ran again, so it
        // could not fail no matter how rebuilding the list behaved. Made real:
        // derive the list, tick a line, derive the list AGAIN from the same
        // meals (nothing here is cached -- build() recomputes from scratch
        // every call), and assert the second build's line is still ticked.
        let ctx = try context()
        let chilli = recipe("Beef Chilli", servings: 4, lines: ["500 g lean beef mince"])
        let meal = PlannedMeal(recipe: chilli, mealType: .dinner,
                               plannedFor: try XCTUnwrap(DayKey.date(from: "2026-09-14")), servings: 2)

        let firstBuild = ShoppingList.build(from: [meal], recipes: [chilli.id: chilli])
        let mince = try XCTUnwrap(firstBuild.first { $0.key.contains("mince") })
        ClientShoppingCheck.toggle(mince, clientID: "ana", in: [], context: ctx)
        try ctx.save()

        let secondBuild = ShoppingList.build(from: [meal], recipes: [chilli.id: chilli])
        let minceAgain = try XCTUnwrap(secondBuild.first { $0.key.contains("mince") })
        XCTAssertEqual(minceAgain.key, mince.key, "the derived key must be stable across rebuilds")
        XCTAssertTrue(ClientShoppingCheck.isChecked(minceAgain, clientID: "ana", in: try checks(ctx)),
                      "the tick made against the first build must still match the key the second build derives")
    }

    // MARK: - Per-client ticks

    /// Coach's real container, so a tick is saved through the same schema
    /// the app opens.
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema(CoachSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func checks(_ ctx: ModelContext) throws -> [ClientShoppingCheck] {
        try ctx.fetch(FetchDescriptor<ClientShoppingCheck>())
    }

    private func line(_ ingredient: String) throws -> ShoppingListLine {
        let dish = recipe("Dish", servings: 1, lines: [ingredient])
        let meal = PlannedMeal(recipe: dish, mealType: .dinner,
                               plannedFor: try XCTUnwrap(DayKey.date(from: "2026-09-14")))
        return try XCTUnwrap(ShoppingList.build(from: [meal], recipes: [dish.id: dish]).first)
    }

    func testTickingForOneClientDoesNotTickForAnother() throws {
        // The bug this model exists to fix: LiftCore's ShoppingListCheck is
        // keyed by item name alone, so ticking mince for Ana ticked it for
        // Ben too.
        let ctx = try context()
        let mince = try line("500 g lean beef mince")

        ClientShoppingCheck.toggle(mince, clientID: "ana", in: try checks(ctx), context: ctx)
        try ctx.save()

        XCTAssertTrue(ClientShoppingCheck.isChecked(mince, clientID: "ana", in: try checks(ctx)))
        XCTAssertFalse(ClientShoppingCheck.isChecked(mince, clientID: "ben", in: try checks(ctx)),
                       "Ben's basket is not Ana's")

        // And unticking for Ben is not a way to untick Ana's.
        ClientShoppingCheck.toggle(mince, clientID: "ben", in: try checks(ctx), context: ctx)
        ClientShoppingCheck.toggle(mince, clientID: "ben", in: try checks(ctx), context: ctx)
        try ctx.save()
        XCTAssertTrue(ClientShoppingCheck.isChecked(mince, clientID: "ana", in: try checks(ctx)))
        XCTAssertFalse(ClientShoppingCheck.isChecked(mince, clientID: "ben", in: try checks(ctx)))
    }

    func testTogglingTwiceUnticks() throws {
        let ctx = try context()
        let eggs = try line("2 eggs")
        ClientShoppingCheck.toggle(eggs, clientID: "ana", in: try checks(ctx), context: ctx)
        try ctx.save()
        ClientShoppingCheck.toggle(eggs, clientID: "ana", in: try checks(ctx), context: ctx)
        try ctx.save()
        XCTAssertFalse(ClientShoppingCheck.isChecked(eggs, clientID: "ana", in: try checks(ctx)))
        XCTAssertTrue(try checks(ctx).isEmpty, "an untick deletes the row rather than leaving a stale one")
    }

    func testClearTicksOnlyClearsThatClient() throws {
        let ctx = try context()
        let mince = try line("500 g lean beef mince")
        let eggs = try line("2 eggs")
        for client in ["ana", "ben"] {
            for item in [mince, eggs] {
                ClientShoppingCheck.toggle(item, clientID: client, in: try checks(ctx), context: ctx)
            }
        }
        try ctx.save()

        ClientShoppingCheck.clear(clientID: "ana", in: try checks(ctx), context: ctx)
        try ctx.save()

        XCTAssertTrue(ClientShoppingCheck.checks(for: "ana", in: try checks(ctx)).isEmpty)
        let bens = ClientShoppingCheck.checks(for: "ben", in: try checks(ctx))
        XCTAssertEqual(Set(bens.map(\.itemKey)), [mince.key, eggs.key],
                       "clearing Ana's basket must leave Ben's alone")
    }

    func testATickMatchesTheListLineWhateverCaseOrSpacingTheRecipeUsed() throws {
        // The key is LiftCore's, stored as ShoppingList.build derived it.
        // Two recipes spelling the same item differently land on one line, and
        // a tick made against that line still matches when the list is built
        // from either recipe alone.
        let ctx = try context()
        let day = try XCTUnwrap(DayKey.date(from: "2026-09-14"))
        let a = recipe("Chilli", servings: 1, lines: ["500 g Lean Beef Mince"])
        let b = recipe("Bolognese", servings: 1, lines: ["300 g lean beef mince  "])
        let mealA = PlannedMeal(recipe: a, mealType: .dinner, plannedFor: day)
        let mealB = PlannedMeal(recipe: b, mealType: .lunch, plannedFor: day)

        let both = ShoppingList.build(from: [mealA, mealB], recipes: [a.id: a, b.id: b])
        XCTAssertEqual(both.count, 1, "one line for one item, however it was spelled")
        ClientShoppingCheck.toggle(both[0], clientID: "ana", in: [], context: ctx)
        try ctx.save()

        let stored = try XCTUnwrap(try checks(ctx).first)
        XCTAssertEqual(stored.itemKey, both[0].key, "stored as the package derived it, not re-normalised")

        for alone in [ShoppingList.build(from: [mealA], recipes: [a.id: a]),
                      ShoppingList.build(from: [mealB], recipes: [b.id: b])] {
            XCTAssertTrue(ClientShoppingCheck.isChecked(try XCTUnwrap(alone.first),
                                                        clientID: "ana", in: try checks(ctx)))
        }
    }

    func testTheSchemaCarriesPerClientTicksAndNotTheSharedOnes() {
        // SwiftData names an entity by its class's simple name. A Coach model
        // sharing a name with a LiftCore one collapses into it silently (see
        // EntityNameCollisionTests), so check both that the new entity exists
        // under its own name and that the shared one is gone.
        let names = Set(Schema(CoachSchema.models).entities.map(\.name))
        XCTAssertTrue(names.contains("ClientShoppingCheck"))
        XCTAssertFalse(names.contains("ShoppingListCheck"),
                       "a tick keyed by item name alone reaches every client")
    }
}
