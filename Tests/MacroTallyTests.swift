import XCTest
import LiftCore
@testable import Coach

final class MacroTallyTests: XCTestCase {

    func testTallyAccumulatesAndDividesByServings() {
        var tally = MacroTally()
        tally.add(NutritionFacts(calories: 1200, proteinG: 100, carbsG: 60, fatG: 40))
        tally.add(NutritionFacts(calories: 552, proteinG: 44, carbsG: 64, fatG: 36))
        XCTAssertEqual(tally.lines, 2)
        XCTAssertEqual(tally.total.calories, 1752)
        XCTAssertEqual(tally.perServing(4).calories, 438)
    }

    func testPerServingSurvivesAZeroServingCount() {
        var tally = MacroTally()
        tally.add(NutritionFacts(calories: 400))
        XCTAssertTrue(tally.perServing(0).calories.isFinite,
                      "a servings field a coach has just cleared must not divide by zero")
    }

    func testComputedMacrosFillOnlyUntouchedFields() {
        var fields = MacroFields()
        fields.calories = "500"
        fields.markTyped(.calories)

        fields.applyComputed(NutritionFacts(calories: 438, proteinG: 36, carbsG: 31, fatG: 19))

        XCTAssertEqual(fields.calories, "500", "a looked-up figure must never overwrite a typed one")
        XCTAssertEqual(fields.protein, "36")
        XCTAssertEqual(fields.carbs, "31")
        XCTAssertEqual(fields.fat, "19")
    }

    func testReopeningARecipeWithMacrosCountsEveryFieldAsTyped() {
        // "A recipe already carrying macros counts as typed: reopening it to
        // add one more ingredient must not throw away numbers that were
        // already right."
        var fields = MacroFields()
        fields.loadExisting(NutritionFacts(calories: 500, proteinG: 40, carbsG: 30, fatG: 20))
        fields.applyComputed(NutritionFacts(calories: 438, proteinG: 36, carbsG: 31, fatG: 19))

        XCTAssertEqual(fields.calories, "500")
        XCTAssertEqual(fields.protein, "40")
        XCTAssertEqual(fields.carbs, "30")
        XCTAssertEqual(fields.fat, "20")
    }

    func testAnUntouchedFormEntersNilNotZero() {
        // A zero here becomes a zero-calorie dinner in the client's day total.
        XCTAssertNil(MacroFields().entered())
    }

    func testAPartlyFilledFormKeepsWhatWasTypedAndZeroesTheRest() {
        var fields = MacroFields()
        fields.calories = "438"
        let entered = fields.entered()
        XCTAssertEqual(entered?.calories, 438)
        XCTAssertEqual(entered?.proteinG, 0,
                       "once anything is entered the record exists; blanks in it read as zero")
    }

    func testLoadingNoMacrosLeavesEveryFieldBlankAndUntyped() {
        var fields = MacroFields()
        fields.loadExisting(nil)
        XCTAssertEqual(fields.calories, "")
        XCTAssertTrue(fields.typed.isEmpty)
    }

    func testLocaleRoundTripPreservesDecimalInCommaLocale() {
        // Under the old CookFormat.trimmed write path, a recipe with 36.5g protein
        // would write "36.5". A German parser expects "36,5" and returns nil for
        // "36.5", which the `?? 0` fallback converts to zero — a silent data loss
        // that would corrupt a client's day total. The write path must be the
        // exact inverse of the read path, both using the same locale-aware formatter.
        let deDELocale = Locale(identifier: "de_DE")
        var fields = MacroFields()

        // Load a recipe with fractional protein (36.5g) in German locale
        fields.loadExisting(NutritionFacts(calories: 438, proteinG: 36.5, carbsG: 31, fatG: 19),
                           locale: deDELocale)

        // The stored text must be German-formatted (comma decimal, not period)
        XCTAssertTrue(fields.protein.contains(","),
                     "German locale must format 36.5 as \"36,5\" not \"36.5\"")

        // Round-trip through entered() in the same locale must recover the value
        let entered = fields.entered(locale: deDELocale)
        XCTAssertEqual(entered?.proteinG, 36.5,
                       "locale round-trip in de_DE must recover 36.5, not nil or 0")
    }

