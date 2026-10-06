import SwiftUI
import SwiftData
import LiftCore

/// Review a recipe Safari handed over, then cost whatever the page did not
/// price. The page was never fetched by Coach: Safari's `RecipePage.js` passed
/// its JSON-LD to the share extension, which queued the raw block
/// (`PendingRecipeImports`), and this re-reads it with `LiftCore`'s
/// `RecipeJSONLD` -- the same labels a fetch used to read.
///
/// Where it differs from LIFT's copy: a coach sends these to clients, so a
/// macro figure has to say where it came from. A page that publishes its own
/// nutrition is taken at its word and flagged as an estimate; one that
/// publishes none is costed against the reference database, and the
/// transcript says how much of the dish that costing covered.
struct RecipeLinkImportView: View {

    let item: PendingRecipeImports.Item

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var found: ImportedRecipe?
    @State private var servings: Double = 1
    @State private var pageDidNotStateServings = false
    @State private var note = ""
    @State private var busy = false

    private var sourceURL: URL? { URL(string: item.pageURL) }

    var body: some View {
        NavigationStack {
            Form {
                if let found {
                    review(found, sourceURL)
                } else {
                    Section {
                        Text("This recipe couldn't be read. Share the page from Safari again, or use Paste the text.")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .navigationTitle("Import from Safari")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let found {
                        Button("Save") { Task { await take(found, sourceURL) } }
                            .disabled(busy)
                    }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard found == nil, let imported = RecipeJSONLD.recipe(fromJSON: item.block) else { return }
        servings = imported.servings ?? 1
        pageDidNotStateServings = imported.servings == nil
        found = imported
    }

    // MARK: - Review

    @ViewBuilder
    private func review(_ imported: ImportedRecipe, _ url: URL?) -> some View {
        Section("Recipe") {
            Text(imported.name).foregroundStyle(Theme.textPrimary)
            if let author = imported.author {
                Text("By \(author)").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Stepper(value: $servings, in: 1...48, step: 1) {
                Text(CookFormat.servingsLabel(servings)).foregroundStyle(Theme.textPrimary)
            }
            if pageDidNotStateServings {
                // A guessed yield silently divides every macro by a number
                // nobody chose.
                Text("The page didn't say how many this serves. Set it before saving.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }

        Section("Ingredients (\(imported.ingredientLines.count))") {
            ForEach(Array(imported.ingredientLines.enumerated()), id: \.offset) { index, line in
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

        if !imported.steps.isEmpty {
            Section("Method (\(imported.steps.count))") {
                ForEach(Array(imported.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)")
                        .font(.caption)
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }

        Section("Macros") {
            if let nutrition = imported.nutritionPerServing {
                Text("\(Int(nutrition.calories)) kcal · P \(Int(nutrition.proteinG)) · C \(Int(nutrition.carbsG)) · F \(Int(nutrition.fatG))")
                    .foregroundStyle(Theme.textPrimary)
                Text("Per serving, as the site states them. Not resolved against the food database, so they save as an estimate.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("The page published none. The ingredients will be costed against the food database on save, and the recipe will record how much of the dish that covered.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }

        Section("Source") {
            if let url {
                // Safari can hand over any scheme; only a web address is
                // offered as a link, and anything else is shown as text.
                if ["http", "https"].contains(url.scheme?.lowercased()) {
                    Link(url.absoluteString, destination: url).font(.caption).tint(Theme.accent)
                } else {
                    Text(url.absoluteString).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            if !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: - Save

    /// Writes the reviewed import, costing the ingredients when the page gave
    /// no macros of its own.
    ///
    /// `busy` guards the whole await because a second tap during a slow costing
    /// pass would insert the recipe twice.
    private func take(_ imported: ImportedRecipe, _ url: URL?) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        var reviewed = imported
        reviewed.servings = servings

        let (recipe, ingredients) = reviewed.makeRecipe(sourceURL: url)
        context.insert(recipe)
        for ingredient in ingredients {
            ingredient.recipe = recipe
            context.insert(ingredient)
        }

        var costed: CostingResult?
        if LinkImportMacros.needsCosting(imported) {
            note = "Costing the ingredients\u{2026}"
            costed = await RecipeCosting.cost(lines: imported.ingredientLines,
                                              lookup: RecipeCosting.databaseLookup)
        }

        // The decision itself lives in `LinkImportMacros`, not here: it
        // decides whether a number reaches a client's day total, and a rule
        // in a view's `@State` cannot be tested.
        let outcome = LinkImportMacros.resolve(imported: imported,
                                               servings: servings,
                                               costed: costed)
        recipe.nutritionPerServing = outcome.nutritionPerServing
        recipe.nutritionIsEstimated = outcome.isEstimated
        recipe.sourceTranscript = outcome.transcript

        try? context.save()
        dismiss()
    }
}
