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

/// The five macro text fields, and which of them the coach has typed into.
///
/// Text rather than `Double?` because these bind to text fields, and the
/// round trip goes through `OptionalNumberField` -- a `.formatted()` getter
/// paired with a `Double()` setter clears the field in en_US and turns 1000
/// into 1.0 in de_DE.
struct MacroFields: Equatable {
    enum Field: Hashable { case calories, protein, carbs, fat, fiber }

    var calories = ""
    var protein = ""
    var carbs = ""
    var fat = ""
    /// Fibre is a field like the other four as of this change. Before it, the
    /// food database's fibre was costed, tallied, and then silently discarded
    /// for any recipe that did not already carry some -- `entered(merging:)`
    /// could only carry fibre forward, never accept a newly computed figure.
    var fiber = ""
    private(set) var typed: Set<Field> = []

    /// The exact string `applyComputed` most recently wrote into each field.
    /// `userEdited` compares against this to tell a person's own edit apart
    /// from the view's `onChange` firing on `applyComputed`'s own write.
    private var computed: [Field: String] = [:]

    /// A field the coach edits stops being ours to fill in.
    mutating func markTyped(_ field: Field) { typed.insert(field) }

    /// Called from the view's `onChange` when a field's text changes.
    ///
    /// SwiftUI's `onChange` fires on ANY change to the bound text, including
    /// the programmatic write `applyComputed` itself just made -- not only
    /// when the coach actually types. Marking a field typed on that echo
    /// would permanently block `applyComputed` from ever updating it again:
    /// add one ingredient, every field gets marked typed by the echo of its
    /// own computed value, add a second ingredient, and the per-serving
    /// macros are frozen at the first ingredient's contribution forever.
    /// `userEdited` only marks a field typed when the new text differs from
    /// what `applyComputed` itself last wrote there.
    mutating func userEdited(_ field: Field, to newValue: String) {
        guard computed[field] != newValue else { return }
        typed.insert(field)
    }

    /// Loads an existing recipe's macros. A recipe that already carries them
    /// counts as typed throughout: reopening it to add one more ingredient
    /// must not throw away numbers that were already right.
    mutating func loadExisting(_ facts: NutritionFacts?, locale: Locale = .autoupdatingCurrent) {
        guard let facts else {
            calories = ""; protein = ""; carbs = ""; fat = ""; fiber = ""
            typed = []
            return
        }
        calories = OptionalNumberField.string(from: facts.calories, locale: locale)
        protein = OptionalNumberField.string(from: facts.proteinG, locale: locale)
        carbs = OptionalNumberField.string(from: facts.carbsG, locale: locale)
        fat = OptionalNumberField.string(from: facts.fatG, locale: locale)
        // Fibre is optional on `NutritionFacts` and the other four are not, so
        // a recipe with no fibre leaves the field blank and UNtyped -- letting
        // a costing pass fill it in, rather than pinning it to a blank the
        // coach never chose.
        if let fiberG = facts.fiberG {
            fiber = OptionalNumberField.string(from: fiberG, locale: locale)
            typed = [.calories, .protein, .carbs, .fat, .fiber]
        } else {
            fiber = ""
            typed = [.calories, .protein, .carbs, .fat]
        }
    }

    /// Writes a computed per-serving figure into only the fields the coach has
    /// not typed into.
    mutating func applyComputed(_ facts: NutritionFacts, locale: Locale = .autoupdatingCurrent) {
        if !typed.contains(.calories) {
            calories = rounded(facts.calories, locale: locale)
            computed[.calories] = calories
        }
        if !typed.contains(.protein) {
            protein = rounded(facts.proteinG, locale: locale)
            computed[.protein] = protein
        }
        if !typed.contains(.carbs) {
            carbs = rounded(facts.carbsG, locale: locale)
            computed[.carbs] = carbs
        }
        if !typed.contains(.fat) {
            fat = rounded(facts.fatG, locale: locale)
            computed[.fat] = fat
        }
        // Only when the tally actually produced a figure. Writing "0" for a
        // dish whose ingredients carry no fibre data would state a measurement
        // nobody made -- the same reason `NutritionFacts.fiberG` is optional
        // while the other four are not.
        if !typed.contains(.fiber), let fiberG = facts.fiberG {
            fiber = rounded(fiberG, locale: locale)
            computed[.fiber] = fiber
        }
    }

    /// nil unless something was actually entered. An untouched form must not
    /// write zeros -- PLAN-FORMAT: "It must never be sent as zeros."
    ///
    /// Fibre comes from its own field now, and stays `nil` when that field is
    /// blank rather than becoming a measured zero.
    ///
    /// `merging existing:` still carries `sugarG`/`sodiumMg`, because there is
    /// no sugar or sodium TextField in `RecipeEditorView` and those two would
    /// otherwise be zeroed the first time a coach opened a recipe that had
    /// them (imported via `WebLibraryImporter`, or restored via
    /// `BackupCodec`) and tapped Done. A nil result (blank form) carries
    /// nothing, unaffected.
    func entered(locale: Locale = .autoupdatingCurrent, merging existing: NutritionFacts? = nil) -> NutritionFacts? {
        let values = [calories, protein, carbs, fat, fiber].map { OptionalNumberField.value(from: $0, locale: locale) }
        guard values.contains(where: { $0 != nil }) else { return nil }
        var result = NutritionFacts(calories: values[0] ?? 0, proteinG: values[1] ?? 0,
                              carbsG: values[2] ?? 0, fatG: values[3] ?? 0)
        result.fiberG = values[4]
        result.sugarG = existing?.sugarG
        result.sodiumMg = existing?.sodiumMg
        return result
    }

    /// `value.rounded()` always produces a whole number, so this is
    /// locale-insensitive in practice today: a whole number has no decimal
    /// separator to render differently, and `OptionalNumberField` disables
    /// grouping, so there is no thousands separator to differ over either --
    /// "37" comes out the same in de_DE and en_US. The `locale` parameter is
    /// kept anyway so this stays correct if the rounding is ever removed or
    /// softened to preserve a fraction, and so all three read/write paths
    /// (`loadExisting`, `applyComputed`, `entered`) take the same shape.
    private func rounded(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        OptionalNumberField.string(from: value.rounded(), locale: locale)
    }
}
