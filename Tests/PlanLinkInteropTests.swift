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

    func testTheFixtureIsNotSomethingThisCodeCouldHaveWritten() throws {
        // Same provenance check `PlanLinkMealInteropTests` already has for its
        // own fixture, copied here: `Codable` discards key order, so nothing
        // downstream of `decode` can tell web JSON from Coach JSON. The one
        // property that distinguishes a fixture the web app wrote from one
        // this codebase wrote is upstream of decoding -- Coach's JSONEncoder
        // sets `.sortedKeys`, so its top-level keys always come out
        // alphabetically (`l` before `n` before `r` before `t` before `v`).
        // The web app builds an ordinary object literal, so its keys come out
        // in insertion order -- `v` first, per PLAN-FORMAT's field order.
        // Without this check, this file's only "interop" test could silently
        // be exercising a fixture regenerated from Coach's own encoder, which
        // would prove nothing.
        let fragment = try fixture()
        XCTAssertTrue(fragment.hasPrefix("1z"), "expected the deflate-raw envelope, got: \(fragment.prefix(8))")
        let payloadString = String(fragment.dropFirst(2))
        let compressed = try XCTUnwrap(CompactEncoding.base64URLDecode(payloadString))
        let jsonData = try XCTUnwrap(CompactEncoding.inflateRaw(compressed))
        let json = try XCTUnwrap(String(data: jsonData, encoding: .utf8))

        XCTAssertTrue(json.hasPrefix("{\"v\""),
                      "web-app JSON preserves insertion order (v first); got: \(json.prefix(20))")
        XCTAssertFalse(json.hasPrefix("{\"l\""),
                       "Coach's .sortedKeys would put l first -- this shape means the fixture " +
                       "was regenerated from Coach's own encoder and no longer proves interop")
    }

    func testTheWebAppAlwaysSendsREmptyAndMEmptyForATrainingOnlyWeek() throws {
        // Pins the web fact from the OTHER side of the false claim corrected
        // in PlanLinkMealInteropTests: the web app's encodePlan does NOT omit
        // empty r/m -- it always emits them, even empty, for a training-only
        // week. This fixture (all training, no meals) decodes with `r` and
        // `m` present as EMPTY arrays, not nil. Coach's own encoder omits
        // both when empty instead -- PlanLinkEncoder.swift's comment -- which
        // is Coach's own choice, permitted by PLAN-FORMAT ("a coach who plans
        // only training sends a payload with no r or m at all") and safe
        // because every decoder treats all four keys as optional.
        let payload = try PlanLinkCodec.decode(fragment: try fixture(),
                                               expectedLifterID: lifterIDFromFixture())
        XCTAssertEqual(payload.r, [], "the web app sends r as an empty array for a training-only week, not nil")
        XCTAssertEqual(payload.m, [], "the web app sends m as an empty array for a training-only week, not nil")
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
