import XCTest
import SwiftData
import LiftCore
@testable import Coach

final class ModelsTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Client.self, Goal.self, TrainingDay.self, ExerciseSet.self, Coach.FoodEntry.self])
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
        // Was one day high every evening: a client's dayKey is their LOCAL day,
        // and this compared it against a UTC "today".
        let client = Client(id: "c1", name: "Ana", displayUnit: "lb", platform: "ios")
        let day = TrainingDay(client: client, dayKey: DayKey.today)
        client.trainingDays.append(day)
        XCTAssertEqual(client.daysSinceLastLoggedDay, 0)
    }
}
