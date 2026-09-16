import SwiftUI
import SwiftData
import LiftCore
import LiftReference

/// Browse the bundled recipe catalogue and copy one into the library.
///
/// The third import source, beside TheMealDB search and a pasted link, and the
/// only one that needs no network at all: 622 recipes ship in `recipes.db`.
///
/// Nothing is costed here. `RecipeCosting` applies the same weight-only rules
/// the catalogue's own build already applied, so re-running it would spend a
/// database pass to reach the identical answer. A catalogue recipe's macros
/// and its coverage note are both already decided.
///
/// **Attribution does not travel on the wire.** `PlanLinkEncoder.planRecipe`
/// sends name, servings, macros, ingredients and steps -- there is no field
/// for a credit, and PLAN-FORMAT is a contract with three other clients rather
/// than something to extend unilaterally. A CC BY-SA recipe sent to a client
/// therefore arrives uncredited, which that licence asks for on
/// redistribution. Adding recipes to the library is fine; sending one onward
/// is the open question, and it needs a wire-format decision, not a patch here.
struct RecipeCatalogView: View {

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var entries: [CatalogEntry] = []
    @State private var selected: CatalogEntry?
    @State private var servings: Double = 4
    @State private var note = ""
    @State private var credits: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                if let selected {
                    detail(selected)
                } else {
                    list
                }
            }
            .navigationTitle(selected == nil ? "Recipe catalogue" : "Add recipe")
            .searchable(text: $query, prompt: "Search 600+ recipes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if selected == nil {
                        Button("Done") { dismiss() }
                    } else {
                        Button("Back") { selected = nil }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let selected {
                        Button("Add") { add(selected) }
                    }
                }
            }
            .task(id: query) { await load() }
            .task { credits = (try? await ReferenceDatabase.shared.recipeAttributions()) ?? [] }
        }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if !note.isEmpty {
            Section { Text(note).font(.caption).foregroundStyle(Theme.textSecondary) }
        }

        Section {
            ForEach(entries) { entry in
                Button { open(entry) } label: { row(entry) }
            }
        } footer: {
            Text("Ships with Coach; no connection needed. Nothing is added to your library until you tap Add.")
                .font(.caption)
        }

        if !credits.isEmpty {
            // CC BY-SA requires the credit be given, so it sits on the screen
            // that shows the data rather than in a settings page.
            Section("Credits") {
                ForEach(credits, id: \.self) {
                    Text($0).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func row(_ entry: CatalogEntry) -> some View {
        let recipe = entry.recipe
        return VStack(alignment: .leading, spacing: 2) {
            Text(recipe.name).foregroundStyle(Theme.textPrimary)
            Text(macroSummary(recipe) + " · \(entry.ingredientLines.count) ingredients")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func macroSummary(_ recipe: CatalogRecipe) -> String {
        if let calories = recipe.caloriesPerServing {
            return "\(Int(calories)) kcal per serving"
        }
        // Said in the list, not only the detail, so a browsing eye never reads
        // a whole-pot figure as a portion.
        if recipe.needsServings { return "Macros for the whole dish" }
        return "No macros"
    }

    // MARK: - Detail

    @ViewBuilder
    private func detail(_ entry: CatalogEntry) -> some View {
        let recipe = entry.recipe

        Section("Recipe") {
            Text(recipe.name).foregroundStyle(Theme.textPrimary)
            if let summary = recipe.summary {
                Text(summary).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if recipe.needsServings {
                Stepper(value: $servings, in: 1...48, step: 1) {
                    Text(CookFormat.servingsLabel(servings)).foregroundStyle(Theme.textPrimary)
                }
                Text("This book states no yield, so the macros are for the whole dish. Set how many it serves before sending it to anyone.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else if let stated = recipe.servings {
                Text(CookFormat.servingsLabel(stated)).foregroundStyle(Theme.textPrimary)
            }
        }

        Section("Ingredients (\(entry.ingredientLines.count))") {
            ForEach(Array(entry.ingredientLines.enumerated()), id: \.offset) { index, line in
                let parsed = IngredientParser.parse(line, sortOrder: index)
                HStack {
                    Text(parsed.displayText).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if parsed.qty == nil {
                        Text("as written").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }

        if !recipe.stepLines.isEmpty {
            Section("Method (\(recipe.stepLines.count))") {
                ForEach(Array(recipe.stepLines.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)")
                        .font(.caption)
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }

        Section("Macros") {
            if let facts = recipe.nutrition(servings: servings) {
                Text("\(Int(facts.calories)) kcal · P \(Int(facts.proteinG)) · C \(Int(facts.carbsG)) · F \(Int(facts.fatG))")
                    .foregroundStyle(Theme.textPrimary)
                Text(recipe.needsServings
                     ? "Per serving at \(CookFormat.servingsLabel(servings))."
                     : "Per serving, as published.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("None.").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if let reason = recipe.nutritionNote {
                Text(reason).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }

        Section("Source") {
            Text(recipe.attribution).font(.caption).foregroundStyle(Theme.textSecondary)
            Text(recipe.license).font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Behaviour

    private func open(_ entry: CatalogEntry) {
        servings = entry.recipe.servings ?? 4
        selected = entry
    }

    /// Debounced with a two-character floor, the same as every other search
    /// against the reference database.
    private func load() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed.count < 2 { return }
        if !trimmed.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
        }

        do {
            let found = trimmed.count >= 2
                ? try await ReferenceDatabase.shared.searchRecipes(trimmed)
                : try await ReferenceDatabase.shared.browseRecipes()
            guard !Task.isCancelled else { return }
            entries = found
            note = found.isEmpty && trimmed.count >= 2 ? "Nothing matches that." : ""
        } catch {
            entries = []
            note = "The recipe catalogue could not be opened."
        }
    }

    /// Copies the entry into the library, inserting the recipe and each
    /// ingredient before wiring the relationship -- the order
    /// `RecipeImportView.take(_:)` uses.
    private func add(_ entry: CatalogEntry) {
        let (recipe, ingredients) = entry.makeRecipe(servings: entry.recipe.servings ?? servings)
        context.insert(recipe)
        for ingredient in ingredients {
            ingredient.recipe = recipe
            context.insert(ingredient)
        }
        try? context.save()
        dismiss()
    }
}
