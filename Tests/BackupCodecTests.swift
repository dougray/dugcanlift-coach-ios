import XCTest
import SwiftData
import LiftCore
@testable import Coach

final class BackupCodecTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Client.self, Goal.self, TrainingDay.self, ExerciseSet.self, ClientFoodEntry.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func context() throws -> ModelContext {
        let schema = Schema([
            Client.self, Goal.self, TrainingDay.self, ExerciseSet.self, ClientFoodEntry.self,
            Routine.self, RoutineExercise.self, RoutinePrescribedSet.self, ScheduledSession.self,
            Recipe.self, RecipeIngredient.self, PlannedMeal.self, ShoppingListCheck.self,
        ])
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

    func testRestoringAV1FileDoesNotWipeTheLibrary() throws {
        let ctx = try context()
        ctx.insert(Recipe(name: "Already here", servings: 2))
        try ctx.save()

        try BackupCodec.restore(from: Data("{\"v\":1,\"clients\":[]}".utf8), into: ctx)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Recipe>()).count, 1,
                       "a v1 file has no library; absent must not mean delete")
    }
}
