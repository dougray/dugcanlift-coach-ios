import Foundation
import LiftCore

/// What the looked-up ingredients add up to, for the recipe being edited.
///
/// A value type with no view in it, because the two rules it enforces are the
/// two the spec names as most likely to be lost in a refactor, and a rule that
/// lives only in a view's @State cannot be tested.
struct MacroTally: Equatable {
    private(set) var total: NutritionFacts = .zero
    private(set) var lines: Int = 0

    mutating func add(_ contribution: NutritionFacts) {
        total = total + contribution
        lines += 1
    }

    mutating func reset() {
        total = .zero
        lines = 0
    }

    /// The whole recipe divided by how many it feeds. Guards a servings field
    /// a coach has cleared mid-edit -- `Recipe.init` clamps the same way.
    func perServing(_ servings: Double) -> NutritionFacts {
        let clampedServings = (servings.isFinite && servings > 0) ? servings : 0.0001
        return total.scaled(by: 1 / clampedServings)
    }
}

/// The four macro text fields, and which of them the coach has typed into.
///
/// Text rather than `Double?` because these bind to text fields, and the
/// round trip goes through `OptionalNumberField` -- a `.formatted()` getter
/// paired with a `Double()` setter clears the field in en_US and turns 1000
/// into 1.0 in de_DE.
struct MacroFields: Equatable {
    enum Field: Hashable { case calories, protein, carbs, fat }

    var calories = ""
    var protein = ""
    var carbs = ""
    var fat = ""
    private(set) var typed: Set<Field> = []

    /// A field the coach edits stops being ours to fill in.
    mutating func markTyped(_ field: Field) { typed.insert(field) }

    /// Loads an existing recipe's macros. A recipe that already carries them
    /// counts as typed throughout: reopening it to add one more ingredient
    /// must not throw away numbers that were already right.
    mutating func loadExisting(_ facts: NutritionFacts?, locale: Locale = .autoupdatingCurrent) {
        guard let facts else {
            calories = ""; protein = ""; carbs = ""; fat = ""
            typed = []
            return
        }
        calories = OptionalNumberField.string(from: facts.calories, locale: locale)
        protein = OptionalNumberField.string(from: facts.proteinG, locale: locale)
        carbs = OptionalNumberField.string(from: facts.carbsG, locale: locale)
        fat = OptionalNumberField.string(from: facts.fatG, locale: locale)
        typed = [.calories, .protein, .carbs, .fat]
    }

    /// Writes a computed per-serving figure into only the fields the coach has
    /// not typed into.
    mutating func applyComputed(_ facts: NutritionFacts, locale: Locale = .autoupdatingCurrent) {
        if !typed.contains(.calories) { calories = rounded(facts.calories, locale: locale) }
        if !typed.contains(.protein) { protein = rounded(facts.proteinG, locale: locale) }
        if !typed.contains(.carbs) { carbs = rounded(facts.carbsG, locale: locale) }
        if !typed.contains(.fat) { fat = rounded(facts.fatG, locale: locale) }
    }

    /// nil unless something was actually entered. An untouched form must not
    /// write zeros -- PLAN-FORMAT: "It must never be sent as zeros."
    func entered(locale: Locale = .autoupdatingCurrent) -> NutritionFacts? {
        let values = [calories, protein, carbs, fat].map { OptionalNumberField.value(from: $0, locale: locale) }
        guard values.contains(where: { $0 != nil }) else { return nil }
        return NutritionFacts(calories: values[0] ?? 0, proteinG: values[1] ?? 0,
                              carbsG: values[2] ?? 0, fatG: values[3] ?? 0)
    }

    private func rounded(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        OptionalNumberField.string(from: value.rounded(), locale: locale)
    }
}
