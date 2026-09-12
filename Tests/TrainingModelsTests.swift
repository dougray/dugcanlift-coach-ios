import XCTest
import SwiftData
import LiftCore
@testable import Coach

final class TrainingModelsTests: XCTestCase {

    private func context() throws -> ModelContext {
        // Routine and friends come from the package; ScheduledSession is
        // Coach's. Both in one schema is the case the ClientFoodEntry rename
        // made safe -- see EntityNameCollisionTests.
        let schema = Schema([
            Client.self, Goal.self, TrainingDay.self, ExerciseSet.self,
            ClientFoodEntry.self,
            Routine.self, RoutineExercise.self, RoutinePrescribedSet.self,
            ScheduledSession.self,
        ])
        return ModelContext(try ModelContainer(
            for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    func testATemplateSurvivesASaveWithItsExercisesAndSets() throws {
        let ctx = try context()
        let routine = Routine(name: "Lower A")
        let squat = RoutineExercise(name: "Back Squat", equipment: "Barbell", orderIndex: 0)
        squat.routine = routine
        let top = RoutinePrescribedSet(orderIndex: 0)
        top.targetWeightKg = 102.06
        top.targetReps = 5
        top.exercise = squat
        ctx.insert(routine); ctx.insert(squat); ctx.insert(top)
        try ctx.save()

        let back = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Routine>()).first)
        XCTAssertEqual(back.name, "Lower A")
        XCTAssertEqual(back.orderedExercises.count, 1)
        XCTAssertEqual(back.orderedExercises.first?.orderedSets.count, 1)
        XCTAssertEqual(back.orderedExercises.first?.orderedSets.first?.targetReps, 5)
    }

    func testCoachAndPackageModelsCoexistInOneSchema() throws {
        // Train is the feature that first puts LiftCore models into Coach's
        // store, so this checks that this app's ACTUAL container list builds
        // and saves.
        //
        // It is not the entity-name collision test, despite reading like one:
        // none of these LiftCore types share a simple name with a Coach
        // model, so they could not collide whatever the names were. The real
        // regression test for that is
        // EntityNameCollisionTests.testCoachAndLiftCoreFoodTypesCanShareOneSchema
        // in ModelsTests.swift, which deliberately puts ClientFoodEntry and
        // LiftCore.FoodEntry in one schema together.
        let ctx = try context()
        let client = Client(id: "c1", name: "Ana", displayUnit: "lb", platform: "ios")
        let food = ClientFoodEntry(day: nil, foodName: "Oats", servings: 1,
                                   calories: 379, proteinG: 13, fatG: 6, carbsG: 68,
                                   fiberG: 10, meal: 0)
        ctx.insert(client); ctx.insert(food); ctx.insert(Routine(name: "Lower A"))
        XCTAssertNoThrow(try ctx.save())
    }

    func testASessionBooksATemplateOntoADay() throws {
        let ctx = try context()
        let routine = Routine(name: "Lower A")
        ctx.insert(routine)
        let session = ScheduledSession(clientID: "c1", dayKey: "2026-09-14", routineID: routine.id)
        ctx.insert(session)
        try ctx.save()

        let found = try ctx.fetch(FetchDescriptor<ScheduledSession>())
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.dayKey, "2026-09-14")
        XCTAssertEqual(found.first?.routineID, routine.id)
    }

    func testOneTemplateCanBeBookedOnSeveralDays() throws {
        // The normal case for a programme that repeats a week.
        let ctx = try context()
        let routine = Routine(name: "Lower A")
        ctx.insert(routine)
        for day in ["2026-09-14", "2026-09-17", "2026-09-21"] {
            ctx.insert(ScheduledSession(clientID: "c1", dayKey: day, routineID: routine.id))
        }
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ScheduledSession>()).count, 3)
    }

    func testDeletingARoutineSweepsItsOrphanedSessions() throws {
        // `ScheduledSession.routineID` is a plain value, not a relationship
        // (see this project's CLAUDE.md, "Train"), so deleting a `Routine`
        // directly does not cascade -- it leaves orphaned rows behind
        // forever. `deleteRoutineAndSessions` is the reaper; this pins that
        // it actually removes both the routine and every session booked
        // against it, and nothing else.
        let ctx = try context()
        let doomed = Routine(name: "Lower A")
        let survivor = Routine(name: "Upper B")
        ctx.insert(doomed); ctx.insert(survivor)
        ctx.insert(ScheduledSession(clientID: "c1", dayKey: "2026-09-14", routineID: doomed.id))
        ctx.insert(ScheduledSession(clientID: "c1", dayKey: "2026-09-17", routineID: doomed.id))
        ctx.insert(ScheduledSession(clientID: "c1", dayKey: "2026-09-15", routineID: survivor.id))
        try ctx.save()

        let allSessions = try ctx.fetch(FetchDescriptor<ScheduledSession>())
        ScheduledSession.deleteRoutineAndSessions(doomed, from: allSessions, in: ctx)
        try ctx.save()

        let remainingRoutines = try ctx.fetch(FetchDescriptor<Routine>())
        XCTAssertEqual(remainingRoutines.map(\.name), ["Upper B"])

        let remainingSessions = try ctx.fetch(FetchDescriptor<ScheduledSession>())
        XCTAssertEqual(remainingSessions.count, 1)
        XCTAssertEqual(remainingSessions.first?.routineID, survivor.id)
    }
}
