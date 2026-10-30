import XCTest
import SwiftData
import LiftCore
@testable import Coach

/// `PrescriptionText` is a port of Coach web's `coach/prescriptions.js`
/// (`prescriptionText`, `setText`, `summary`), the reference implementation.
/// Every expected string here is what web's own functions return for the same
/// set, run through node -- Coach Android's `PrescriptionSides` reads the same
/// words, in its own kilograms. Change a string in every build or in none.
///
/// The locale is pinned only so a grouped number can be asserted; the app uses
/// the reader's, as web's `toLocaleString()` does.
final class PrescriptionTextTests: XCTestCase {

    private let us = Locale(identifier: "en_US")

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema(CoachSchema.models),
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    /// One set, entered in pounds as the editor's field takes it.
    private struct S {
        var lb: Double? = nil
        var reps: Int? = nil
        var rpe: Double? = nil
        var seconds: Int? = nil
        var metres: Double? = nil
        var side: SetSide? = nil
        var kind: SetKind? = nil
    }

    private func set(_ s: S, order: Int = 0, in context: ModelContext) -> RoutinePrescribedSet {
        let set = RoutinePrescribedSet(orderIndex: order, targetWeightKg: s.lb.map(PlanLinkEncoder.lbToKg),
                                       targetReps: s.reps, targetRPE: s.rpe,
                                       targetDurationSec: s.seconds, targetDistanceMeters: s.metres)
        context.insert(set)
        return set
    }

    private func text(_ s: S) throws -> String {
        PrescriptionText.text(set(s, in: try context()), side: s.side, kind: s.kind, locale: us)
    }

    /// A one-exercise summary, with its sides and kinds written the way the
    /// editor writes them.
    private func summary(eachSide: Bool = false, _ sets: [S]) throws -> String {
        let ctx = try context()
        let routine = Routine(name: "R")
        ctx.insert(routine)
        let exercise = RoutineExercise(name: "X", orderIndex: 0)
        exercise.routine = routine
        ctx.insert(exercise)
        if eachSide { PrescriptionSides.setEachSide(true, for: exercise.id, in: ctx) }
        for (order, spec) in sets.enumerated() {
            let made = set(spec, order: order, in: ctx)
            made.exercise = exercise
            PrescriptionSides.setSide(spec.side, for: made.id, in: ctx)
            PrescriptionTypes.setKind(spec.kind, for: made.id, in: ctx)
        }
        try ctx.save()
        return PrescriptionText.summary(exercise, sides: PrescriptionSides.load(from: ctx),
                                        types: PrescriptionTypes.load(from: ctx), locale: us)
    }

    // MARK: - One set

    func testWeightAndRepsCarryNoUnitAndAWeightAloneDoes() throws {
        XCTAssertEqual(try text(S(lb: 225, reps: 5)), "225 × 5")
        XCTAssertEqual(try text(S(reps: 5)), "5 reps")
        XCTAssertEqual(try text(S(lb: 225)), "225 lb")
    }

    func testEffortIsAnAtSignWrittenAsJavaScriptWritesANumber() throws {
        XCTAssertEqual(try text(S(lb: 225, reps: 5, rpe: 8)), "225 × 5 · @8")
        XCTAssertEqual(try text(S(lb: 225, reps: 5, rpe: 8.5)), "225 × 5 · @8.5")
        XCTAssertEqual(try text(S(rpe: 7)), "@7")
        // A "." decimal whatever the reader's locale: web concatenates the number.
        let set = set(S(reps: 5, rpe: 8.5), in: try context())
        XCTAssertEqual(PrescriptionText.text(set, side: nil, locale: Locale(identifier: "de_DE")), "5 reps · @8.5")
    }

    func testADurationIsMinutesAndSecondsFromAMinuteUp() throws {
        XCTAssertEqual(try text(S(seconds: 600)), "10:00")
        XCTAssertEqual(try text(S(seconds: 60)), "1:00")
        XCTAssertEqual(try text(S(seconds: 3725)), "62:05")
        XCTAssertEqual(try text(S(seconds: 45)), "45s")
        XCTAssertEqual(try text(S(seconds: 0)), "0s")
    }

    func testADistanceIsWholeMetresGroupedWithASpace() throws {
        XCTAssertEqual(try text(S(metres: 1600)), "1,600 m")
        XCTAssertEqual(try text(S(metres: 400)), "400 m")
        XCTAssertEqual(try text(S(metres: 1609.5)), "1,610 m")
        let set = set(S(metres: 1600), in: try context())
        XCTAssertEqual(PrescriptionText.text(set, side: nil, locale: Locale(identifier: "de_DE")), "1.600 m")
    }

    func testTheClausesRunInWebsOrder() throws {
        XCTAssertEqual(try text(S(seconds: 600, metres: 1600)), "1,600 m · 10:00")
        XCTAssertEqual(try text(S(lb: 135, reps: 10, rpe: 9, seconds: 30, metres: 20)),
                       "135 × 10 · 20 m · 30s · @9")
    }

    func testAConditioningPieceKeepsItsSideAndKind() throws {
        XCTAssertEqual(try text(S(seconds: 600, metres: 1600, side: .left)), "1,600 m · 10:00 L")
        XCTAssertEqual(try text(S(lb: 30, reps: 12, side: .left, kind: .drop)), "30 × 12 L drop")
        XCTAssertEqual(try text(S(lb: 65, reps: 4, kind: .restPause)), "65 × 4 rest-pause")
    }

    func testBlankIsLeftOutAndNeverBecomesAZero() throws {
        XCTAssertEqual(try text(S()), "as written")
        XCTAssertEqual(try text(S(lb: 0, reps: 0)), "0 × 0")
        XCTAssertEqual(try text(S(seconds: 600)), "10:00")
    }

    func testWeightsArePoundsRoundedWholeAndGrouped() throws {
        // Web stores 22.5 lb and rounds it to 23; here it went through
        // kilograms and must not come back as 22.4999... and round down.
        XCTAssertEqual(try text(S(lb: 22.5, reps: 10)), "23 × 10")
        XCTAssertEqual(try text(S(lb: 1000, reps: 1)), "1,000 × 1")
    }

    // MARK: - An exercise

    func testSetsCollapseOnWhatTheyPrescribeNotOnTheirText() throws {
        let squat = S(lb: 225, reps: 5, rpe: 8)
        XCTAssertEqual(try summary([squat, squat, squat]), "3 × 225 × 5 · @8")
        XCTAssertEqual(try summary([S(lb: 225, reps: 5), S(lb: 225.4, reps: 5)]), "225 × 5, 225 × 5")
        XCTAssertEqual(try summary([S(), S()]), "2 × as written")
    }

    func testEachSideReadsWebsWords() throws {
        let run = S(seconds: 600, metres: 1600)
        var left = run
        left.side = .left
        XCTAssertEqual(try summary(eachSide: true, [run, run, left]), "2 × 1,600 m · 10:00 each side + 1 L")
        XCTAssertEqual(try summary(eachSide: true, [S(reps: 10), S(reps: 12, side: .right, kind: .drop)]),
                       "10 reps each side + 12 reps R drop")
    }
}
