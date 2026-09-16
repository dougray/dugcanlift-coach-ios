import SwiftUI
import SwiftData
import LiftCore

/// Import a recipe from a link, then cost whatever the page did not price.
///
/// The sibling of `RecipeImportView`, which searches TheMealDB by name. This
/// one takes an address: most recipe sites publish their ingredients and
/// method as schema.org JSON-LD for Google's rich results, and `LiftCore`'s
/// `RecipeJSONLD` reads those labels rather than scraping a layout.
///
/// Where it differs from LIFT's copy of this screen: a coach sends these to
/// clients, so a macro figure has to say where it came from. A page that
/// publishes its own nutrition is taken at its word and flagged as an
/// estimate. A page that publishes none is costed here against the reference
/// database, and the transcript says how much of the dish that costing
/// actually covered — the rule `RecipeImportView.summary` already follows,
/// because macros built from three of seventeen ingredients are worse than
/// useless if they look whole.
struct RecipeLinkImportView: View {

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var found: ImportedRecipe?
    @State private var sourceURL: URL?
    @State private var servings: Double = 1
    @State private var pageDidNotStateServings = false
    @State private var note = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                if let found, let sourceURL {
                    review(found, sourceURL)
                } else {
                    entry
                }
            }
            .navigationTitle("Import from a link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let found, let sourceURL {
                        Button("Save") { Task { await take(found, sourceURL) } }
                            .disabled(busy)
                    }
                }
            }
        }
    }

    // MARK: - Entry

    private var entry: some View {
        Section {
            HStack {
                TextField("Recipe address", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { Task { await fetch() } }
                Button("Fetch") { Task { await fetch() } }
                    .tint(Theme.accent)
                    .disabled(busy || normalisedURL == nil)
            }
            if !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        } footer: {
            Text("Uses the internet, like importing a dish. Nothing is saved until you have "
                 + "read what the page published — check the macros before you send it to anyone.")
                .font(.caption)
        }
    }

    // MARK: - Review

    @ViewBuilder
    private func review(_ imported: ImportedRecipe, _ url: URL) -> some View {
        Section("Recipe") {
            Text(imported.name).foregroundStyle(Theme.textPrimary)
            if let author = imported.author {
                Text("By \(author)").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Stepper(value: $servings, in: 1...48, step: 1) {
                Text(CookFormat.servingsLabel(servings)).foregroundStyle(Theme.textPrimary)
            }
            if pageDidNotStateServings {
                // Same rule `take(_:)` follows for TheMealDB: a guessed yield
                // silently divides every macro by a number nobody chose.
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
            Text(url.absoluteString).font(.caption).foregroundStyle(Theme.textSecondary)
            if !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: - Fetch

    private var normalisedURL: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), let host = url.host(), host.contains(".") else { return nil }
        return url
    }

    private func fetch() async {
        guard let url = normalisedURL else { return }
        busy = true
        defer { busy = false }
        note = "Reading the page…"

        do {
            var request = URLRequest(url: url)
            // Names Coach rather than impersonating a browser, the same as
            // `MealDBClient`. A site that refuses it produces an honest error.
            request.setValue("Coach (recipe import)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                note = "The site answered with \(http.statusCode)."
                return
            }
            guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
                note = "That page wasn't readable as text."
                return
            }
            guard let imported = RecipeJSONLD.recipe(fromHTML: html) else {
                note = "That page doesn't publish a recipe in a form this can read. A recipe card usually works where a blog post often doesn't — you can still write it by hand."
                return
            }
            servings = imported.servings ?? 1
            pageDidNotStateServings = imported.servings == nil
            sourceURL = url
            found = imported
            note = ""
        } catch {
            note = "Could not reach that page. Check your connection, or write the recipe by hand."
        }
    }

    // MARK: - Save

    /// Writes the reviewed import, costing the ingredients when the page gave
    /// no macros of its own.
    ///
    /// `busy` guards the whole await for the same reason `RecipeImportView`'s
    /// `take(_:)` does: a second tap during a slow costing pass would insert
    /// the recipe twice.
    private func take(_ imported: ImportedRecipe, _ url: URL) async {
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
