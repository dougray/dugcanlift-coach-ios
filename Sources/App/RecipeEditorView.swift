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
    var isNew: Bool = false
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var nameText = ""
    @State private var servingsText = ""
    @State private var ingredientText = ""
    @State private var stepText = ""
    @State private var macros = MacroFields()
    @State private var tally = MacroTally()

    @State private var query = ""
    @State private var matches: [FoodRecord] = []
    @State private var searchNote = ""
    @State private var amounts: [String: String] = [:]

    /// Total finished weight of the dish, in whichever unit the coach prefers.
    /// Stored canonically as grams on `Recipe.totalWeightGrams`; this is the
    /// display value only.
    @State private var totalWeightText = ""

    /// The coach's own preference, not a client's. Grams or ounces -- never a
    /// volume, because a cup of oil and a cup of flour are not the same mass
    /// and `IngredientParser` refuses to pretend otherwise.
    @AppStorage("recipeWeightUnit") private var weightUnitRaw = ServingUnit.grams.rawValue
    private var weightUnit: ServingUnit { ServingUnit(rawValue: weightUnitRaw) ?? .grams }

    /// The unit `totalWeightText` is currently written in.
    ///
    /// Needed because the text is a display value and the picker can change
    /// underneath it. Without this, switching grams to ounces relabelled 1200 g
    /// as 1200 oz -- the number stayed put and the dish got 28 times heavier,
    /// which is exactly the silent unit error `ClientDisplay` exists to stop on
    /// the bodyweight side.
    @State private var displayedUnit: ServingUnit = .grams

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Labelled rows, not placeholders. A placeholder vanishes
                    // once the field has a value, which left the top of this
                    // form reading as an untitled name and a bare number.
                    LabeledContent("Name") {
                        TextField("Beef chilli", text: $nameText)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Servings") {
                        TextField("4", text: $servingsText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: servingsText) { retally() }
                    }
                }

                Section {
                    Picker("Weigh in", selection: $weightUnitRaw) {
                        Text("Grams").tag(ServingUnit.grams.rawValue)
                        Text("Ounces").tag(ServingUnit.ounces.rawValue)
                    }
                    .onChange(of: weightUnitRaw) { reweigh() }
                    LabeledContent("Total weight") {
                        HStack(spacing: 4) {
                            TextField("—", text: $totalWeightText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text(weightUnit.abbreviation)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    if let each = perServingWeight {
                        Text(each).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                } header: {
                    Text("Weight")
                } footer: {
                    Text("The whole finished dish. Optional — a recipe without it plans by "
                         + "servings as before. With it, a serving has a weight a client can "
                         + "put on a scale, which a count never gives them.")
                        .font(.caption)
                }

                Section("Ingredients") {
                    TextEditor(text: $ingredientText).frame(minHeight: 120)
                    Text("One per line, as you'd write them — \"500 g lean beef mince\".")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                ingredientSearch

                Section("Macros, per serving") {
                    macroField("Calories", unit: "kcal", text: $macros.calories, field: .calories)
                    macroField("Protein", unit: "g", text: $macros.protein, field: .protein)
                    macroField("Carbs", unit: "g", text: $macros.carbs, field: .carbs)
                    macroField("Fat", unit: "g", text: $macros.fat, field: .fat)
                    macroField("Fibre", unit: "g", text: $macros.fiber, field: .fiber)
                    macroField("Saturated fat", unit: "g", text: $macros.saturatedFat, field: .saturatedFat)
                    macroField("Sugar", unit: "g", text: $macros.sugar, field: .sugar)
                    macroField("Sodium", unit: "mg", text: $macros.sodium, field: .sodium)
                    if recipe.nutritionIsEstimated {
                        Text("Estimated from an import — check these before sending.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        if let transcript = recipe.sourceTranscript {
                            Text(transcript)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancel() } }
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

    /// A labelled macro row: name on the left, value and unit on the right.
    ///
    /// The label is a `Text`, not the `TextField`'s placeholder. A placeholder
    /// disappears the moment the field has a value, so the macro section read
    /// as a column of bare numbers -- 352, 25, 63, 1, 11 -- exactly when it
    /// mattered most, with nothing to say which was protein and which was
    /// fibre. A coach sends these to a client to eat against; an unlabelled
    /// number is worse than a blank one.
    ///
    /// The unit is shown too, because "Calories" and the four gram figures are
    /// not in the same units and a column of numbers does not say so.
    private func macroField(_ label: String,
                            unit: String,
                            text: Binding<String>,
                            field: MacroFields.Field) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 12)
            TextField("—", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Theme.textPrimary)
                // A field the coach edits stops being ours to fill in -- but
                // onChange also fires on applyComputed's own write, so
                // `userEdited` (not `markTyped`) tells the two apart.
                .onChange(of: text.wrappedValue) { macros.userEdited(field, to: text.wrappedValue) }
            Text(unit)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 34, alignment: .leading)
        }
    }

    // MARK: - Lookup

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { matches = []; searchNote = ""; return }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }

        let found: [FoodRecord]
        if Self.looksLikeBarcode(trimmed) {
            found = (try? await ReferenceDatabase.shared.food(barcode: trimmed)).map { [$0] } ?? []
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
        // Staged, like servings/ingredients/steps -- CookView inserts a new
        // recipe into the context BEFORE presenting this sheet (autosave
        // persists it), so binding straight to `recipe.name` would mutate
        // the model live on every keystroke and Cancel would not cancel.
        nameText = recipe.name
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
        // Canonical grams on the model, converted for display only -- the same
        // "convert at the view layer and nowhere else" rule `ClientDisplay`
        // follows for a client's bodyweight.
        totalWeightText = recipe.totalWeightGrams
            .map { OptionalNumberField.string(from: (weightUnit.fromGrams($0) * 10).rounded() / 10) } ?? ""
        displayedUnit = weightUnit
    }

    /// Rewrites the displayed weight into the newly chosen unit.
    ///
    /// Converts through grams rather than editing the string, so the dish keeps
    /// the mass the coach entered and only its spelling changes.
    private func reweigh() {
        defer { displayedUnit = weightUnit }
        guard let shown = OptionalNumberField.value(from: totalWeightText), shown > 0 else { return }
        let grams = displayedUnit.toGrams(shown)
        let converted = weightUnit.fromGrams(grams)
        totalWeightText = OptionalNumberField.string(from: (converted * 10).rounded() / 10)
    }

    /// "4 servings · 250 g each", when both numbers are known.
    ///
    /// The point of the weight field: a count tells a client how many portions
    /// exist, not how much to put on a scale.
    private var perServingWeight: String? {
        guard let entered = OptionalNumberField.value(from: totalWeightText), entered > 0,
              let count = OptionalNumberField.value(from: servingsText), count > 0
        else { return nil }
        let each = entered / count
        return "\(CookFormat.servingsLabel(count)) · "
            + "\(CookFormat.trimmed((each * 10).rounded() / 10)) \(weightUnit.abbreviation) each"
    }

    private func save() {
        let trimmedName = nameText.trimmingCharacters(in: .whitespaces)
        // Done on a new recipe with an empty name is treated as Cancel: there
        // is nothing here worth keeping, and an untitled phantom recipe is
        // exactly the failure this fix exists to prevent.
        if isNew, trimmedName.isEmpty {
            Self.discard(recipe, in: context, isNew: true)
            dismiss()
            return
        }
        recipe.name = trimmedName
        recipe.servings = servings
        recipe.steps = lines(stepText)
        recipe.nutritionPerServing = macros.entered()
        // Blank or unparseable stays nil: a recipe without a total weight keeps
        // planning by servings exactly as before. Stored as grams whatever the
        // coach typed in, so a converted value never reaches the model.
        recipe.totalWeightGrams = OptionalNumberField.value(from: totalWeightText)
            .flatMap { $0 > 0 ? weightUnit.toGrams($0) : nil }

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

    private func cancel() {
        Self.discard(recipe, in: context, isNew: isNew)
        dismiss()
    }

    /// A new recipe was inserted into the context before this sheet was
    /// presented (so autosave persists it), and every field here is staged
    /// in `@State` rather than bound live -- so Cancel on an existing recipe
    /// is just a dismiss (nothing live-bound remains to have mutated), and
    /// Cancel on a new one must actually remove the phantom row, or it shows
    /// up in every Plan menu and every "Send recipes" link forever.
    ///
    /// A static function, not inline in `cancel()`, so `CookModelsTests` can
    /// pin both branches against an in-memory context without standing up a
    /// live view instance.
    static func discard(_ recipe: Recipe, in context: ModelContext, isNew: Bool) {
        guard isNew else { return }
        context.delete(recipe)
        try? context.save()
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
