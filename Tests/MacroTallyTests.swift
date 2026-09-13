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

    // MARK: - F1: entered(merging:) must not destroy fibre/sugar/sodium

    func testEnteredMergesFibreSugarSodiumFromTheExistingFactsWhenNothingChanged() {
        // Loading an existing recipe and changing nothing, then saving, must
        // not zero out fields the four visible text fields never touched --
        // WebLibraryImporter and BackupCodec both populate fiberG on a real
        // recipe, and RecipeEditorView.save() must not silently drop it.
        let existing = NutritionFacts(calories: 438, proteinG: 36, carbsG: 31, fatG: 19, fiberG: 9)
        var fields = MacroFields()
        fields.loadExisting(existing)

        let entered = fields.entered(merging: existing)

        XCTAssertEqual(entered?.fiberG, 9, "fibre must survive a save that touched nothing")
    }
}
