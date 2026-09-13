import SwiftUI
import SwiftData
import LiftCore
import LiftReference

/// Edits one recipe. Ingredients come from the bundled food database, searched
/// offline -- the same rows a client's LIFT app logs from, so a coach costing
/// a recipe and a client eating it read identical numbers.
///
/// The PWA splits this into two sources, "Ingredients" (bundled USDA) and
/// "Packaged & barcodes" (Open Food Facts, over the network). `food.db`
/// carries both, barcodes included, offline -- so there is one field here, and
/// a query that looks like a barcode is tried as one.
struct RecipeEditorView: View {
    @Bindable var recipe: Recipe
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var servingsText = ""
    @State private var ingredientText = ""
    @State private var stepText = ""
    @State private var macros = MacroFields()
    @State private var tally = MacroTally()

    @State private var query = ""
    @State private var matches: [FoodRecord] = []
    @State private var searchNote = ""
    @State private var amounts: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $recipe.name)
                    TextField("Servings", text: $servingsText)
                        .keyboardType(.decimalPad)
                        .onChange(of: servingsText) { retally() }
                }

                Section("Ingredients") {
                    TextEditor(text: $ingredientText).frame(minHeight: 120)
                    Text("One per line, as you'd write them — \"500 g lean beef mince\".")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                ingredientSearch

                Section("Macros, per serving") {
                    macroField("Calories", text: $macros.calories, field: .calories)
                    macroField("Protein (g)", text: $macros.protein, field: .protein)
                    macroField("Carbs (g)", text: $macros.carbs, field: .carbs)
                    macroField("Fat (g)", text: $macros.fat, field: .fat)
                    if !tallyNote.isEmpty {
                        Text(tallyNote).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Text("Leave these blank if you don't know them. A blank travels as "
                         + "\"unknown\"; a zero would log as a zero-calorie meal.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Section("Method") {
                    TextEditor(text: $stepText).frame(minHeight: 100)
                }
            }
            .navigationTitle("Recipe")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { save() } }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear(perform: load)
        }
    }

    private var ingredientSearch: some View {
        Section("Look one up") {
            TextField("Chicken breast, oats, or a barcode", text: $query)
                .autocorrectionDisabled()
                // `.task(id:)` cancels the previous search when the query
                // changes, so a slower earlier keystroke cannot land after a
                // faster later one. The sleep debounces a burst of typing.
                .task(id: query) { await search() }

            ForEach(matches, id: \.id) { record in
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.name).foregroundStyle(Theme.textPrimary)
                    Text("\(CookFormat.trimmed(record.caloriesPer100g.rounded())) kcal per 100 g"
                         + " · P \(CookFormat.trimmed(record.proteinPer100g.rounded()))"
                         + " C \(CookFormat.trimmed(record.carbsPer100g.rounded()))"
                         + " F \(CookFormat.trimmed(record.fatPer100g.rounded()))")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    HStack {
                        TextField("Grams", text: Binding(
                            get: { amounts[record.id] ?? "100" },
                            set: { amounts[record.id] = $0 }))
                            .keyboardType(.decimalPad)
                        Button("Add") { add(record) }
                            .tint(Theme.accent)
                    }
                }
            }

            if !searchNote.isEmpty {
                Text(searchNote).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func macroField(_ label: String, text: Binding<String>, field: MacroFields.Field) -> some View {
        TextField(label, text: text)
            .keyboardType(.decimalPad)
            // A field the coach edits stops being ours to fill in.
            .onChange(of: text.wrappedValue) { macros.markTyped(field) }
    }

    // MARK: - Lookup

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { matches = []; searchNote = ""; return }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }

        let found: [FoodRecord]
        if Self.looksLikeBarcode(trimmed) {
            found = (try? await ReferenceDatabase.shared.food(barcode: trimmed)).flatMap { $0.map { [$0] } } ?? []
        } else {
            found = (try? await ReferenceDatabase.shared.searchFoods(trimmed, limit: 12)) ?? []
        }
        guard !Task.isCancelled else { return }
        matches = found
        searchNote = found.isEmpty ? "Nothing found for that." : ""
    }

    /// Barcodes are recognised by shape rather than by a source toggle, which
    /// is what lets one field serve both jobs. Same test the PWA's proxy path
    /// uses: 8 to 14 digits.
    static func looksLikeBarcode(_ query: String) -> Bool {
        query.count >= 8 && query.count <= 14 && query.allSatisfy(\.isNumber)
    }

    /// The ingredient line a pick writes — and it must survive this app's own
    /// parser, because that is what the shopping list aggregates on.
    static func ingredientLine(for record: FoodRecord, grams: Double) -> String {
        "\(CookFormat.trimmed(grams)) g \(record.name)"
    }

    static func contribution(of record: FoodRecord, grams: Double) -> NutritionFacts {
        record.nutrition(grams: grams)
    }

    private func add(_ record: FoodRecord) {
        guard let grams = OptionalNumberField.value(from: amounts[record.id] ?? "100"),
              grams > 0 else { return }
        let line = Self.ingredientLine(for: record, grams: grams)
        ingredientText = ingredientText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? line
            : ingredientText.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + line
        tally.add(Self.contribution(of: record, grams: grams))
        retally()
        query = ""
        matches = []
    }

    private func retally() {
        guard tally.lines > 0 else { return }
        macros.applyComputed(tally.perServing(servings))
    }

    private var tallyNote: String {
        guard tally.lines > 0 else { return "" }
        let total = CookFormat.trimmed(tally.total.calories.rounded())
        let each = CookFormat.trimmed(tally.perServing(servings).calories.rounded())
        return "\(tally.lines) looked-up ingredient\(tally.lines == 1 ? "" : "s") · "
             + "\(total) kcal for the whole recipe, \(each) a serving."
    }

    private var servings: Double {
        let entered = OptionalNumberField.value(from: servingsText) ?? 1
        return (entered.isFinite && entered > 0) ? entered : 0.0001
    }

    // MARK: - Load and save

    private func load() {
        // OptionalNumberField, NOT CookFormat.trimmed: this text is parsed
        // back by `servings` above, through OptionalNumberField's locale-aware
        // parser, and the two must be exact inverses. See the correction note
        // at the top of the task brief.
        servingsText = OptionalNumberField.string(from: recipe.servings)
        ingredientText = (recipe.ingredients ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.rawText)
            .joined(separator: "\n")
        stepText = recipe.steps.joined(separator: "\n")
        macros.loadExisting(recipe.nutritionPerServing)
    }

    private func save() {
        recipe.name = recipe.name.trimmingCharacters(in: .whitespaces)
        recipe.servings = servings
        recipe.steps = lines(stepText)
        recipe.nutritionPerServing = macros.entered()

        // Replace rather than diff. Ingredients have no identity the user can
        // see -- they typed a block of text -- so matching old rows to new
        // lines would be guesswork. Same rule as LIFT's own editor.
        for existing in recipe.ingredients ?? [] { context.delete(existing) }
        recipe.ingredients = []
        for (index, raw) in lines(ingredientText).enumerated() {
            let parsed = IngredientParser.parse(raw, sortOrder: index)
            parsed.recipe = recipe
            context.insert(parsed)
        }

        try? context.save()
        dismiss()
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
