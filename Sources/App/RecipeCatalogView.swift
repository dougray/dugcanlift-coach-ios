import SwiftUI
import SwiftData
import LiftCore
import LiftReference

/// Browse the bundled recipe catalogue and copy one into the library.
///
/// One of the import sources, beside Safari and pasted text. None of the three
/// needs a network; this one reads the 622 recipes that ship in `recipes.db`.
///
/// What it shows follows `CatalogDisplay`, the rules every LIFT and Coach
/// build that ships the catalogue holds: the whole list with no search typed,
/// whole numbers rounded, and a servings count asked for whenever the source
/// states no yield.
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
    @State private var servings: Double = CatalogDisplay.defaultServings
    @State private var note = ""
    @State private var credits: [String] = []

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    if let selected {
                        detail(selected)
                    } else {
                        list
                    }
                }
                .onChange(of: selected?.id) { old, new in
                    reposition(proxy, from: old, to: new)
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
            Text(CatalogDisplay.listSummary(recipe) + " · \(entry.ingredientLines.count) ingredients")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private func detail(_ entry: CatalogEntry) -> some View {
        let recipe = entry.recipe

        Section("Recipe") {
            Text(recipe.name).foregroundStyle(Theme.textPrimary)
                .id(Self.detailTop)
            if let summary = recipe.summary {
                Text(summary).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if CatalogDisplay.asksForServings(recipe) {
                Stepper(value: $servings, in: 1...48, step: 1) {
                    Text(CookFormat.servingsLabel(servings)).foregroundStyle(Theme.textPrimary)
                }
                Text(CatalogDisplay.servingsNote(recipe))
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
                Text(CatalogDisplay.macroLine(facts))
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

    private static let detailTop = "catalogue-detail-top"

    /// Opening a recipe starts it at its top, and Back returns to the row it
    /// was opened from. The list and the detail share one scroll view, so
    /// without this a recipe opened from far down the whole catalogue opened
    /// scrolled past its own name and stepper, and Back landed at a random row.
    private func reposition(_ proxy: ScrollViewProxy, from old: String?, to new: String?) {
        Task { @MainActor in
            if new != nil {
                proxy.scrollTo(Self.detailTop, anchor: .top)
            } else if let old {
                proxy.scrollTo(old, anchor: .center)
            }
        }
    }

    private func open(_ entry: CatalogEntry) {
        servings = CatalogDisplay.startingServings(entry.recipe)
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
                : try await ReferenceDatabase.shared.browseRecipes(limit: CatalogDisplay.browseLimit)
            guard !Task.isCancelled else { return }
            entries = found
            note = found.isEmpty && trimmed.count >= 2 ? "Nothing matches that." : ""
        } catch {
            entries = []
            note = "The recipe catalogue could not be opened."
        }
    }

    /// Copies the entry into the library, inserting the recipe and each
    /// ingredient before wiring the relationship, so each is already in the
    /// store when it is attached.
    private func add(_ entry: CatalogEntry) {
        let (recipe, ingredients) = entry.makeRecipe(
            servings: CatalogDisplay.servingsToSave(entry.recipe, chosen: servings))
        context.insert(recipe)
        for ingredient in ingredients {
            ingredient.recipe = recipe
            context.insert(ingredient)
        }
        try? context.save()
        dismiss()
    }
}
