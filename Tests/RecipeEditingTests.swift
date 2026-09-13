import XCTest
import LiftCore
import LiftReference
@testable import Coach

final class RecipeEditingTests: XCTestCase {

    // `FoodRecord` (LiftKit 1.1.0) has no public memberwise initializer --
    // its stored properties are all `public`, but Swift's synthesized
    // memberwise init for a struct is `internal` unless the type writes its
    // own `public init`, so `FoodRecord(id:name:...)` does not compile from
    // this module. It is, however, plain `Codable` with no custom
    // `CodingKeys`, so decoding one from JSON (matching property names) is
    // the only cross-module construction route available without editing
    // the package. This factory is the brief's `record(...)` helper,
    // rebuilt to go through that route; the fixture values are unchanged.
    private func record(calories: Double, protein: Double, carbs: Double, fat: Double) -> FoodRecord {
        let json: [String: Any?] = [
            "id": "usda:test",
            "name": "Chicken, broilers or fryers, breast, meat only, raw",
            "brand": nil,
            "servingGrams": nil,
            "servingLabel": nil,
            "caloriesPer100g": calories,
            "proteinPer100g": protein,
            "carbsPer100g": carbs,
            "fatPer100g": fat,
            "fiberPer100g": 0,
            "sugarPer100g": nil,
            "sodiumPer100g": nil,
            "source": "usda",
        ]
        let data = try! JSONSerialization.data(withJSONObject: json.compactMapValues { $0 })
        return try! JSONDecoder().decode(FoodRecord.self, from: data)
    }

    func testPickingAnIngredientWritesTheLineItsQuantityAndName() {
        let line = RecipeEditorView.ingredientLine(for: record(calories: 120, protein: 22, carbs: 0, fat: 3),
                                                   grams: 600)
        XCTAssertEqual(line, "600 g Chicken, broilers or fryers, breast, meat only, raw")
        XCTAssertEqual(IngredientParser.parse(line, sortOrder: 0).qty, 600,
                       "the line it writes must survive its own parser")
    }

    func testAPickedIngredientContributesItsShareOfPer100gMacros() {
        let contribution = RecipeEditorView.contribution(
            of: record(calories: 120, protein: 22, carbs: 0, fat: 3), grams: 600)
        XCTAssertEqual(contribution.calories, 720, accuracy: 0.001)
        XCTAssertEqual(contribution.proteinG, 132, accuracy: 0.001)
    }

    func testAddingIngredientsFillsTheMacroFieldsPerServing() {
        var tally = MacroTally()
        var fields = MacroFields()
        tally.add(RecipeEditorView.contribution(of: record(calories: 120, protein: 22, carbs: 0, fat: 3),
                                                grams: 600))
        fields.applyComputed(tally.perServing(4))
        XCTAssertEqual(fields.calories, "180")
        XCTAssertEqual(fields.protein, "33")
    }

    func testABarcodeQueryIsRecognisedByShapeNotByAToggle() {
        XCTAssertTrue(RecipeEditorView.looksLikeBarcode("5000112637939"))
        XCTAssertTrue(RecipeEditorView.looksLikeBarcode("12345678"))
        XCTAssertFalse(RecipeEditorView.looksLikeBarcode("1234567"), "too short")
        XCTAssertFalse(RecipeEditorView.looksLikeBarcode("123456789012345"), "too long")
        XCTAssertFalse(RecipeEditorView.looksLikeBarcode("chicken breast"))
    }

    func testTheIngredientLineIsWrittenWithATrimmedQuantity() {
        let line = RecipeEditorView.ingredientLine(for: record(calories: 100, protein: 0, carbs: 0, fat: 0),
                                                   grams: 100)
        XCTAssertTrue(line.hasPrefix("100 g "), "not 100.0 g")
    }

    /// Pins the CONTROLLER CORRECTION: `load()` must format `servings` with
    /// `OptionalNumberField.string(from:)`, the exact locale-aware inverse of
    /// the `OptionalNumberField.value(from:)` parse the `servings` computed
    /// property uses -- not `CookFormat.trimmed`, whose `%g` always writes a
    /// `.` and which `de_DE`'s `OptionalNumberField.value(from:)` cannot read
    /// back (it would parse as nil, and the `?? 1` fallback would silently
    /// turn a 2.5-serving recipe into a 1-serving one).
    func testServingsRoundTripsThroughDeDELocale() {
        let de = Locale(identifier: "de_DE")
        let recipe = Recipe(name: "Chili", servings: 2.5)

        // What RecipeEditorView.load() writes into `servingsText`.
        let stored = OptionalNumberField.string(from: recipe.servings, locale: de)
        // What RecipeEditorView.servings reads back out of `servingsText`.
        let roundTripped = OptionalNumberField.value(from: stored, locale: de) ?? 1

        XCTAssertEqual(stored, "2,5", "de_DE writes a comma decimal separator")
        XCTAssertEqual(roundTripped, 2.5, accuracy: 0.0001,
                       "a fractional serving count must survive a de_DE load/save round trip")
    }
}
