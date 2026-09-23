import XCTest
import SwiftData
import LiftCore
@testable import Coach

/// `rf` on the wire: what this encoder writes, what it does not write, and
/// what the link Coach web's own encoder wrote says.
///
/// `Fixtures/web-plan-road-picks.txt` is that link, the same bytes checked in
/// at `dugcanlift-coach/coach/fixtures/` and `dugcanlift-site/lift/fixtures/`
/// (md5 5c2f783c291f9c757e86a75a014510e6). It is the only thing here that
/// proves interoperability rather than agreement with itself. **Never
/// regenerate it from this code**; that would defeat its entire purpose.
final class PlanLinkRoadPicksTests: XCTestCase {

    private static let lifterID = "a1b2c3d4"

    /// The link, whole. `fragment()` is what a decoder is handed.
    private func fixture() throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self)
            .url(forResource: "web-plan-road-picks", withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The fixture's JSON as a dictionary: `rf` is not a field on `LiftCore`'s
    /// `PlanPayload` (see `PlanLinkEncoder.PayloadWithRoadPicks` for why), so
    /// the raw object is where a test reads it.
    private func fixtureJSON() throws -> [String: Any] {
        let link = try fixture()
        // The fixture is the whole link, as a coach would paste it.
        let hash = try XCTUnwrap(link.firstIndex(of: "#"))
        let fragment = String(link[link.index(after: hash)...])
        let body = String(fragment.dropFirst(2))
        let raw = try XCTUnwrap(CompactEncoding.base64URLDecode(body))
        let json = try XCTUnwrap(CompactEncoding.inflateRaw(raw))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    private func fragment() throws -> String {
        let link = try fixture()
        let hash = try XCTUnwrap(link.firstIndex(of: "#"))
        return String(link[link.index(after: hash)...])
    }

    private func catalog() throws -> RoadFoodCatalog {
        try XCTUnwrap(RoadFoodCatalog.bundled(in: Bundle(for: Self.self)))
    }

    private func context() throws -> ModelContext {
        let schema = Schema(CoachSchema.models)
        return ModelContext(try ModelContainer(
            for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func recipe(in context: ModelContext) -> Recipe {
        let recipe = Recipe(name: "Beef Chilli", servings: 4, steps: ["Brown the mince."])
        recipe.nutritionPerServing = NutritionFacts(calories: 438, proteinG: 36, carbsG: 31,
                                                    fatG: 19, fiberG: 9)
        context.insert(recipe)
        return recipe
    }

    // MARK: - What this encoder writes

    func testAPlanWithPicksCarriesThemAsAFlatListOfIDsInOrder() throws {
        let context = try context()
        let recipe = recipe(in: context)
        let ids = ["wendys-large-chili", "chickfila-grilled-filet"]
        let data = try XCTUnwrap(PlanLinkEncoder.json(
            recipes: [recipe], meals: [], roadPicks: ids,
            lifterID: Self.lifterID, coachName: "Doug"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["rf"] as? [String], ids)
        XCTAssertEqual(json["v"] as? Int, 1, "purely additive: no version bump")
    }

    func testAPicksOnlyPlanIsALegitimateSend() throws {
        let data = try XCTUnwrap(PlanLinkEncoder.json(
            roadPicks: ["wendys-large-chili"], lifterID: Self.lifterID, coachName: "Doug"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["rf"] as? [String], ["wendys-large-chili"])
        // A coach whose only answer this week is "these are fine on the road"
        // sends a plan with no `r`, `m`, `w` or `k` at all.
        for key in ["r", "m", "w", "k"] { XCTAssertNil(json[key], key) }

        let fragment = PlanLinkEncoder.fragment(roadPicks: ["wendys-large-chili"],
                                                lifterID: Self.lifterID, coachName: "Doug")
        XCTAssertFalse(fragment.isEmpty)
        let decoded = try PlanLinkCodec.decode(fragment: fragment,
                                               expectedLifterID: Self.lifterID)
        XCTAssertEqual(decoded.t, "plan", "and it is still a plan a client will open")
    }

    /// The byte check: a plan with no picks is exactly what the encoder wrote
    /// before road picks existed.
    ///
    /// `PlanLinkEncoder`'s last step used to be `encoder.encode(payload)` on
    /// `LiftCore`'s `PlanPayload`, with `.sortedKeys`. That encoder is still
    /// here, unchanged and pinned to an exact kit tag, so the frozen "old"
    /// side below is the real thing rather than a copy of it: re-encoding the
    /// payload this way is byte for byte what main produced.
    func testAPlanWithNoPicksEncodesByteForByteAsBefore() throws {
        let context = try context()
        let recipe = recipe(in: context)
        let routine = Routine(name: "Lower A")
        let exercise = RoutineExercise(name: "Back Squat", equipment: "Barbell", orderIndex: 0)
        exercise.prescribedSets = [RoutinePrescribedSet(orderIndex: 0,
                                                        targetWeightKg: 102.06, targetReps: 5)]
        routine.exercises = [exercise]
        context.insert(routine)
        let session = ScheduledSession(clientID: Self.lifterID, dayKey: "2026-09-28",
                                       routineID: routine.id)
        context.insert(session)

        func encode(_ picks: [String]) throws -> Data {
            try XCTUnwrap(PlanLinkEncoder.json(
                routines: [routine], sessions: [session], recipes: [recipe], meals: [],
                sides: PrescriptionSides(), roadPicks: picks,
                lifterID: Self.lifterID, coachName: "Doug"))
        }

        let plain = try encode([])
        let plainKeys = try XCTUnwrap(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
        XCTAssertNil(plainKeys["rf"], "no key at all, and never []")

        // Frozen: main's final step, on the same payload this encoder built.
        let payload = try JSONDecoder().decode(PlanPayload.self, from: plain)
        let old = JSONEncoder()
        old.outputFormatting = [.sortedKeys]
        XCTAssertEqual(plain, try old.encode(payload),
                       "the wrapper adds nothing when there is nothing to add")

        // A blank or duplicated id is not picks either.
        XCTAssertEqual(try encode(["", "   "]), plain)

        // And with picks, `rf` is the only difference.
        let withPicks = try encode(["wendys-large-chili"])
        var a = try XCTUnwrap(try JSONSerialization.jsonObject(with: withPicks) as? [String: Any])
        XCTAssertNotNil(a["rf"])
        a["rf"] = nil
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]),
                       try JSONSerialization.data(
                        withJSONObject: try XCTUnwrap(
                            try JSONSerialization.jsonObject(with: plain) as? [String: Any]),
                        options: [.sortedKeys]))
    }

    func testDuplicateAndBlankIDsNeverReachTheWire() throws {
        let data = try XCTUnwrap(PlanLinkEncoder.json(
            roadPicks: [" wendys-large-chili ", "wendys-large-chili", "", "chickfila-grilled-filet"],
            lifterID: Self.lifterID, coachName: "Doug"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["rf"] as? [String],
                       ["wendys-large-chili", "chickfila-grilled-filet"])
    }

    // MARK: - The link the web app wrote

    func testTheFixtureCarriesRFAsAFlatListOfIDs() throws {
        let json = try fixtureJSON()
        XCTAssertEqual(json["v"] as? Int, 1)
        XCTAssertEqual(json["t"] as? String, "plan")
        let rf = try XCTUnwrap(json["rf"] as? [String])
        XCTAssertEqual(rf, RoadPicks.normalise(rf), "already normalised")
        XCTAssertEqual(rf.count, 6)

        // The rest of the payload still decodes through LiftCore exactly as it
        // always did: `rf` is additive, and an unknown key is ignored.
        let payload = try PlanLinkCodec.decode(fragment: try fragment(),
                                               expectedLifterID: Self.lifterID)
        XCTAssertEqual(payload.n, "Doug")
        XCTAssertEqual(payload.r?.count, 1)
        XCTAssertEqual(payload.m?.count, 2)
        XCTAssertEqual(payload.w?.count, 1)
        XCTAssertEqual(payload.k?.count, 1)
    }

    func testTheFixturesPicksResolveAtThreePlacesAndExactlyOneDoesNot() throws {
        let rf = try XCTUnwrap(try fixtureJSON()["rf"] as? [String])
        let catalog = try catalog()
        XCTAssertEqual(RoadPicks.missing(rf, in: catalog), ["wendys-item-withdrawn-2019"],
                       "deliberately bogus, so every decoder's skip rule is exercised")
        XCTAssertEqual(RoadPicks.summary(rf, in: catalog), "5 items at 3 places",
                       "two chains and the gas station; the sixth is not counted on screen")
    }

    /// The same ids, put back on the wire by this encoder, come out the same.
    /// Not a regeneration of the fixture -- the fixture's own bytes are read
    /// above, and this only asks whether Coach iOS would write the same list.
    func testThisEncoderWritesTheFixturesOwnPicksUnchanged() throws {
        let rf = try XCTUnwrap(try fixtureJSON()["rf"] as? [String])
        let data = try XCTUnwrap(PlanLinkEncoder.json(roadPicks: rf, lifterID: Self.lifterID,
                                                      coachName: "Doug"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["rf"] as? [String], rf,
                       "including the id this copy of the file does not have")
    }
}
