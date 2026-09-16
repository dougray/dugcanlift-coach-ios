import Foundation
import LiftCore

/// Where an imported recipe's macros came from, and what to say about it.
///
/// A value type with no view in it, for the same reason `MacroFields` is one:
/// a rule living in a view's `@State` cannot be tested, and this one decides
/// whether a number reaches a client's day total.
///
/// The rule in one line: **stated figures win, and costing only fills a gap.**
/// A source that publishes nutrition has measured something we cannot
/// re-derive from ingredient lines alone; a source that publishes none leaves
/// us costing what can be weighed, which is partial by construction. Both are
/// estimates and both say so, but they are not equally good and the transcript
/// keeps them distinguishable.
///
/// Named for the link import it was written for, and used unchanged by
/// `RecipePasteImportView` as well: a pasted caption states no macros, so it
/// is always the costing branch. That the rule needed no new case to accept a
/// second source is the argument for it living here rather than in a view.
enum LinkImportMacros {

    /// What to write, and what to record about how complete it is.
    struct Outcome: Equatable {
        /// Per serving, never pre-scaled — `PlannedMeal.snapshotNutrition`'s
        /// invariant, and `Recipe.nutritionPerServing`'s own contract.
        ///
        /// `nil` when nothing could be costed. Blank stays blank: a zero here
        /// becomes a zero-calorie dinner in a client's day total, which is the
        /// failure `MacroFields` exists to prevent on the typed side.
        var nutritionPerServing: NutritionFacts?
        var isEstimated: Bool
        var transcript: String
    }

    /// Whether the ingredients need costing at all.
    ///
    /// Only when the source published nothing. Costing over the top of a
    /// site's own figures would replace a whole-dish measurement with a
    /// partial one. Always true for a pasted caption.
    static func needsCosting(_ imported: ImportedRecipe) -> Bool {
        imported.nutritionPerServing == nil
    }

    /// - Parameter costed: the costing pass, or `nil` when the source
    ///   published its own macros and none was run.
    static func resolve(imported: ImportedRecipe,
                        servings: Double,
                        costed: CostingResult?) -> Outcome {

        // The source text stays at the top of the transcript either way --
        // the JSON-LD block, or the caption as pasted. It is what a misread
        // quantity is checked against afterwards.
        let source = imported.sourceTranscript

        if let published = imported.nutritionPerServing {
            return Outcome(
                nutritionPerServing: published,
                // The site's figure, not one resolved against the food
                // database. True for the same reason TheMealDB imports are.
                isEstimated: true,
                transcript: source.isEmpty
                    ? "Macros are the site's own figures, per serving."
                    : source + "\n\nMacros are the site's own figures, per serving."
            )
        }

        guard let costed else {
            // No published macros and no costing pass: nothing to say beyond
            // the source text.
            return Outcome(nutritionPerServing: nil, isEstimated: false, transcript: source)
        }

        let note = costingNote(costed, of: imported.ingredientLines.count)
        let transcript = source.isEmpty ? note : source + "\n\n" + note

        guard costed.tally.lines > 0 else {
            // Nothing could be weighed. `.zero` would look like a measured
            // dish that happens to be free of calories.
            return Outcome(nutritionPerServing: nil, isEstimated: false, transcript: transcript)
        }

        return Outcome(
            nutritionPerServing: costed.tally.perServing(servings),
            isEstimated: true,
            transcript: transcript
        )
    }

    /// The gap, in words, with a count.
    ///
    /// The rule the recipe editor's macro section and the library card already
    /// follow: macros built from three of seventeen ingredients are worse than
    /// useless if they look whole, so the shortfall is stated rather than
    /// implied by a number that looks complete.
    private static func costingNote(_ costed: CostingResult, of total: Int) -> String {
        guard costed.tally.lines > 0 else {
            return "No macros came with this recipe, and nothing here could be weighed "
                 + "automatically, so it has none. Add them by hand before sending it."
        }
        guard !costed.unpriced.isEmpty else {
            return "No macros came with this recipe. Every ingredient was costed here."
        }
        return "No macros came with this recipe. \(costed.unpriced.count) of \(total) "
             + "ingredients could not be weighed automatically, so the macros are short:\n"
             + costed.unpriced.joined(separator: "\n")
    }
}