    func testPerServingSurvivesNaN() {
        var tally = MacroTally()
        tally.add(NutritionFacts(calories: 400))
        let result = tally.perServing(.nan)
        XCTAssertTrue(result.calories.isFinite,
                      "NaN servings must not produce NaN macros; must clamp to safe floor")
    }

    func testPerServingSurvivesNegativeServings() {
        var tally = MacroTally()
        tally.add(NutritionFacts(calories: 400))
        let result = tally.perServing(-5)
        XCTAssertTrue(result.calories.isFinite,
                      "negative servings must not produce NaN macros; must clamp to safe floor")
    }

    // MARK: - userEdited vs. applyComputed's own writes
    //
    // `.onChange` fires on a PROGRAMMATIC write too, not just a person typing.
    // Regression: add one ingredient -> applyComputed writes all four fields
    // -> the view's onChange sees each field change and (with the old
    // `markTyped`) marks all four typed -> add a second ingredient ->
    // applyComputed is now blocked on every field -> the per-serving macros
    // freeze at the first ingredient's contribution forever.

    func testApplyComputedsOwnWriteIsNotMistakenForAUserEdit() {
        var fields = MacroFields()
        fields.applyComputed(NutritionFacts(calories: 100, proteinG: 10, carbsG: 5, fatG: 2))

        // The view's onChange fires with the exact string applyComputed just
        // wrote -- an echo, not a person typing.
        fields.userEdited(.calories, to: fields.calories)
        XCTAssertTrue(fields.typed.isEmpty,
                      "an onChange firing on applyComputed's own write must not count as typed")

        // A second ingredient recomputes -- this must not be frozen out.
        fields.applyComputed(NutritionFacts(calories: 300, proteinG: 30, carbsG: 15, fatG: 6))
        XCTAssertEqual(fields.calories, "300",
                      "a second ingredient's contribution must update the field, not freeze at the first")
    }

    func testUserEditedWithADifferentValueMarksTypedAndSticks() {
        var fields = MacroFields()
        fields.applyComputed(NutritionFacts(calories: 100, proteinG: 10, carbsG: 5, fatG: 2))

        // The TextField's own binding writes the new text to the field
        // directly; `userEdited` only decides whether that write counts as
        // typed. Simulate both halves, as the view does.
        fields.calories = "500"
        fields.userEdited(.calories, to: "500")
        XCTAssertTrue(fields.typed.contains(.calories))

        fields.applyComputed(NutritionFacts(calories: 300, proteinG: 30, carbsG: 15, fatG: 6))
        XCTAssertEqual(fields.calories, "500", "a real edit must not be overwritten by a later computation")
    }

    func testUserEditedOnAFieldNeverComputedMarksTyped() {
        var fields = MacroFields()
        fields.userEdited(.protein, to: "42")
        XCTAssertTrue(fields.typed.contains(.protein))
    }

    // MARK: - F1: a save that touched nothing must not destroy fibre/sugar/sodium

    func testASaveThatTouchedNothingKeepsFibre() {
        // Loading an existing recipe and changing nothing, then saving, must
        // not zero out fields the four visible text fields never touched --
        // WebLibraryImporter and BackupCodec both populate fiberG on a real
        // recipe, and RecipeEditorView.save() must not silently drop it.
        let existing = NutritionFacts(calories: 438, proteinG: 36, carbsG: 31, fatG: 19, fiberG: 9)
        var fields = MacroFields()
        fields.loadExisting(existing)

        let entered = fields.entered()

        XCTAssertEqual(entered?.fiberG, 9, "fibre must survive a save that touched nothing")
    }
}

// MARK: - Fibre

extension MacroTallyTests {

    /// The defect this field exists to fix: the food database carries fibre,
    /// `RecipeCosting` tallied it, and the editor then dropped it on the floor
    /// for any recipe that did not already have some.
    func testComputedFibreSurvivesTheEditor() {
        var fields = MacroFields()
        fields.applyComputed(NutritionFacts(calories: 400, proteinG: 30, carbsG: 40,
                                            fatG: 10, fiberG: 6),
                             locale: Locale(identifier: "en_US"))

        XCTAssertEqual(fields.fiber, "6")
        let saved = fields.entered(locale: Locale(identifier: "en_US"))
        XCTAssertEqual(saved?.fiberG, 6)
    }

