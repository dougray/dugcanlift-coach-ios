import XCTest
import LiftCore
@testable import Coach

/// Pins the fix-round-1 Finding 1 bug: `CookPlanView.RebuildKey.Inlined` must
/// mirror every field `PlanLinkEncoder.planRecipe` puts on the wire in `u`
/// (calories/protein/carbs/fat/fibre), not just calories. A coach who books a
/// recipe, sends the link, then corrects protein with calories unchanged must
/// still rebuild the link -- `.task(id:)` only reruns when the key changes.
final class CookPlanViewRebuildKeyTests: XCTestCase {

    /// Same `id` for every call -- `Recipe.init` mints a fresh random UUID
    /// each time, which would make any two instances compare unequal on `id`
    /// alone and mask the bug this test exists to catch.
    private let fixedID = UUID()

    private func recipe(protein: Double) -> Recipe {
        let r = Recipe(name: "Chicken Bowl", servings: 2,
               nutritionPerServing: NutritionFacts(calories: 500, proteinG: protein, carbsG: 40, fatG: 10))
        r.id = fixedID
        return r
    }

    func testChangingProteinAloneMovesTheRebuildKey() {
        let keyBefore = CookPlanView.rebuildKey(
            clientID: "client-1", weekStart: "2026-09-14", coachName: "Doug",
            mine: [], used: [recipe(protein: 20)])
        let keyAfter = CookPlanView.rebuildKey(
            clientID: "client-1", weekStart: "2026-09-14", coachName: "Doug",
            mine: [], used: [recipe(protein: 40)])

        XCTAssertNotEqual(keyBefore, keyAfter,
            "protein changed from 20g to 40g with calories held steady -- the " +
            "rebuild key must move or the share link ships stale macros")
    }
}
