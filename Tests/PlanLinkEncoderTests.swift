import XCTest
import SwiftData
import LiftCore
@testable import Coach

final class PlanLinkEncoderTests: XCTestCase {

    private func routine() -> (Routine, RoutineExercise, RoutinePrescribedSet) {
        let r = Routine(name: "Lower A")
        let e = RoutineExercise(name: "Back Squat", equipment: "Barbell", orderIndex: 0)
        e.routine = r
        let s = RoutinePrescribedSet(orderIndex: 0)
        s.exercise = e
        return (r, e, s)
    }

    /// Decodes a fragment back to the payload, the way LIFT does.
    private func decode(_ fragment: String) throws -> PlanPayload {
        try PlanLinkCodec.decode(fragment: fragment, expectedLifterID: "a1b2c3d4")
    }

    func testKilogramsBecomePoundsOnTheWire() throws {
        // THE test for this task. The package stores kg; PLAN-FORMAT's set
        // tuple is [weightLb, ...]. 102.06 kg is 225 lb. Skipping the
        // conversion ships a number 2.2x wrong, silently, to a real client.
        let (r, _, s) = routine()
        s.targetWeightKg = 102.06
        s.targetReps = 5

        let payload = try decode(PlanLinkEncoder.fragment(
            routines: [r], sessions: [], lifterID: "a1b2c3d4", coachName: "Doug"))

        let set = try XCTUnwrap(payload.w?.first?.e.first?.s.first)
        XCTAssertEqual(try XCTUnwrap(set[0]), 225, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(set[1]), 5)
    }

    func testAPrescriptionWithNoWeightSendsNullNotZero() throws {
        // "Five reps, you pick the weight". A zero here is a real, wrong
        // prescription rather than an absent one.
        let (r, _, s) = routine()
        s.targetReps = 5

        let payload = try decode(PlanLinkEncoder.fragment(
            routines: [r], sessions: [], lifterID: "a1b2c3d4", coachName: "Doug"))
        let set = try XCTUnwrap(payload.w?.first?.e.first?.s.first)
        XCTAssertNil(set[0])
        XCTAssertEqual(try XCTUnwrap(set[1]), 5)
    }

    func testTrailingNullsAreTrimmed() throws {
        // [225, 5] not [225, 5, null, null, null]. The format says so, and a
        // week of untrimmed sets is a materially longer link.
        let (r, _, s) = routine()
        s.targetWeightKg = 102.06
        s.targetReps = 5

        let payload = try decode(PlanLinkEncoder.fragment(
            routines: [r], sessions: [], lifterID: "a1b2c3d4", coachName: "Doug"))
        XCTAssertEqual(try XCTUnwrap(payload.w?.first?.e.first?.s.first).count, 2)
    }

    func testAConditioningPieceKeepsItsLeadingNulls() throws {
        // [null, null, null, 600, 1600] -- only TRAILING nulls are trimmed.
        let (r, _, s) = routine()
        s.targetDurationSec = 600
        s.targetDistanceMeters = 1600

        let payload = try decode(PlanLinkEncoder.fragment(
            routines: [r], sessions: [], lifterID: "a1b2c3d4", coachName: "Doug"))
        let set = try XCTUnwrap(payload.w?.first?.e.first?.s.first)
        XCTAssertEqual(set.count, 5)
        XCTAssertNil(set[0]); XCTAssertNil(set[1]); XCTAssertNil(set[2])
        XCTAssertEqual(try XCTUnwrap(set[3]), 600)
        XCTAssertEqual(try XCTUnwrap(set[4]), 1600)
    }

