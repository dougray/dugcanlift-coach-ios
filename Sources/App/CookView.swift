import SwiftUI
import SwiftData
import LiftCore

struct CookView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Recipe.name) private var recipes: [Recipe]
    @Query(sort: \Client.name) private var clients: [Client]
    @State private var editing: Recipe?
    /// Set alongside `editing`, never independently -- see F2 in the final
    /// fix wave. `RecipeEditorView` needs to know whether the recipe it is
    /// presenting is new so Cancel can delete it instead of leaving a
    /// phantom row; `editing` alone (an `Identifiable` item) has no room for
    /// that second fact without changing its type.
    @State private var editingIsNew = false
    @State private var importing = false
    @State private var importingLink = false
    @State private var browsingCatalogue = false
    @State private var pasting = false
    @State private var section: Section = .recipes

    /// Mirrors `CookPlanView`'s own `@AppStorage("cookPlanOwners")` --
    /// deleting a recipe here orphans its `PlannedMeal`s (see `delete(_:)`),
    /// and this needs write access to the same blob so a deleted meal's
    /// ownership entry does not outlive the meal itself.
    @AppStorage("cookPlanOwners") private var ownersData = Data()

    // Owned here, not by the child screens: CookView's section switch gives
    // each branch its own subtree, so @State living below would be torn down
    // and rebuilt on every section change, losing the picked client.
    // Scene storage rather than @State: switching the top tabs tears this
    // whole view down, and @State went with it, so the picked client reset
    // every time the coach looked at another tab. Shared by Cook and Train, so
    // planning one client's meals and then their training keeps the same pick.
    @SceneStorage("planClientID") private var planClientID: String = ""
    @State private var planWeekStart: String = DayKey.today
    @State private var planShareLink: String = ""

    /// The PWA's three Cook chips, in its order.
    private enum Section: String, CaseIterable, Identifiable {
        case recipes = "Recipes"
        case plan = "Plan"
        case shopping = "Shopping"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $section) {
                    ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                // Capped so the three segments do not spread across an iPad;
                // narrower than any iPhone, so no change there.
                .frame(maxWidth: AdaptiveLayout.readableWidth)
                .padding()
                .tint(Theme.accent)

                switch section {
                case .recipes: library
                case .plan: CookPlanView(clientID: $planClientID, weekStart: $planWeekStart,
                                         shareLink: $planShareLink)
                case .shopping: ShoppingView(clientID: $planClientID, weekStart: $planWeekStart)
                }
            }
            // Applied once, by the parent every section shares -- see the
            // note in TrainPlanView about nesting this inside itself.
            .safeAreaPadding(.bottom, 72)
            .coachScreen()
            .background(Theme.background)
            // The tab row above already names this screen, and the browser build
            // goes straight from its tabs into the content.
            .navigationBarTitleDisplayMode(.inline)
            .regularWidthTitle("Cook")
            .focusedSceneValue(\.coachNewItem, section == .recipes
                               ? CoachNewItem(title: "New Recipe", action: newRecipe) : nil)
            .sheet(item: $editing) { RecipeEditorView(recipe: $0, isNew: editingIsNew) }
            .sheet(isPresented: $importing) { RecipeImportView() }
            .sheet(isPresented: $importingLink) { RecipeLinkImportView() }
            .sheet(isPresented: $browsingCatalogue) { RecipeCatalogView() }
            .sheet(isPresented: $pasting) { RecipePasteImportView() }
        }
    }

    private var library: some View {
        AdaptiveScrollPage { width in
            let columns = AdaptiveLayout.columns(for: width, minColumnWidth: 280, maxColumns: 4)
            if recipes.isEmpty {
                LiftCard(title: "Recipes") {
                    Text("No recipes yet. Write the ones you actually give clients — "
                         + "the plan and their shopping list build themselves from here.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            // Below the cards on a phone, where they are the first thing to
            // read; above them in a grid, where a long library would push them
            // off the bottom of the screen.
            if columns > 1 { libraryActions(wide: true) }

            if !recipes.isEmpty {
                AdaptiveGrid(recipes, columns: columns) { recipe in
                    LiftCard(title: recipe.name) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(CookFormat.servingsLabel(recipe.servings))
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                            Text(macroLine(recipe))
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                            Spacer(minLength: 0)
                            HStack {
                                Button("Edit") { editingIsNew = false; editing = recipe }
                                    .tint(Theme.accent)
                                Spacer()
                                Button("Delete", role: .destructive) { delete(recipe) }
                            }
                        }
                        .fillsGridCell()
                    }
                }
            }

            if columns == 1 { libraryActions(wide: false) }
        }
    }

    /// On a phone, New and Import share a line with Send beneath, as they
    /// always have. Wide, the three sit together on one line at the left: the
    /// phone's `Spacer` put Import a whole iPad's width away from New.
    @ViewBuilder
    private func libraryActions(wide: Bool) -> some View {
        if wide {
            HStack(spacing: 28) {
                newRecipeButton
                importMenu
                sendRecipesMenu
                Spacer(minLength: 0)
            }
        } else {
            HStack {
                newRecipeButton
                Spacer()
                importMenu
            }
            sendRecipesMenu
        }
    }

    private var newRecipeButton: some View {
        Button("New recipe", action: newRecipe)
            .tint(Theme.accent)
    }

    // A Menu rather than a row of buttons: four import
    // sources would not fit the line at iPhone width, and
    // "Send recipes" below is the same shape.
    private var importMenu: some View {
        Menu("Import") {
            // First: it needs no connection and no typing.
            Button("From the catalogue") { browsingCatalogue = true }
            // The pair for a recipe found elsewhere. A link is
            // better whenever the page has a recipe card, so it
            // leads; pasting the text is what is left when it
            // does not -- a caption, an email, a photo retyped.
            Button("From a link") { importingLink = true }
            Button("Paste the text") { pasting = true }
            Button("A dish by name") { importing = true }
        }
        .tint(Theme.accent)
    }

    @ViewBuilder
    private var sendRecipesMenu: some View {
        if !recipes.isEmpty {
            // "Here is the recipe", with nothing booked into a day --
            // PLAN-FORMAT's library send. Scheduling is a separate
            // claim from possession.
            Menu("Send recipes") {
                if clients.isEmpty {
                    Text("No clients yet")
                } else {
                    ForEach(clients) { client in
                        ShareLink(item: libraryLink(for: client)) { Text(client.name) }
                    }
                }
            }
            .tint(Theme.accent)
        }
    }

    private func newRecipe() {
        section = .recipes
        let recipe = Recipe(name: "New recipe")
        context.insert(recipe)
        editingIsNew = true
        editing = recipe
    }

    private func macroLine(_ recipe: Recipe) -> String {
        // A recipe with only saturated fat, sugar or sodium entered carries
        // zeros in the four macros -- "not entered", as `PlanLinkEncoder`
        // reads it, never a zero-calorie dish.
        guard let n = recipe.nutritionPerServing,
              n.calories != 0 || n.proteinG != 0 || n.carbsG != 0 || n.fatG != 0
        else { return "Macros not set" }
        let line = "\(CookFormat.trimmed(n.calories.rounded())) kcal  "
             + "P \(CookFormat.trimmed(n.proteinG.rounded()))  "
             + "C \(CookFormat.trimmed(n.carbsG.rounded()))  "
             + "F \(CookFormat.trimmed(n.fatG.rounded()))"
        return recipe.nutritionIsEstimated ? line + " · estimated" : line
    }

    private func libraryLink(for client: Client) -> String {
        let fragment = PlanLinkEncoder.fragment(
            recipes: recipes, lifterID: client.id,
            coachName: PlanLinkEncoder.coachName(UserDefaults.standard.string(forKey: "coachName")))
        return "https://www.dugcanlift.com/lift/#" + fragment
    }

    /// Deleting a recipe orphans the meals planned from it, the same way
    /// deleting a Routine orphans its sessions -- so sweep them here, where
    /// the planned meals are still reachable. Also sweeps their entries out
    /// of `cookPlanOwners`: leaving them behind doesn't break anything --
    /// the deleted meal's UUID matches nothing once the meal itself is
    /// gone -- but it violates the ownership contract this key is, and the
    /// fix is a few lines.
    private func delete(_ recipe: Recipe) {
        let orphans = ((try? context.fetch(FetchDescriptor<PlannedMeal>())) ?? [])
            .filter { $0.recipeID == recipe.id }
        for meal in orphans { context.delete(meal) }
        ownersData = Self.sweepOwners(ownersData, removing: orphans.map(\.id))
        context.delete(recipe)
        try? context.save()
    }

    /// Removes the given meal IDs' entries from a `cookPlanOwners`-shaped
    /// blob. A static, pure function -- rather than inline in `delete(_:)` --
    /// so `CookViewOwnershipTests` can pin the sweep without standing up a
    /// live `@Query`/`@Environment` view instance.
    static func sweepOwners(_ data: Data, removing mealIDs: [UUID]) -> Data {
        var mapping = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        for id in mealIDs { mapping.removeValue(forKey: id.uuidString) }
        return (try? JSONEncoder().encode(mapping)) ?? Data()
    }
}
