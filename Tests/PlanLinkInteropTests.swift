import XCTest
import LiftCore
@testable import Coach

/// The only test in this repo that proves interoperability rather than
/// self-consistency: bytes produced by the web app, read by this code.
final class PlanLinkInteropTests: XCTestCase {

    private func fixture() throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self)
            .url(forResource: "web-plan-link", withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testDecodesAPlanLinkTheWebAppProduced() throws {
        let payload = try PlanLinkCodec.decode(fragment: try fixture(),
                                               expectedLifterID: lifterIDFromFixture())
        let workout = try XCTUnwrap(payload.w?.first)
        XCTAssertEqual(workout.n, "Lower A")

        let exercise = try XCTUnwrap(workout.e.first)
        XCTAssertEqual(exercise.n, "Back Squat")
        XCTAssertEqual(exercise.q, "Barbell")
        XCTAssertEqual(exercise.s.count, 3)

        // Pounds on the wire, as PLAN-FORMAT specifies.
        XCTAssertEqual(try XCTUnwrap(exercise.s[0][0]), 225, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(exercise.s[2][0]), 245, accuracy: 0.5)
    }

    func testCoachProducesTheSameShapeTheWebAppDoes() throws {
        // Build the same workout through Coach's encoder and compare the
        // decoded structure field by field. Not byte equality -- key order
        // and float formatting legitimately differ between two encoders --
        // but every value a client will see must match.
        let web = try PlanLinkCodec.decode(fragment: try fixture(),
                                           expectedLifterID: lifterIDFromFixture())

        let routine = Routine(name: "Lower A")
        let squat = RoutineExercise(name: "Back Squat", equipment: "Barbell", orderIndex: 0)
        squat.routine = routine
        for (i, lb) in [225.0, 225.0, 245.0].enumerated() {
            let set = RoutinePrescribedSet(orderIndex: i)
            set.targetWeightKg = PlanLinkEncoder.lbToKg(lb)
            set.targetReps = i == 2 ? 3 : 5
            set.exercise = squat
        }

        let mine = try PlanLinkCodec.decode(
            fragment: PlanLinkEncoder.fragment(routines: [routine], sessions: [],
                                               lifterID: lifterIDFromFixture(),
                                               coachName: "Doug"),
            expectedLifterID: lifterIDFromFixture())

        let webSets = try XCTUnwrap(web.w?.first?.e.first?.s)
        let mySets = try XCTUnwrap(mine.w?.first?.e.first?.s)
        XCTAssertEqual(mySets.count, webSets.count)
        for (a, b) in zip(mySets, webSets) {
            XCTAssertEqual(a.count, b.count, "tuple lengths differ — trimming disagrees")
            for (x, y) in zip(a, b) {
                if let x, let y { XCTAssertEqual(x, y, accuracy: 0.5) } else { XCTAssertNil(x); XCTAssertNil(y) }
            }
        }
    }

    /// The fixture addresses whichever client it was built for. The brief's
    /// original helper re-decoded the fixture with `expectedLifterID: nil`,
    /// but `PlanLinkCodec.decode(fragment:expectedLifterID:)` takes a
    /// non-optional `String` — widening that shared, shipped API is not this
    /// task's call to make (see task-3-report.md). The fixture's lifter id is
    /// known (`a1b2c3d4`, verified by decoding it directly), so it is
    /// hard-coded here instead.
    private func lifterIDFromFixture() -> String {
        "a1b2c3d4"
    }
}
