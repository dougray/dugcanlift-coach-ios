import XCTest
import SwiftData
import PDFKit
import LiftCore
@testable import Coach

final class PlanPrintoutTests: XCTestCase {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema(CoachSchema.models),
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func routine(_ name: String, in context: ModelContext) -> Routine {
        let routine = Routine(name: name)
        context.insert(routine)
        let squat = RoutineExercise(name: "Back Squat", equipment: "Barbell", orderIndex: 0, note: "Belt on the last set.")
        squat.routine = routine
        context.insert(squat)
        squat.prescribedSets = (0..<3).map { index in
            let set = RoutinePrescribedSet(orderIndex: index,
                                           targetWeightKg: PlanLinkEncoder.lbToKg(225), targetReps: 5)
            context.insert(set)
            return set
        }
        return routine
    }

    func testOnlyBookedDaysInOrderAndARemovedTemplateSaysSo() throws {
        let context = try context()
        let lower = routine("Lower A", in: context)
        let week = PlanWeek(startDayKey: "2026-10-26").days
        let sessions = [
            ScheduledSession(clientID: "c1", dayKey: "2026-10-29", routineID: UUID()),
            ScheduledSession(clientID: "c1", dayKey: "2026-10-26", routineID: lower.id),
        ]
        let days = PlanPrintout.days(weekDays: week, sessions: sessions, routines: [lower],
                                     sides: PrescriptionSides(), types: PrescriptionTypes())
        XCTAssertEqual(days.map(\.dayKey), ["2026-10-26", "2026-10-29"])
        XCTAssertEqual(days[0].workouts.first?.name, "Lower A")
        XCTAssertEqual(days[0].workouts.first?.exercises,
                       [.init(name: lower.orderedExercises[0].displayName,
                              prescription: "3 × 225 lb × 5", note: "Belt on the last set.")])
        XCTAssertEqual(days[1].workouts, [.init(name: "Removed workout", exercises: [])])
    }

    func testThePDFCarriesTheWeek() throws {
        let context = try context()
        let lower = routine("Lower A", in: context)
        let days = PlanPrintout.days(
            weekDays: PlanWeek(startDayKey: "2026-10-26").days,
            sessions: [ScheduledSession(clientID: "c1", dayKey: "2026-10-26", routineID: lower.id)],
            routines: [lower], sides: PrescriptionSides(), types: PrescriptionTypes())
        let data = PlanPrintout.pdf(clientName: "Jordan Reyes", weekStart: "2026-10-26",
                                    coachName: "Doug", days: days)
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 1)
        let text = document.string ?? ""
        XCTAssertTrue(text.contains("Jordan Reyes"))
        XCTAssertTrue(text.contains("from Doug"))
        XCTAssertTrue(text.contains("Lower A"))
        XCTAssertTrue(text.contains("3 × 225 lb × 5"))
    }

    /// A long programme goes on to a second page rather than off the bottom.
    func testALongWeekRunsOntoMorePages() throws {
        let exercises = (0..<80).map { PlanPrintout.Exercise(name: "Exercise \($0)", prescription: "3 × 10", note: nil) }
        let days = [PlanPrintout.Day(dayKey: "2026-10-26", workouts: [.init(name: "Big", exercises: exercises)])]
        let data = PlanPrintout.pdf(clientName: "A", weekStart: "2026-10-26", coachName: nil, days: days)
        XCTAssertGreaterThan(try XCTUnwrap(PDFDocument(data: data)).pageCount, 1)
    }

    func testTheFileNameIsSafe() {
        XCTAssertEqual(PlanPrintout.fileName(clientName: "Jo/Rey:es", weekStart: "2026-10-26"),
                       "JoReyes – week of 2026-10-26.pdf")
    }
}
