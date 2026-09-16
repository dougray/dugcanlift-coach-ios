import XCTest
import SwiftData
import LiftCore
@testable import Coach

final class WebLibraryImporterTests: XCTestCase {

    private func context() throws -> ModelContext {
        let schema = Schema(CoachSchema.models)
        return ModelContext(try ModelContainer(
            for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private let v2 = """
    { "v": 2, "clients": [], "settings": { "name": "Doug" },
      "recipes": [ { "id": "r1", "name": "Beef Chilli", "servings": 4,
        "ingredients": [ { "rawText": "500 g lean beef mince", "item": "lean beef mince",
                           "qty": 500, "unit": "g", "grams": 500 } ],
        "steps": ["Brown the mince."],
        "nutritionPerServing": { "calories": 438, "proteinG": 36, "carbsG": 31,
                                 "fatG": 19, "fiberG": 9 } } ],
      "plans": [ { "id": "p1", "clientId": "a1b2c3d4", "recipeId": "r1",
                   "recipeName": "Beef Chilli", "date": "2026-09-14",
                   "meal": "DINNER", "servings": 2 } ],
      "workouts": [ { "id": "w1", "name": "Lower A", "exercises": [
        { "name": "Back Squat", "equipment": "Barbell", "note": "Belt on the last set.",
          "sets": [ { "weightLb": 225, "reps": 5, "rpe": null,
                      "durationSec": null, "distanceM": null } ] } ] } ],
      "sessions": [ { "id": "k1", "clientId": "a1b2c3d4", "date": "2026-09-14",
                      "workoutId": "w1", "workoutName": "Lower A" } ] }
    """

    func testImportsRecipesWithTheirIngredientsAndMacros() throws {
        let ctx = try context()
        let summary = try WebLibraryImporter.importLibrary(from: Data(v2.utf8), into: ctx)
        XCTAssertEqual(summary.recipes, 1)

        let recipe = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Recipe>()).first)
        XCTAssertEqual(recipe.name, "Beef Chilli")
        XCTAssertEqual(recipe.servings, 4)
        XCTAssertEqual(recipe.nutritionPerServing?.calories, 438)
        XCTAssertEqual((recipe.ingredients ?? []).first?.rawText, "500 g lean beef mince")
    }

    /// Coach web writes `totalWeightGrams`. Dropping it here would lose a
    /// weight a coach entered in the browser the moment they moved to iOS.
    func testAWebRecipesWeightImports() throws {
        let body = """
        { "v": 2, "clients": [], "recipes": [ { "id": "r5", "name": "Weighed", "servings": 4,
          "ingredients": [], "steps": [], "totalWeightGrams": 1200 } ] }
        """
        let ctx = try context()
        _ = try WebLibraryImporter.importLibrary(from: Data(body.utf8), into: ctx)
        XCTAssertEqual(try XCTUnwrap(try ctx.fetch(FetchDescriptor<Recipe>()).first).totalWeightGrams, 1200)
    }

    func testARecipeWithNoMacrosImportsAsNilNotZero() throws {
        let body = """
        { "v": 2, "clients": [], "recipes": [ { "id": "r9", "name": "Mystery", "servings": 1,
          "ingredients": [], "steps": [], "nutritionPerServing": null } ] }
        """
        let ctx = try context()
        _ = try WebLibraryImporter.importLibrary(from: Data(body.utf8), into: ctx)
        let recipe = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Recipe>()).first)
        XCTAssertNil(recipe.nutritionPerServing,
                     "a zero would log as a zero-calorie dinner on the client's phone")
    }

    func testWorkoutWeightsConvertFromPoundsToKilograms() throws {
        let ctx = try context()
        _ = try WebLibraryImporter.importLibrary(from: Data(v2.utf8), into: ctx)
        let routine = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Routine>()).first)
        let set = try XCTUnwrap(routine.orderedExercises.first?.orderedSets.first)
        XCTAssertEqual(try XCTUnwrap(set.targetWeightKg), 102.058, accuracy: 0.01,
                       "the web store is pounds; RoutinePrescribedSet is kilograms")
        XCTAssertEqual(set.targetReps, 5)
        XCTAssertNil(set.targetRPE, "a blank prescription must not become zero")
    }

    func testScheduledSessionsKeepTheirClientAndDay() throws {
        let ctx = try context()
        _ = try WebLibraryImporter.importLibrary(from: Data(v2.utf8), into: ctx)
        let session = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ScheduledSession>()).first)
        XCTAssertEqual(session.clientID, "a1b2c3d4")
        XCTAssertEqual(session.dayKey, "2026-09-14")
    }

    func testAV1FileLeavesTheLibraryAlone() throws {
        let ctx = try context()
        ctx.insert(Recipe(name: "Already here", servings: 2))
        try ctx.save()

        let summary = try WebLibraryImporter.importLibrary(
            from: Data("{\"v\":1,\"clients\":[],\"settings\":{}}".utf8), into: ctx)
        XCTAssertEqual(summary.recipes, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Recipe>()).count, 1,
                       "absent must stay absent, not wipe what is on the phone")
    }

    func testImportingTheSameFileTwiceDoesNotDuplicate() throws {
        let ctx = try context()
        _ = try WebLibraryImporter.importLibrary(from: Data(v2.utf8), into: ctx)
        let second = try WebLibraryImporter.importLibrary(from: Data(v2.utf8), into: ctx)
        XCTAssertEqual(second.recipes, 0, "merge is by id, additively")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Recipe>()).count, 1)
    }

    func testAFileThatIsNotACoachBackupThrows() {
        XCTAssertThrowsError(try WebLibraryImporter.importLibrary(
            from: Data("{\"hello\":true}".utf8), into: try context()))
    }

    // MARK: - Meal ownership (fix round 1, Finding 1)

    /// A fresh, isolated `UserDefaults` suite per call -- never `.standard` --
    /// cleared before use so nothing leaks between test runs.
    private func isolatedDefaults(_ name: String) -> UserDefaults {
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    func testImportingPlannedMealsRecordsTheirOwner() throws {
        let name = "WebLibraryImporterTests.owner"
        let defaults = isolatedDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }

        let ctx = try context()
        let summary = try WebLibraryImporter.importLibrary(from: Data(v2.utf8), into: ctx, defaults: defaults)
        XCTAssertEqual(summary.meals, 1)

        let meal = try XCTUnwrap(try ctx.fetch(FetchDescriptor<PlannedMeal>()).first)
        let owners = MealOwners.load(from: defaults)
        XCTAssertEqual(owners[meal.id.uuidString], "a1b2c3d4",
                       "an imported meal with no owner entry is stored but invisible to every client")
    }

    func testReimportingTheSameFileDoesNotDuplicateMealOwnership() throws {
        let name = "WebLibraryImporterTests.owner.reimport"
        let defaults = isolatedDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }

        let ctx = try context()
        _ = try WebLibraryImporter.importLibrary(from: Data(v2.utf8), into: ctx, defaults: defaults)
        let second = try WebLibraryImporter.importLibrary(from: Data(v2.utf8), into: ctx, defaults: defaults)
        XCTAssertEqual(second.meals, 0, "merge is by id, additively")

        let meal = try XCTUnwrap(try ctx.fetch(FetchDescriptor<PlannedMeal>()).first)
        let owners = MealOwners.load(from: defaults)
        XCTAssertEqual(owners.count, 1)
        XCTAssertEqual(owners[meal.id.uuidString], "a1b2c3d4")
    }
}
