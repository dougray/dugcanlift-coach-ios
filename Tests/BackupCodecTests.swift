import XCTest
import SwiftData
import LiftCore
@testable import Coach

final class BackupCodecTests: XCTestCase {

    // v1 schema, deliberately: no Recipe/RecipeIngredient/PlannedMeal/
    // ClientShoppingCheck here, matching a real v1 backup file. BackupCodec.export
    // still unconditionally fetches FetchDescriptor<Recipe>() etc. against
    // whatever context it's given, which only works against this narrower
    // schema because SwiftData returns empty for a type absent from a
    // context's own schema rather than throwing.
    private func makeContext() throws -> ModelContext {
        let schema = Schema([Client.self, Goal.self, TrainingDay.self, ExerciseSet.self, ClientFoodEntry.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func context() throws -> ModelContext {
        let schema = Schema(CoachSchema.models)
        return ModelContext(try ModelContainer(
            for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    func testExportThenRestoreRoundTripsAClient() throws {
        let sourceContext = try makeContext()
        let client = Client(id: "b7f3a1c8", name: "Jordan Reyes", displayUnit: "lb", platform: "ios")
        sourceContext.insert(client)
        let day = TrainingDay(client: client, dayKey: "2026-09-10", sessionName: "Push Day")
        sourceContext.insert(day)
        client.trainingDays.append(day)
        let set = ExerciseSet(day: day, exerciseName: "Back Squat", equipment: "Barbell", weightLb: 225, reps: 5)
        sourceContext.insert(set)
        day.sets.append(set)
        try sourceContext.save()

        let data = try BackupCodec.export(from: sourceContext)

        let destinationContext = try makeContext()
        try BackupCodec.restore(from: data, into: destinationContext)

        let clients = try destinationContext.fetch(FetchDescriptor<Client>())
        XCTAssertEqual(clients.count, 1)
        XCTAssertEqual(clients.first?.name, "Jordan Reyes")
        XCTAssertEqual(clients.first?.trainingDays.first?.sets.first?.exerciseName, "Back Squat")
    }

    func testRestoreReplacesExistingData() throws {
        let context = try makeContext()
        let oldClient = Client(id: "old", name: "Old Client", displayUnit: "lb", platform: "ios")
        context.insert(oldClient)
        try context.save()

        let newClient = Client(id: "new", name: "New Client", displayUnit: "lb", platform: "ios")
        let backupContext = try makeContext()
        backupContext.insert(newClient)
        try backupContext.save()
        let data = try BackupCodec.export(from: backupContext)

        try BackupCodec.restore(from: data, into: context)

        let clients = try context.fetch(FetchDescriptor<Client>())
        XCTAssertEqual(clients.count, 1)
        XCTAssertEqual(clients.first?.id, "new")
    }

    func testCorruptDataThrowsRatherThanCrashing() {
        let context = try! makeContext()
        XCTAssertThrowsError(try BackupCodec.restore(from: Data("not json".utf8), into: context))
    }

    func testExportThenRestorePreservesLastImportedAt() throws {
        let sourceContext = try makeContext()
        let originalTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let client = Client(id: "b7f3a1c8", name: "Jordan Reyes", displayUnit: "lb",
                             platform: "ios", lastImportedAt: originalTimestamp)
        sourceContext.insert(client)
        try sourceContext.save()

        let data = try BackupCodec.export(from: sourceContext)
        let destinationContext = try makeContext()
        try BackupCodec.restore(from: data, into: destinationContext)

        let restored = try destinationContext.fetch(FetchDescriptor<Client>()).first
        XCTAssertEqual(restored?.lastImportedAt, originalTimestamp)
    }

    func testABackupCarriesTheWholeLibraryNotJustTheRoster() throws {
        let ctx = try context()
        ctx.insert(Recipe(name: "Beef Chilli", servings: 4))
        let routine = Routine(name: "Lower A")
        ctx.insert(routine)
        ctx.insert(ScheduledSession(clientID: "a1b2c3d4", dayKey: "2026-09-14", routineID: routine.id))
        try ctx.save()

        let data = try BackupCodec.export(from: ctx)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["v"] as? Int, 2)
        XCTAssertEqual((json["recipes"] as? [Any])?.count, 1)
        XCTAssertEqual((json["routines"] as? [Any])?.count, 1)
        XCTAssertEqual((json["sessions"] as? [Any])?.count, 1)
    }

    func testRestoringARoundTripReturnsTheLibrary() throws {
        let source = try context()
        source.insert(Recipe(name: "Beef Chilli", servings: 4))
        let routine = Routine(name: "Lower A")
        source.insert(routine)
        try source.save()

        let data = try BackupCodec.export(from: source)
        let target = try context()
        try BackupCodec.restore(from: data, into: target)

        XCTAssertEqual(try target.fetch(FetchDescriptor<Recipe>()).count, 1)
        XCTAssertEqual(try target.fetch(FetchDescriptor<Routine>()).count, 1)
    }

    /// A recipe's weight is what gives a serving something to put on a scale.
    /// Before `BackupRecipe` carried it, a backup silently dropped it.
    func testARecipesWeightSurvivesBackupAndRestore() throws {
        let source = try context()
        let recipe = Recipe(name: "Beef Chilli", servings: 4)
        recipe.totalWeightGrams = 1200
        source.insert(recipe)
        try source.save()

        let target = try context()
        try BackupCodec.restore(from: try BackupCodec.export(from: source), into: target)

        let restored = try XCTUnwrap(try target.fetch(FetchDescriptor<Recipe>()).first)
        XCTAssertEqual(restored.totalWeightGrams, 1200)
    }

    /// A file written before the field existed must still restore, unweighed.
    func testABackupWithoutAWeightRestoresUnweighed() throws {
        let body = """
        { "v": 2, "clients": [], "recipes": [ { "id": "8E1C4C2A-0000-0000-0000-000000000009",
          "name": "Old", "servings": 2, "steps": [], "ingredients": [] } ] }
        """
        let ctx = try context()
        try BackupCodec.restore(from: Data(body.utf8), into: ctx)
        XCTAssertNil(try XCTUnwrap(try ctx.fetch(FetchDescriptor<Recipe>()).first).totalWeightGrams)
    }

    func testAZeroOrNegativeWeightRestoresAsUnweighed() {
        XCTAssertNil(BackupCodec.weighed(0))
        XCTAssertNil(BackupCodec.weighed(-5))
        XCTAssertNil(BackupCodec.weighed(.infinity))
        XCTAssertNil(BackupCodec.weighed(nil))
        XCTAssertEqual(BackupCodec.weighed(1200), 1200)
    }

    func testRestoringAV1FileDoesNotWipeTheLibrary() throws {
        let ctx = try context()
        ctx.insert(Recipe(name: "Already here", servings: 2))
        try ctx.save()

        try BackupCodec.restore(from: Data("{\"v\":1,\"clients\":[]}".utf8), into: ctx)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Recipe>()).count, 1,
                       "a v1 file has no library; absent must not mean delete")
    }

    // MARK: - Meal ownership (fix round 1, Finding 1)

    /// A fresh, isolated `UserDefaults` suite per call -- never `.standard` --
    /// cleared before use so a previous test's leftovers (or a previous run's,
    /// if a suite name were ever reused) can never leak in.
    private func isolatedDefaults(_ name: String) -> UserDefaults {
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    func testMealRoundTripPreservesIdSnapshotAndOwner() throws {
        let sourceDefaults = isolatedDefaults("BackupCodecTests.meal.source")
        defer { sourceDefaults.removePersistentDomain(forName: "BackupCodecTests.meal.source") }

        let source = try context()
        let recipe = Recipe(name: "Beef Chilli", servings: 4,
                            nutritionPerServing: NutritionFacts(calories: 438, proteinG: 36,
                                                                carbsG: 31, fatG: 19, fiberG: 9))
        source.insert(recipe)
        let plannedFor = try XCTUnwrap(DayKey.date(from: "2026-09-14"))
        let meal = PlannedMeal(recipe: recipe, mealType: .dinner, plannedFor: plannedFor, servings: 2)
        source.insert(meal)
        try source.save()
        MealOwners.save([meal.id.uuidString: "a1b2c3d4"], to: sourceDefaults)

        // Mutate the recipe's macros *after* the meal snapshotted them, so a
        // restore that recomputed `snapshotNutrition` from the restored
        // recipe (999 cal) rather than carrying the backup's own snapshot
        // (438 cal) would be caught red-handed.
        recipe.nutritionPerServing = NutritionFacts(calories: 999, proteinG: 1, carbsG: 1, fatG: 1, fiberG: 1)
        try source.save()

        let data = try BackupCodec.export(from: source, defaults: sourceDefaults)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((json["meals"] as? [Any])?.count, 1)

        let targetDefaults = isolatedDefaults("BackupCodecTests.meal.target")
        defer { targetDefaults.removePersistentDomain(forName: "BackupCodecTests.meal.target") }

        let target = try context()
        try BackupCodec.restore(from: data, into: target, defaults: targetDefaults)

        let meals = try target.fetch(FetchDescriptor<PlannedMeal>())
        XCTAssertEqual(meals.count, 1)
        let restored = try XCTUnwrap(meals.first)
        XCTAssertEqual(restored.id, meal.id)
        XCTAssertEqual(restored.snapshotNutrition?.calories, 438,
                       "the restored meal must carry the backup's own snapshot, not a recomputation")

        let restoredOwners = MealOwners.load(from: targetDefaults)
        XCTAssertEqual(restoredOwners[meal.id.uuidString], "a1b2c3d4",
                       "a restored meal with no owner entry is stored but invisible to every client")
    }

    func testAMealWhoseRecipeIsAbsentFromTheFileIsSkipped() throws {
        let ctx = try context()
        let body = """
        { "v": 2, "clients": [],
          "meals": [ { "id": "\(UUID().uuidString)", "recipeID": "\(UUID().uuidString)",
                       "recipeName": "Ghost", "dayKey": "2026-09-14", "meal": "DINNER",
                       "servings": 1, "snapshotNutrition": null, "clientID": "a1b2c3d4" } ] }
        """
        try BackupCodec.restore(from: Data(body.utf8), into: ctx, defaults: isolatedDefaults("BackupCodecTests.meal.ghost"))
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<PlannedMeal>()).count, 0,
                       "a meal whose recipe never arrived cannot be shown; it must not be inserted orphaned")
    }

    // MARK: - Outdoor

    func testOutdoorRoundTripsThroughABackup() throws {
        let source = try makeContext()
        let client = Client(id: "outdoor-fixture", name: "Runner", displayUnit: "kg", platform: "web")
        let bests = [WireOutdoorBest(type: 0, count: 2, farthestMeters: 10001, longestSec: 3000, fastestSecPerKm: 300),
                     WireOutdoorBest(type: 1, count: 1, farthestMeters: 300, longestSec: 240, fastestSecPerKm: nil)]
        let route = WireLastRoute(type: 0, startedAtEpochSec: 1_789_259_200, durationSec: 1720,
                                  distanceMeters: 2795, climbMeters: 37, polyline: "_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        client.outdoorBests = bests
        client.lastRoute = route
        client.exportedAtEpochSec = 1_789_500_000
        source.insert(client)
        let day = TrainingDay(client: client, dayKey: "2026-09-13")
        let activities = [WireOutdoorActivity(type: 0, durationSec: 1720, distanceMeters: 2795, climbMeters: 37)]
        day.outdoor = activities
        source.insert(day)
        client.trainingDays.append(day)
        try source.save()

        let data = try BackupCodec.export(from: source)
        let target = try makeContext()
        try BackupCodec.restore(from: data, into: target)

        let restored = try XCTUnwrap(try target.fetch(FetchDescriptor<Client>()).first)
        XCTAssertEqual(restored.outdoorBests, bests)
        XCTAssertNil(restored.outdoorBests?[1].fastestSecPerKm, "a null best must come back null, not 0")
        XCTAssertEqual(restored.lastRoute, route)
        XCTAssertEqual(restored.exportedAtEpochSec, 1_789_500_000,
                       "without it, a stale link after a restore would replace the route")
        XCTAssertEqual(restored.trainingDays.first?.outdoor, activities)
    }

    func testABackupWrittenBeforeOutdoorStillRestores() throws {
        let body = """
        { "v": 2, "clients": [ { "id": "old", "name": "Old", "displayUnit": "lb",
            "days": [ { "dayKey": "2026-09-01", "sets": [], "foodEntries": [] } ] } ] }
        """
        let ctx = try makeContext()
        try BackupCodec.restore(from: Data(body.utf8), into: ctx)
        let restored = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Client>()).first)
        XCTAssertNil(restored.outdoorBests)
        XCTAssertNil(restored.lastRoute)
        XCTAssertNil(restored.exportedAtEpochSec)
        XCTAssertEqual(restored.trainingDays.first?.outdoor, [])
    }

    /// The names and object shapes Coach Android's backup writes, so a file
    /// moves between the two apps.
    func testRestoresOutdoorInCoachAndroidsBackupShape() throws {
        let body = """
        { "v": 2, "clients": [ { "id": "runner", "name": "Runner", "displayUnit": "kg",
            "exportedAtEpochSec": 1789500000,
            "outdoorBests": [
              { "type": 0, "count": 2, "farthestMeters": 10001, "longestSec": 3000, "fastestSecPerKm": 300 },
              { "type": 1, "count": 1, "farthestMeters": 300, "longestSec": 240, "fastestSecPerKm": null } ],
            "lastRoute": { "type": 0, "startedAtEpochSec": 1789259200, "durationSec": 1720,
                           "distanceMeters": 2795, "climbMeters": 37, "polyline": "_p~iF~ps|U_ulLnnqC" },
            "days": [
              { "dayKey": "2026-09-13", "sets": [], "foodEntries": [],
                "outdoor": [ { "type": 0, "durationSec": 1720, "distanceMeters": 2795, "climbMeters": 37 } ] },
              { "dayKey": "2026-09-14", "sets": [], "foodEntries": [], "outdoor": [] } ] } ] }
        """
        let ctx = try makeContext()
        try BackupCodec.restore(from: Data(body.utf8), into: ctx)

        let client = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Client>()).first)
        XCTAssertEqual(client.exportedAtEpochSec, 1_789_500_000)
        XCTAssertEqual(client.outdoorBests, [
            WireOutdoorBest(type: 0, count: 2, farthestMeters: 10001, longestSec: 3000, fastestSecPerKm: 300),
            WireOutdoorBest(type: 1, count: 1, farthestMeters: 300, longestSec: 240, fastestSecPerKm: nil)])
        XCTAssertEqual(client.lastRoute, WireLastRoute(type: 0, startedAtEpochSec: 1_789_259_200, durationSec: 1720,
                                                       distanceMeters: 2795, climbMeters: 37,
                                                       polyline: "_p~iF~ps|U_ulLnnqC"))
        let days = client.trainingDays.sorted { $0.dayKey < $1.dayKey }
        XCTAssertEqual(days[0].outdoor, [WireOutdoorActivity(type: 0, durationSec: 1720, distanceMeters: 2795, climbMeters: 37)])
        XCTAssertEqual(days[1].outdoor, [])
    }

    func testWritesOutdoorInCoachAndroidsBackupShape() throws {
        let ctx = try makeContext()
        let client = Client(id: "runner", name: "Runner", displayUnit: "lb", platform: "and")
        client.outdoorBests = [WireOutdoorBest(type: 1, count: 1, farthestMeters: 300, longestSec: 240, fastestSecPerKm: nil)]
        client.lastRoute = WireLastRoute(type: 0, startedAtEpochSec: 5, durationSec: 6, distanceMeters: 7,
                                         climbMeters: 8, polyline: "_p~iF~ps|U_ulLnnqC")
        client.exportedAtEpochSec = 9
        ctx.insert(client)
        let day = TrainingDay(client: client, dayKey: "2026-09-13")
        day.outdoor = [WireOutdoorActivity(type: 2, durationSec: 1, distanceMeters: 2, climbMeters: 3)]
        ctx.insert(day)
        client.trainingDays.append(day)
        let empty = TrainingDay(client: client, dayKey: "2026-09-14")
        ctx.insert(empty)
        client.trainingDays.append(empty)
        try ctx.save()

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: BackupCodec.export(from: ctx)) as? [String: Any])
        let written = try XCTUnwrap((json["clients"] as? [[String: Any]])?.first)
        XCTAssertEqual(written["exportedAtEpochSec"] as? Int, 9)
        let best = try XCTUnwrap((written["outdoorBests"] as? [[String: Any]])?.first)
        XCTAssertEqual(best["farthestMeters"] as? Int, 300)
        XCTAssertEqual(best["count"] as? Int, 1)
        let route = try XCTUnwrap(written["lastRoute"] as? [String: Any])
        XCTAssertEqual(route["polyline"] as? String, "_p~iF~ps|U_ulLnnqC", "the polyline as received, not points")
        XCTAssertEqual(route["startedAtEpochSec"] as? Int, 5)
        let days = try XCTUnwrap(written["days"] as? [[String: Any]])
        let outdoor = days.first { $0["dayKey"] as? String == "2026-09-13" }?["outdoor"] as? [[String: Any]]
        XCTAssertEqual(outdoor?.first?["type"] as? Int, 2)
        XCTAssertEqual(outdoor?.first?["climbMeters"] as? Int, 3)
        let none = days.first { $0["dayKey"] as? String == "2026-09-14" }?["outdoor"] as? [Any]
        XCTAssertEqual(none?.count, 0, "an empty array when none, as Coach Android writes")
    }
}
