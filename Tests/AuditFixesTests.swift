import XCTest
import SwiftData
import LiftCore
@testable import Coach

/// The 2026-10-08 audit fixes that carry rules: what the delete and restore
/// alerts say, and taking an exercise or a set out of a workout.
final class AuditFixesTests: XCTestCase {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema(CoachSchema.models),
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    // MARK: Recipe delete

    func testRecipeDeleteWarningCountsThePlannedMeals() {
        XCTAssertEqual(CookView.deleteWarning(planned: 0), "This cannot be undone.")
        XCTAssertTrue(CookView.deleteWarning(planned: 1).hasPrefix("This also removes 1 planned meal built"))
        XCTAssertTrue(CookView.deleteWarning(planned: 3).hasPrefix("This also removes 3 planned meals built"))
    }

    // MARK: Restore

    func testRestoreWarningSaysTheRosterIsReplacedAndTheLibraryMerged() {
        let text = ConnectView.restoreWarning(clients: 12)
        XCTAssertTrue(text.hasPrefix("Restoring replaces your 12 clients and their logs"), text)
        XCTAssertTrue(text.contains("can't be undone"), text)
        XCTAssertTrue(text.contains("nothing in your library is deleted"), text)
        XCTAssertTrue(ConnectView.restoreWarning(clients: 1).contains("your 1 client and"))
    }

    func testRestoredNoteSaysWhatArrived() {
        XCTAssertTrue(ConnectView.restoredNote(clients: 1).hasPrefix("Restored 1 client."))
        XCTAssertTrue(ConnectView.restoredNote(clients: 4).hasPrefix("Restored 4 clients."))
    }

    // MARK: Workout editor removal

    private func workout(in ctx: ModelContext) -> Routine {
        let routine = Routine(name: "Lower A")
        ctx.insert(routine)
        for (i, name) in ["Back Squat", "Split Squat", "Calf Raise"].enumerated() {
            let exercise = RoutineExercise(name: name, orderIndex: i)
            exercise.routine = routine
            ctx.insert(exercise)
            for s in 0..<3 {
                let set = RoutinePrescribedSet(orderIndex: s)
                set.exercise = exercise
                ctx.insert(set)
            }
        }
        try? ctx.save()
        return routine
    }

    func testRemovingAnExerciseTakesItsSetsAndSidesAndRenumbers() throws {
        let ctx = try context()
        let routine = workout(in: ctx)
        let middle = routine.orderedExercises[1]
        PrescriptionSides.setEachSide(true, for: middle.id, in: ctx)
        PrescriptionSides.setSide(.left, for: middle.orderedSets[0].id, in: ctx)
        try ctx.save()

        PrescriptionSides.removeExercise(middle, in: ctx)
        try ctx.save()

        XCTAssertEqual(routine.orderedExercises.map(\.name), ["Back Squat", "Calf Raise"])
        XCTAssertEqual(routine.orderedExercises.map(\.orderIndex), [0, 1])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<RoutinePrescribedSet>()), 6)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<EachSideExercise>()), 0)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<PrescribedSetSide>()), 0)
    }

    func testRemovingASetTakesItsSideAndRenumbers() throws {
        let ctx = try context()
        let routine = workout(in: ctx)
        let squat = routine.orderedExercises[0]
        let first = squat.orderedSets[0]
        PrescriptionSides.setSide(.right, for: first.id, in: ctx)
        try ctx.save()

        PrescriptionSides.removeSet(first, in: ctx)
        try ctx.save()

        XCTAssertEqual(squat.orderedSets.count, 2)
        XCTAssertEqual(squat.orderedSets.map(\.orderIndex), [0, 1])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<PrescribedSetSide>()), 0)
    }
}
