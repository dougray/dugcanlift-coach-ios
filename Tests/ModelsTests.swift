import XCTest
import SwiftData
import LiftCore
@testable import Coach

final class ModelsTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Client.self, Goal.self, TrainingDay.self, ExerciseSet.self, ClientFoodEntry.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    func testDayKeyRoundTrips() {
        let key = "2026-09-10"
        let date = try? XCTUnwrap(DayKey.date(from: key))
        XCTAssertEqual(date.map { DayKey.string(from: $0) }, key)
    }

    func testDayKeyAddingDaysCrossesMonthBoundary() {
        XCTAssertEqual(DayKey.adding(days: 5, to: "2026-08-28"), "2026-09-02")
    }

    func testDayKeyAddingNegativeDays() {
        XCTAssertEqual(DayKey.adding(days: -3, to: "2026-09-10"), "2026-09-07")
    }

    func testClientPersistsWithRelatedTrainingDay() throws {
        let context = try makeContext()
        let client = Client(id: "b7f3a1c8", name: "Jordan Reyes", displayUnit: "lb", platform: "ios")
        context.insert(client)

        let day = TrainingDay(client: client, dayKey: "2026-09-10", sessionName: "Push Day", focus: "POWERLIFTING")
        context.insert(day)

        try context.save()

        let fetched = try context.fetch(FetchDescriptor<TrainingDay>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.client?.id, "b7f3a1c8")
    }

    func testExerciseSetDefaultsIsWarmupFalse() {
        let set = ExerciseSet(exerciseName: "Back Squat", equipment: "Barbell", weightLb: 225, reps: 5)
        XCTAssertFalse(set.isWarmup)
    }

    func testDaysSinceLastLoggedIsZeroForAClientWhoLoggedToday() {
        // Was one day high every evening: a client's dayKey is their LOCAL
        // day, and this compared it against a UTC "today".
        //
        // The expected key is built HERE, with its own formatter, rather than
        // from `DayKey.today`. Using `DayKey` on both sides would put the
        // same code path on either end of the assertion, so the test would
        // pass whether that path were local or UTC — it would pin nothing.
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let localToday = formatter.string(from: .now)

        let client = Client(id: "c1", name: "Ana", displayUnit: "lb", platform: "ios")
        let day = TrainingDay(client: client, dayKey: localToday)
        client.trainingDays.append(day)

        XCTAssertEqual(client.daysSinceLastLoggedDay, 0,
                       "a client who logged today must not read as silent")
    }

    func testDaysSinceLastLoggedWouldHaveBeenWrongUnderUTC() {
        // Pins the actual defect. A UTC "today" is already tomorrow for
        // anyone west of Greenwich late in the evening, so a client who
        // logged today measured as a day silent. This asserts the two
        // formatters genuinely disagree at that hour, which is the thing
        // that made the old code wrong -- and it fails if someone ever
        // reintroduces a UTC day key.
        let evening = ISO8601DateFormatter().date(from: "2026-09-11T20:30:00-05:00")!

        let chicago = DateFormatter()
        chicago.locale = Locale(identifier: "en_US_POSIX")
        chicago.timeZone = TimeZone(identifier: "America/Chicago")!
        chicago.dateFormat = "yyyy-MM-dd"

        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")!
        utc.dateFormat = "yyyy-MM-dd"

        XCTAssertEqual(chicago.string(from: evening), "2026-09-11")
        XCTAssertEqual(utc.string(from: evening), "2026-09-12")

        // And DayKey follows the local one, not UTC.
        XCTAssertEqual(DayKey.make(from: evening,
                                   timeZone: TimeZone(identifier: "America/Chicago")!),
                       "2026-09-11")
        XCTAssertEqual(DayKey.daysBetween("2026-09-11", chicago.string(from: evening)), 0)
        XCTAssertEqual(DayKey.daysBetween("2026-09-11", utc.string(from: evening)), 1,
                       "this 1 is the bug the fix removed")
    }
}


/// The reason `ClientFoodEntry` is not called `FoodEntry`.
final class EntityNameCollisionTests: XCTestCase {

    func testCoachAndLiftCoreFoodTypesCanShareOneSchema() throws {
        // SwiftData identifies an entity by its class's SIMPLE name. Before
        // the rename both of these were "FoodEntry", and putting them in one
        // schema silently produced a single entity carrying whichever type
        // was listed last -- then failed at save() with a Core Data
        // validation error naming the other type's properties.
        //
        // Cook reaches this state as soon as LiftCore.PlannedMeal is stored
        // here, since makeFoodEntry() returns a LiftCore.FoodEntry.
        let schema = Schema([
            Client.self, Goal.self, TrainingDay.self, ExerciseSet.self,
            ClientFoodEntry.self,
            LiftCore.FoodEntry.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        // Two entities, not one collapsed into the other.
        let names = Set(schema.entities.map(\.name))
        XCTAssertTrue(names.contains("ClientFoodEntry"))
        XCTAssertTrue(names.contains("FoodEntry"))

        // And a Coach row actually saves, which is where the old collision
        // surfaced -- the schema built fine either way.
        let client = Client(id: "c1", name: "Ana", displayUnit: "lb", platform: "ios")
        let day = TrainingDay(client: client, dayKey: DayKey.today)
        let food = ClientFoodEntry(day: day, foodName: "Chicken breast", servings: 1.4,
                                   calories: 231, proteinG: 43, fatG: 5, carbsG: 0,
                                   fiberG: 0, meal: 2)
        context.insert(client)
        context.insert(day)
        context.insert(food)
        XCTAssertNoThrow(try context.save())

        let saved = try context.fetch(FetchDescriptor<ClientFoodEntry>())
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.foodName, "Chicken breast")
    }
}