    /// Ingredients with no fibre data must not produce a measured zero. The
    /// reason `NutritionFacts.fiberG` is optional and the other four are not.
    func testNoFibreDataLeavesTheFieldBlankRatherThanZero() {
        var fields = MacroFields()
        fields.applyComputed(NutritionFacts(calories: 400, proteinG: 30, carbsG: 40, fatG: 10),
                             locale: Locale(identifier: "en_US"))

        XCTAssertEqual(fields.fiber, "")
        XCTAssertNil(fields.entered(locale: Locale(identifier: "en_US"))?.fiberG)
    }

    func testTypedFibreWinsOverAComputedOne() {
        var fields = MacroFields()
        fields.fiber = "9"
        fields.markTyped(.fiber)
        fields.applyComputed(NutritionFacts(calories: 400, proteinG: 30, carbsG: 40,
                                            fatG: 10, fiberG: 6),
                             locale: Locale(identifier: "en_US"))

        XCTAssertEqual(fields.fiber, "9")
        XCTAssertEqual(fields.entered(locale: Locale(identifier: "en_US"))?.fiberG, 9)
    }

    /// A recipe carrying fibre counts as typed throughout, so reopening it to
    /// add one more ingredient cannot overwrite a figure that was already
    /// right -- the rule the other four fields already followed.
    func testLoadingARecipeWithFibreMarksItTyped() {
        var fields = MacroFields()
        fields.loadExisting(NutritionFacts(calories: 400, proteinG: 30, carbsG: 40,
                                           fatG: 10, fiberG: 6),
                            locale: Locale(identifier: "en_US"))
        XCTAssertEqual(fields.fiber, "6")

        fields.applyComputed(NutritionFacts(calories: 800, proteinG: 60, carbsG: 80,
                                            fatG: 20, fiberG: 12),
                             locale: Locale(identifier: "en_US"))
        XCTAssertEqual(fields.fiber, "6", "a loaded fibre figure must not be recomputed over")
    }

    /// A recipe with no fibre must leave the field open to a later costing
    /// pass rather than pinning it to a blank nobody chose.
    func testLoadingARecipeWithoutFibreLeavesItOpenToComputation() {
        var fields = MacroFields()
        fields.loadExisting(NutritionFacts(calories: 400, proteinG: 30, carbsG: 40, fatG: 10),
                            locale: Locale(identifier: "en_US"))
        XCTAssertEqual(fields.fiber, "")

        fields.applyComputed(NutritionFacts(calories: 400, proteinG: 30, carbsG: 40,
                                            fatG: 10, fiberG: 6),
                             locale: Locale(identifier: "en_US"))
        XCTAssertEqual(fields.fiber, "6")
    }

