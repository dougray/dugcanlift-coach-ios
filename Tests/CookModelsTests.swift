import XCTest
import SwiftData
import LiftCore
@testable import Coach

final class CookModelsTests: XCTestCase {

    /// Coach's ACTUAL container list, so this fails if CoachApp and the tests
    /// drift apart.
    private func context() throws -> ModelContext {
        let schema = Schema([
            Client.self, Goal.self, TrainingDay.self, ExerciseSet.self,
            ClientFoodEntry.self,
            Routine.self, RoutineExercise.self, RoutinePrescribedSet.self,
            ScheduledSession.self,
            Recipe.self, RecipeIngredient.self, PlannedMeal.self, ShoppingListCheck.self,
        ])
        return ModelContext(try ModelContainer(
            for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    func testARecipeSurvivesASaveWithItsIngredients() throws {
        let ctx = try context()
        let recipe = Recipe(name: "Beef Chilli", servings: 4, steps: ["Brown the mince."])
        ctx.insert(recipe)
        for (i, line) in ["500 g lean beef mince", "2 cloves garlic"].enumerated() {
            let ingredient = IngredientParser.parse(line, sortOrder: i)
            ingredient.recipe = recipe
            ctx.insert(ingredient)
        }
        try ctx.save()

        let back = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Recipe>()).first)
        XCTAssertEqual(back.name, "Beef Chilli")
        XCTAssertEqual(back.servings, 4)
        XCTAssertEqual((back.ingredients ?? []).count, 2)
    }

    func testRecipeAndClientFoodEntryCoexistInOneSchema() throws {
        // The collision this app renamed FoodEntry to avoid: Recipe's module
        // also declares a `FoodEntry`, and SwiftData identifies an entity by
        // its class's simple name. A save is what surfaces a clash -- schema
        // construction alone does not.
        let ctx = try context()
        let client = Client(id: "a1b2c3d4", name: "Doug", displayUnit: "lb", platform: "ios")
        ctx.insert(client)
        let day = TrainingDay(client: client, dayKey: "2026-09-14")
        ctx.insert(day)
        ctx.insert(ClientFoodEntry(day: day, foodName: "Oats", servings: 1,
                                   calories: 380, proteinG: 13, fatG: 7, carbsG: 67, fiberG: 10, meal: 0))
        ctx.insert(Recipe(name: "Beef Chilli", servings: 4))
        XCTAssertNoThrow(try ctx.save())
    }

    func testAPlannedMealSnapshotsMacrosPerServingNotScaled() throws {
        // The invariant behind the 2026-09-10 half-calories bug. Storing the
        // scaled figure works right up until a plan travels between clients.
        let ctx = try context()
        let recipe = Recipe(name: "Beef Chilli", servings: 4,
                            nutritionPerServing: NutritionFacts(calories: 438, proteinG: 36,
                                                                carbsG: 31, fatG: 19))
        ctx.insert(recipe)
        let meal = PlannedMeal(recipe: recipe, mealType: .dinner,
                               plannedFor: try XCTUnwrap(DayKey.date(from: "2026-09-14")),
                               servings: 2)
        ctx.insert(meal)
        try ctx.save()

        let back = try XCTUnwrap(try ctx.fetch(FetchDescriptor<PlannedMeal>()).first)
        XCTAssertEqual(back.snapshotNutrition?.calories, 438, "the snapshot is PER SERVING")
        XCTAssertEqual(back.scaledNutrition?.calories, 876, "scaling happens at the point of use")
        XCTAssertEqual(back.dayKey, "2026-09-14")
    }

    // MARK: - F2: Cancel on a new recipe must delete it, not just dismiss

    func testCancellingANewRecipeDeletesIt() throws {
        let ctx = try context()
        let recipe = Recipe(name: "Beef Chilli")
        ctx.insert(recipe)
        try ctx.save()

        RecipeEditorView.discard(recipe, in: ctx, isNew: true)

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Recipe>()).count, 0,
                       "a coach who types a name then cancels must not leave a phantom recipe behind")
    }

    func testCancellingAnExistingRecipeLeavesItInPlace() throws {
        let ctx = try context()
        let recipe = Recipe(name: "Beef Chilli")
        ctx.insert(recipe)
        try ctx.save()

        RecipeEditorView.discard(recipe, in: ctx, isNew: false)

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Recipe>()).count, 1,
                       "cancelling an edit to an existing recipe must not delete it")
    }
}
