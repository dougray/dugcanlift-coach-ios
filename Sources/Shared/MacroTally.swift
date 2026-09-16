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

/// The five macro text fields plus saturated fat, sugar and sodium, and which
/// of them the coach has typed into.
///
/// Text rather than `Double?` because these bind to text fields, and the
/// round trip goes through `OptionalNumberField` -- a `.formatted()` getter
/// paired with a `Double()` setter clears the field in en_US and turns 1000
/// into 1.0 in de_DE.
struct MacroFields: Equatable {
    enum Field: Hashable { case calories, protein, carbs, fat, fiber, saturatedFat, sugar, sodium }

    var calories = ""
    var protein = ""
    var carbs = ""
    var fat = ""
    /// Fibre is a field like the other four as of this change. Before it, the
    /// food database's fibre was costed, tallied, and then silently discarded
    /// for any recipe that did not already carry some -- `entered(merging:)`
    /// could only carry fibre forward, never accept a newly computed figure.
    var fiber = ""
    /// Saturated fat, sugar (grams) and sodium (milligrams), per serving. They
    /// follow fibre's rules, not the four macros': optional on
    /// `NutritionFacts`, so blank loads blank and untyped, a costing pass fills
    /// them only when the ingredients actually carried a figure, and blank
    /// saves as nil. Tracked, never targeted -- there is no goal for them.
    var saturatedFat = ""
    var sugar = ""
    var sodium = ""
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
            saturatedFat = ""; sugar = ""; sodium = ""
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
        // The same rule as fibre, for each of the three on its own.
        for (field, value) in [(Field.saturatedFat, facts.saturatedFatG), (.sugar, facts.sugarG), (.sodium, facts.sodiumMg)] {
            self[text: field] = OptionalNumberField.string(from: value, locale: locale)
            if value != nil { typed.insert(field) }
        }
    }

    /// The three optional detail fields by name, so `loadExisting` and
    /// `applyComputed` treat them identically.
    private subscript(text field: Field) -> String {
        get {
            switch field {
            case .saturatedFat: return saturatedFat
            case .sugar: return sugar
            case .sodium: return sodium
            default: return ""
            }
        }
        set {
            switch field {
            case .saturatedFat: saturatedFat = newValue
            case .sugar: sugar = newValue
            case .sodium: sodium = newValue
            default: break
            }
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
        // Grams to one decimal -- a whole-gram saturated fat turns 2.4 into 2
        // -- and sodium in whole milligrams. Only when the tally has a figure,
        // for fibre's reason: the food database lacks saturated fat for some
        // foods, and a zero would be a measurement nobody made.
        for (field, value, places) in [(Field.saturatedFat, facts.saturatedFatG, 1.0),
                                       (.sugar, facts.sugarG, 1.0),
                                       (.sodium, facts.sodiumMg, 0.0)] {
            guard !typed.contains(field), let value, value.isFinite else { continue }
            let scale = pow(10, places)
            let text = OptionalNumberField.string(from: (value * scale).rounded() / scale, locale: locale)
            self[text: field] = text
            computed[field] = text
        }
    }

    /// nil unless something was actually entered. An untouched form must not
    /// write zeros -- PLAN-FORMAT: "It must never be sent as zeros."
    ///
    /// Fibre comes from its own field now, and stays `nil` when that field is
    /// blank rather than becoming a measured zero.
    ///
    /// Saturated fat, sugar and sodium come from their own fields too, blank as
    /// nil. They used to be carried forward from the recipe being edited
    /// (`merging:`) because the editor had no field for them; with fields, a
    /// merge would bring back a value the coach had just cleared.
    ///
    /// A form holding only, say, sodium still returns facts, with the four
    /// macros at zero -- the only shape `NutritionFacts` allows.
    /// `PlanLinkEncoder` omits `u` for exactly that shape, so those zeros never
    /// reach a client as a zero-calorie dinner.
    func entered(locale: Locale = .autoupdatingCurrent) -> NutritionFacts? {
        let values = [calories, protein, carbs, fat, fiber, saturatedFat, sugar, sodium]
            .map { OptionalNumberField.value(from: $0, locale: locale) }
        guard values.contains(where: { $0 != nil }) else { return nil }
        return NutritionFacts(calories: values[0] ?? 0, proteinG: values[1] ?? 0,
                              carbsG: values[2] ?? 0, fatG: values[3] ?? 0,
                              fiberG: values[4], sugarG: values[6], sodiumMg: values[7],
                              saturatedFatG: values[5])
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