    /// Sugar and sodium used to be carried forward from the recipe because the
    /// editor had no field for them. They have fields now, and loading and
    /// saving an untouched recipe must still keep them.
    func testSaturatedFatSugarAndSodiumSurviveASaveThatTouchedNothing() {
        var fields = MacroFields()
        let existing = NutritionFacts(calories: 400, proteinG: 30, carbsG: 40, fatG: 10, fiberG: 6,
                                      sugarG: 12, sodiumMg: 300, saturatedFatG: 3.5)
        fields.loadExisting(existing, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(fields.saturatedFat, "3.5")
        XCTAssertEqual(fields.sugar, "12")
        XCTAssertEqual(fields.sodium, "300")

        let saved = fields.entered(locale: Locale(identifier: "en_US"))
        XCTAssertEqual(saved?.saturatedFatG, 3.5)
        XCTAssertEqual(saved?.sugarG, 12)
        XCTAssertEqual(saved?.sodiumMg, 300)
        XCTAssertEqual(saved?.fiberG, 6)
    }

    /// With a field, a cleared value must save as unknown -- a merge from the
    /// old recipe would bring it straight back.
    func testClearingSodiumSavesItAsUnknownNotTheOldValue() {
        var fields = MacroFields()
        fields.loadExisting(NutritionFacts(calories: 400, proteinG: 30, carbsG: 40, fatG: 10, sodiumMg: 300),
                            locale: Locale(identifier: "en_US"))
        fields.sodium = ""
        fields.userEdited(.sodium, to: "")
        XCTAssertNil(fields.entered(locale: Locale(identifier: "en_US"))?.sodiumMg)
    }

    func testBlankDetailFieldsStayBlankAndSaveAsNil() {
        var fields = MacroFields()
        fields.loadExisting(NutritionFacts(calories: 400, proteinG: 30, carbsG: 40, fatG: 10),
                            locale: Locale(identifier: "en_US"))
        XCTAssertEqual([fields.saturatedFat, fields.sugar, fields.sodium], ["", "", ""])
        XCTAssertFalse(fields.typed.contains(.sodium), "a blank loads untyped, open to costing")

        let saved = fields.entered(locale: Locale(identifier: "en_US"))
        XCTAssertNil(saved?.saturatedFatG)
        XCTAssertNil(saved?.sugarG)
        XCTAssertNil(saved?.sodiumMg)
    }

    /// Costing fills the three only when the ingredients carried a figure, grams
    /// to one decimal and sodium whole -- and never over a typed value.
    func testComputedDetailsFillOnlyWhatIsKnownAndUntyped() {
        var fields = MacroFields()
        fields.sugar = "9"
        fields.userEdited(.sugar, to: "9")
        fields.applyComputed(NutritionFacts(calories: 400, proteinG: 30, carbsG: 40, fatG: 10,
                                            sugarG: 4.26, sodiumMg: 612.4, saturatedFatG: 2.44),
                             locale: Locale(identifier: "en_US"))
        XCTAssertEqual(fields.saturatedFat, "2.4")
        XCTAssertEqual(fields.sugar, "9", "a typed value wins over a computed one")
        XCTAssertEqual(fields.sodium, "612")

        var noData = MacroFields()
        noData.applyComputed(NutritionFacts(calories: 400, proteinG: 30, carbsG: 40, fatG: 10),
                             locale: Locale(identifier: "en_US"))
        XCTAssertEqual(noData.saturatedFat, "", "no figure is blank, never a measured zero")
        XCTAssertNil(noData.entered(locale: Locale(identifier: "en_US"))?.saturatedFatG)
    }

    /// The echo of `applyComputed`'s own write must not mark a detail field
    /// typed, or a second ingredient could never update it.
    func testAComputedDetailKeepsUpdatingAcrossIngredients() {
        var fields = MacroFields()
        let enUS = Locale(identifier: "en_US")
        fields.applyComputed(NutritionFacts(calories: 100, sodiumMg: 200), locale: enUS)
        fields.userEdited(.sodium, to: fields.sodium)
        fields.applyComputed(NutritionFacts(calories: 200, sodiumMg: 450), locale: enUS)
        XCTAssertEqual(fields.sodium, "450")
    }

    /// The pairing rule: `OptionalNumberField` writes and reads these, so a
    /// German decimal comma survives the round trip.
    func testDetailFieldsRoundTripUnderAGermanLocale() {
        let deDE = Locale(identifier: "de_DE")
        var fields = MacroFields()
        fields.loadExisting(NutritionFacts(calories: 400, proteinG: 30, carbsG: 40, fatG: 10,
                                           sugarG: 12.5, sodiumMg: 1840, saturatedFatG: 3.5),
                            locale: deDE)
        XCTAssertEqual(fields.saturatedFat, "3,5")
        XCTAssertEqual(fields.sodium, "1840", "no grouping separator for the parser to misread")
        let saved = fields.entered(locale: deDE)
        XCTAssertEqual(saved?.saturatedFatG, 3.5)
        XCTAssertEqual(saved?.sugarG, 12.5)
        XCTAssertEqual(saved?.sodiumMg, 1840)
    }

    /// A form holding only sodium is still worth saving; the four macros it
    /// cannot leave nil are zeros that `PlanLinkEncoder` reads as "not entered".
    func testAFormWithOnlySodiumSaves() {
        var fields = MacroFields()
        fields.sodium = "540"
        let saved = fields.entered(locale: Locale(identifier: "en_US"))
        XCTAssertEqual(saved?.sodiumMg, 540)
        XCTAssertEqual(saved?.calories, 0)
    }

    /// An untouched form still writes nothing at all.
    func testABlankFormStillEntersNothing() {
        XCTAssertNil(MacroFields().entered(locale: Locale(identifier: "en_US")))
    }
}
