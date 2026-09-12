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
        XCTAssertNil(payload.k)
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

    // MARK: - Cook

    private func chilli() -> Recipe {
        let recipe = Recipe(name: "Beef Chilli", servings: 4,
                            steps: ["Brown the mince."],
                            nutritionPerServing: NutritionFacts(calories: 438, proteinG: 36,
                                                                carbsG: 31, fatG: 19, fiberG: 9))
        for (i, line) in ["500 g lean beef mince", "2 cloves garlic"].enumerated() {
            let ingredient = IngredientParser.parse(line, sortOrder: i)
            ingredient.recipe = recipe
        }
        return recipe
    }

    func testARecipeRidesInlineWithMacrosPerServing() throws {
        let recipe = chilli()
        let meal = PlannedMeal(recipe: recipe, mealType: .dinner,
                               plannedFor: try XCTUnwrap(DayKey.date(from: "2026-09-14")),
                               servings: 2)
        let payload = try decode(PlanLinkEncoder.fragment(
            recipes: [recipe], meals: [meal], lifterID: "a1b2c3d4", coachName: "Doug"))

        let inlined = try XCTUnwrap(payload.r?.first)
        XCTAssertEqual(inlined.n, "Beef Chilli")
        XCTAssertEqual(inlined.s, 4)
        XCTAssertEqual(try XCTUnwrap(inlined.u), [438, 36, 31, 19, 9])
        XCTAssertEqual(inlined.i, ["500 g lean beef mince", "2 cloves garlic"],
                       "ingredients travel as raw text, never parsed")
        XCTAssertEqual(inlined.t, ["Brown the mince."])

        let booked = try XCTUnwrap(payload.m?.first)
        XCTAssertEqual(booked.d, "2026-09-14")
        XCTAssertEqual(booked.s, 2, "dinner is slot 2")
        XCTAssertEqual(booked.x, 0)
        XCTAssertEqual(booked.q, 2)
    }

    func testARecipeWithNoMacrosOmitsUEntirelyRatherThanSendingZeros() throws {
        let recipe = Recipe(name: "Whatever Doug makes", servings: 2)
        let meal = PlannedMeal(recipe: recipe, mealType: .lunch,
                               plannedFor: try XCTUnwrap(DayKey.date(from: "2026-09-14")))
        let payload = try decode(PlanLinkEncoder.fragment(
            recipes: [recipe], meals: [meal], lifterID: "a1b2c3d4", coachName: "Doug"))
        XCTAssertNil(try XCTUnwrap(payload.r?.first).u,
                     "a zero here becomes a zero-calorie dinner in the client's day total")
    }

    func testMealSlotsMatchThePlanFormatOrdering() throws {
        let recipe = chilli()
        let day = try XCTUnwrap(DayKey.date(from: "2026-09-14"))
        let meals = MealType.allCases.map {
            PlannedMeal(recipe: recipe, mealType: $0, plannedFor: day)
        }
        let payload = try decode(PlanLinkEncoder.fragment(
            recipes: [recipe], meals: meals, lifterID: "a1b2c3d4", coachName: "Doug"))
        // 0 breakfast, 1 lunch, 2 dinner, 3 snack.
        XCTAssertEqual(payload.m?.map(\.s), [0, 1, 2, 3])
    }

    func testAMealWhoseRecipeIsNotInTheSendIsDropped() throws {
        let sent = chilli()
        let absent = Recipe(name: "Not included", servings: 1)
        let day = try XCTUnwrap(DayKey.date(from: "2026-09-14"))
        let payload = try decode(PlanLinkEncoder.fragment(
            recipes: [sent],
            meals: [PlannedMeal(recipe: sent, mealType: .dinner, plannedFor: day),
                    PlannedMeal(recipe: absent, mealType: .lunch, plannedFor: day)],
            lifterID: "a1b2c3d4", coachName: "Doug"))
        XCTAssertEqual(payload.m?.count, 1, "x indexes into r; a stale index is the wrong dinner")
    }

    func testEmptyCollectionsAreOmittedNotSentAsEmptyArrays() throws {
        // PLAN-FORMAT: "a coach who plans only training sends a payload with
        // no r or m at all".
        let routine = Routine(name: "Lower A")
        let payload = try decode(PlanLinkEncoder.fragment(
            routines: [routine], lifterID: "a1b2c3d4", coachName: "Doug"))
        XCTAssertNil(payload.r)
        XCTAssertNil(payload.m)
        XCTAssertNotNil(payload.w)

        let recipe = chilli()
        let mealsOnly = try decode(PlanLinkEncoder.fragment(
            recipes: [recipe], lifterID: "a1b2c3d4", coachName: "Doug"))
        XCTAssertNil(mealsOnly.w)
        XCTAssertNil(mealsOnly.k)
        XCTAssertNotNil(mealsOnly.r)
    }

    func testAMealsAndTrainingWeekCarriesBoth() throws {
        let recipe = chilli()
        let routine = Routine(name: "Lower A")
        let day = try XCTUnwrap(DayKey.date(from: "2026-09-14"))
        let payload = try decode(PlanLinkEncoder.fragment(
            routines: [routine],
            sessions: [ScheduledSession(clientID: "a1b2c3d4", dayKey: "2026-09-14", routineID: routine.id)],
            recipes: [recipe],
            meals: [PlannedMeal(recipe: recipe, mealType: .dinner, plannedFor: day)],
            lifterID: "a1b2c3d4", coachName: "Doug"))
        XCTAssertEqual(payload.r?.count, 1)
        XCTAssertEqual(payload.m?.count, 1)
        XCTAssertEqual(payload.w?.count, 1)
        XCTAssertEqual(payload.k?.count, 1)
    }
}
