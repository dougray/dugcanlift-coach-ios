import SwiftUI
import SwiftData
import LiftCore

/// Search TheMealDB, then cost what can be weighed.
///
/// An imported dish carries no nutrition of its own. The screen says so, and
/// says how much of the dish the costing actually covered -- a macro figure
/// built from three of seventeen ingredients is worse than useless if it looks
/// whole.
struct RecipeImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var hits: [ImportedRecipe] = []
    @State private var note = ""
    @State private var busy = false

    private let client = MealDBClient()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Dish name", text: $query)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await search() } }
                        Button("Search") { Task { await search() } }
                            .tint(Theme.accent)
                            .disabled(busy || query.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } footer: {
                    Text("The only part of Coach that uses the internet. An imported dish "
                         + "carries no nutrition of its own — check the macros before you "
                         + "send it to anyone.")
                        .font(.caption)
                }

                if !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(Theme.textSecondary)
                }

                ForEach(hits) { hit in
                    Button {
                        Task { await take(hit) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.name).foregroundStyle(Theme.textPrimary)
                            Text("\(hit.ingredients.count) ingredients")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .navigationTitle("Import a dish")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func search() async {
        busy = true
        defer { busy = false }
        note = "Searching…"
        hits = []
        do {
            hits = try await client.search(query.trimmingCharacters(in: .whitespaces))
            note = hits.isEmpty ? "Nothing found for that." : ""
        } catch {
            // Said plainly rather than shown as an empty list, which would
            // read as "no such dish".
            note = "Could not reach TheMealDB. Check your connection, or write the recipe by hand."
        }
    }

    private func take(_ hit: ImportedRecipe) async {
        note = "Costing the ingredients…"
        let costed = await RecipeCosting.cost(lines: hit.ingredients,
                                              lookup: RecipeCosting.databaseLookup)

        // Servings stays at 1: TheMealDB does not say how many a dish feeds,
        // and guessing four would silently divide every macro by a number
        // nobody chose. The coach sets it in the editor.
        let recipe = Recipe(name: hit.name, servings: 1, steps: hit.steps)
        recipe.sourceURL = URL(string: "https://www.themealdb.com")
        recipe.nutritionIsEstimated = true
        if costed.tally.lines > 0 {
            recipe.nutritionPerServing = costed.tally.perServing(1)
        }
        context.insert(recipe)
        for (index, line) in hit.ingredients.enumerated() {
            let ingredient = IngredientParser.parse(line, sortOrder: index)
            ingredient.recipe = recipe
            context.insert(ingredient)
        }
        // Kept verbatim so a misheard quantity is visible before it is saved.
        recipe.sourceTranscript = summary(hit, costed)
        try? context.save()
        dismiss()
    }

    private func summary(_ hit: ImportedRecipe, _ costed: CostingResult) -> String {
        guard !costed.unpriced.isEmpty else {
            return "Imported from TheMealDB. Every ingredient was costed."
        }
        return "Imported from TheMealDB. \(costed.unpriced.count) of \(hit.ingredients.count) "
             + "ingredients could not be weighed automatically, so the macros are short:\n"
             + costed.unpriced.joined(separator: "\n")
    }
}
