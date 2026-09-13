import Foundation
import LiftCore
import LiftReference

/// What an import could and could not be costed.
struct CostingResult: Equatable {
    var tally = MacroTally()
    var unpriced: [String] = []
}

/// Costs raw ingredient lines against the food database.
///
/// Only lines that convert to a weight are costed. Volume and vague units are
/// left alone and counted as unpriced, because pricing "2 tbsp olive oil"
/// means inventing a density -- and the coach can see and fix a gap far more
/// easily than a plausible wrong number.
enum RecipeCosting {

    /// - Parameter lookup: given a parsed item name, the best database match.
    ///   Injected so this is testable without opening SQLite.
    static func cost(lines: [String],
                     lookup: (String) async -> FoodRecord?) async -> CostingResult {
        var result = CostingResult()
        for line in lines {
            let parsed = IngredientParser.parse(line, sortOrder: 0)
            guard let grams = IngredientParser.grams(for: parsed),
                  let item = parsed.item,
                  let match = await lookup(item) else {
                result.unpriced.append(line)
                continue
            }
            result.tally.add(match.nutrition(grams: grams))
        }
        return result
    }

    /// The production lookup: the single best database match for an item name.
    static func databaseLookup(_ item: String) async -> FoodRecord? {
        (try? await ReferenceDatabase.shared.searchFoods(item, limit: 1))?.first
    }
}
