import SwiftUI
import SwiftData
import LiftCore

/// A client's week of meals, and the link that sends it.
///
/// `clientID`/`weekStart`/`shareLink` are owned by `CookView` and passed down
/// as bindings, for the reason spelled out in `TrainPlanView`: @State here
/// would be torn down on every section switch.
struct CookPlanView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Client.name) private var clients: [Client]
    @Query(sort: \Recipe.name) private var recipes: [Recipe]
    @Query private var meals: [PlannedMeal]

    @Binding var clientID: String
    @Binding var weekStart: String
    @Binding var shareLink: String

    /// PlannedMeal has no client field -- it is LiftCore's, shared with LIFT,
    /// where a planned meal belongs to the only person on the device. Coach
    /// plans for several clients, so the booking is keyed by the client whose
    /// week it was placed in. Held here rather than added to the package
    /// model, which would be a schema change for a shipped app.
    @AppStorage("cookPlanOwners") private var ownersData = Data()

    private var days: [String] { PlanWeek(startDayKey: weekStart).days }

    var body: some View {
        // `owners` decodes the AppStorage blob from JSON. Decoded once here
        // and threaded through as a plain value rather than re-decoded by
        // every call to `mine`/`planned`/`usedRecipes` -- `mealRow` alone is
        // invoked 7 days x 4 meal types = 28 times per body evaluation.
        let mapping = owners
        let mineMeals = mine(mapping: mapping)
        let used = usedRecipes(mine: mineMeals)

        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                LiftCard(title: "Client") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Client", selection: $clientID) {
                            Text("Pick a client").tag("")
                            ForEach(clients) { Text($0.name).tag($0.id) }
                        }
                        .tint(Theme.accent)
                        WeekHeader(startDayKey: $weekStart)
                    }
                }

                if recipes.isEmpty {
                    LiftCard(title: "Plan") {
                        Text("Write a recipe first — the plan is built from them.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                ForEach(days, id: \.self) { day in
                    LiftCard(title: "\(CookFormat.dayLabel(dayKey: day)) · \(day)") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(MealType.allCases) { slot in
                                mealRow(day: day, slot: slot, mapping: mapping)
                            }
                        }
                    }
                }

                if !mineMeals.isEmpty {
                    ShareLink(item: shareLink) { Text("Send this week") }
                        .tint(Theme.accent)
                    Text(contentsLabel(mineCount: mineMeals.count))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding()
        }
        .liftScreen()
        .task(id: rebuildKey(mine: mineMeals, used: used)) {
            shareLink = link(mine: mineMeals, used: used)
        }
        .background(Theme.background)
    }

    private func mealRow(day: String, slot: MealType, mapping: [String: String]) -> some View {
        HStack {
            Text(slot.displayName)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            let booked = planned(on: day, slot: slot, mapping: mapping)
            if booked.isEmpty {
                Menu("Add") {
                    ForEach(recipes) { recipe in
                        Button(recipe.name) { book(recipe, on: day, slot: slot) }
                    }
                }
                .tint(Theme.accent)
                .disabled(clientID.isEmpty || recipes.isEmpty)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(booked) { meal in
                        HStack {
                            Text("\(meal.recipeName) · \(CookFormat.servingsLabel(meal.servings))")
                                .font(.caption)
                                .foregroundStyle(Theme.textPrimary)
                            Button("Remove") { remove(meal) }
                                .font(.caption)
                                .tint(Theme.accent)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Ownership

    private var owners: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: ownersData)) ?? [:] }
        nonmutating set { ownersData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    private func planned(on day: String, slot: MealType, mapping: [String: String]) -> [PlannedMeal] {
        meals.filter {
            $0.dayKey == day && $0.mealType == slot
                && mapping[$0.id.uuidString] == clientID
        }
    }

    private func mine(mapping: [String: String]) -> [PlannedMeal] {
        meals.filter {
            days.contains($0.dayKey) && mapping[$0.id.uuidString] == clientID
        }
    }

    private func book(_ recipe: Recipe, on day: String, slot: MealType) {
        guard let date = DayKey.date(from: day) else { return }
        let meal = PlannedMeal(recipe: recipe, mealType: slot, plannedFor: date, servings: 1)
        context.insert(meal)
        var mapping = owners
        mapping[meal.id.uuidString] = clientID
        owners = mapping
        try? context.save()
    }

    private func remove(_ meal: PlannedMeal) {
        var mapping = owners
        mapping.removeValue(forKey: meal.id.uuidString)
        owners = mapping
        context.delete(meal)
        try? context.save()
    }

    // MARK: - Sending

    /// Only the recipes this week actually plans are inlined, which is what
    /// keeps a week inside a link an email client will not mangle.
    private func usedRecipes(mine: [PlannedMeal]) -> [Recipe] {
        recipes.filter { recipe in mine.contains { $0.recipeID == recipe.id } }
    }

    /// Keyed on the content that ends up on the wire, not on counts -- a
    /// rename or a macro edit must rebuild the link. `Inlined` mirrors every
    /// field `PlanLinkEncoder.planRecipe` actually writes to `u`
    /// (calories/protein/carbs/fat/fibre), not just calories -- a coach who
    /// corrects protein with calories unchanged must still rebuild the link.
    /// Same discipline as TrainPlanView's RebuildKey, and for the same bug.
    ///
    /// Internal, and `rebuildKey(clientID:weekStart:coachName:mine:used:)` is
    /// a static function rather than an instance computed property, so
    /// `CookPlanViewRebuildKeyTests` can pin the "protein change moves the
    /// key" behaviour without standing up a live `@Query`/`@Environment`
    /// view instance.
    struct RebuildKey: Equatable {
        let clientID: String
        let weekStart: String
        let coachName: String
        let bookings: [Booking]
        let recipes: [Inlined]

        struct Booking: Equatable { let day: String; let slot: String; let recipeID: UUID; let servings: Double }
        struct Inlined: Equatable {
            let id: UUID, name: String, servings: Double
            let calories: Double?, proteinG: Double?, carbsG: Double?, fatG: Double?, fiberG: Double?
            let ingredients: [String], steps: [String]
        }
    }

    static func rebuildKey(clientID: String, weekStart: String, coachName: String,
                           mine: [PlannedMeal], used: [Recipe]) -> RebuildKey {
        RebuildKey(
            clientID: clientID, weekStart: weekStart, coachName: coachName,
            bookings: mine.map { .init(day: $0.dayKey, slot: $0.mealType.rawValue,
                                       recipeID: $0.recipeID, servings: $0.servings) },
            recipes: used.map { recipe in
                .init(id: recipe.id, name: recipe.name, servings: recipe.servings,
                      calories: recipe.nutritionPerServing?.calories,
                      proteinG: recipe.nutritionPerServing?.proteinG,
                      carbsG: recipe.nutritionPerServing?.carbsG,
                      fatG: recipe.nutritionPerServing?.fatG,
                      fiberG: recipe.nutritionPerServing?.fiberG,
                      ingredients: (recipe.ingredients ?? [])
                          .sorted { $0.sortOrder < $1.sortOrder }.map(\.rawText),
                      steps: recipe.steps)
            })
    }

    private func rebuildKey(mine: [PlannedMeal], used: [Recipe]) -> RebuildKey {
        Self.rebuildKey(clientID: clientID, weekStart: weekStart, coachName: coachName,
                        mine: mine, used: used)
    }

    private var coachName: String {
        PlanLinkEncoder.coachName(UserDefaults.standard.string(forKey: "coachName"))
    }

    private func contentsLabel(mineCount: Int) -> String {
        "\(mineCount) meal\(mineCount == 1 ? "" : "s") this week. "
             + "Nothing in that link goes to a server — it travels in the part of the "
             + "address browsers never send."
    }

    private func link(mine: [PlannedMeal], used: [Recipe]) -> String {
        let fragment = PlanLinkEncoder.fragment(
            recipes: used, meals: mine, lifterID: clientID, coachName: coachName)
        return "https://www.dugcanlift.com/lift/#" + fragment
    }
}
