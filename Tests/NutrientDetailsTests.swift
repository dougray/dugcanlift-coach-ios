import XCTest
import SwiftData
import LiftCore
@testable import Coach

/// Saturated fat, sugar and sodium: SHARE-FORMAT.md `fx`/`fe`, PLAN-FORMAT.md
/// `ux`, and Coach's backup. Tracked, never targeted.
final class NutrientDetailsTests: XCTestCase {

    private let enUS = Locale(identifier: "en_US")

    private func makeContext() throws -> ModelContext {
        let schema = Schema(CoachSchema.models)
        return ModelContext(try ModelContainer(
            for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func payload(z: Int = 1, days: [WireDay]) -> ShareLinkPayload {
        ShareLinkPayload(
            v: 1,
            c: WireClient(i: "b7f3a1c8", n: "Jordan Reyes", s: nil, a: nil, h: nil, u: "lb", p: "and"),
            g: nil, r: "2026-09-01", t: "2026-09-10", z: z, x: [],
            fd: ["Oats", "Salted butter", "Apple", "Ham sandwich"], d: days)
    }

    /// Sends the payload the way a client's app does -- JSON, raw deflate,
    /// base64url, `1z` -- and decodes it with the kit's real decoder, so the
    /// test covers what arrives rather than a struct built in memory.
    private func overTheWire(_ payload: ShareLinkPayload) throws -> ShareLinkPayload {
        let json = try JSONEncoder().encode(payload)
        let deflated = try XCTUnwrap(CompactEncoding.deflateRaw(json))
        return try ShareLinkCodec.decode(fragment: "1z" + CompactEncoding.base64URL(deflated))
    }

    /// Four foods: oats (sugar only), butter x2 servings (all three), an apple
    /// with nothing, a sandwich with sodium only. Built with the kit's own
    /// sender-side helpers, as LIFT builds a link.
    private func itemizedDay() -> WireDay {
        let perServing: [(servings: Double, details: WireNutrientDetails?)] = [
            (1, WireNutrientDetails(sugarG: 1.1)),
            (2, WireNutrientDetails(saturatedFatG: 5.1, sugarG: 0.1, sodiumMg: 90.4)),
            (1, nil),
            (1.5, WireNutrientDetails(sodiumMg: 800)),
        ]
        let f: [[Double]] = [
            [0, 1, 150, 5, 3, 27, 4, 0],
            [1, 2, 100, 0, 11, 0, 0, 0],
            [2, 1, 95, 0, 0, 25, 4, 3],
            [3, 1.5, 300, 18, 10, 30, 2, 1],
        ]
        return WireDay(k: 9, n: nil, fo: nil, bw: nil, st: nil, w: nil, ft: nil, f: f,
                       fx: ShareNutrients.dayTotals(perServing),
                       fe: ShareNutrients.items(perServing.map(\.details)))
    }

    // MARK: - Import

    func testADaysTotalsAndCoverageAreStoredAsSent() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(try overTheWire(payload(days: [itemizedDay()])), into: context)

        let day = try XCTUnwrap(try context.fetch(FetchDescriptor<TrainingDay>()).first)
        let totals = try XCTUnwrap(day.nutrientTotals)
        XCTAssertEqual(totals.saturatedFatG, 10.2)
        XCTAssertEqual(totals.sugarG, 1.3)
        XCTAssertEqual(totals.sodiumMg, 1381)   // 90.4*2 + 800*1.5 = 1380.8
        XCTAssertEqual(totals.foods, 4)
        XCTAssertEqual(totals.withSaturatedFat, 1)
        XCTAssertEqual(totals.withSugar, 2)
        XCTAssertEqual(totals.withSodium, 2)
    }

    func testItemizedDetailsAreStoredAsEatenLikeTheMacros() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(try overTheWire(payload(days: [itemizedDay()])), into: context)

        let foods = try context.fetch(FetchDescriptor<ClientFoodEntry>())
        let byName = Dictionary(uniqueKeysWithValues: foods.map { ($0.foodName, $0) })

        XCTAssertEqual(byName["Oats"]?.nutrientDetails, WireNutrientDetails(sugarG: 1.1))
        let butter = try XCTUnwrap(byName["Salted butter"]?.nutrientDetails)
        XCTAssertEqual(try XCTUnwrap(butter.saturatedFatG), 10.2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(butter.sugarG), 0.2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(butter.sodiumMg), 180, "90.4 rounds to 90 on the wire, then x2")
        XCTAssertEqual(byName["Salted butter"]?.calories, 200, "the macros multiply the same way")
        XCTAssertNil(byName["Apple"]?.nutrientDetails, "nothing recorded is nil, never zeros")
        let sandwich = try XCTUnwrap(byName["Ham sandwich"]?.nutrientDetails)
        XCTAssertNil(sandwich.saturatedFatG)
        XCTAssertNil(sandwich.sugarG)
        XCTAssertEqual(sandwich.sodiumMg, 1200)
    }

    func testADayWithoutFxOrFeImportsWithNone() throws {
        let context = try makeContext()
        let day = WireDay(k: 0, n: nil, fo: nil, bw: nil, st: nil, w: nil, ft: [2000, 150, 70, 200, 30],
                          f: [[0, 1, 150, 5, 3, 27, 4, 0]])
        try ShareLinkImporter.importPayload(try overTheWire(payload(days: [day])), into: context)

        let stored = try XCTUnwrap(try context.fetch(FetchDescriptor<TrainingDay>()).first)
        XCTAssertNil(stored.nutrientTotals)
        XCTAssertNil(stored.nutrientTotalsData)
        XCTAssertEqual(stored.foodCalories, 2000)
        XCTAssertNil(try context.fetch(FetchDescriptor<ClientFoodEntry>()).first?.nutrientDetails)
    }

    func testANullTotalStaysNull() throws {
        let context = try makeContext()
        let fx = WireNutrientTotals(saturatedFatG: nil, sugarG: 48, sodiumMg: nil,
                                    foods: 6, withSaturatedFat: 0, withSugar: 3, withSodium: 0)
        let day = WireDay(k: 0, n: nil, fo: nil, bw: nil, st: nil, w: nil, ft: nil, f: nil, fx: fx)
        try ShareLinkImporter.importPayload(try overTheWire(payload(days: [day])), into: context)

        let totals = try XCTUnwrap(try context.fetch(FetchDescriptor<TrainingDay>()).first?.nutrientTotals)
        XCTAssertNil(totals.saturatedFatG)
        XCTAssertNil(totals.sodiumMg)
        XCTAssertEqual(totals.sugarG, 48)
    }

    /// `fe` is aligned with `f` by position. A malformed `f` entry the importer
    /// skips must not shift every later food's sodium onto its neighbour.
    func testASkippedFoodDoesNotShiftTheDetailsOfTheFoodsAfterIt() throws {
        let context = try makeContext()
        let day = WireDay(k: 0, n: nil, fo: nil, bw: nil, st: nil, w: nil, ft: nil,
                          f: [[99, 1, 100, 0, 0, 0, 0, 0],      // index outside fd: skipped
                              [3, 1, 300, 18, 10, 30, 2, 1]],
                          fe: [WireNutrientDetails(sodiumMg: 5), WireNutrientDetails(sodiumMg: 700)])
        try ShareLinkImporter.importPayload(payload(days: [day]), into: context)

        let foods = try context.fetch(FetchDescriptor<ClientFoodEntry>())
        XCTAssertEqual(foods.count, 1)
        XCTAssertEqual(foods.first?.nutrientDetails?.sodiumMg, 700)
    }

    func testDaysAreReplacedWholeSoALinkWithoutFxClearsIt() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(payload(z: 1, days: [itemizedDay()]), into: context)
        let bare = WireDay(k: 9, n: nil, fo: nil, bw: nil, st: nil, w: nil, ft: [1500, 100, 50, 150, 20], f: nil)
        try ShareLinkImporter.importPayload(payload(z: 2, days: [bare]), into: context)

        let days = try context.fetch(FetchDescriptor<TrainingDay>())
        XCTAssertEqual(days.count, 1)
        XCTAssertNil(days.first?.nutrientTotals)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ClientFoodEntry>()).isEmpty)
    }

    // MARK: - Display

    private func totals(_ sat: Double?, _ sugar: Double?, _ sodium: Double?, foods: Int,
                        _ withSat: Int, _ withSugar: Int, _ withSodium: Int) -> WireNutrientTotals {
        WireNutrientTotals(saturatedFatG: sat, sugarG: sugar, sodiumMg: sodium, foods: foods,
                           withSaturatedFat: withSat, withSugar: withSugar, withSodium: withSodium)
    }

    func testAmountsAreGramsToOneDecimalAndWholeGroupedMilligrams() {
        XCTAssertEqual(NutrientDisplay.amount(21.5, .saturatedFat, locale: enUS), "21.5 g")
        XCTAssertEqual(NutrientDisplay.amount(48, .sugar, locale: enUS), "48 g")
        XCTAssertEqual(NutrientDisplay.amount(1840, .sodium, locale: enUS), "1,840 mg")
        XCTAssertEqual(NutrientDisplay.amount(2104.6, .sodium, locale: enUS), "2,105 mg")
    }

    func testAFullyCoveredDayReadsAsADay() {
        let lines = NutrientDisplay.dayLines(totals(21.5, 48, 2310, foods: 6, 6, 6, 6), locale: enUS)
        XCTAssertEqual(lines, ["Saturated fat 21.5 g", "Sugar 48 g", "Sodium 2,310 mg"])
    }

    func testAPartialTotalSaysHowManyFoodsItCovers() {
        let lines = NutrientDisplay.dayLines(totals(nil, 48, 1840, foods: 5, 0, 5, 3), locale: enUS)
        XCTAssertEqual(lines, ["Sugar 48 g", "Sodium 1,840 mg · from 3 of 5 foods"],
                       "an unrecorded nutrient has no line at all, not a zero or a dash")
        XCTAssertEqual(NutrientDisplay.dayLines(nil), [])
    }

    func testAveragesCountOnlyDaysThatRecordedTheNutrient() throws {
        let days: [(dayKey: String, totals: WireNutrientTotals?)] = [
            ("2026-09-10", totals(20, nil, 2000, foods: 4, 4, 0, 4)),
            ("2026-09-12", totals(10, 30, 1000, foods: 5, 5, 5, 2)),   // sodium partial
            ("2026-09-13", nil),                                      // logged nothing: not a zero day
            ("2026-09-14", totals(nil, 50, nil, foods: 3, 0, 3, 0)),
            ("2026-09-01", totals(99, 99, 9999, foods: 1, 1, 1, 1)),   // outside the week
        ]
        let week = NutrientDisplay.averages(days, windowDays: 7, endKey: "2026-09-14")

        XCTAssertEqual(week, [
            .init(nutrient: .saturatedFat, perDay: 15, days: 2, partialDays: 0),
            .init(nutrient: .sugar, perDay: 40, days: 2, partialDays: 0),
            .init(nutrient: .sodium, perDay: 1500, days: 2, partialDays: 1),
        ])
        XCTAssertEqual(NutrientDisplay.averageLine(week[2], locale: enUS),
                       "Sodium 1,500 mg a day · 2 days, 1 from only some foods")
        XCTAssertEqual(NutrientDisplay.averageLine(.init(nutrient: .sugar, perDay: 12.25, days: 1, partialDays: 0),
                                                   locale: enUS),
                       "Sugar 12.3 g a day · 1 day")

        let fourWeeks = NutrientDisplay.averages(days, windowDays: 28, endKey: "2026-09-14")
        XCTAssertEqual(fourWeeks.first { $0.nutrient == .sodium }?.days, 3)
    }

    func testANutrientNoDayRecordedIsLeftOutRatherThanAveragedToZero() {
        let days: [(dayKey: String, totals: WireNutrientTotals?)] = [
            ("2026-09-14", totals(nil, 12, nil, foods: 2, 0, 1, 0)),
        ]
        XCTAssertEqual(NutrientDisplay.averages(days, windowDays: 7, endKey: "2026-09-14").map(\.nutrient), [.sugar])
        XCTAssertEqual(NutrientDisplay.averages([], windowDays: 7, endKey: "2026-09-14"), [])
    }

    // MARK: - Plan links

    private func planRecipe(_ facts: NutritionFacts?) throws -> PlanRecipe {
        let recipe = Recipe(name: "Beef Chilli", servings: 4, nutritionPerServing: facts)
        let fragment = PlanLinkEncoder.fragment(recipes: [recipe], lifterID: "a1b2c3d4", coachName: "Doug")
        let payload = try PlanLinkCodec.decode(fragment: fragment, expectedLifterID: "a1b2c3d4")
        return try XCTUnwrap(payload.r?.first)
    }

    private func rawJSON(_ fragment: String) throws -> String {
        XCTAssertTrue(fragment.hasPrefix("1z"))
        let deflated = try XCTUnwrap(CompactEncoding.base64URLDecode(String(fragment.dropFirst(2))))
        return String(decoding: try XCTUnwrap(CompactEncoding.inflateRaw(deflated)), as: UTF8.self)
    }

    func testARecipeCarriesUxPerServingRounded() throws {
        let inlined = try planRecipe(NutritionFacts(calories: 438, proteinG: 36, carbsG: 31, fatG: 19,
                                                    sugarG: 6.04, sodiumMg: 612.5, saturatedFatG: 7.25))
        XCTAssertEqual(inlined.ux, WireNutrientDetails(saturatedFatG: 7.3, sugarG: 6, sodiumMg: 613))
        XCTAssertEqual(inlined.u, [438, 36, 31, 19, 0])
    }

    func testUxTrimsTrailingNullsButKeepsLeadingOnes() throws {
        let recipe = Recipe(name: "Fruit salad", servings: 2,
                            nutritionPerServing: NutritionFacts(calories: 120, proteinG: 1, carbsG: 30, fatG: 0,
                                                                sugarG: 24))
        let json = try rawJSON(PlanLinkEncoder.fragment(recipes: [recipe], lifterID: "a1b2c3d4", coachName: "Doug"))
        XCTAssertTrue(json.contains(#""ux":[null,24]"#), json)
    }

    func testUxIsOmittedWhenNoneIsKnown() throws {
        let recipe = Recipe(name: "Beef Chilli", servings: 4,
                            nutritionPerServing: NutritionFacts(calories: 438, proteinG: 36, carbsG: 31, fatG: 19))
        let json = try rawJSON(PlanLinkEncoder.fragment(recipes: [recipe], lifterID: "a1b2c3d4", coachName: "Doug"))
        XCTAssertFalse(json.contains(#""ux""#), json)
        XCTAssertNil(try planRecipe(nil).ux)
    }

    /// A coach may know a dish's sodium and not its calories. The zeros
    /// `NutritionFacts` must hold for the four macros never become `u`.
    func testUxTravelsWithoutU() throws {
        let inlined = try planRecipe(NutritionFacts(sodiumMg: 540))
        XCTAssertNil(inlined.u)
        XCTAssertEqual(inlined.ux, WireNutrientDetails(sodiumMg: 540))
    }

    // MARK: - Backups

    private func clientWithNutrients(in context: ModelContext) throws {
        let client = Client(id: "b7f3a1c8", name: "Jordan Reyes", displayUnit: "lb", platform: "and")
        context.insert(client)
        let day = TrainingDay(client: client, dayKey: "2026-09-10")
        day.nutrientTotals = WireNutrientTotals(saturatedFatG: nil, sugarG: 48, sodiumMg: 1840,
                                                foods: 5, withSaturatedFat: 0, withSugar: 5, withSodium: 3)
        context.insert(day)
        client.trainingDays.append(day)
        let food = ClientFoodEntry(day: day, foodName: "Ham sandwich", servings: 1.5, calories: 450,
                                   proteinG: 27, fatG: 15, carbsG: 45, fiberG: 3, meal: 1)
        food.nutrientDetails = WireNutrientDetails(sodiumMg: 1200)
        context.insert(food)
        day.foodEntries.append(food)
        try context.save()
    }

    func testDayTotalsAndFoodDetailsRoundTripThroughABackup() throws {
        let source = try makeContext()
        try clientWithNutrients(in: source)
        let data = try BackupCodec.export(from: source, defaults: UserDefaults(suiteName: UUID().uuidString)!)

        let destination = try makeContext()
        try BackupCodec.restore(from: data, into: destination, defaults: UserDefaults(suiteName: UUID().uuidString)!)

        let day = try XCTUnwrap(try destination.fetch(FetchDescriptor<TrainingDay>()).first)
        XCTAssertEqual(day.nutrientTotals, WireNutrientTotals(saturatedFatG: nil, sugarG: 48, sodiumMg: 1840,
                                                              foods: 5, withSaturatedFat: 0, withSugar: 5,
                                                              withSodium: 3))
        XCTAssertEqual(day.foodEntries.first?.nutrientDetails, WireNutrientDetails(sodiumMg: 1200))
    }

    /// Coach Android's names and shapes, so one file moves between the two apps:
    /// `nutrientTotals` with all seven keys and explicit nulls on the day, and
    /// the three values on a food only when known.
    func testWritesNutrientsInCoachAndroidsBackupShape() throws {
        let source = try makeContext()
        try clientWithNutrients(in: source)
        let data = try BackupCodec.export(from: source, defaults: UserDefaults(suiteName: UUID().uuidString)!)

        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let client = try XCTUnwrap((root["clients"] as? [[String: Any]])?.first)
        let day = try XCTUnwrap((client["days"] as? [[String: Any]])?.first)
        let totals = try XCTUnwrap(day["nutrientTotals"] as? [String: Any])
        XCTAssertEqual(Set(totals.keys), ["saturatedFatG", "sugarG", "sodiumMg", "foods",
                                          "withSaturatedFat", "withSugar", "withSodium"])
        XCTAssertTrue(totals["saturatedFatG"] is NSNull, "an unknown total is an explicit null, never 0")
        XCTAssertEqual(totals["sodiumMg"] as? Double, 1840)
        XCTAssertEqual(totals["withSodium"] as? Int, 3)

        let food = try XCTUnwrap((day["foodEntries"] as? [[String: Any]])?.first)
        XCTAssertEqual(food["sodiumMg"] as? Double, 1200)
        XCTAssertNil(food["sugarG"], "an unknown value is absent, as an older file says it")
        XCTAssertNil(food["saturatedFatG"])
    }

    func testRestoresABackupWrittenBeforeTheseExisted() throws {
        let json = """
        {"v":2,"clients":[{"id":"b7f3a1c8","name":"Jordan Reyes","displayUnit":"lb","days":[
          {"dayKey":"2026-09-10","sets":[],"foodEntries":[
            {"foodName":"Oats","servings":1,"calories":150,"proteinG":5,"fatG":3,"carbsG":27,"fiberG":4,"meal":0}
          ]}
        ]}]}
        """
        let context = try makeContext()
        try BackupCodec.restore(from: Data(json.utf8), into: context,
                                defaults: UserDefaults(suiteName: UUID().uuidString)!)

        let day = try XCTUnwrap(try context.fetch(FetchDescriptor<TrainingDay>()).first)
        XCTAssertNil(day.nutrientTotals)
        XCTAssertEqual(day.foodEntries.count, 1)
        XCTAssertNil(day.foodEntries.first?.nutrientDetails)
    }

    func testRestoresNutrientsInCoachAndroidsBackupShape() throws {
        let json = """
        {"v":2,"clients":[{"id":"b7f3a1c8","name":"Jordan Reyes","displayUnit":"kg","days":[
          {"dayKey":"2026-09-10","sets":[],
           "nutrientTotals":{"saturatedFatG":21.5,"sugarG":null,"sodiumMg":2310,"foods":6,
                             "withSaturatedFat":6,"withSugar":0,"withSodium":2},
           "foodEntries":[
            {"foodName":"Butter","servings":2,"calories":200,"proteinG":0,"fatG":22,"carbsG":0,"fiberG":0,
             "meal":0,"saturatedFatG":14.2,"sodiumMg":180}
          ]}
        ]}]}
        """
        let context = try makeContext()
        try BackupCodec.restore(from: Data(json.utf8), into: context,
                                defaults: UserDefaults(suiteName: UUID().uuidString)!)

        let day = try XCTUnwrap(try context.fetch(FetchDescriptor<TrainingDay>()).first)
        XCTAssertEqual(day.nutrientTotals, WireNutrientTotals(saturatedFatG: 21.5, sugarG: nil, sodiumMg: 2310,
                                                              foods: 6, withSaturatedFat: 6, withSugar: 0,
                                                              withSodium: 2))
        XCTAssertEqual(day.foodEntries.first?.nutrientDetails,
                       WireNutrientDetails(saturatedFatG: 14.2, sodiumMg: 180))
    }

    /// `NutritionFacts` is encoded directly, so a recipe gains `saturatedFatG`
    /// with no change to `BackupRecipe`.
    func testARecipesSaturatedFatSugarAndSodiumSurviveABackup() throws {
        let source = try makeContext()
        let recipe = Recipe(name: "Beef Chilli", servings: 4,
                            nutritionPerServing: NutritionFacts(calories: 438, proteinG: 36, carbsG: 31, fatG: 19,
                                                                sugarG: 6, sodiumMg: 612, saturatedFatG: 7.3))
        source.insert(recipe)
        try source.save()
        let data = try BackupCodec.export(from: source, defaults: UserDefaults(suiteName: UUID().uuidString)!)

        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let written = try XCTUnwrap(((root["recipes"] as? [[String: Any]])?.first?["nutritionPerServing"])
                                    as? [String: Any])
        XCTAssertEqual(written["saturatedFatG"] as? Double, 7.3)

        let destination = try makeContext()
        try BackupCodec.restore(from: data, into: destination, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let restored = try XCTUnwrap(try destination.fetch(FetchDescriptor<Recipe>()).first?.nutritionPerServing)
        XCTAssertEqual(restored.saturatedFatG, 7.3)
        XCTAssertEqual(restored.sugarG, 6)
        XCTAssertEqual(restored.sodiumMg, 612)
    }
}
