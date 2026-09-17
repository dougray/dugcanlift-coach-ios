import XCTest
import SwiftData
import LiftCore
@testable import Coach

/// A port of Coach Android's `ClientRemovalTest.kt`, case for case, against
/// Coach's own store. The two apps must agree about what a coach loses when
/// they remove a client, and about the sentence they read before they do.
final class ClientRemovalTests: XCTestCase {

    // MARK: - Fixture

    /// The app's real schema, so the cascade rules under test are the shipped
    /// ones rather than a narrower set assembled here.
    private func context() throws -> ModelContext {
        let schema = Schema(CoachSchema.models)
        return ModelContext(try ModelContainer(
            for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func isolatedDefaults(_ name: String) -> UserDefaults {
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    /// Jordan: 2 logged days, 2 planned meals, 1 booked session, 1 ticked item.
    /// Sam: 1 logged day, 1 planned meal, 1 booked session.
    /// Plus a recipe, a routine, and one planned meal owned by nobody.
    private struct Fixture {
        let context: ModelContext
        let defaults: UserDefaults
        let recipe: Recipe
        let routine: Routine
        /// The meal with no entry in `cookPlanOwners` -- it belongs to no
        /// client and must survive any client's removal.
        let unownedMeal: PlannedMeal
    }

    private func fixture(_ name: String) throws -> Fixture {
        let context = try context()
        let defaults = isolatedDefaults(name)

        let jordan = Client(id: "jordan", name: "Jordan Reyes", displayUnit: "lb", platform: "ios")
        let sam = Client(id: "sam", name: "Sam Ortiz", displayUnit: "kg", platform: "and")
        context.insert(jordan)
        context.insert(sam)

        let goal = Goal(client: jordan, calories: 2600, proteinG: 180, fatG: 80, carbsG: 280, fiberG: 30)
        context.insert(goal)
        jordan.goal = goal

        for key in ["2026-09-10", "2026-09-11"] {
            let day = TrainingDay(client: jordan, dayKey: key, sessionName: "Push Day")
            context.insert(day)
            jordan.trainingDays.append(day)
            let set = ExerciseSet(day: day, exerciseName: "Back Squat", equipment: "Barbell",
                                  weightLb: 225, reps: 5)
            context.insert(set)
            day.sets.append(set)
            let food = ClientFoodEntry(day: day, foodName: "Oats", servings: 1, calories: 380,
                                       proteinG: 13, fatG: 7, carbsG: 66, fiberG: 9, meal: 0)
            context.insert(food)
            day.foodEntries.append(food)
        }
        let samDay = TrainingDay(client: sam, dayKey: "2026-09-11", sessionName: "Pull Day")
        context.insert(samDay)
        sam.trainingDays.append(samDay)

        let recipe = Recipe(name: "Beef Chilli", servings: 4)
        context.insert(recipe)
        let routine = Routine(name: "Lower A")
        context.insert(routine)

        let plannedFor = try XCTUnwrap(DayKey.date(from: "2026-09-14"))
        func meal(_ type: MealType) throws -> PlannedMeal {
            let meal = PlannedMeal(recipe: recipe, mealType: type, plannedFor: plannedFor)
            context.insert(meal)
            return meal
        }
        let jordanBreakfast = try meal(.breakfast)
        let jordanDinner = try meal(.dinner)
        let samLunch = try meal(.lunch)
        let unowned = try meal(.snack)

        context.insert(ScheduledSession(clientID: "jordan", dayKey: "2026-09-14", routineID: routine.id))
        context.insert(ScheduledSession(clientID: "sam", dayKey: "2026-09-15", routineID: routine.id))
        context.insert(ClientShoppingCheck(clientID: "jordan", itemKey: "lean beef mince"))
        context.insert(ClientShoppingCheck(clientID: "sam", itemKey: "oats"))

        try context.save()

        MealOwners.save([
            jordanBreakfast.id.uuidString: "jordan",
            jordanDinner.id.uuidString: "jordan",
            samLunch.id.uuidString: "sam",
        ], to: defaults)

        return Fixture(context: context, defaults: defaults,
                       recipe: recipe, routine: routine, unownedMeal: unowned)
    }

    private func ids<T: PersistentModel>(_ type: T.Type, in context: ModelContext,
                                         _ key: (T) -> String) throws -> [String] {
        try context.fetch(FetchDescriptor<T>()).map(key).sorted()
    }

    // MARK: - impact

    func testImpactCountsTheClientsDaysMealsAndSessions() throws {
        let f = try fixture("ClientRemovalTests.impact")
        defer { f.defaults.removePersistentDomain(forName: "ClientRemovalTests.impact") }

        XCTAssertEqual(ClientRemoval.impact(clientID: "jordan", in: f.context, defaults: f.defaults),
                       RemovalImpact(clientID: "jordan", clientName: "Jordan Reyes",
                                     loggedDays: 2, plannedMeals: 2, bookedSessions: 1),
                       "the confirmation's counts are what the coach decides on")
    }

    func testImpactOfAClientNotOnThisDeviceIsNil() throws {
        let f = try fixture("ClientRemovalTests.missing")
        defer { f.defaults.removePersistentDomain(forName: "ClientRemovalTests.missing") }

        XCTAssertNil(ClientRemoval.impact(clientID: "nobody", in: f.context, defaults: f.defaults))
    }

    // MARK: - remove

    func testRemoveDeletesTheClientAndOnlyWhatWasPlannedForThem() throws {
        let f = try fixture("ClientRemovalTests.remove")
        defer { f.defaults.removePersistentDomain(forName: "ClientRemovalTests.remove") }

        let outcome = ClientRemoval.remove(clientID: "jordan", in: f.context, defaults: f.defaults)

        XCTAssertTrue(outcome.removed)
        XCTAssertEqual(outcome.message, "Removed Jordan Reyes.")

        XCTAssertEqual(try ids(Client.self, in: f.context, \.id), ["sam"])
        XCTAssertEqual(try ids(ScheduledSession.self, in: f.context, \.clientID), ["sam"],
                       "a session booked for a removed client can never be sent or edited")
        XCTAssertEqual(try ids(ClientShoppingCheck.self, in: f.context, \.clientID), ["sam"],
                       "one client's ticks are not another's, and not a ghost's")

        // Sam's lunch and the meal owned by nobody both stay; Jordan's two go.
        let meals = try f.context.fetch(FetchDescriptor<PlannedMeal>())
        XCTAssertEqual(meals.count, 2)
        XCTAssertTrue(meals.contains { $0.id == f.unownedMeal.id },
                      "a planned meal belonging to no client is not any client's to lose")

        // The days, and through them the sets and the foods, go by cascade.
        XCTAssertTrue(try f.context.fetch(FetchDescriptor<TrainingDay>()).allSatisfy { $0.client?.id == "sam" })
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<ExerciseSet>()).count, 0)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<ClientFoodEntry>()).count, 0)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<Goal>()).count, 0)

        // The coach's own library is untouched.
        XCTAssertEqual(try ids(Recipe.self, in: f.context, \.name), ["Beef Chilli"])
        XCTAssertEqual(try ids(Routine.self, in: f.context, \.name), ["Lower A"])
    }

    func testRemoveSweepsTheRemovedClientsEntriesOutOfTheOwnersMap() throws {
        let f = try fixture("ClientRemovalTests.owners")
        defer { f.defaults.removePersistentDomain(forName: "ClientRemovalTests.owners") }

        _ = ClientRemoval.remove(clientID: "jordan", in: f.context, defaults: f.defaults)

        let owners = MealOwners.load(from: f.defaults)
        XCTAssertEqual(owners.values.sorted(), ["sam"],
                       "an entry pointing at a removed client breaks the contract this key is")
    }

    func testAClientWithNothingPlannedLeavesTheOwnersMapAlone() throws {
        let f = try fixture("ClientRemovalTests.noWrite")
        defer { f.defaults.removePersistentDomain(forName: "ClientRemovalTests.noWrite") }

        let solo = Client(id: "solo", name: "Solo", displayUnit: "lb", platform: "web")
        f.context.insert(solo)
        try f.context.save()

        let before = f.defaults.data(forKey: MealOwners.key)
        _ = ClientRemoval.remove(clientID: "solo", in: f.context, defaults: f.defaults)

        XCTAssertEqual(f.defaults.data(forKey: MealOwners.key), before,
                       "a client who was never planned for must not cost a write")
    }

    func testRemovingAClientWhoIsAlreadyGoneChangesNothingAndDoesNotFail() throws {
        let f = try fixture("ClientRemovalTests.gone")
        defer { f.defaults.removePersistentDomain(forName: "ClientRemovalTests.gone") }

        let outcome = ClientRemoval.remove(clientID: "nobody", in: f.context, defaults: f.defaults)

        XCTAssertTrue(outcome.removed, "there is nothing left to remove, which is not a failure")
        XCTAssertEqual(outcome.message, ClientRemoval.alreadyGoneMessage)
        XCTAssertEqual(try ids(Client.self, in: f.context, \.id), ["jordan", "sam"])
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<PlannedMeal>()).count, 4)
    }

    // MARK: - What the coach reads

    func testTheConfirmationSaysWhatGoesAndWhatStays() throws {
        XCTAssertEqual(
            ClientRemoval.confirmationText(
                RemovalImpact(clientID: "jordan", clientName: "Jordan Reyes",
                              loggedDays: 2, plannedMeals: 2, bookedSessions: 1)),
            "Their 2 logged days will be removed from this device, and the 2 planned meals "
            + "and 1 booked session you made for them. Your recipes and routines stay. "
            + "A backup file you saved earlier still has them. This can't be undone.")

        XCTAssertEqual(
            ClientRemoval.confirmationText(
                RemovalImpact(clientID: "sam", clientName: "Sam",
                              loggedDays: 1, plannedMeals: 0, bookedSessions: 0)),
            "Their 1 logged day will be removed from this device. "
            + "Your recipes and routines stay. A backup file you saved earlier still has them. "
            + "This can't be undone.",
            "a count of zero is left out entirely rather than read aloud as none")
    }

    func testTheConfirmationNamesOnlyTheCountsThatAreThere() throws {
        func text(days: Int, meals: Int, sessions: Int) -> String {
            ClientRemoval.confirmationText(
                RemovalImpact(clientID: "x", clientName: "X", loggedDays: days,
                              plannedMeals: meals, bookedSessions: sessions))
        }

        XCTAssertTrue(text(days: 3, meals: 1, sessions: 0)
            .contains(", and the 1 planned meal you made for them."))
        XCTAssertTrue(text(days: 3, meals: 0, sessions: 4)
            .contains(", and the 4 booked sessions you made for them."))
        XCTAssertTrue(text(days: 0, meals: 0, sessions: 0)
            .hasPrefix("Their 0 logged days will be removed from this device. "),
            "a client who has logged nothing still reads as a client being removed")
        XCTAssertFalse(text(days: 2, meals: 0, sessions: 0).contains("planned"))
    }

    func testTheConfirmationTitleNamesTheClient() throws {
        XCTAssertEqual(
            ClientRemoval.confirmationTitle(
                RemovalImpact(clientID: "jordan", clientName: "Jordan Reyes",
                              loggedDays: 2, plannedMeals: 0, bookedSessions: 0)),
            "Remove Jordan Reyes?")
        XCTAssertEqual(ClientRemoval.confirmationTitle(nil), "",
                       "a view can hand this whatever it is holding, including nothing")
    }
}
