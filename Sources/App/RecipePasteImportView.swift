import SwiftUI
import SwiftData
import LiftCore

/// Import a recipe by pasting the text of one — a social caption, an email, a
/// card retyped.
///
/// The fourth import, and the only one that reads prose. `RecipeLinkImportView`
/// can be a *review* screen because JSON-LD is labelled: the publisher already
/// said which strings are ingredients. A caption is not labelled, so this is an
/// **editor**. `LiftCore.CaptionRecipe` proposes a split and the coach corrects
/// it before anything is saved.
///
/// That is the whole safety argument for the screen. A wrong split costs an
/// edit, never a number: quantities are still `IngredientParser`'s job, on
/// save, from the text finally approved here.
///
/// Two plain text boxes rather than a per-line Ingredient/Step picker. The
/// picker is a day of UI to solve what cut-and-paste solves, and the boxes
/// match the rule `WebLibraryImporter` already follows — the raw text is the
/// contract, and reparsing it on save is how that stays true.
///
/// Macros work exactly as they do for a page that published none: nothing is
/// stated, so `LinkImportMacros` costs the ingredients and records how much of
/// the dish that covered. The rule needed no change to accept this source.
///
/// **What a coach sends on is someone else's writing.** A creator's method is
/// their prose, and `PlanLinkEncoder.planRecipe` has no field to say whose —
/// the same wire-format gap `RecipeCatalogView` records for CC BY-SA. Adding a
/// pasted recipe to the library is unaffected; sending one onward is the open
/// question.
struct RecipePasteImportView: View {

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var pasted = ""
    @State private var parsed: ParsedCaption?

    @State private var name = ""
    @State private var ingredientsText = ""
    @State private var methodText = ""
    @State private var servings: Double = 1
    @State private var yieldWasStated = false

    @State private var note = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                if parsed == nil { entry } else { editor }
            }
            .navigationTitle(parsed == nil ? "Paste a recipe" : "Check it over")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if parsed != nil {
                        Button("Save") { Task { await save() } }
                            .disabled(busy || !canSave)
                    }
                }
            }
        }
    }

    // MARK: - Entry

    private var entry: some View {
        Section {
            TextEditor(text: $pasted)
                .frame(minHeight: 180)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)

            // `PasteButton`, not a plain Button reading `UIPasteboard.general`.
            // Reading the pasteboard in code raises iOS's "Allow Paste?" alert
            // every single time; tapping the system button *is* the consent,
            // so the coach gets one tap instead of two and no alert at all.
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first, !text.isEmpty else { return }
                pasted = text
            }
            .labelStyle(.titleAndIcon)
            .tint(Theme.accent)

            Button("Read it") { read() }
                .tint(Theme.accent)
                .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        } footer: {
            // Says plainly where this works, because the link importer is the
            // better tool whenever a page has a recipe card and the coach
            // should not paste a URL in here and wonder why it read as one
            // ingredient.
            Text("For a recipe written out as text — a video caption, an email, a "
                 + "handwritten card. No connection needed. For a recipe website, "
                 + "\"From a link\" reads the page properly.")
                .font(.caption)
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        Section("Recipe") {
            TextField("Name", text: $name)
                .foregroundStyle(Theme.textPrimary)
            Stepper(value: $servings, in: 1...48, step: 1) {
                Text(CookFormat.servingsLabel(servings)).foregroundStyle(Theme.textPrimary)
            }
            if !yieldWasStated {
                // The same rule the link import and TheMealDB both follow: a
                // guessed yield silently divides every macro by a number
                // nobody chose.
                Text("The text didn't say how many this serves. Set it before saving.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }

        Section {
            TextEditor(text: $ingredientsText)
                .frame(minHeight: 150)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)
        } header: {
            Text("Ingredients (\(ingredientCount))")
        } footer: {
            Text(splitAdvice).font(.caption)
        }

        Section {
            TextEditor(text: $methodText)
                .frame(minHeight: 110)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)
        } header: {
            Text("Method")
        } footer: {
            Text("One step per line. Optional.").font(.caption)
        }

        Section("Macros") {
            Text("The text states none. The ingredients will be costed against the "
                 + "food database on save, and the recipe will record how much of the "
                 + "dish that covered.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }

        Section {
            Button("Start over") { reset() }
                .tint(Theme.accent)
        }
    }

    /// What to say about the split, which is the one thing the coach has to
    /// check and the one thing the parser is honest about not knowing.
    private var splitAdvice: String {
        switch parsed?.split {
        case .labelled:
            return "One per line. Split on the headings in the text — check it read them right."
        case .inferred:
            return "One per line. The text labelled one section and this worked out the "
                 + "rest, so check the division before saving."
        case .unsorted, .none:
            return "One per line. The text had no headings, so everything landed here — "
                 + "cut any method steps out and paste them below."
        }
    }

    private var ingredientCount: Int { CaptionRecipe.lines(from: ingredientsText).count }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ingredientCount > 0
    }

    // MARK: - Reading

    private func read() {
        let found = CaptionRecipe.parse(pasted)
        guard !found.isEmpty else {
            note = "Nothing in that reads as a recipe. Paste the ingredients and steps as text."
            return
        }

        name = found.name ?? ""
        ingredientsText = found.ingredientLines.joined(separator: "\n")
        methodText = found.steps.joined(separator: "\n")
        servings = found.servings ?? 1
        yieldWasStated = found.servings != nil
        note = ""
        parsed = found
    }

    private func reset() {
        parsed = nil
        name = ""
        ingredientsText = ""
        methodText = ""
        servings = 1
        note = ""
    }

    // MARK: - Save

    /// Writes what the coach approved, costing the ingredients as it goes.
    ///
    /// The boxes are reparsed here rather than tracked as arrays while they
    /// were edited: the text is the contract, and reading it back once at the
    /// end is what keeps an edit and a parse from disagreeing.
    ///
    /// `busy` guards the whole await for the reason `RecipeLinkImportView`'s
    /// `take` does — a second tap during a slow costing pass inserts twice.
    private func save() async {
        guard !busy, let parsed else { return }
        busy = true
        defer { busy = false }

        let ingredientLines = CaptionRecipe.lines(from: ingredientsText)
        let steps = CaptionRecipe.lines(from: methodText)
        guard !ingredientLines.isEmpty else { return }

        let imported = parsed.imported(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            ingredientLines: ingredientLines,
            steps: steps,
            servings: servings)

        // No source URL: a caption has no address, and inventing one would put
        // a link in the recipe that goes nowhere.
        let (recipe, ingredients) = imported.makeRecipe(sourceURL: nil)
        context.insert(recipe)
        for ingredient in ingredients {
            ingredient.recipe = recipe
            context.insert(ingredient)
        }

        note = "Costing the ingredients\u{2026}"
        let costed = await RecipeCosting.cost(lines: ingredientLines,
                                             lookup: RecipeCosting.databaseLookup)

        // The same decision the link import makes, unchanged: a pasted recipe
        // states no macros, so this is always the costing branch.
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