    func testSetsAreListedIndividuallyNotCollapsed() throws {
        // Coaches ramp. 225/225/245 has no count-and-tuple representation.
        //
        // Builds its own exercise rather than using `routine()`: that helper
        // already attaches one set, so reusing it here would prescribe four.
        let r = Routine(name: "Lower A")
        let e = RoutineExercise(name: "Back Squat", equipment: "Barbell", orderIndex: 0)
        e.routine = r
        for (i, kg) in [102.06, 102.06, 111.13].enumerated() {
            let s = RoutinePrescribedSet(orderIndex: i)
            s.targetWeightKg = kg
            s.targetReps = i == 2 ? 3 : 5
            s.exercise = e
        }
        let payload = try decode(PlanLinkEncoder.fragment(
            routines: [r], sessions: [], lifterID: "a1b2c3d4", coachName: "Doug"))
        XCTAssertEqual(payload.w?.first?.e.first?.s.count, 3)
    }

    func testALibrarySendCarriesWorkoutsWithNoSessions() throws {
        // "Here is the programme", nothing booked. Legal per PLAN-FORMAT.
        let (r, _, s) = routine()
        s.targetReps = 5
        let payload = try decode(PlanLinkEncoder.fragment(
            routines: [r], sessions: [], lifterID: "a1b2c3d4", coachName: "Doug"))
        XCTAssertEqual(payload.w?.count, 1)
        XCTAssertTrue(payload.k?.isEmpty ?? true)
    }

    func testSessionsIndexIntoTheWorkoutArray() throws {
        let (a, _, sa) = routine(); a.name = "Lower A"; sa.targetReps = 5
        let (b, _, sb) = routine(); b.name = "Upper B"; sb.targetReps = 8

        let sessions = [
            ScheduledSession(clientID: "c1", dayKey: "2026-09-14", routineID: b.id),
            ScheduledSession(clientID: "c1", dayKey: "2026-09-15", routineID: a.id),
        ]
        let payload = try decode(PlanLinkEncoder.fragment(
            routines: [a, b], sessions: sessions, lifterID: "a1b2c3d4", coachName: "Doug"))

        let byDay = Dictionary(uniqueKeysWithValues: (payload.k ?? []).map { ($0.d, $0.x) })
        let names = payload.w?.map(\.n) ?? []
        XCTAssertEqual(names[byDay["2026-09-14"]!], "Upper B")
        XCTAssertEqual(names[byDay["2026-09-15"]!], "Lower A")
    }

    func testTheFragmentCarriesTheAddressingFields() throws {
        let (r, _, s) = routine(); s.targetReps = 5
        let payload = try decode(PlanLinkEncoder.fragment(
            routines: [r], sessions: [], lifterID: "a1b2c3d4", coachName: "Doug"))
        XCTAssertEqual(payload.v, 1)
        XCTAssertEqual(payload.t, "plan")
        XCTAssertEqual(payload.l, "a1b2c3d4")
        XCTAssertEqual(payload.n, "Doug")
    }

    func testAFragmentForAnotherClientIsRejectedByTheDecoder() {
        let (r, _, s) = routine(); s.targetReps = 5
        let fragment = PlanLinkEncoder.fragment(
            routines: [r], sessions: [], lifterID: "someone-else", coachName: "Doug")
        XCTAssertThrowsError(
            try PlanLinkCodec.decode(fragment: fragment, expectedLifterID: "a1b2c3d4"))
    }

    func testCoachNameFallsBackOnEmptyStringNotJustNil() {
        // `UserDefaults` returns nil only when the key was never set;
        // `ConnectView`'s `@AppStorage` writes "" the moment a coach clears
        // the field. `?? "Your coach"` alone lets that empty string reach
        // the wire as `n:""` -- the fallback must catch both.
        XCTAssertEqual(PlanLinkEncoder.coachName(nil), "Your coach")
        XCTAssertEqual(PlanLinkEncoder.coachName(""), "Your coach")
        XCTAssertEqual(PlanLinkEncoder.coachName("Doug"), "Doug")
    }

    func testTheEnvelopeIsVersionAndCodecPrefixed() {
        let (r, _, s) = routine(); s.targetReps = 5
        let fragment = PlanLinkEncoder.fragment(
            routines: [r], sessions: [], lifterID: "a1b2c3d4", coachName: "Doug")
        XCTAssertTrue(fragment.hasPrefix("1z") || fragment.hasPrefix("1u"), fragment)
    }
}
